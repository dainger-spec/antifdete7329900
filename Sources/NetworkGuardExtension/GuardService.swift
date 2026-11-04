import Foundation
import NetworkGuardCore
import os
import Security

/// The guard's Mach service: where the app holds and releases profiles' processes and reads back
/// what the filter did (`NetworkGuardControl`). Only Lumen, signed by this extension's own team, is
/// let in, and it can hold only processes that are Lumen's own: a registration narrows what a
/// process may reach, and is given to nothing else.
///
/// A held process is released when it exits (the kernel says so), whatever the app does; a process
/// the app never registered — anything else on this Mac, the app's own — is never filtered.
final class GuardService: NSObject, NSXPCListenerDelegate, NetworkGuardControl, @unchecked Sendable {
    static let shared = GuardService()

    let ledger = GuardLedger()
    /// Every flow the filter is given, counted (`GuardFilterProvider`).
    let tally = FlowTally()
    private let lock = NSLock()
    private var running = false
    private var listener: NSXPCListener?
    private var exitWatches: [Int32: DispatchSourceProcess] = [:]
    private let queue = DispatchQueue(label: "PrivacyBrowser.NetworkGuard.service")
    private let logger = Logger(subsystem: "PrivacyBrowser.NetworkGuard", category: "service")

    /// Whether the filter runs (set by `GuardFilterProvider`), as `hello` says it.
    var filterRunning: Bool {
        get { lock.lock(); defer { lock.unlock() }; return running }
        set { lock.lock(); running = newValue; lock.unlock() }
    }

    func start() {
        guard let networkExtension = Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any],
              let name = networkExtension["NEMachServiceName"] as? String else {
            logger.error("no NEMachServiceName in Info.plist: the app cannot reach the guard")
            return
        }
        let listener = NSXPCListener(machServiceName: name)
        listener.delegate = self
        listener.resume()
        self.listener = listener
        logger.notice("listening")
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = Self.clientRequirement else {
            logger.error("refused a connection: this extension's team or the app's identifier is not known")
            return false
        }
        // Checked by the system on every message: a process that is not Lumen of this team gets nothing.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: NetworkGuardControl.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    // MARK: NetworkGuardControl

    func hello(reply: @escaping (String, Bool) -> Void) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        reply(version, filterRunning)
    }

    func hold(_ registration: Data, reply: @escaping (Bool, String?) -> Void) {
        guard let decoded = try? JSONDecoder().decode(GuardRegistration.self, from: registration),
              decoded.format == GuardRegistration.currentFormat else {
            reply(false, "unreadable registration")
            return
        }
        guard filterRunning else {
            reply(false, "the filter is not running")
            return
        }
        guard Self.isLumen(pid: decoded.pid) else {
            logger.error("refused to hold process \(decoded.pid, privacy: .public): not Lumen's own")
            reply(false, "not a process of Lumen's")
            return
        }
        ledger.hold(decoded)
        watchExit(of: decoded.pid)
        logger.notice("holding process \(decoded.pid, privacy: .public) to its proxy")
        reply(true, nil)
    }

    func release(_ pid: Int32, reply: @escaping () -> Void) {
        ledger.release(pid)
        queue.sync {
            exitWatches.removeValue(forKey: pid)?.cancel()
        }
        logger.notice("released process \(pid, privacy: .public)")
        reply()
    }

    func report(_ pid: Int32, reply: @escaping (Data) -> Void) {
        reply((try? JSONEncoder().encode(ledger.report(for: pid))) ?? Data())
    }

    func diagnostics(reply: @escaping (Data) -> Void) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let diagnostics = GuardDiagnostics(version: version, filterRunning: filterRunning,
                                           heldPIDs: ledger.heldPIDs.sorted(), flows: tally.snapshot())
        reply((try? JSONEncoder().encode(diagnostics)) ?? Data())
    }

    // MARK: Processes

    /// Released when it exits: a pid the system gives again is never held by mistake.
    private func watchExit(of pid: Int32) {
        queue.sync {
            exitWatches.removeValue(forKey: pid)?.cancel()
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.ledger.release(pid)
                self.exitWatches.removeValue(forKey: pid)?.cancel()
                self.logger.notice("process \(pid, privacy: .public) exited: released")
            }
            exitWatches[pid] = source
            source.resume()
        }
    }

    /// The requirement a client and a held process must meet: Lumen's identifier, signed by the team
    /// that signed this extension.
    static let clientRequirement: String? = {
        guard let app = Bundle.main.object(forInfoDictionaryKey: NetworkGuardNames.extensionAppKey) as? String,
              let team = ownTeamIdentifier() else { return nil }
        return "anchor apple generic and identifier \"\(app)\" and certificate leaf[subject.OU] = \"\(team)\""
    }()

    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Whether the running process `pid` is Lumen of this team (its code, as the kernel has it).
    private static func isLumen(pid: Int32) -> Bool {
        guard let requirementText = clientRequirement else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else { return false }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }
}
