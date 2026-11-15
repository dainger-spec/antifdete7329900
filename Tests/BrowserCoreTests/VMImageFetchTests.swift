#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BrowserCore

/// A file server on loopback that speaks HTTP/1.1 ranges as Apple's does — `Range`, `If-Range`
/// against its ETag, 206 with `Content-Range`, 200 for the whole file — and can be told to be
/// worse: no ranges, connections cut short, a refusal, a file replaced. It writes down what it
/// was asked for and how many answers it was sending at once.
final class RangeServer: @unchecked Sendable {
    struct Asked: Equatable {
        var range: String?
        var ifRange: String?
    }

    private let lock = NSLock()
    private var listener: Int32 = -1
    private var stopped = false
    private(set) var port = 0

    private var _body: [UInt8]
    private var _etag: String
    private var _ranges = true
    private var _cuts = 0
    private var _cutAfter = 0
    private var _status: Int?
    private var _asked: [Asked] = []
    private var _servedBytes = 0
    private var _servedFirsts: [Int] = []
    private var _concurrent = 0
    private var _maxConcurrent = 0
    /// Bytes written at a time, and the wait between: answers that take long enough to overlap.
    var piece = 16 << 10
    var pause: useconds_t = 1_500

    init(body: [UInt8], etag: String = "\"v1\"") {
        _body = body
        _etag = etag
    }

    private func locked<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }

    var body: [UInt8] { locked { _body } }
    var asked: [Asked] { locked { _asked } }
    var servedBytes: Int { locked { _servedBytes } }
    /// Where each answer's body began.
    var servedFirsts: [Int] { locked { _servedFirsts } }
    var maxConcurrent: Int { locked { _maxConcurrent } }

    func replace(body: [UInt8], etag: String) { locked { _body = body; _etag = etag } }
    func noRanges() { locked { _ranges = false } }
    func cut(_ count: Int, after bytes: Int) { locked { _cuts = count; _cutAfter = bytes } }
    func answer(_ status: Int?) { locked { _status = status } }

    func start() {
        let descriptor = socket(AF_INET, Self.stream, 0)
        precondition(descriptor >= 0)
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(bound == 0 && listen(descriptor, 64) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        listener = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in
            while !locked({ stopped }) {
                var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                guard poll(&entry, 1, 100) > 0 else { continue }
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { continue }
                #if canImport(Darwin)
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                #endif
                Thread.detachNewThread { [self] in serve(client) }
            }
        }
    }

    func stop() {
        locked { stopped = true }
        if listener >= 0 { close(listener) }
        listener = -1
    }

    #if canImport(Darwin)
    private static let stream = SOCK_STREAM
    private static let sendFlags: Int32 = 0
    #else
    private static let stream = Int32(SOCK_STREAM.rawValue)
    private static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif

    private func serve(_ client: Int32) {
        defer { close(client) }
        var request = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !request.suffix(4).elementsEqual([13, 10, 13, 10]) {
            let got = recv(client, &buffer, buffer.count, 0)
            guard got > 0 else { return }
            request += buffer[0..<got]
            if request.count > 65536 { return }
        }
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        func header(_ name: String) -> String? {
            lines.dropFirst().first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
                .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        let asked = Asked(range: header("Range"), ifRange: header("If-Range"))
        let (body, etag, ranges, status, cutAfter): ([UInt8], String, Bool, Int?, Int?) = locked {
            _asked.append(asked)
            _concurrent += 1
            _maxConcurrent = max(_maxConcurrent, _concurrent)
            var cut: Int?
            if _cuts > 0 {
                _cuts -= 1
                cut = _cutAfter
            }
            return (_body, _etag, _ranges, _status, cut)
        }
        defer { locked { _concurrent -= 1 } }
        if let status {
            send(client, "HTTP/1.1 \(status) No\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        var first = 0, last = body.count - 1, partial = false
        if ranges, let range = asked.range, range.hasPrefix("bytes="), asked.ifRange == nil || asked.ifRange == etag {
            let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 2, let from = Int(parts[0]) {
                guard from < body.count else {
                    send(client, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(body.count)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                    return
                }
                first = from
                last = parts[1].isEmpty ? body.count - 1 : min(Int(parts[1]) ?? body.count - 1, body.count - 1)
                partial = true
            }
        }
        var head = partial ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(first)-\(last)/\(body.count)\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Length: \(last - first + 1)\r\nETag: \(etag)\r\nAccept-Ranges: \(ranges ? "bytes" : "none")\r\nConnection: close\r\n\r\n"
        guard send(client, head) else { return }
        locked { _servedFirsts.append(first) }
        var offset = first
        let end = cutAfter.map { min(last + 1, first + $0) } ?? last + 1
        while offset < end {
            let count = min(piece, end - offset)
            let sent = body[offset..<(offset + count)].withUnsafeBytes { Glue.send(client, $0.baseAddress, count, Self.sendFlags) }
            guard sent > 0 else { return }
            offset += sent
            locked { _servedBytes += sent }
            // Between pieces only: an answer that has sent its last byte is not one at work.
            if offset < end { usleep(pause) }
        }
    }

    @discardableResult
    private func send(_ client: Int32, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBytes { Glue.send(client, $0.baseAddress, bytes.count, Self.sendFlags) } == bytes.count
    }
}

/// The C library's `send`, by a name the server's own `send` does not hide.
private enum Glue {
    static func send(_ socket: Int32, _ bytes: UnsafeRawPointer?, _ count: Int, _ flags: Int32) -> Int {
        #if canImport(Darwin)
        return Darwin.send(socket, bytes, count, flags)
        #else
        return Glibc.send(socket, bytes, count, flags)
        #endif
    }
}

/// The restore image's download over several connections (`VMImageFetch`), against the server
/// above: what comes is the file, byte for byte, however it came.
final class VMImageFetchTests: XCTestCase {
    private var root: URL!
    private var library: VMLibrary!
    private var server: RangeServer!
    private static let chunk: Int64 = 64 << 10

    override func setUpWithError() throws {
        // Nothing between the tests and their server.
        setenv("no_proxy", "127.0.0.1,localhost", 1)
        setenv("NO_PROXY", "127.0.0.1,localhost", 1)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-fetch-\(UUID().uuidString)", isDirectory: true)
        library = VMLibrary(root: root)
    }

    override func tearDown() {
        server?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private static func bytes(_ count: Int, seed: UInt64) -> [UInt8] {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        return (0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        }
    }

    private func serve(_ body: [UInt8], etag: String = "\"v1\"") -> RangeServer {
        let server = RangeServer(body: body, etag: etag)
        server.start()
        self.server = server
        return server
    }

    private func image(_ server: RangeServer) -> VMRestoreImage {
        VMRestoreImage(url: URL(string: "http://127.0.0.1:\(server.port)/UniversalMac.ipsw")!, version: "26.1", build: "25B78")
    }

    private final class Seen: @unchecked Sendable {
        let lock = NSLock()
        var progress: [VMImageFetch.Progress] = []
        var result: Result<Void, Error>?
        var last: VMImageFetch.Progress? { lock.lock(); defer { lock.unlock() }; return progress.last }
    }

    private func fetch(_ server: RangeServer, connections: Int = 4, seen: Seen, done: XCTestExpectation) -> VMImageFetch {
        let fetch = VMImageFetch(library: library, image: image(server), connections: connections, chunkSize: Self.chunk,
                                 configuration: {
                                     let configuration = URLSessionConfiguration.ephemeral
                                     configuration.timeoutIntervalForRequest = 10
                                     configuration.connectionProxyDictionary = [:]
                                     return configuration
                                 },
                                 onProgress: { progress in
                                     seen.lock.lock()
                                     seen.progress.append(progress)
                                     seen.lock.unlock()
                                 },
                                 onFinish: { result in
                                     seen.lock.lock()
                                     seen.result = result
                                     seen.lock.unlock()
                                     done.fulfill()
                                 })
        fetch.acceptsLoopbackHTTP = true
        fetch.start()
        return fetch
    }

    /// Runs a download to its end; its result.
    @discardableResult
    private func run(_ server: RangeServer, connections: Int = 4) -> Result<Void, Error>? {
        let seen = Seen()
        let done = expectation(description: "the download ends")
        let fetch = self.fetch(server, connections: connections, seen: seen, done: done)
        wait(for: [done], timeout: 60)
        _ = fetch
        return seen.result
    }

    private func downloaded() throws -> [UInt8] {
        [UInt8](try Data(contentsOf: library.restoreImageURL))
    }

    // MARK: - Whole

    func testAFileComesWholeOverSeveralConnections() throws {
        let body = Self.bytes(Int(Self.chunk) * 20 + 12_345, seed: 1)
        let server = serve(body)
        let seen = Seen()
        let done = expectation(description: "the download ends")
        let fetch = self.fetch(server, seen: seen, done: done)
        wait(for: [done], timeout: 60)
        _ = fetch
        guard case .success = seen.result else { return XCTFail("\(String(describing: seen.result))") }
        XCTAssertEqual(try downloaded(), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.partialRestoreImageURL.path))
        XCTAssertGreaterThanOrEqual(server.maxConcurrent, 2, "one connection at a time")
        XCTAssertLessThanOrEqual(seen.progress.map(\.connections).max() ?? 0, 4, "more connections than it was given")
        // Every chunk once, and the file's length, no more.
        XCTAssertEqual(server.asked.count, 21)
        XCTAssertEqual(server.servedBytes, body.count)
        // The first asks for the first chunk; every other one under If-Range, with the ETag.
        XCTAssertEqual(server.asked.first?.range, "bytes=0-\(Self.chunk - 1)")
        XCTAssertNil(server.asked.first?.ifRange)
        XCTAssertTrue(server.asked.dropFirst().allSatisfy { $0.ifRange == "\"v1\"" })
        // What the setup shows: the file's length, and all of it.
        XCTAssertEqual(seen.last?.have, Int64(body.count))
        XCTAssertEqual(seen.last?.total, Int64(body.count))
        let state = try XCTUnwrap(library.downloadState())
        XCTAssertEqual(state.chunks?.isComplete, true)
        XCTAssertEqual(state.validator, "\"v1\"")
        XCTAssertEqual(library.setupState(), .downloaded)
    }

    func testAFileSmallerThanAChunk() throws {
        let body = Self.bytes(5_000, seed: 2)
        let server = serve(body)
        guard case .success = run(server) else { return XCTFail() }
        XCTAssertEqual(try downloaded(), body)
        XCTAssertEqual(server.asked.count, 1)
    }

    // MARK: - Going on where it stopped

    func testAPausedDownloadGoesOnWithTheChunksItHas() throws {
        let body = Self.bytes(Int(Self.chunk) * 48, seed: 3)
        let server = serve(body)
        server.pause = 25_000
        let seen = Seen()
        let done = expectation(description: "not ended")
        done.isInverted = true
        let first = fetch(server, seen: seen, done: done)
        // Until a third of it is here.
        let deadline = Date().addingTimeInterval(30)
        while (seen.last?.have ?? 0) < Int64(body.count / 3), Date() < deadline { usleep(20_000) }
        first.pause()
        wait(for: [done], timeout: 1)
        let paused = try XCTUnwrap(library.downloadState()?.chunks)
        XCTAssertGreaterThan(paused.doneBytes, 0)
        XCTAssertFalse(paused.isComplete)
        XCTAssertEqual(VMLibrary.fileSize(library.partialRestoreImageURL), Int64(body.count), "the partial file has the whole length")
        // What the setup shows while it is paused: the chunks that are here, not the file's length.
        XCTAssertEqual(library.setupState(), .downloading(have: paused.doneBytes, of: Int64(body.count)))
        let servedBefore = server.servedBytes
        let firstsBefore = server.servedFirsts.count

        server.pause = 500
        guard case .success = run(server) else { return XCTFail() }
        XCTAssertEqual(try downloaded(), body)
        // Only what was not here was fetched again: the chunks that were done, never.
        let again = server.servedBytes - servedBefore
        XCTAssertLessThanOrEqual(Int64(again), Int64(body.count) - paused.doneBytes)
        let doneFirsts = Set((0..<paused.count).filter(paused.isDone).map { Int(paused.bytes(of: $0).first) })
        let secondFirsts = Set(server.servedFirsts.dropFirst(firstsBefore))
        XCTAssertTrue(doneFirsts.isDisjoint(with: secondFirsts), "a chunk that was here was fetched again")
    }

    /// A download of one stream, from before: the chunks its file holds whole are not fetched again.
    func testADownloadOfOneStreamFromBeforeIsTakenUp() throws {
        let body = Self.bytes(Int(Self.chunk) * 16 + 999, seed: 4)
        let server = serve(body)
        let have = Int(Self.chunk) * 5 + 300
        try SecureFile.ensureDirectory(library.downloadsDirectory)
        try Data(body.prefix(have)).write(to: library.partialRestoreImageURL)
        try library.saveDownloadState(VMDownloadState(image: image(server), expectedLength: Int64(body.count), validator: "\"v1\""))
        XCTAssertEqual(library.setupState(), .downloading(have: Int64(have), of: Int64(body.count)))
        guard case .success = run(server) else { return XCTFail() }
        XCTAssertEqual(try downloaded(), body)
        XCTAssertTrue(server.servedFirsts.allSatisfy { $0 >= Int(Self.chunk) * 5 }, "\(server.servedFirsts)")
        XCTAssertEqual(server.servedBytes, body.count - Int(Self.chunk) * 5)
    }

    /// Apple replaced the file between two runs: the chunks here are another file's, and it starts
    /// over instead of gluing the two together.
    func testAFileThatChangedStartsOver() throws {
        let old = Self.bytes(Int(Self.chunk) * 8, seed: 5)
        let new = Self.bytes(Int(Self.chunk) * 9 + 77, seed: 6)
        let server = serve(old)
        try SecureFile.ensureDirectory(library.downloadsDirectory)
        var partial = old
        partial.replaceSubrange(Int(Self.chunk) * 3..<old.count, with: [UInt8](repeating: 0, count: old.count - Int(Self.chunk) * 3))
        try Data(partial).write(to: library.partialRestoreImageURL)
        try library.saveDownloadState(VMDownloadState(image: image(server), expectedLength: Int64(old.count), validator: "\"v1\"",
                                                      chunks: VMChunkMap(chunkSize: Self.chunk, total: Int64(old.count), done: [[0, 2]])))
        server.replace(body: new, etag: "\"v2\"")
        guard case .success = run(server) else { return XCTFail() }
        XCTAssertEqual(try downloaded(), new)
        XCTAssertEqual(library.downloadState()?.validator, "\"v2\"")
    }

    // MARK: - Worse servers

    func testAServerWithoutRangesGivesOneStream() throws {
        let body = Self.bytes(Int(Self.chunk) * 6 + 5, seed: 7)
        let server = serve(body)
        server.noRanges()
        guard case .success = run(server) else { return XCTFail() }
        XCTAssertEqual(try downloaded(), body)
        XCTAssertEqual(server.maxConcurrent, 1)
        XCTAssertNil(library.downloadState()?.chunks)
    }

    func testConnectionsCutShortAreTakenUpAgain() throws {
        let body = Self.bytes(Int(Self.chunk) * 12, seed: 8)
        let server = serve(body)
        server.cut(5, after: 20_000)
        guard case .success = run(server) else { return XCTFail() }
        XCTAssertEqual(try downloaded(), body)
        XCTAssertGreaterThan(server.asked.count, 12, "a chunk cut short was asked for again")
    }

    func testARefusalIsSaidAndWhatIsHereStays() throws {
        let server = serve(Self.bytes(1000, seed: 9))
        server.answer(404)
        guard case .failure(let error) = run(server) else { return XCTFail("not refused") }
        XCTAssertEqual(error as? VMImageFetch.Failure, .refused(404))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.restoreImageURL.path))
    }

    func testOnlyHTTPSIsFetched() throws {
        let server = serve(Self.bytes(1000, seed: 10))
        let done = expectation(description: "ends")
        let seen = Seen()
        let fetch = VMImageFetch(library: library, image: image(server), onProgress: { _ in }, onFinish: { result in
            seen.result = result
            done.fulfill()
        })
        fetch.start()
        wait(for: [done], timeout: 10)
        guard case .failure(let error) = seen.result else { return XCTFail() }
        XCTAssertEqual(error as? VMImageFetch.Failure, .notFetchable)
        XCTAssertEqual(server.asked.count, 0)
    }
}

/// The chunks of a download, and which are here.
final class VMChunkMapTests: XCTestCase {
    func testChunksTheirBytesAndWhichAreHere() {
        var map = VMChunkMap(chunkSize: 100, total: 1050)
        XCTAssertEqual(map.count, 11)
        XCTAssertEqual(map.bytes(of: 0).first, 0)
        XCTAssertEqual(map.bytes(of: 0).last, 99)
        XCTAssertEqual(map.bytes(of: 10).first, 1000)
        XCTAssertEqual(map.bytes(of: 10).last, 1049)
        XCTAssertEqual(map.missing, Array(0...10))
        for index in [3, 1, 2, 10, 5] { map.markDone(index) }
        XCTAssertEqual(map.done, [[1, 3], [5, 5], [10, 10]])
        XCTAssertEqual(map.missing, [0, 4, 6, 7, 8, 9])
        XCTAssertEqual(map.doneBytes, 300 + 100 + 50)
        map.markDone(4)
        map.markDone(0)
        XCTAssertEqual(map.done, [[0, 5], [10, 10]])
        for index in 6...9 { map.markDone(index) }
        XCTAssertTrue(map.isComplete)
        XCTAssertEqual(map.doneBytes, 1050)
        map.markDone(11)
        map.markDone(-1)
        XCTAssertEqual(map.done, [[0, 10]])
    }

    func testAFileOfOneStreamHoldsItsWholeChunks() {
        XCTAssertEqual(VMChunkMap(chunkSize: 100, total: 1050, contiguous: 0).done, [])
        XCTAssertEqual(VMChunkMap(chunkSize: 100, total: 1050, contiguous: 99).done, [])
        XCTAssertEqual(VMChunkMap(chunkSize: 100, total: 1050, contiguous: 100).done, [[0, 0]])
        XCTAssertEqual(VMChunkMap(chunkSize: 100, total: 1050, contiguous: 555).done, [[0, 4]])
        XCTAssertTrue(VMChunkMap(chunkSize: 100, total: 1050, contiguous: 1050).isComplete)
    }

    func testAStateFromBeforeChunksReadsAsOneStream() throws {
        let old = #"{"image":{"url":"https://updates.example/a.ipsw","version":"26.1","build":"25B78"},"expectedLength":1000,"validator":"\"x\""}"#
        let state = try JSONCoding.decoder.decode(VMDownloadState.self, from: Data(old.utf8))
        XCTAssertNil(state.chunks)
        var chunked = state
        chunked.chunks = VMChunkMap(chunkSize: 100, total: 1000, done: [[0, 3], [7, 7]])
        let again = try JSONCoding.decoder.decode(VMDownloadState.self, from: JSONCoding.encoder.encode(chunked))
        XCTAssertEqual(again, chunked)
        XCTAssertEqual(again.chunks?.doneBytes, 500)
    }

    func testAContentRangeIsRead() {
        XCTAssertEqual(VMDownload.contentRange("bytes 100-999/1000")?.first, 100)
        XCTAssertEqual(VMDownload.contentRange("bytes 100-999/1000")?.last, 999)
        XCTAssertEqual(VMDownload.contentRange("bytes 100-999/1000")?.total, 1000)
        XCTAssertNil(VMDownload.contentRange("bytes 100-999/*")?.total)
        XCTAssertNotNil(VMDownload.contentRange("bytes 100-999/*"))
        XCTAssertNil(VMDownload.contentRange("bytes 999-100/1000"))
        XCTAssertNil(VMDownload.contentRange("items 1-2/3"))
        XCTAssertNil(VMDownload.contentRange(nil))
    }
}
