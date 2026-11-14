import Foundation

/// The DHCP server of a guest's network (RFC 2131): it has one address to give, to one network
/// card. The guest is told its address, its mask, that the gateway is its router and its DNS
/// server, and to keep all of it for a day.
struct DHCPServer {
    static let serverPort: UInt16 = 67
    static let clientPort: UInt16 = 68
    static let leaseSeconds: UInt32 = 86400

    enum MessageType: UInt8 {
        case discover = 1, offer = 2, request = 3, decline = 4, ack = 5, nak = 6, release = 7, inform = 8
    }

    /// What a client's message says, as far as the server needs it.
    struct Message: Equatable {
        var type: MessageType
        var transactionID: UInt32
        var flags: UInt16
        /// The address the client already uses (a renewal, an INFORM), or zero.
        var clientAddress: VMNetIPv4
        var hardwareAddress: VMNetMAC
        /// Option 50: the address the client asks for.
        var requestedAddress: VMNetIPv4?
        /// Option 54: the server the client chose.
        var serverIdentifier: VMNetIPv4?

        /// Nil for anything that is not a client's DHCP message over Ethernet.
        init?(_ bytes: UnsafeRawBufferPointer) {
            // The fixed part (236 bytes), the magic cookie, and at least the message type.
            guard bytes.count >= 240, bytes[0] == 1, bytes[1] == 1, bytes[2] == 6, bytes.be32(236) == 0x6382_5363 else { return nil }
            transactionID = bytes.be32(4)
            flags = bytes.be16(10)
            clientAddress = VMNetIPv4(bytes.be32(12))
            hardwareAddress = bytes.mac(28)
            var type: MessageType?
            var index = 240
            while index < bytes.count {
                let code = bytes[index]
                if code == 255 { break }
                if code == 0 { index += 1; continue }
                guard index + 1 < bytes.count else { break }
                let length = Int(bytes[index + 1])
                let value = index + 2
                guard value + length <= bytes.count else { break }
                switch code {
                case 53 where length == 1: type = MessageType(rawValue: bytes[value])
                case 50 where length == 4: requestedAddress = VMNetIPv4(bytes.be32(value))
                case 54 where length == 4: serverIdentifier = VMNetIPv4(bytes.be32(value))
                default: break
                }
                index = value + length
            }
            guard let type else { return nil }
            self.type = type
        }
    }

    var guestMAC: VMNetMAC
    var guestAddress: VMNetIPv4
    var gatewayAddress: VMNetIPv4
    var prefixLength: Int
    var mtu: Int

    /// The UDP payload that answers `message`, or nil when it gets no answer: another network
    /// card's message, a message for another server, a release.
    func reply(to message: Message) -> [UInt8]? {
        guard message.hardwareAddress == guestMAC else { return nil }
        if let server = message.serverIdentifier, server != gatewayAddress { return nil }
        switch message.type {
        case .discover:
            return build(.offer, for: message, address: guestAddress, lease: true)
        case .request:
            // The address asked for (a new lease) or already in use (a renewal) must be the one there is.
            let wanted = message.requestedAddress ?? message.clientAddress
            guard wanted == guestAddress else { return build(.nak, for: message, address: .unspecified, lease: false) }
            return build(.ack, for: message, address: guestAddress, lease: true)
        case .inform:
            // The client keeps the address it has and only asks for the rest.
            return build(.ack, for: message, address: .unspecified, lease: false)
        default:
            return nil
        }
    }

    private func build(_ type: MessageType, for message: Message, address: VMNetIPv4, lease: Bool) -> [UInt8] {
        var reply = [UInt8](repeating: 0, count: 240)
        reply.withUnsafeMutableBytes { buffer in
            buffer[0] = 2
            buffer[1] = 1
            buffer[2] = 6
            buffer.put32(4, message.transactionID)
            buffer.put16(10, message.flags)
            if type != .nak { buffer.put32(12, message.clientAddress.value) }
            buffer.put32(16, address.value)
            if type != .nak { buffer.put32(20, gatewayAddress.value) }
            buffer.putMAC(28, message.hardwareAddress)
            buffer.put32(236, 0x6382_5363)
        }
        func option(_ code: UInt8, _ value: [UInt8]) { reply += [code, UInt8(value.count)] + value }
        func quad(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        option(53, [type.rawValue])
        option(54, quad(gatewayAddress.value))
        if type != .nak {
            if lease {
                option(51, quad(Self.leaseSeconds))
                option(58, quad(Self.leaseSeconds / 2))
                option(59, quad(Self.leaseSeconds / 8 * 7))
            }
            let mask = VMNetIPv4.mask(prefixLength)
            option(1, quad(mask))
            option(28, quad(gatewayAddress.value | ~mask))
            option(3, quad(gatewayAddress.value))
            option(6, quad(gatewayAddress.value))
            option(26, [UInt8(mtu >> 8 & 0xFF), UInt8(mtu & 0xFF)])
        }
        reply.append(255)
        // BOOTP's minimum: some clients drop a shorter message.
        if reply.count < 300 { reply += [UInt8](repeating: 0, count: 300 - reply.count) }
        return reply
    }
}
