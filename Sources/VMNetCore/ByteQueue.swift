import Foundation

/// Bytes waiting in order: added at the end, taken from the front. Taking from the front moves a
/// mark instead of the bytes, and the storage is tidied once the taken part is the larger one, so
/// a megabyte that passes through in small pieces costs a megabyte of copying, not its square.
struct ByteQueue {
    private var storage: [UInt8] = []
    private var head = 0

    var count: Int { storage.count - head }
    var isEmpty: Bool { storage.count == head }

    mutating func append(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        storage.append(contentsOf: bytes)
    }

    mutating func append(_ bytes: [UInt8]) {
        storage.append(contentsOf: bytes)
    }

    /// Drops the first `amount` bytes (all of them when there are fewer).
    mutating func removeFirst(_ amount: Int) {
        guard amount > 0 else { return }
        head = min(head + amount, storage.count)
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 4096 && head >= storage.count - head {
            storage.removeSubrange(0..<head)
            head = 0
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: false)
        head = 0
    }

    /// The bytes from `offset`, at most `length` of them, for as long as `body` runs.
    func withBytes<Result>(from offset: Int = 0, length: Int = .max, _ body: (UnsafeRawBufferPointer) -> Result) -> Result {
        storage.withUnsafeBytes { all in
            let start = min(head + max(offset, 0), all.count)
            let end = start + min(max(length, 0), all.count - start)
            return body(UnsafeRawBufferPointer(rebasing: all[start..<end]))
        }
    }

    /// A copy of everything waiting. For tests and small buffers.
    var bytes: [UInt8] { Array(storage[head...]) }
}
