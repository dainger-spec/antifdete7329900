import AppKit
import BrowserCore
import CoreServices
import Foundation

/// `PrivacyBrowser --menu-walk` (CI): Safari's menu bar walked item by item in a profile's own
/// process, from the manager's side (`SafariMenuWalk` is the profile's side).
///
/// A new profile in a temporary vault, launched as the app launches one (a process of its own,
/// Safari's window), held to the self-test proxy when `PB_SELFTEST_HTTP_PROXY_PORT` names one (its
/// start page then loads through it) or else to a proxy that goes nowhere. It is asked to walk its
/// menu; what each item did comes back over its channel, and this side adds what it sees from
/// outside the process while the item runs:
///
///   * the XPC services that started for it (`XPCServiceWatch`), and what they held open in the
///     real Safari's places;
///   * the files written (FSEvents): in the profile's vault and home, in the real Safari's places,
///     and anywhere else in the account's home (minus this run's working folder and the prefixes
///     in `PB_MENU_WALK_IGNORE`, colon-separated: the CI runner's own files).
///
/// An item that ends the process is a crash: the profile is started again (its home sealed and
/// opened as at any launch) and the walk goes on from the next item; one that answers nothing for
/// 25 seconds is a hang, and its process is killed. One `MENUWALK` line of JSON per item, after
/// the walk; scripts/menu_walk.py reads them, adds the crash reports, and compares the result with
/// the recorded one. Exit 0 when the walk got to the end, 1 when it could not.
@MainActor
enum SafariMenuWalkCheck {
    /// What one item did, as the profile's process told it and as this side saw it.
    private final class Item {
        var fields: [String: Any]
        var begin: Double
        var end: Double?
        var xpc: [String] = []
        /// Safari's agents that started meanwhile, whoever asked for them (`XPCServiceWatch`).
        var agents: [String] = []
        /// What the manager was asked for meanwhile (its Settings).
        var asked: [String] = []
        init(fields: [String: Any], begin: Double) {
            self.fields = fields
            self.begin = begin
        }
    }

    private final class Walk {
        var hostsChrome: Bool?
        var count: Int?
        var done = false
        var exited: Int32?
        var current: Item?
        var items: [Int: Item] = [:]
        var services: XPCServiceWatch?
        var nextIndex = 0
    }

    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        // A process of its own per profile, with Safari's window: what this check is about.
        setenv("PB_PROFILE_PROCESS", "1", 1)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2400) {
            print("MENUWALK-ERROR the walk did not finish in 40 minutes")
            exit(1)
        }
        Task { @MainActor in exit(await run()) }
        application.run()
    }

    private static func run() async -> Int32 {
        guard !AppEnvironment.isSandboxed else {
            print("MENUWALK-ERROR the sandboxed build runs no process per profile")
            return 1
        }
        let environment = ProcessInfo.processInfo.environment
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-menu-walk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let port = environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init)
        let proxy = ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: port ?? 1)
        let repository: ProfileRepository
        let profile: ProfileSummary
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "menu-walk", iterations: 10_000))
            profile = try repository.create(name: "Menu walk", configuration: ProfileConfiguration(
                startURL: port == nil ? nil : URL(string: "http://menu-walk.selftest.invalid/pb-login"),
                proxy: proxy, matchProxyLocation: false))
        } catch {
            print("MENUWALK-ERROR could not make a profile: \(error)")
            return 1
        }
        print("MENUWALK-INFO macOS \(ProcessInfo.processInfo.operatingSystemVersionString), Safari \(HostSafari.version), "
              + (port == nil ? "a proxy that goes nowhere" : "the self-test proxy on port \(port ?? 0)"))

        let realHome = SafariPaths.realHome ?? NSHomeDirectory()
        // FSEvents names /var/folders as /private/var/folders.
        let ours = [root.path, root.resolvingSymlinksInPath().path, "/private" + root.path]
        let ignored = [FileManager.default.currentDirectoryPath]
            + (environment["PB_MENU_WALK_IGNORE"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let files = FileChangeWatch(paths: [realHome] + ours)
        // This app's own preferences in the account's home: which keys a walk adds, by name (a
        // profile's process keeps its preferences in its own home; the manager's are here).
        let preferencesDomain = Bundle.main.bundleIdentifier ?? "dev.local.PrivacyBrowser"
        let keysBefore = Set(UserDefaults.standard.persistentDomain(forName: preferencesDomain)?.keys.map { $0 } ?? [])
        // And the account's own com.apple.Safari preferences outside Safari's container, read as a
        // file: whether a profile's process writes Safari's domain there.
        let safariPreferences = realHome + "/Library/Preferences/com.apple.Safari.plist"
        let safariBefore = PreferencesFile(path: safariPreferences)

        let walk = Walk()
        let manager = ProfileManager(repository: repository)
        manager.onProfileRunning = { _, hosts in walk.hostsChrome = hosts }
        manager.onError = { message in print("MENUWALK-INFO the manager was told: \(message)") }
        manager.onShowSettings = { walk.current?.asked.append("the manager was asked for its Settings") }
        manager.onChildExited = { _, status in walk.exited = status }
        manager.onMenuWalk = { _, line in
            guard let data = line.data(using: .utf8),
                  let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let event = fields["event"] as? String else { return }
            switch event {
            case "list":
                walk.count = fields["count"] as? Int
                print("MENUWALK-INFO \(walk.count ?? 0) items in the menu bar; walking from \(fields["from"] as? Int ?? 0)")
            case "begin":
                let index = fields["index"] as? Int ?? -1
                let item = Item(fields: fields, begin: fields["time"] as? Double ?? Date().timeIntervalSince1970)
                walk.current = item
                walk.items[index] = item
                walk.services = SafariPaths.realHome.map { XPCServiceWatch(realHome: $0, alsoMatching: ["Safari"]) }
            case "end":
                guard let item = walk.current else { return }
                for (key, value) in fields where key != "time" && key != "event" { item.fields[key] = value }
                item.end = fields["time"] as? Double ?? Date().timeIntervalSince1970
                let pid = manager.processIdentifier(of: profile.id)
                for (service, opened) in walk.services?.stop() ?? [] {
                    let held = opened.isEmpty ? "" : " (held open in the real Safari's places: \(opened.joined(separator: ", ")))"
                    if service.path.contains(".xpc/") {
                        if service.responsible == nil || service.responsible == pid { item.xpc.append(service.bundleName + held) }
                    } else {
                        item.agents.append(service.bundleName + held)
                    }
                }
                walk.services = nil
                walk.current = nil
                walk.nextIndex = (fields["index"] as? Int ?? walk.nextIndex) + 1
                print("MENUWALK-PROGRESS \(fields["index"] as? Int ?? -1) \(fields["path"] as? String ?? "?")")
            case "done":
                walk.done = true
            default:
                break
            }
        }

        var launches = 0
        while !walk.done, launches < 40 {
            launches += 1
            walk.hostsChrome = nil
            walk.exited = nil
            do {
                try await manager.launch(profile.id)
            } catch {
                print("MENUWALK-ERROR the profile did not start: \(error)")
                break
            }
            let started = Date()
            while walk.hostsChrome == nil, walk.exited == nil, Date().timeIntervalSince(started) < 90 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard walk.hostsChrome == true else {
                print("MENUWALK-ERROR the profile's window is not Safari's (\(walk.hostsChrome == nil ? "no answer" : "this app's own window"))")
                break
            }
            manager.walkMenu(profile.id, from: walk.nextIndex)
            while !walk.done, walk.exited == nil {
                if let current = walk.current, Date().timeIntervalSince1970 - current.begin > 25,
                   current.fields["hang"] == nil, let pid = manager.processIdentifier(of: profile.id) {
                    current.fields["hang"] = true
                    _ = kill(pid, SIGKILL)
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if walk.done { break }
            // The process ended in the middle of an item: that item crashed it (or hung).
            if let current = walk.current {
                current.fields["exit"] = Int(walk.exited ?? -1)
                current.end = Date().timeIntervalSince1970
                if let services = walk.services?.stop() {
                    current.xpc += services.map { $0.service.bundleName }
                }
                walk.services = nil
                walk.current = nil
                walk.nextIndex = (current.fields["index"] as? Int ?? walk.nextIndex) + 1
                print("MENUWALK-PROGRESS \(current.fields["index"] as? Int ?? -1) ended the process (status \(walk.exited ?? -1))")
            } else {
                print("MENUWALK-INFO the profile's process ended between items (status \(walk.exited ?? -1)); starting it again")
            }
        }
        // Where the profile's process keeps preferences: every property list under a Preferences
        // folder of its home, and Safari's window state (SafariUIState), read while it still runs
        // (its home is sealed when it stops).
        let profileHomes = (try? FileManager.default.contentsOfDirectory(atPath: root.path + "/profiles")) ?? []
        for name in profileHomes {
            let home = root.path + "/profiles/" + name + "/home.noindex"
            let found = FileManager.default.enumerator(atPath: home)?.compactMap { $0 as? String }
                .filter { ($0.contains("Preferences/") || $0.hasPrefix("Library/PrivacyBrowser/")) && $0.hasSuffix(".plist") }
                .sorted() ?? []
            var described: [String] = []
            for path in found {
                let keys = PreferencesFile(path: home + "/" + path)?.keys.sorted() ?? []
                described.append("\(path) (\(keys.count) keys: \(keys.prefix(40).joined(separator: ", ")))")
            }
            print("MENUWALK-INFO preferences in the profile's home: " + (described.isEmpty ? "none" : described.joined(separator: "; ")))
        }
        if manager.isRunning(profile.id) { try? await manager.stop(profile.id) }
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // The files written while each item ran (FSEvents tells them a moment after).
        let changes = files.stop()
        let ordered = walk.items.keys.sorted()
        for (position, index) in ordered.enumerated() {
            guard let item = walk.items[index] else { continue }
            let next = position + 1 < ordered.count ? walk.items[ordered[position + 1]]?.begin : nil
            let until = (next ?? (item.end ?? item.begin) + 1) + 0.3
            var home: Set<String> = [], realSafari: Set<String> = [], outside: Set<String> = []
            for change in changes where change.time >= item.begin + 0.1 && change.time < until {
                let path = change.path
                if ignored.contains(where: { path.hasPrefix($0) }) { continue }
                if let prefix = ours.first(where: { path.hasPrefix($0) }) {
                    home.insert(String(path.dropFirst(prefix.count)))
                } else if SafariPaths.isRealSafariPlace(path, realHome: realHome) {
                    realSafari.insert(path)
                } else if path.hasPrefix(realHome) {
                    outside.insert("~" + path.dropFirst(realHome.count))
                } else {
                    outside.insert(path)
                }
            }
            item.fields["event"] = nil
            item.fields["home"] = home.sorted()
            item.fields["realSafari"] = realSafari.sorted()
            item.fields["outside"] = outside.sorted()
            item.fields["xpc"] = item.xpc
            item.fields["agents"] = item.agents
            item.fields["effects"] = (item.fields["effects"] as? [String] ?? []) + item.asked
            item.fields["begin"] = item.begin
            guard let data = try? JSONSerialization.data(withJSONObject: item.fields, options: [.sortedKeys]) else { continue }
            print("MENUWALK " + String(decoding: data, as: UTF8.self))
        }
        let keysAfter = Set(UserDefaults.standard.persistentDomain(forName: preferencesDomain)?.keys.map { $0 } ?? [])
        print("MENUWALK-INFO the app's own preferences (\(preferencesDomain)) in the account's home: keys added during the walk "
              + "\(keysAfter.subtracting(keysBefore).sorted())")
        let safariAfter = PreferencesFile(path: safariPreferences)
        let added = (safariAfter?.keys ?? []).subtracting(safariBefore?.keys ?? []).sorted()
        print("MENUWALK-INFO the account's ~/Library/Preferences/com.apple.Safari.plist: before the walk "
              + (safariBefore?.summary ?? "absent") + ", after it " + (safariAfter?.summary ?? "absent")
              + "; keys added \(added)")
        print("MENUWALK-INFO walked \(walk.items.count) of \(walk.count ?? 0) items in \(launches) launch(es); "
              + (walk.done ? "the walk got to the end" : "the walk did NOT get to the end"))
        return walk.done ? 0 : 1
    }
}

/// A property list's top-level keys and when it was last written, read as a file.
private struct PreferencesFile {
    let keys: Set<String>
    let modified: Date

    init?(path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        keys = Set(plist.keys)
        self.modified = modified
    }

    var summary: String { "\(keys.count) keys, written \(modified)" }
}

/// The files written under some folders, as FSEvents tells them, with when it told: the menu walk
/// says which were written while an item ran (`SafariMenuWalkCheck`).
final class FileChangeWatch: @unchecked Sendable {
    struct Change {
        let time: Double
        let path: String
    }

    private let lock = NSLock()
    private var changes: [Change] = []
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "PrivacyBrowser.FileChangeWatch")

    init(paths: [String]) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watch = Unmanaged<FileChangeWatch>.fromOpaque(info).takeUnretainedValue()
            let names = Unmanaged<NSArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watch.record(names)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func record(_ names: [String]) {
        let now = Date().timeIntervalSince1970
        lock.withLock { changes.append(contentsOf: names.map { Change(time: now, path: $0) }) }
    }

    /// Stops watching: every change told so far.
    func stop() -> [Change] {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        return lock.withLock { changes }
    }
}
