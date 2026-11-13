import Foundation

/// A proxy's user name and password. Never written to a log.
struct ProxyCredentials: Equatable {
    var username: String
    var password: String

    /// The pair to use, if the profile has one: a user name that is not empty (a password may be).
    init?(username: String?, password: String?) {
        guard let username, !username.isEmpty else { return nil }
        self.username = username
        self.password = password ?? ""
    }
}

/// Why a proxy did not open a tunnel. Its text goes to the log, so it holds a kind and a number
/// and nothing of where the connection was going.
enum ProxyFailure: Equatable, Error {
    /// The proxy's answer is not the protocol's.
    case malformedReply
    /// SOCKS5: the proxy takes none of the ways to sign in that the profile has.
    case noAcceptableMethod
    /// SOCKS5: the user name and password were not accepted.
    case authenticationRejected
    /// The proxy answered and said no: SOCKS5's reply code, or HTTP's status.
    case refused(Int)
    /// SOCKS5 carries at most 255 bytes of each.
    case credentialsTooLong
    case nameTooLong

    var reason: String {
        switch self {
        case .malformedReply: return "the proxy's answer was not understood"
        case .noAcceptableMethod: return "the proxy accepts no sign-in method the profile has"
        case .authenticationRejected: return "the proxy rejected the user name and password"
        case .refused(let code): return "the proxy refused (code \(code))"
        case .credentialsTooLong: return "the user name or password is too long for SOCKS5"
        case .nameTooLong: return "the host name is too long for SOCKS5"
        }
    }
}

/// What to do after the proxy's bytes so far.
enum ProxyHandshakeStep: Equatable {
    /// Wait for more.
    case needMore
    /// Send these, then wait for more.
    case send([UInt8])
    /// The tunnel is open. `leftover` came after the proxy's answer: it is already the tunnel's.
    case established(leftover: [UInt8])
    case failed(ProxyFailure)
}

/// The conversation that opens a tunnel through a proxy, as bytes in and bytes out — no socket,
/// so both protocols are tested as data.
protocol ProxyHandshake {
    /// What to send as soon as the connection to the proxy is open.
    mutating func begin() -> ProxyHandshakeStep
    /// The proxy's next bytes.
    mutating func receive(_ bytes: [UInt8]) -> ProxyHandshakeStep
}

/// SOCKS5 (RFC 1928) CONNECT, with user name and password (RFC 1929) when the profile has them.
/// A host name is sent as a name (address type 3), so the proxy resolves it.
struct SOCKS5Handshake: ProxyHandshake {
    private enum Stage { case method, authentication, reply, done }

    private let target: ProxyTarget
    private let credentials: ProxyCredentials?
    private var stage = Stage.method
    private var buffer: [UInt8] = []

    init(target: ProxyTarget, credentials: ProxyCredentials?) {
        self.target = target
        self.credentials = credentials
    }

    mutating func begin() -> ProxyHandshakeStep {
        if let credentials, credentials.username.utf8.count > 255 || credentials.password.utf8.count > 255 {
            stage = .done
            return .failed(.credentialsTooLong)
        }
        if case .name(let name, _) = target, name.utf8.count > 255 || name.isEmpty {
            stage = .done
            return .failed(.nameTooLong)
        }
        // Version 5; the methods offered: none, and user name/password when there is one.
        return .send(credentials == nil ? [5, 1, 0] : [5, 2, 0, 2])
    }

    mutating func receive(_ bytes: [UInt8]) -> ProxyHandshakeStep {
        buffer += bytes
        switch stage {
        case .method:
            guard buffer.count >= 2 else { return .needMore }
            guard buffer[0] == 5 else { return fail(.malformedReply) }
            let method = buffer[1]
            buffer.removeFirst(2)
            switch method {
            case 0:
                stage = .reply
                return .send(request())
            case 2:
                guard let credentials else { return fail(.malformedReply) }
                stage = .authentication
                let user = Array(credentials.username.utf8), password = Array(credentials.password.utf8)
                return .send([1, UInt8(user.count)] + user + [UInt8(password.count)] + password)
            case 0xFF:
                return fail(.noAcceptableMethod)
            default:
                return fail(.malformedReply)
            }
        case .authentication:
            guard buffer.count >= 2 else { return .needMore }
            let status = buffer[1]
            buffer.removeFirst(2)
            guard status == 0 else { return fail(.authenticationRejected) }
            stage = .reply
            return .send(request())
        case .reply:
            // VER, REP, RSV, ATYP, the bound address (its length depends on ATYP), the port.
            guard buffer.count >= 2 else { return .needMore }
            guard buffer[0] == 5 else { return fail(.malformedReply) }
            guard buffer[1] == 0 else { return fail(.refused(Int(buffer[1]))) }
            guard buffer.count >= 5 else { return .needMore }
            let addressLength: Int
            switch buffer[3] {
            case 1: addressLength = 4
            case 4: addressLength = 16
            case 3: addressLength = 1 + Int(buffer[4])
            default: return fail(.malformedReply)
            }
            let total = 4 + addressLength + 2
            guard buffer.count >= total else { return .needMore }
            stage = .done
            return .established(leftover: Array(buffer[total...]))
        case .done:
            return .failed(.malformedReply)
        }
    }

    private mutating func fail(_ failure: ProxyFailure) -> ProxyHandshakeStep {
        stage = .done
        return .failed(failure)
    }

    /// VER 5, CMD 1 (CONNECT), RSV, then the destination and its port.
    private func request() -> [UInt8] {
        var bytes: [UInt8] = [5, 1, 0]
        switch target {
        case .name(let name, _):
            let text = Array(name.utf8)
            bytes += [3, UInt8(text.count)] + text
        case .address(let address, _):
            bytes += [1, UInt8(address.value >> 24), UInt8(address.value >> 16 & 0xFF), UInt8(address.value >> 8 & 0xFF), UInt8(address.value & 0xFF)]
        }
        return bytes + [UInt8(target.port >> 8), UInt8(target.port & 0xFF)]
    }
}

/// HTTP CONNECT: one request, and the proxy's status line and headers in answer. Any 2xx status
/// is a tunnel; what comes after the empty line that ends the headers already belongs to it.
struct HTTPConnectHandshake: ProxyHandshake {
    /// A proxy's headers longer than this are not headers.
    static let maximumHeaderBytes = 16 * 1024

    private let target: ProxyTarget
    private let credentials: ProxyCredentials?
    private var buffer: [UInt8] = []
    private var done = false

    init(target: ProxyTarget, credentials: ProxyCredentials?) {
        self.target = target
        self.credentials = credentials
    }

    mutating func begin() -> ProxyHandshakeStep {
        let authority = "\(target.hostText):\(target.port)"
        var request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n"
        if let credentials {
            let pair = Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(pair)\r\n"
        }
        request += "Proxy-Connection: keep-alive\r\n\r\n"
        return .send(Array(request.utf8))
    }

    mutating func receive(_ bytes: [UInt8]) -> ProxyHandshakeStep {
        guard !done else { return .failed(.malformedReply) }
        // The end of the headers may straddle two reads: look again from three bytes back.
        let searchFrom = max(buffer.count - 3, 0)
        buffer += bytes
        guard let end = Self.endOfHeaders(buffer, from: searchFrom) else {
            guard buffer.count <= Self.maximumHeaderBytes else {
                done = true
                return .failed(.malformedReply)
            }
            return .needMore
        }
        done = true
        guard let status = Self.status(buffer) else { return .failed(.malformedReply) }
        guard (200..<300).contains(status) else { return .failed(.refused(status)) }
        return .established(leftover: Array(buffer[end...]))
    }

    /// The index just after the first CR LF CR LF at or after `from`.
    private static func endOfHeaders(_ bytes: [UInt8], from: Int) -> Int? {
        guard bytes.count >= 4 else { return nil }
        var index = from
        while index + 4 <= bytes.count {
            if bytes[index] == 13, bytes[index + 1] == 10, bytes[index + 2] == 13, bytes[index + 3] == 10 { return index + 4 }
            index += 1
        }
        return nil
    }

    /// The status of "HTTP/1.x NNN reason".
    private static func status(_ bytes: [UInt8]) -> Int? {
        let prefix = Array("HTTP/1.".utf8)
        guard bytes.count >= 12, Array(bytes[0..<7]) == prefix, bytes[8] == 0x20 else { return nil }
        var status = 0
        for byte in bytes[9..<12] {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            status = status * 10 + Int(byte - 0x30)
        }
        return status
    }
}

extension VMNetUpstream {
    /// The proxy's host and port, or nil when there is no proxy.
    var endpoint: (host: String, port: Int)? {
        switch self {
        case .socks5(let host, let port, _, _), .httpConnect(let host, let port, _, _): return (host, port)
        case .none: return nil
        }
    }

    /// The handshake that asks this proxy for `target`, or nil when there is no proxy.
    func handshake(for target: ProxyTarget) -> ProxyHandshake? {
        switch self {
        case .socks5(_, _, let username, let password):
            return SOCKS5Handshake(target: target, credentials: ProxyCredentials(username: username, password: password))
        case .httpConnect(_, _, let username, let password):
            return HTTPConnectHandshake(target: target, credentials: ProxyCredentials(username: username, password: password))
        case .none:
            return nil
        }
    }
}
