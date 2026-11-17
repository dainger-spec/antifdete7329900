import OpenVPNLink
/// DNS questions and answers (RFC 1035) as the tunnel's resolver asks them: one question, A or
/// AAAA, recursion desired, EDNS(0) with a 1232-byte payload. Answers are read defensively — they
/// come from the far side of the tunnel: every length is checked, compression pointers may only
/// point backwards and are followed a bounded number of times, and only records that belong to
/// the name asked (directly or through the CNAME chain the answer itself gives) are taken.
public enum DNSMessage {
    public enum RecordType: UInt16, Sendable {
        case a = 1
        case cname = 5
        case aaaa = 28
    }

    /// The question's wire form.
    public static func query(id: UInt16, name: String, type: RecordType) -> [UInt8]? {
        guard let encoded = encode(name: name) else { return nil }
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF),
                              0x01, 0x00, // RD
                              0x00, 0x01, // one question
                              0x00, 0x00, 0x00, 0x00,
                              0x00, 0x01] // one additional: OPT
        bytes += encoded
        bytes += [UInt8(type.rawValue >> 8), UInt8(type.rawValue & 0xFF), 0x00, 0x01]
        // OPT: root name, type 41, payload 1232, no extended flags, no options.
        bytes += [0x00, 0x00, 0x29, 0x04, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        return bytes
    }

    public struct Answer: Equatable, Sendable {
        public enum Outcome: Equatable, Sendable {
            /// Addresses of the type asked (possibly none: the name exists without them).
            case addresses([TunnelAddress], ttl: UInt32)
            /// The name does not exist (NXDOMAIN).
            case noSuchName(ttl: UInt32)
            /// The server failed or refused (SERVFAIL, REFUSED, …): another server may answer.
            case serverFailure(code: UInt8)
        }
        public var id: UInt16
        public var truncated: Bool
        public var outcome: Outcome
    }

    /// Reads an answer to the question (`name`, `type`); nil when the message is not one (not a
    /// response, another question, malformed).
    public static func readAnswer(_ bytes: [UInt8], name: String, type: RecordType) -> Answer? {
        guard bytes.count >= 12 else { return nil }
        let id = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let flags = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        guard flags & 0x8000 != 0 else { return nil } // QR: a response
        guard (flags >> 11) & 0xF == 0 else { return nil } // a standard query's answer
        let truncated = flags & 0x0200 != 0
        let code = UInt8(flags & 0xF)
        let questions = Int(UInt16(bytes[4]) << 8 | UInt16(bytes[5]))
        let answers = Int(UInt16(bytes[6]) << 8 | UInt16(bytes[7]))
        let authorities = Int(UInt16(bytes[8]) << 8 | UInt16(bytes[9]))
        guard questions == 1 else { return nil }
        var offset = 12
        guard let (asked, afterName) = readName(bytes, at: offset), afterName + 4 <= bytes.count else { return nil }
        offset = afterName
        let askedType = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        let askedClass = UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3])
        offset += 4
        guard asked == name.lowercased(), askedType == type.rawValue, askedClass == 1 else { return nil }

        var owners: Set<String> = [asked]
        var found: [TunnelAddress] = []
        var minimumTTL: UInt32 = .max
        var records: [(owner: String, type: UInt16, ttl: UInt32, data: Range<Int>)] = []
        for _ in 0..<(answers + authorities) {
            guard let (owner, afterOwner) = readName(bytes, at: offset), afterOwner + 10 <= bytes.count else { return nil }
            let recordType = UInt16(bytes[afterOwner]) << 8 | UInt16(bytes[afterOwner + 1])
            let recordClass = UInt16(bytes[afterOwner + 2]) << 8 | UInt16(bytes[afterOwner + 3])
            let ttl = UInt32(bytes[afterOwner + 4]) << 24 | UInt32(bytes[afterOwner + 5]) << 16
                | UInt32(bytes[afterOwner + 6]) << 8 | UInt32(bytes[afterOwner + 7])
            let length = Int(UInt16(bytes[afterOwner + 8]) << 8 | UInt16(bytes[afterOwner + 9]))
            let dataStart = afterOwner + 10
            guard dataStart + length <= bytes.count else { return nil }
            if recordClass == 1 { records.append((owner, recordType, ttl, dataStart..<(dataStart + length))) }
            offset = dataStart + length
        }
        let answerRecords = records.prefix(answers)
        // CNAMEs first, in whatever order the server gave them: the chain from the name asked.
        var grew = true
        var rounds = 0
        while grew && rounds < 16 {
            grew = false
            rounds += 1
            for record in answerRecords where record.type == RecordType.cname.rawValue && owners.contains(record.owner) {
                guard let (target, _) = readName(bytes, at: record.data.lowerBound) else { return nil }
                if owners.insert(target).inserted {
                    grew = true
                    minimumTTL = min(minimumTTL, record.ttl)
                }
            }
        }
        for record in answerRecords where record.type == type.rawValue && owners.contains(record.owner) {
            let data = Array(bytes[record.data])
            if let address = TunnelAddress(family: type == .a ? .v4 : .v6, bytes: data) {
                found.append(address)
                minimumTTL = min(minimumTTL, record.ttl)
            }
        }
        switch code {
        case 0:
            // A name without records of this type: the negative answer's lifetime is the SOA's
            // (authority section), or a minute.
            if found.isEmpty {
                let negative = records.dropFirst(answers).first { $0.type == 6 }?.ttl ?? 60
                return Answer(id: id, truncated: truncated, outcome: .addresses([], ttl: negative))
            }
            return Answer(id: id, truncated: truncated, outcome: .addresses(found, ttl: minimumTTL))
        case 3:
            let negative = records.dropFirst(answers).first { $0.type == 6 }?.ttl ?? 60
            return Answer(id: id, truncated: truncated, outcome: .noSuchName(ttl: negative))
        default:
            return Answer(id: id, truncated: truncated, outcome: .serverFailure(code: code))
        }
    }

    // MARK: Names

    static func encode(name: String) -> [UInt8]? {
        guard let normalized = HostName.normalized(Array(name.utf8)) else { return nil }
        var bytes: [UInt8] = []
        for label in normalized.split(separator: ".") {
            let raw = Array(label.utf8)
            bytes.append(UInt8(raw.count))
            bytes += raw
        }
        bytes.append(0)
        return bytes
    }

    /// The name at `offset` in lower case, and where what follows it begins. Pointers may only go
    /// backwards, at most 32 of them; the name may not exceed 255 bytes.
    static func readName(_ bytes: [UInt8], at start: Int) -> (String, Int)? {
        var labels: [String] = []
        var offset = start
        var end: Int?
        var jumps = 0
        var total = 0
        while true {
            guard offset < bytes.count else { return nil }
            let length = Int(bytes[offset])
            if length == 0 {
                if end == nil { end = offset + 1 }
                break
            }
            if length & 0xC0 == 0xC0 {
                guard offset + 1 < bytes.count else { return nil }
                let target = (length & 0x3F) << 8 | Int(bytes[offset + 1])
                guard target < offset, jumps < 32 else { return nil }
                if end == nil { end = offset + 2 }
                jumps += 1
                offset = target
                continue
            }
            guard length & 0xC0 == 0, offset + 1 + length <= bytes.count else { return nil }
            total += length + 1
            guard total <= 255 else { return nil }
            let label = bytes[(offset + 1)..<(offset + 1 + length)]
            labels.append(String(decoding: label, as: UTF8.self).lowercased())
            offset += 1 + length
        }
        return (labels.joined(separator: "."), end!)
    }
}
