// Stand-ins for the Apple APIs Relay.swift uses, so the relay can be type-checked and driven on
// Linux (or on a Mac without the NE entitlement). They mirror the PUBLIC SIGNATURES of
// Network / NetworkExtension / os / Security that the relay calls; they are not those frameworks.
// Every NWConnection is an in-memory ECHO peer: bytes sent come back, a final message comes back
// as EOF, and `proxyScript` can script the first replies to impersonate a proxy. A match here
// says the relay's logic holds; only an NE=1 build on a Mac proves the real SDK agrees.
import Foundation
// --- minimal stand-ins for Apple's Network / NetworkExtension / os APIs, signatures as in the SDK ---
public enum NWError: Error { case posix(Int32) }
public struct IPv4Address { public let rawValue: Data; public init?(_ rawValue: Data, _ interface: Int? = nil) { guard rawValue.count == 4 else { return nil }; self.rawValue = rawValue } }
extension IPv4Address: CustomDebugStringConvertible { public var debugDescription: String { "" } }
public struct IPv6Address { public let rawValue: Data; public init?(_ rawValue: Data, _ interface: Int? = nil) { guard rawValue.count == 16 else { return nil }; self.rawValue = rawValue } }
public enum NWEndpoint {
    public enum Host: ExpressibleByStringLiteral { case name(String, Int?), ipv4(IPv4Address), ipv6(IPv6Address)
        public init(_ string: String) { self = .name(string, nil) }
        public init(stringLiteral: String) { self = .name(stringLiteral, nil) } }
    public struct Port: RawRepresentable { public var rawValue: UInt16; public init?(rawValue: UInt16) { self.rawValue = rawValue }
        public static let any = Port(rawValue: 0)! }
    case hostPort(host: Host, port: Port)
}
public final class NWProtocolTCP { public final class Options { public init() {}; public var noDelay = false; public var connectionTimeout = 0 } }
public final class sec_protocol_options_t {}
public func sec_protocol_options_set_tls_server_name(_ o: sec_protocol_options_t, _ name: UnsafePointer<CChar>) {}
public final class NWProtocolTLS { public final class Options { public init() {}; public let securityProtocolOptions = sec_protocol_options_t() } }
public final class NWParameters { public init(tls: NWProtocolTLS.Options?, tcp: NWProtocolTCP.Options = .init()) {}
    public static var udp: NWParameters { NWParameters(tls: nil) } }
public var proxyScript: ((Data) -> Data?)?
public var proxyLog: [Data] = []
public final class NWConnection {
    public enum State { case setup, waiting(NWError), preparing, ready, failed(NWError), cancelled }
    public final class ContentContext { public static let finalMessage = ContentContext(); public static let defaultMessage = ContentContext() }
    public enum SendCompletion { case contentProcessed((NWError?) -> Void), idempotent }
    // Echo server: everything sent comes back; FIN comes back as EOF.
    var buffer = Data(); var eof = false; var queue: DispatchQueue!
    var pendingReceive: (Int, Int, (Data?, ContentContext?, Bool, NWError?) -> Void)?
    public init(to: NWEndpoint, using: NWParameters) {}
    public init(host: NWEndpoint.Host, port: NWEndpoint.Port, using: NWParameters) {}
    public var stateUpdateHandler: ((State) -> Void)?
    public func start(queue: DispatchQueue) { self.queue = queue; queue.async { self.stateUpdateHandler?(.ready) } }
    public func cancel() { queue?.async { self.stateUpdateHandler?(.cancelled) } }
    public func send(content: Data?, contentContext: ContentContext = .defaultMessage, isComplete: Bool = true, completion: SendCompletion) {
        if let content { if let r = proxyScript?(content) { buffer.append(r) } else { buffer.append(content) } }
        if contentContext === ContentContext.finalMessage { eof = true }
        if case let .contentProcessed(c) = completion { queue.async { c(nil) } }
        queue.async { self.satisfy() }
    }
    func satisfy() {
        guard let (minLen, maxLen, c) = pendingReceive else { return }
        if buffer.count >= minLen && !buffer.isEmpty { let d = Data(buffer.prefix(maxLen)); buffer = Data(buffer.dropFirst(d.count)); pendingReceive = nil; c(d, nil, false, nil) }
        else if eof { pendingReceive = nil; c(nil, nil, true, nil) }
    }
    public func receive(minimumIncompleteLength: Int, maximumLength: Int, completion: @escaping (Data?, ContentContext?, Bool, NWError?) -> Void) {
        pendingReceive = (minimumIncompleteLength, maximumLength, completion); queue.async { self.satisfy() }
    }
    public func receiveMessage(completion: @escaping (Data?, ContentContext?, Bool, NWError?) -> Void) {
        receive(minimumIncompleteLength: 1, maximumLength: 65535, completion: completion)
    }
}
public class NEPacketTunnelFlow {
    public init() {}
    public var reader: (([Data], [NSNumber]) -> Void)?
    public var written: [Data] = []
    public var writtenFamilies: [NSNumber] = []
    public func readPackets(completionHandler: @escaping ([Data], [NSNumber]) -> Void) { reader = completionHandler }
    @discardableResult public func writePackets(_ packets: [Data], withProtocols: [NSNumber]) -> Bool { written += packets; writtenFamilies += withProtocols; return true }
}
#if os(Linux)
public let AF_INET: Int32 = 2, AF_INET6: Int32 = 30
#endif
public struct OSLogPrivacy { public static let `public` = OSLogPrivacy(), `private` = OSLogPrivacy() }
public struct LogMessage: ExpressibleByStringInterpolation {
    public struct StringInterpolation: StringInterpolationProtocol {
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ s: String) {}
        public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> String, privacy: OSLogPrivacy = .private) {}
        public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> Bool, privacy: OSLogPrivacy = .private) {}
        public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> Int, privacy: OSLogPrivacy = .private) {}
    }
    public init(stringLiteral: String) {}
    public init(stringInterpolation: StringInterpolation) {}
}
public struct Logger { public init(subsystem: String, category: String) {}
    public func notice(_ m: LogMessage) {}; public func error(_ m: LogMessage) {}; public func debug(_ m: LogMessage) {} }
