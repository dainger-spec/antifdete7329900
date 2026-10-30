import AppKit
import BrowserCore
import Darwin
import Foundation
import SwiftUI

/// `PrivacyBrowser --scale-check [--profiles 200] [--running 1,5,10,20] [--quit 10] [--out DIR]`
/// (CI): how the app holds up with many profiles, in numbers. Nobody had measured it; the owner
/// has 22 profiles and had never run more than ten at once.
///
///   1. Creating: the profiles made one by one as the app makes them (`ProfileRepository.create`),
///      each timed, and what the vault then takes on disk.
///   2. The list: what the Profiles window does to show them — the index read, each profile's
///      settings decrypted (`AppModel.refresh`), the rows built — and its search and filters run
///      over all of them (`ProfilesScreen.matches`, `ProfileFilter`), timed and checked against
///      what they must find; the window itself drawn with every row (`profiles-<N>.png`).
///   3. Running: groups of profiles launched as the list's Launch does for a selection (one after
///      the other, each in a process of its own with Safari's window, its start page loading
///      through the self-test proxy), the time until each window is up, then what they take — each
///      profile's processes (its own and WebKit's that work for it) by memory footprint, the
///      machine's free memory, compression and swap, and how busy its processors were — and
///      the time to stop them all.
///   4. Quitting: profiles running with a cookie set by their pages, the app's quit (every one
///      stopped and sealed at once), how long it took and how each seal went, then each launched
///      again on a page that sets nothing, and its cookie looked for: none may be lost.
///
/// `PB_SELFTEST_HTTP_PROXY_PORT` names the self-test proxy (scripts/scale_check.py starts it).
/// One `SCALE` line of JSON per measurement; the script makes the report. A measurement: exit 0
/// when every step ran, 1 when one could not.
@MainActor
enum ScaleCheck {
    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        // A process of its own per profile, with Safari's window, as the build without the App
        // Sandbox runs profiles.
        setenv("PB_PROFILE_PROCESS", "1", 1)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3300) {
            print("SCALE-ERROR did not finish in 55 minutes")
            exit(1)
        }
        Task { @MainActor in exit(await run(arguments: arguments)) }
        application.run()
    }

    private static func value(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func report(_ step: String, _ fields: [String: Any]) {
        var line = fields
        line["step"] = step
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        print("SCALE " + String(decoding: data, as: UTF8.self))
    }

    private static func milliseconds(since start: Date) -> Double {
        (Date().timeIntervalSince(start) * 100_000).rounded() / 100
    }

    private static func run(arguments: [String]) async -> Int32 {
        guard !AppEnvironment.isSandboxed else {
            print("SCALE-ERROR the sandboxed build runs no process per profile")
            return 1
        }
        let count = value("--profiles", in: arguments).flatMap(Int.init) ?? 200
        let groups = (value("--running", in: arguments) ?? "1,5,10,20").split(separator: ",").compactMap { Int($0) }
        let quitting = value("--quit", in: arguments).flatMap(Int.init) ?? 10
        let out = URL(fileURLWithPath: value("--out", in: arguments) ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        let port = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init)
        guard let port else {
            print("SCALE-ERROR PB_SELFTEST_HTTP_PROXY_PORT is not set: the profiles' pages need the self-test proxy")
            return 1
        }
        let proxy = ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: port)
        report("machine", ["macOS": ProcessInfo.processInfo.operatingSystemVersionString, "safari": HostSafari.version,
                           "processors": ProcessInfo.processInfo.activeProcessorCount,
                           "memoryMB": Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576])

        // 1. Creating.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-scale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository: ProfileRepository
        let vaultStart = Date()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "scale-check"))
        } catch {
            print("SCALE-ERROR no vault: \(error)")
            return 1
        }
        report("vault", ["createdMs": milliseconds(since: vaultStart)])
        let marker = String(UUID().uuidString.prefix(8)).lowercased()
        var ids: [UUID] = []
        var times: [Double] = []
        let sizeBefore = size(of: root)
        for index in 0..<count {
            var configuration = ProfileConfiguration(
                startURL: URL(string: "http://scale-\(index).selftest.invalid/pb-warmup/scale\(index)?run=\(marker)"),
                proxy: index % 3 == 2 ? nil : proxy, matchProxyLocation: false)
            configuration.tags = ["team-\(index % 7)"] + (index % 4 == 0 ? ["ads"] : [])
            configuration.notes = "Client \(index): seller account, region \(index % 11)"
            let started = Date()
            do {
                ids.append(try repository.create(name: "Profile \(String(format: "%03d", index))", configuration: configuration).id)
            } catch {
                print("SCALE-ERROR profile \(index) was not made: \(error)")
                return 1
            }
            times.append(milliseconds(since: started))
        }
        let sizeAfter = size(of: root)
        report("create", ["profiles": count, "totalMs": times.reduce(0, +), "medianMs": median(times), "maxMs": times.max() ?? 0,
                          "firstTenMs": Array(times.prefix(10)), "lastTenMs": Array(times.suffix(10)),
                          "vaultBytes": sizeAfter, "bytesPerProfile": Double(sizeAfter - sizeBefore) / Double(max(count, 1))])

        // 2. The list.
        var refreshTimes: [Double] = []
        var rows: [ProfileRowItem] = []
        for _ in 0..<5 {
            let started = Date()
            let profiles = repository.list()
            var details: [UUID: ProfileDetails] = [:]
            for profile in profiles {
                if let configuration = try? repository.loadConfiguration(profile.id) { details[profile.id] = ProfileDetails(configuration) }
            }
            rows = profiles.map { profile in
                let detail = details[profile.id]
                return ProfileRowItem(
                    id: profile.id, name: profile.name, activity: .stopped,
                    exit: detail?.proxyEndpoint.map { ProfileExit.proxy(endpoint: $0, countryCode: detail?.exitCountryCode) } ?? .direct,
                    ephemeral: detail?.ephemeral ?? false,
                    appearsAs: ProfileRowItem.appearsAs(detail?.deviceGeneration ?? DeviceGenerations.resolved(id: nil)),
                    lastUsed: profile.lastLaunchedAt, tags: detail?.tags ?? [], notes: detail?.notes ?? "", avatar: detail?.avatar)
            }
            refreshTimes.append(milliseconds(since: started))
        }
        report("list", ["rows": rows.count, "refreshMedianMs": median(refreshTimes), "refreshMs": refreshTimes])
        let expectedProxied = (0..<count).filter { $0 % 3 != 2 }.count
        let expectedTag = (0..<count).filter { $0 % 7 == 3 }.count
        let expectedAds = (0..<count).filter { $0 % 4 == 0 }.count
        var searches: [[String: Any]] = []
        for (query, expected) in [("Profile 1", (0..<count).filter { String(format: "%03d", $0).hasPrefix("1") }.count),
                                  ("team-3", expectedTag), ("ads", expectedAds), ("region 10", (0..<count).filter { $0 % 11 == 10 }.count),
                                  ("no such profile", 0)] {
            let started = Date()
            var found = 0
            for _ in 0..<20 { found = rows.filter { ProfilesScreen.matches($0, query) }.count }
            searches.append(["query": query, "found": found, "expected": expected, "ms": milliseconds(since: started) / 20,
                             "right": found == expected])
        }
        report("search", ["queries": searches])
        var filters: [[String: Any]] = []
        let filterCases: [(ProfileFilter, Int)] = [(.all, count), (.proxied, expectedProxied), (.ephemeral, 0), (.tag("TEAM-3"), expectedTag)]
        for (filter, expected) in filterCases {
            let started = Date()
            var found = 0
            for _ in 0..<20 { found = rows.filter { filter.includes($0) }.count }
            filters.append(["filter": filter.title, "found": found, "expected": expected, "ms": milliseconds(since: started) / 20,
                            "right": found == expected])
        }
        let tagsStarted = Date()
        let tags = ProfileFilter.tags(of: rows)
        report("filter", ["filters": filters, "tags": tags.count, "tagsExpected": 8, "tagsMs": milliseconds(since: tagsStarted)])
        let drawStarted = Date()
        let drawn = await draw(rows, into: out.appendingPathComponent("profiles-\(count).png"))
        report("draw", ["rows": rows.count, "ms": milliseconds(since: drawStarted), "written": drawn])

        // 3. Running.
        let manager = ProfileManager(repository: repository)
        var running: [UUID: Date] = [:]
        var seals: [UUID: ProfileSealReport] = [:]
        var errors: [String] = []
        manager.onProfileRunning = { id, _ in running[id] = Date() }
        manager.onChildSealed = { id, sealed in seals[id] = sealed }
        manager.onError = { message in errors.append(message) }
        let proxiedIDs = ids.enumerated().filter { $0.offset % 3 != 2 }.map { $0.element }
        var offset = 0
        for groupSize in groups {
            guard offset + groupSize <= proxiedIDs.count else { break }
            let group = Array(proxiedIDs[offset..<(offset + groupSize)])
            offset += groupSize
            running = [:]
            errors = []
            let cpuBefore = cpuTicks()
            let batchStart = Date()
            var launchCalls: [UUID: Date] = [:]
            for id in group {
                launchCalls[id] = Date()
                do { try await manager.launch(id) } catch { errors.append("launch: \(error)") }
            }
            let allIssued = milliseconds(since: batchStart)
            let deadline = Date().addingTimeInterval(60 + Double(groupSize) * 6)
            while running.count < group.count, Date() < deadline { try? await Task.sleep(nanoseconds: 250_000_000) }
            let startTimes = group.compactMap { id in running[id].map { $0.timeIntervalSince(launchCalls[id] ?? batchStart) * 1000 } }
            let windowsUp = group.compactMap { id in running[id].map { $0.timeIntervalSince(batchStart) * 1000 } }
            // The pages load and the machine settles; then what they take.
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            let cpuAfter = cpuTicks()
            var perProfile: [[String: Any]] = []
            var totalMB = 0.0
            for id in group {
                guard let pid = manager.processIdentifier(of: id) else { continue }
                let processes = family(of: pid)
                let megabytes = processes.reduce(0.0) { $0 + $1.megabytes }
                totalMB += megabytes
                perProfile.append(["pid": Int(pid), "MB": (megabytes * 10).rounded() / 10,
                                   "processes": processes.map { "\($0.name) \(Int($0.megabytes)) MB" }])
            }
            let busy: Double? = {
                guard let before = cpuBefore, let after = cpuAfter, after.total > before.total else { return nil }
                return (Double(after.busy - before.busy) / Double(after.total - before.total) * 1000).rounded() / 10
            }()
            let stopStart = Date()
            await withTaskGroup(of: Void.self) { tasks in
                for id in group where manager.isRunning(id) {
                    tasks.addTask { @MainActor in try? await manager.stop(id) }
                }
            }
            let stopMs = milliseconds(since: stopStart)
            report("run", ["profiles": groupSize, "windowsUp": running.count, "launchCallsMs": allIssued,
                           "startMedianMs": median(startTimes), "startMaxMs": startTimes.max() ?? 0,
                           "allWindowsUpMs": windowsUp.max() ?? 0, "memoryMB": (totalMB * 10).rounded() / 10,
                           "memoryPerProfileMB": group.isEmpty ? 0 : (totalMB / Double(group.count) * 10).rounded() / 10,
                           "cpuBusyPercent": busy ?? -1, "machine": machineMemory(), "stopAllMs": stopMs,
                           "errors": errors, "each": perProfile])
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }

        // 4. Quitting with profiles running, and nothing lost.
        let quitGroup = Array(proxiedIDs.prefix(quitting))
        running = [:]
        seals = [:]
        errors = []
        for id in quitGroup {
            do { try await manager.launch(id) } catch { errors.append("launch: \(error)") }
        }
        let quitDeadline = Date().addingTimeInterval(120)
        while running.count < quitGroup.count, Date() < quitDeadline { try? await Task.sleep(nanoseconds: 250_000_000) }
        // The start pages set their cookie as they load.
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        let upBeforeQuit = running.count
        let quitStart = Date()
        manager.prepareForQuit()
        await manager.shutDown()
        let quitMs = milliseconds(since: quitStart)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let sealSeconds = quitGroup.compactMap { seals[$0]?.seconds }
        report("quit", ["profiles": quitGroup.count, "runningAtQuit": upBeforeQuit, "quitMs": quitMs,
                        "sealsReported": seals.count, "sealMedianS": median(sealSeconds), "sealMaxS": sealSeconds.max() ?? 0,
                        "forced": seals.values.filter(\.forced).count, "errors": errors])

        // Each launched again on a page that sets nothing; its cookie must still be there.
        let checker = ProfileManager(repository: repository)
        var checkerRunning: Set<UUID> = []
        checker.onProfileRunning = { id, _ in checkerRunning.insert(id) }
        var kept = 0
        var missing: [String] = []
        for id in quitGroup {
            guard var configuration = try? repository.loadConfiguration(id),
                  let index = ids.firstIndex(of: id) else { continue }
            configuration.startURL = URL(string: "http://scale-\(index).selftest.invalid/pb-cookies")
            try? repository.saveConfiguration(configuration, for: id)
            do { try await checker.launch(id) } catch { missing.append("profile \(index): no launch (\(error))"); continue }
            let deadline = Date().addingTimeInterval(60)
            while !checkerRunning.contains(id), Date() < deadline { try? await Task.sleep(nanoseconds: 250_000_000) }
            let cookies = (try? await checker.exportCookies(of: id)) ?? []
            if cookies.contains(where: { $0.name == "pbwarm_scale\(index)" && $0.value == marker }) {
                kept += 1
            } else {
                missing.append("profile \(index): \(cookies.count) cookie(s), not its own")
            }
            try? await checker.stop(id)
        }
        report("kept", ["profiles": quitGroup.count, "cookieKept": kept, "missing": missing])

        // With every profile in the vault, one more launch still works.
        let lastID = ids[ids.count - 1]
        let lastStart = Date()
        var lastUp = false
        checker.onProfileRunning = { id, _ in if id == lastID { lastUp = true } }
        do { try await checker.launch(lastID) } catch { errors.append("last launch: \(error)") }
        let lastDeadline = Date().addingTimeInterval(60)
        while !lastUp, Date() < lastDeadline { try? await Task.sleep(nanoseconds: 250_000_000) }
        report("launch-last", ["profiles": count, "up": lastUp, "ms": milliseconds(since: lastStart)])
        try? await checker.stop(lastID)
        print("SCALE-DONE")
        return 0
    }

    // MARK: Measuring

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return (sorted[sorted.count / 2] * 100).rounded() / 100
    }

    /// The bytes of every file under `url`.
    private static func size(of url: URL) -> Int {
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total = 0
        for case let file as URL in files {
            total += (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
        }
        return total
    }

    /// A profile's process and the processes that work for it (WebKit's, the services it started),
    /// by the system's record of which process is responsible for which, with their footprints.
    private static func family(of pid: pid_t) -> [(name: String, megabytes: Double)] {
        var found: [(name: String, megabytes: Double)] = []
        for candidate in allProcesses() where candidate == pid || XPCServiceWatch.responsible(for: candidate) == pid {
            guard let bytes = footprint(of: candidate) else { continue }
            found.append((name: name(of: candidate), megabytes: Double(bytes) / 1_048_576))
        }
        return found.sorted { $0.megabytes > $1.megabytes }
    }

    private static func allProcesses() -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return count > 0 ? pids.prefix(Int(count)).filter { $0 > 0 } : []
    }

    private static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "pid \(pid)"
    }

    /// The machine's processor ticks, busy and in all.
    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (busy: user + system + nice, total: user + system + idle + nice)
    }

    /// Free and compressed memory and swap in use, in megabytes.
    private static func machineMemory() -> [String: Double] {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapRead = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        let page = Double(sysconf(Int32(_SC_PAGESIZE)))
        let mb = { (pages: UInt64) in (Double(pages) * page / 1_048_576 * 10).rounded() / 10 }
        guard result == KERN_SUCCESS else { return ["swapUsedMB": swapRead ? Double(swap.xsu_used) / 1_048_576 : -1] }
        return ["freeMB": mb(UInt64(stats.free_count)), "inactiveMB": mb(UInt64(stats.inactive_count)),
                "compressedMB": mb(UInt64(stats.compressor_page_count)),
                "swapUsedMB": swapRead ? (Double(swap.xsu_used) / 1_048_576 * 10).rounded() / 10 : -1]
    }

    /// The Profiles window's screen with every row, drawn into a PNG as the UI snapshots are.
    private static func draw(_ rows: [ProfileRowItem], into url: URL) async -> Bool {
        let size = CGSize(width: 1180, height: 900)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let host = NSHostingView(rootView: ProfilesScreen(rows: rows, filter: .constant(.all), search: .constant(""))
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        window.contentView = host
        window.setContentSize(size)
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        host.layoutSubtreeIfNeeded()
        host.display()
        defer {
            window.orderOut(nil)
            window.close()
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
