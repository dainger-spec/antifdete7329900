import Darwin
import Foundation
import TunnelCore

/// A utun interface opened directly through the kernel control `com.apple.net.utun_control`
/// (root only), routed like the packet tunnel: the relays' /24 and /64, nothing else. It is what
/// `NEPacketTunnelProvider.packetFlow` gives the extension, without the Network Extension a CI
/// runner cannot load, so the CI harness (`PrivacyBrowser --utun-relay`) runs the extension's
/// `PacketRouter` on real IP packets from real WebKit. Not used by the browser itself.
///
/// What it does not reproduce: NetworkExtension's enforced routes; its routes are ordinary ones.
/// (WebKit gathered on it anyway: its TURN traffic came from the utun's own addresses.)
public final class UTunDevice {
    public enum DeviceError: Error, CustomStringConvertible {
        case system(String)
        public var description: String { if case let .system(text) = self { return text }; return "" }
    }

    /// utunN, as the kernel named it.
    public let name: String
    private let descriptor: Int32
    private let source: DispatchSourceRead

    /// Opens the next free utun unit; `onPacket` gets every IP packet routed into it, on `queue`.
    public init(queue: DispatchQueue, onPacket: @escaping ([UInt8]) -> Void) throws {
        // <sys/sys_domain.h>, <sys/kern_control.h> and <net/if_utun.h>, which Swift does not import.
        let systemFamily: Int32 = 32           // AF_SYSTEM, PF_SYSTEM
        let controlProtocol: Int32 = 2         // SYSPROTO_CONTROL
        let controlAddressFamily: UInt16 = 2   // AF_SYS_CONTROL
        let CTLIOCGINFO: UInt = 0xC064_4E03    // _IOWR('N', 3, struct ctl_info)
        let UTUN_OPT_IFNAME: Int32 = 2
        let fd = socket(systemFamily, SOCK_DGRAM, controlProtocol)
        guard fd >= 0 else { throw DeviceError.system("socket(PF_SYSTEM): errno \(errno) (root needed)") }
        // struct ctl_info { u_int32_t ctl_id; char ctl_name[96]; } — CTLIOCGINFO fills in the id.
        var info = [UInt8](repeating: 0, count: 100)
        let controlName = Array("com.apple.net.utun_control".utf8)
        info.replaceSubrange(4..<(4 + controlName.count), with: controlName)
        guard info.withUnsafeMutableBytes({ ioctl(fd, CTLIOCGINFO, $0.baseAddress!) }) == 0 else {
            Darwin.close(fd)
            throw DeviceError.system("CTLIOCGINFO: errno \(errno)")
        }
        let controlID = info.withUnsafeBytes { $0.load(as: UInt32.self) }
        // struct sockaddr_ctl { u_char sc_len, sc_family; u_int16_t ss_sysaddr; u_int32_t sc_id, sc_unit; u_int32_t sc_reserved[5]; }
        var address = [UInt8](repeating: 0, count: 32)
        address[0] = 32
        address[1] = UInt8(systemFamily)
        withUnsafeBytes(of: controlAddressFamily) { address.replaceSubrange(2..<4, with: $0) }
        withUnsafeBytes(of: controlID) { address.replaceSubrange(4..<8, with: $0) }
        // sc_unit 0: the kernel picks the next free utun unit.
        guard address.withUnsafeBytes({ connect(fd, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), 32) }) == 0 else {
            Darwin.close(fd)
            throw DeviceError.system("connect(utun_control): errno \(errno)")
        }
        var nameBuffer = [CChar](repeating: 0, count: 64)
        var nameLength = socklen_t(nameBuffer.count)
        guard getsockopt(fd, controlProtocol, UTUN_OPT_IFNAME, &nameBuffer, &nameLength) == 0 else {
            Darwin.close(fd)
            throw DeviceError.system("UTUN_OPT_IFNAME: errno \(errno)")
        }
        name = String(cString: nameBuffer)
        descriptor = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65_540)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            // Each packet starts with its protocol family (4 bytes, network order).
            if count > 4 { onPacket(Array(buffer[4..<count])) }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    deinit { source.cancel() }

    /// Writes one IP packet into the interface (to the local stack).
    public func write(_ packet: [UInt8]) {
        guard let version = packet.first.map({ $0 >> 4 }) else { return }
        let family = UInt32(version == 6 ? AF_INET6 : AF_INET).bigEndian
        let frame = withUnsafeBytes(of: family) { Array($0) } + packet
        _ = frame.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    /// Addresses and routes as the packet tunnel sets them (`TunnelAddressing`), with ifconfig and
    /// route. IPv6 is best effort: a failure there is returned, IPv4 keeps working.
    public func configure() throws -> [String] {
        let v4 = TunnelAddressing.ipv4Interface.description
        try Self.run("/sbin/ifconfig", [name, "inet", v4, v4, "netmask", TunnelAddressing.ipv4Mask, "up"])
        try Self.run("/sbin/route", ["-n", "add", "-net", "\(TunnelAddressing.ipv4Network)/\(TunnelAddressing.ipv4PrefixLength)", "-interface", name],
                     tolerating: "File exists")
        var problems: [String] = []
        do {
            try Self.run("/sbin/ifconfig", [name, "inet6", TunnelAddressing.ipv6Interface.description, "prefixlen", "\(TunnelAddressing.ipv6PrefixLength)"])
            try Self.run("/sbin/route", ["-n", "add", "-inet6", "-net", TunnelAddressing.ipv6Network.description,
                                         "-prefixlen", "\(TunnelAddressing.ipv6PrefixLength)", "-interface", name], tolerating: "File exists")
        } catch {
            problems.append("IPv6: \(error)")
        }
        return problems
    }

    /// Runs a configuration tool; an error whose output contains `tolerating` (a route the
    /// address already added) is not one.
    private static func run(_ tool: String, _ arguments: [String], tolerating: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if let tolerating, text.contains(tolerating) { return }
            throw DeviceError.system("\(tool) \(arguments.joined(separator: " ")): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
