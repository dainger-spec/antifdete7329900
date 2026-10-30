import Foundation

/// A ZIP archive of a few files stored as they are, without compression: what a diagnostics bundle
/// needs (Finder, `unzip` and Windows open it), with no dependency — and, being uncompressed, one
/// whose every byte can be searched for what must not be in it (the self-test does).
public enum StoredZip {
    public struct Entry: Equatable, Sendable {
        /// The path inside the archive ("logs/app.txt"): "/"-separated, relative.
        public var path: String
        public var data: Data
        public var modified: Date

        public init(path: String, data: Data, modified: Date = Date()) {
            self.path = path
            self.data = data
            self.modified = modified
        }
    }

    public enum Failure: Error, Equatable {
        /// A path that is empty, absolute, or climbs out with "..".
        case badPath(String)
        /// Over what a ZIP without its 64-bit extension can hold.
        case tooLarge
    }

    /// The archive of `entries`, in their order.
    public static func archive(_ entries: [Entry]) throws -> Data {
        var output = Data()
        var central = Data()
        for entry in entries {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.path.isEmpty, !entry.path.hasPrefix("/"),
                  !components.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else {
                throw Failure.badPath(entry.path)
            }
            let name = Data(entry.path.utf8)
            guard entry.data.count < Int(UInt32.max), output.count < Int(UInt32.max), name.count < Int(UInt16.max),
                  entries.count < Int(UInt16.max) else { throw Failure.tooLarge }
            let crc = crc32(entry.data)
            let (time, date) = dosTime(entry.modified)
            let offset = UInt32(output.count)
            // Local file header; bit 11 of the flags: the name is UTF-8.
            output.append(le32: 0x0403_4b50)
            output.append(le16: 20)
            output.append(le16: 0x0800)
            output.append(le16: 0)
            output.append(le16: time)
            output.append(le16: date)
            output.append(le32: crc)
            output.append(le32: UInt32(entry.data.count))
            output.append(le32: UInt32(entry.data.count))
            output.append(le16: UInt16(name.count))
            output.append(le16: 0)
            output.append(name)
            output.append(entry.data)
            // Its central directory record: made on Unix (3), version 2.0; a regular file, rw-r--r--.
            central.append(le32: 0x0201_4b50)
            central.append(le16: 0x0314)
            central.append(le16: 20)
            central.append(le16: 0x0800)
            central.append(le16: 0)
            central.append(le16: time)
            central.append(le16: date)
            central.append(le32: crc)
            central.append(le32: UInt32(entry.data.count))
            central.append(le32: UInt32(entry.data.count))
            central.append(le16: UInt16(name.count))
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le32: UInt32(0o100644) << 16)
            central.append(le32: offset)
            central.append(name)
        }
        guard output.count + central.count < Int(UInt32.max) else { throw Failure.tooLarge }
        let centralOffset = UInt32(output.count)
        output.append(central)
        // End of the central directory.
        output.append(le32: 0x0605_4b50)
        output.append(le16: 0)
        output.append(le16: 0)
        output.append(le16: UInt16(entries.count))
        output.append(le16: UInt16(entries.count))
        output.append(le32: UInt32(central.count))
        output.append(le32: centralOffset)
        output.append(le16: 0)
        return output
    }

    /// The entries of an archive this type wrote (stored, no extension): the test's and the
    /// self-test's reading of it, not a general ZIP reader.
    public static func entries(of archive: Data) -> [(path: String, data: Data)]? {
        let bytes = [UInt8](archive)
        func le16(_ at: Int) -> Int {
            let low = Int(bytes[at]), high = Int(bytes[at + 1])
            return low | (high << 8)
        }
        func le32(_ at: Int) -> Int {
            let low = le16(at), high = le16(at + 2)
            return low | (high << 16)
        }
        guard bytes.count >= 22 else { return nil }
        let end = bytes.count - 22
        guard le32(end) == 0x0605_4b50 else { return nil }
        let count = le16(end + 10)
        var at = le32(end + 16)
        var result: [(String, Data)] = []
        for _ in 0..<count {
            guard at + 46 <= bytes.count, le32(at) == 0x0201_4b50 else { return nil }
            let size = le32(at + 24), nameLength = le16(at + 28), extra = le16(at + 30), comment = le16(at + 32)
            let local = le32(at + 42)
            guard at + 46 + nameLength <= bytes.count,
                  let name = String(bytes: bytes[(at + 46)..<(at + 46 + nameLength)], encoding: .utf8),
                  local + 30 <= bytes.count, le32(local) == 0x0403_4b50 else { return nil }
            let start = local + 30 + le16(local + 26) + le16(local + 28)
            guard start + size <= bytes.count else { return nil }
            result.append((name, Data(bytes[start..<(start + size)])))
            at += 46 + nameLength + extra + comment
        }
        return result
    }

    /// CRC-32 (IEEE 802.3), as ZIP stores it.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { (index: Int) -> UInt32 in
        let polynomial: UInt32 = 0xEDB8_8320
        var value = UInt32(index)
        for _ in 0..<8 {
            let shifted = value >> 1
            value = value & 1 == 1 ? shifted ^ polynomial : shifted
        }
        return value
    }

    /// MS-DOS time and date, which ZIP stores (local time, two-second steps, from 1980). One step
    /// per line: Swift on Linux gave up type-checking the two in one expression each (CI run 424).
    static func dosTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let years: Int = (parts.year ?? 1980) - 1980
        let year: Int = min(max(years, 0), 127)
        let hour: Int = parts.hour ?? 0
        let minute: Int = parts.minute ?? 0
        let second: Int = parts.second ?? 0
        let month: Int = parts.month ?? 1
        let dayOfMonth: Int = parts.day ?? 1
        let time: Int = (hour << 11) | (minute << 5) | (second / 2)
        let day: Int = (year << 9) | (month << 5) | dayOfMonth
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: day))
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(le32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
