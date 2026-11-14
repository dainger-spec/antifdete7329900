import Foundation

/// The answer to the guest's question for the time (NTP, UDP port 123), whoever it asked: this
/// Mac's clock, and nothing leaves. A guest's own clock is set once, as it starts, from the
/// virtual Mac's; with every datagram refused it could never be corrected afterwards — and a
/// machine woken from a saved state has the clock of the moment it was put to sleep, until
/// something tells it the time. macOS asks by itself now and then, and the boot script asks right
/// after a wake (`sntp`).
enum TimeResponder {
    static let port: UInt16 = 123
    /// Seconds from 1900, NTP's beginning, to 1970, Unix's.
    private static let epochOffset: UInt64 = 2_208_988_800

    /// The reply to a client's request (mode 3, versions 1 to 4), as a server one step from a
    /// reference clock would give it; nil for anything else. `now` is seconds since 1970.
    static func reply(to query: UnsafeRawBufferPointer, now: Double, reference: VMNetIPv4) -> [UInt8]? {
        guard query.count >= 48, now.isFinite, now >= 0 else { return nil }
        let version = query[0] >> 3 & 0x7, mode = query[0] & 0x7
        guard mode == 3, (1...4).contains(version) else { return nil }
        var reply = [UInt8](repeating: 0, count: 48)
        // No leap second announced, the client's version, a server's answer.
        reply[0] = version << 3 | 4
        // Stratum 2: synchronised to a server, which is what this Mac is.
        reply[1] = 2
        reply[2] = query[2]
        // Precision: about a microsecond (2^-20 s).
        reply[3] = 0xEC
        // Root delay 0; root dispersion 1/256 s.
        reply[10] = 1
        // The reference: for stratum 2, the address of the server asked.
        let address = reference.value
        reply[12] = UInt8(address >> 24)
        reply[13] = UInt8(address >> 16 & 0xFF)
        reply[14] = UInt8(address >> 8 & 0xFF)
        reply[15] = UInt8(address & 0xFF)
        let whole = now.rounded(.down)
        let seconds = UInt32(truncatingIfNeeded: UInt64(whole) &+ epochOffset)
        let fraction = UInt32(min(((now - whole) * 4_294_967_296).rounded(.down), 4_294_967_295))
        func write(at offset: Int) {
            for index in 0..<4 {
                reply[offset + index] = UInt8(seconds >> UInt32(24 - 8 * index) & 0xFF)
                reply[offset + 4 + index] = UInt8(fraction >> UInt32(24 - 8 * index) & 0xFF)
            }
        }
        // When the clock was last set, when the request came, when the answer left: all now.
        write(at: 16)
        write(at: 32)
        write(at: 40)
        // The client's own transmit time, back to it: how it knows the answer is to its question.
        for index in 0..<8 { reply[24 + index] = query[40 + index] }
        return reply
    }
}
