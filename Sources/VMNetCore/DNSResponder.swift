import Foundation

/// The addresses the DNS responder hands out instead of real ones: one from 198.18.0.0/15 (the
/// range set aside for benchmarks, which no host on the internet has) for each name asked. The
/// guest connects to that address, the stack looks the name up again and asks the proxy for the
/// NAME — so the proxy resolves it, and the guest's DNS never leaves this Mac.
///
/// A name keeps its address while the network runs. When more names than `capacity` are known,
/// the one unused the longest is forgotten; its address is given out again only after every other
/// address of the range has been.
struct FakeAddressPool {
    static let network: UInt32 = 0xC612_0000
    static let prefixLength = 15
    /// Addresses ending in .0 and .255 are left out: some stacks will not connect to them.
    static let usableAddresses = 512 * 254

    static func contains(_ address: VMNetIPv4) -> Bool {
        address.isIn(network, prefixLength)
    }

    private struct Slot {
        var name: String
        var address: UInt32
        var newer: Int
        var older: Int
    }

    let capacity: Int
    private var slots: [Slot] = []
    private var slotByName: [String: Int] = [:]
    private var slotByAddress: [UInt32: Int] = [:]
    /// The ends of the list of slots in order of use; -1 when there is none.
    private var newest = -1
    private var oldest = -1
    private var nextFresh = 0
    private var released: [UInt32] = []
    private var releasedHead = 0

    init(capacity: Int = 60_000) {
        self.capacity = min(max(capacity, 1), Self.usableAddresses / 2)
    }

    var count: Int { slots.count }

    /// The address of `name` (already in lower case), given now if it had none.
    mutating func address(for name: String) -> VMNetIPv4 {
        if let slot = slotByName[name] {
            touch(slot)
            return VMNetIPv4(slots[slot].address)
        }
        let slot: Int
        if slots.count < capacity {
            slot = slots.count
            slots.append(Slot(name: name, address: 0, newer: -1, older: -1))
        } else {
            slot = oldest
            unlink(slot)
            slotByName[slots[slot].name] = nil
            slotByAddress[slots[slot].address] = nil
            released.append(slots[slot].address)
            slots[slot].name = name
        }
        let address = nextAddress()
        slots[slot].address = address
        slotByName[name] = slot
        slotByAddress[address] = slot
        linkAsNewest(slot)
        return VMNetIPv4(address)
    }

    /// The name `address` was given for, if it still is.
    mutating func name(for address: VMNetIPv4) -> String? {
        guard let slot = slotByAddress[address.value] else { return nil }
        touch(slot)
        return slots[slot].name
    }

    private mutating func nextAddress() -> UInt32 {
        if nextFresh < Self.usableAddresses {
            let index = nextFresh
            nextFresh += 1
            return Self.network + UInt32(index / 254) * 256 + UInt32(index % 254) + 1
        }
        let address = released[releasedHead]
        releasedHead += 1
        if releasedHead >= 4096 && releasedHead * 2 >= released.count {
            released.removeSubrange(0..<releasedHead)
            releasedHead = 0
        }
        return address
    }

    private mutating func touch(_ slot: Int) {
        guard slot != newest else { return }
        unlink(slot)
        linkAsNewest(slot)
    }

    private mutating func unlink(_ slot: Int) {
        let newer = slots[slot].newer, older = slots[slot].older
        if newer >= 0 { slots[newer].older = older } else { newest = older }
        if older >= 0 { slots[older].newer = newer } else { oldest = newer }
        slots[slot].newer = -1
        slots[slot].older = -1
    }

    private mutating func linkAsNewest(_ slot: Int) {
        slots[slot].newer = -1
        slots[slot].older = newest
        if newest >= 0 { slots[newest].newer = slot }
        newest = slot
        if oldest < 0 { oldest = slot }
    }
}

/// The guest's DNS server. It answers every query itself and asks nobody: an address query gets
/// a fake address (`FakeAddressPool`), a blocked name does not exist, and every other kind of
/// record is "no such record" — so the guest never learns an IPv6 address or that a site speaks
/// HTTP/3, and stays on TCP over IPv4, which is what the proxy carries.
struct DNSResponder {
    enum Outcome: Equatable {
        /// A well-formed query, answered.
        case answered
        /// A well-formed query for a name under a blocked suffix, answered "no such name".
        case blocked
        /// Not a query this responder reads: no answer.
        case dropped
    }

    static let port: UInt16 = 53
    static let timeToLive: UInt32 = 60

    private static let typeA: UInt16 = 1
    private static let typeOPT: UInt16 = 41
    private static let classIN: UInt16 = 1
    private static let noSuchName: UInt16 = 3
    private static let notImplemented: UInt16 = 4

    private(set) var pool: FakeAddressPool
    private let blockedSuffixes: [String]

    init(blockedHostSuffixes: [String], poolCapacity: Int = 60_000) {
        pool = FakeAddressPool(capacity: poolCapacity)
        blockedSuffixes = blockedHostSuffixes.map(Self.normalized).filter { !$0.isEmpty }
    }

    /// A host name as the responder compares it: lower case, without dots at its ends.
    static func normalized(_ name: String) -> String {
        var text = Substring(name.lowercased())
        while text.hasPrefix(".") { text = text.dropFirst() }
        while text.hasSuffix(".") { text = text.dropLast() }
        return String(text)
    }

    /// Whether `name` (lower case) is a blocked suffix or under one.
    func isBlocked(_ name: String) -> Bool {
        blockedSuffixes.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    /// The name a fake address stands for, when a connection is opened to it.
    mutating func name(for address: VMNetIPv4) -> String? {
        pool.name(for: address)
    }

    /// The answer to a DNS message, and what kind of message it was.
    mutating func respond(to query: UnsafeRawBufferPointer) -> (reply: [UInt8]?, outcome: Outcome) {
        // A header, and in it: a query (not a response) with exactly one question and no records
        // of its own before the additional section.
        guard query.count >= 12 else { return (nil, .dropped) }
        let flags = query.be16(2)
        guard flags & 0x8000 == 0, query.be16(4) == 1, query.be16(6) == 0, query.be16(8) == 0 else { return (nil, .dropped) }

        var labels: [String] = []
        var index = 12
        var nameLength = 0
        while true {
            guard index < query.count else { return (nil, .dropped) }
            let length = Int(query[index])
            index += 1
            if length == 0 { break }
            // A pointer or an extended label has no place in a question.
            guard length <= 63, index + length <= query.count else { return (nil, .dropped) }
            nameLength += length + 1
            guard nameLength <= 254 else { return (nil, .dropped) }
            labels.append(String(decoding: query[index..<(index + length)], as: UTF8.self))
            index += length
        }
        guard index + 4 <= query.count else { return (nil, .dropped) }
        let type = query.be16(index), questionClass = query.be16(index + 2)
        let questionEnd = index + 4
        // EDNS: an OPT record (the root name, type 41) first in the additional section is answered with one.
        let hasOPT = query.be16(10) >= 1 && questionEnd + 11 <= query.count && query[questionEnd] == 0
            && query.be16(questionEnd + 1) == Self.typeOPT

        var code: UInt16 = 0
        var answer: [UInt8] = []
        var outcome = Outcome.answered
        let name = labels.joined(separator: ".").lowercased()
        if flags >> 11 & 0xF != 0 {
            code = Self.notImplemented
        } else if labels.isEmpty {
            // The root: it exists and has nothing this responder gives.
        } else if !Self.isResolvable(labels: labels, name: name) {
            code = Self.noSuchName
        } else if isBlocked(name) {
            code = Self.noSuchName
            outcome = .blocked
        } else if type == Self.typeA && questionClass == Self.classIN {
            let address = pool.address(for: name).value
            // The name is a pointer to the question's; type A, class IN, the TTL, four bytes.
            answer = [0xC0, 0x0C, 0, 1, 0, 1,
                      UInt8(Self.timeToLive >> 24), UInt8(Self.timeToLive >> 16 & 0xFF), UInt8(Self.timeToLive >> 8 & 0xFF), UInt8(Self.timeToLive & 0xFF),
                      0, 4, UInt8(address >> 24), UInt8(address >> 16 & 0xFF), UInt8(address >> 8 & 0xFF), UInt8(address & 0xFF)]
        }

        var reply = [UInt8](repeating: 0, count: 12)
        reply[0] = query[0]
        reply[1] = query[1]
        // A response, the query's opcode and "recursion desired" bit, recursion available.
        let replyFlags: UInt16 = 0x8000 | (flags & 0x7900) | 0x0080 | code
        reply[2] = UInt8(replyFlags >> 8)
        reply[3] = UInt8(replyFlags & 0xFF)
        reply[5] = 1
        reply[7] = answer.isEmpty ? 0 : 1
        reply[11] = hasOPT ? 1 : 0
        // The question as it was asked, letter case included: some resolvers check it.
        reply.append(contentsOf: query[12..<questionEnd])
        reply.append(contentsOf: answer)
        if hasOPT { reply.append(contentsOf: [0, 0, 41, 0x04, 0xD0, 0, 0, 0, 0, 0, 0]) }
        return (reply, outcome)
    }

    /// Whether a name may be handed to the proxy at all. Not: a single label and `localhost`
    /// (this machine's own names), `.local` (the local network's, which mDNS owns), and anything
    /// that is not letters, digits, hyphens and underscores — a name goes into the proxy's request
    /// as text, and a space or a line break in it would be read there as something else.
    static func isResolvable(labels: [String], name: String) -> Bool {
        guard labels.count >= 2, let last = labels.last?.lowercased(), last != "localhost", last != "local" else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.allSatisfy { byte in
                (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F
            }
        }
    }
}
