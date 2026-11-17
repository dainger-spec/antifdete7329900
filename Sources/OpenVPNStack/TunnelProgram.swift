@_exported import OpenVPNLink
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What LumenTunnel says it is (`--version`), and what the app checks it against.
public enum OpenVPNStackVersion {
    /// The protocol between the app and the program: the environment it reads, the lines it writes.
    public static let protocolVersion = 1
    public static var description: String { "protocol \(protocolVersion), lwIP 2.2.1" }
}

/// Lines to the app (`LUMEN_STATUS_FD`): one JSON object per line, string values only, each
/// written in one call (shorter than PIPE_BUF, so lines of successive programs never mix).
public struct TunnelStatus {
    let descriptor: Int32?

    public init(descriptor: Int32?) {
        self.descriptor = descriptor
        if let descriptor { _ = fcntl(descriptor, F_SETFD, fcntl(descriptor, F_GETFD, 0) | FD_CLOEXEC) }
    }

    public func say(_ fields: [String: String]) {
        guard let descriptor else { return }
        let line = Self.line(fields)
        _ = TunnelSystem.write(descriptor, Array(line.utf8))
    }

    /// The object, keys sorted, values escaped.
    public static func line(_ fields: [String: String]) -> String {
        let body = fields.keys.sorted().map { key in "\"\(escape(key))\":\"\(escape(fields[key]!))\"" }
        return "{" + body.joined(separator: ",") + "}\n"
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            default:
                if scalar.value < 0x20 { result += "\\u" + String(repeating: "0", count: 4 - String(scalar.value, radix: 16).count) + String(scalar.value, radix: 16) }
                else { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }
}

/// The listening socket the app gave: it must listen on 127.0.0.1, or the program does not start.
public enum TunnelListener {
    /// Its port when it is a stream socket bound to 127.0.0.1.
    public static func check(_ descriptor: Int32) -> UInt16? {
        guard TunnelSystem.isSocket(descriptor), let local = TunnelSystem.localAddress(descriptor),
              local.address == TunnelAddress("127.0.0.1"), local.port != 0 else { return nil }
        var type: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &length) == 0, type == TunnelSystem.streamType else { return nil }
        TunnelSystem.setCloseOnExec(descriptor)
        return local.port
    }
}

/// The signal handler's way to the loop: a byte on the server's wake pipe.
public enum TunnelSignals {
    public static var wake: Int32 = -1
}

public let tunnelSignalHandler: @convention(c) (Int32) -> Void = { _ in
    var byte: UInt8 = 1
    let descriptor = TunnelSignals.wake
    if descriptor >= 0 { _ = write(descriptor, &byte, 1) }
}
