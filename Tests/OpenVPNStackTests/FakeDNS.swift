/// DNS answers made by the tests: the question echoed, and records after it.
enum FakeDNS {
    /// An answer to `query` (one question) holding one A record with `address` for the name asked,
    /// or, for an AAAA question, none.
    static func answer(_ query: [UInt8], with address: [UInt8], ttl: UInt32 = 300) -> [UInt8] {
        guard let (questionEnd, type) = questionEnd(query) else { return [] }
        var response = Array(query[0..<2])
        response += [0x81, 0x80] // QR, RD, RA, NOERROR
        response += [0, 1, 0, type == 1 ? 1 : 0, 0, 0, 0, 0]
        response += query[12..<questionEnd]
        if type == 1 {
            response += [0xC0, 0x0C, 0, 1, 0, 1]
            response += [UInt8(ttl >> 24), UInt8((ttl >> 16) & 0xFF), UInt8((ttl >> 8) & 0xFF), UInt8(ttl & 0xFF)]
            response += [0, 4] + address
        }
        return response
    }

    /// NXDOMAIN for `query`.
    static func noSuchName(_ query: [UInt8]) -> [UInt8] {
        guard let (questionEnd, _) = questionEnd(query) else { return [] }
        return Array(query[0..<2]) + [0x81, 0x83, 0, 1, 0, 0, 0, 0, 0, 0] + query[12..<questionEnd]
    }

    /// Where the question ends, and its type.
    static func questionEnd(_ query: [UInt8]) -> (Int, UInt16)? {
        var offset = 12
        while offset < query.count, query[offset] != 0 { offset += 1 + Int(query[offset]) }
        guard offset + 5 <= query.count else { return nil }
        let type = UInt16(query[offset + 1]) << 8 | UInt16(query[offset + 2])
        return (offset + 5, type)
    }

    /// The name asked in `query`.
    static func name(_ query: [UInt8]) -> String {
        var labels: [String] = []
        var offset = 12
        while offset < query.count, query[offset] != 0 {
            let length = Int(query[offset])
            labels.append(String(decoding: query[(offset + 1)..<min(query.count, offset + 1 + length)], as: UTF8.self))
            offset += 1 + length
        }
        return labels.joined(separator: ".")
    }
}
