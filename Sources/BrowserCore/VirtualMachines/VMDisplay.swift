import Foundation

/// The screen a virtual machine's macOS has. A page reads the screen's size and pixel ratio
/// (`screen.width`, `devicePixelRatio`), so the guest gets the screen of a Mac people own — one of
/// these — and never the size its window on this Mac happens to have: the window shows that screen
/// scaled.
public struct VMDisplay: Equatable, Identifiable, Sendable {
    public let id: String
    /// The Mac whose screen it is, as the list names it ("MacBook Air 13″").
    public let name: String
    /// What a page reads: `screen.width` × `screen.height`, in points.
    public let pointsWide: Int
    public let pointsHigh: Int
    /// 2 on a Retina screen (`devicePixelRatio`), 1 on an ordinary external one.
    public let scale: Int
    public let pixelsPerInch: Int

    public var pixelsWide: Int { pointsWide * scale }
    public var pixelsHigh: Int { pointsHigh * scale }

    /// Each as that Mac has it out of the box (its default "looks like" size).
    public static let presets: [VMDisplay] = [
        VMDisplay(id: "macbook-air-13", name: "MacBook Air 13″", pointsWide: 1470, pointsHigh: 956, scale: 2, pixelsPerInch: 224),
        // "More Space" in Displays: what many people with a small screen choose.
        VMDisplay(id: "macbook-air-13-more", name: "MacBook Air 13″ · More Space", pointsWide: 1710, pointsHigh: 1112, scale: 2, pixelsPerInch: 224),
        VMDisplay(id: "macbook-air-15", name: "MacBook Air 15″", pointsWide: 1710, pointsHigh: 1107, scale: 2, pixelsPerInch: 224),
        VMDisplay(id: "macbook-pro-14", name: "MacBook Pro 14″", pointsWide: 1512, pointsHigh: 982, scale: 2, pixelsPerInch: 254),
        VMDisplay(id: "macbook-pro-14-more", name: "MacBook Pro 14″ · More Space", pointsWide: 1800, pointsHigh: 1169, scale: 2, pixelsPerInch: 254),
        VMDisplay(id: "macbook-pro-16", name: "MacBook Pro 16″", pointsWide: 1728, pointsHigh: 1117, scale: 2, pixelsPerInch: 254),
        VMDisplay(id: "macbook-pro-16-more", name: "MacBook Pro 16″ · More Space", pointsWide: 2056, pointsHigh: 1329, scale: 2, pixelsPerInch: 254),
        VMDisplay(id: "imac-24", name: "iMac 24″", pointsWide: 2240, pointsHigh: 1260, scale: 2, pixelsPerInch: 218),
        VMDisplay(id: "external-1080p", name: "Mac mini, 1920 × 1080", pointsWide: 1920, pointsHigh: 1080, scale: 1, pixelsPerInch: 92),
        VMDisplay(id: "external-1440p", name: "Mac mini, 2560 × 1440", pointsWide: 2560, pointsHigh: 1440, scale: 1, pixelsPerInch: 109),
        VMDisplay(id: "external-4k", name: "Mac mini, 4K", pointsWide: 1920, pointsHigh: 1080, scale: 2, pixelsPerInch: 163),
    ]

    /// The most common Mac's.
    public static let standard = presets[0]

    /// The preset `id` names; the standard one for an id this version does not know.
    public static func preset(_ id: String) -> VMDisplay {
        presets.first { $0.id == id } ?? standard
    }
}

/// What a virtual machine costs and needs, as numbers the setup screen shows and checks before
/// anything is downloaded.
public enum VMRequirements {
    public static let gibibyte: Int64 = 1 << 30

    /// The machine's disk as the guest sees it. Sparse: only what the guest wrote takes room.
    public static let diskImageBytes: Int64 = 64 * gibibyte
    /// What an installed, set-up macOS takes of that, roughly (the base every profile is a
    /// copy-on-write clone of).
    public static let installedBaseBytes: Int64 = 22 * gibibyte
    /// What a profile's own changes come to with use, roughly.
    public static let profileGrowthBytes: Int64 = 4 * gibibyte

    public static let memoryChoices = [3, 4, 6, 8]
    /// The processors a profile may ask for instead of a Mac's eight: fewer spare this Mac.
    public static let coreChoices = [4, 6, 8]
    public static let standardMemoryGB = 4
    /// Safari reports at most 8 cores, and no Mac with Apple silicon has fewer: a machine with
    /// fewer would be told apart. Virtual cores cost no memory.
    public static let coresWanted = 8
    /// Apple's limit of macOS virtual machines running at once on one Mac.
    public static let runningLimit = 2

    /// Free room the setup needs: the restore image (deleted once installed), the base, and a
    /// tenth to spare.
    public static func setupBytes(downloadBytes: Int64) -> Int64 {
        let needed = downloadBytes + installedBaseBytes
        return needed + needed / 10
    }

    public enum Problem: Equatable, Sendable {
        /// Not a Mac with Apple silicon: macOS runs as a guest only there.
        case notAppleSilicon
        /// The build cannot run the machines' helper (the sandboxed build).
        case unavailableInThisBuild
        case notEnoughDisk(needed: Int64, free: Int64)
        /// With the machine's memory taken, this Mac keeps less than 4 GiB.
        case littleMemory(machine: Int64, host: Int64)
    }

    /// What stands in the way of setting the machines up on this Mac. Memory is a warning the
    /// screen shows, not a refusal; the others stop it.
    public static func problems(appleSilicon: Bool, helperAvailable: Bool, freeDisk: Int64, downloadBytes: Int64,
                                hostMemory: Int64, machineMemoryGB: Int = standardMemoryGB) -> [Problem] {
        var problems: [Problem] = []
        if !appleSilicon { problems.append(.notAppleSilicon) }
        if !helperAvailable { problems.append(.unavailableInThisBuild) }
        let needed = setupBytes(downloadBytes: downloadBytes)
        if freeDisk < needed { problems.append(.notEnoughDisk(needed: needed, free: freeDisk)) }
        let machine = Int64(machineMemoryGB) * gibibyte
        if hostMemory - machine < 4 * gibibyte { problems.append(.littleMemory(machine: machine, host: hostMemory)) }
        return problems
    }

    public static func stops(_ problem: Problem) -> Bool {
        if case .littleMemory = problem { return false }
        return true
    }

    /// Cores a machine gets on a Mac with `hostCores`: eight, or all there are.
    public static func cores(hostCores: Int) -> Int { max(2, min(coresWanted, hostCores)) }

    /// Host names the machines' network answers "no such name" for (`VMNetCore`): Apple's software
    /// update and its downloads. A guest left to itself would fetch gigabytes of updates through a
    /// proxy that is paid by the gigabyte; no page can tell they were not fetched. Certificate
    /// checks (ocsp.apple.com) and everything else stay reachable.
    public static let blockedHosts = [
        "swscan.apple.com", "swcdn.apple.com", "swdist.apple.com", "swdownload.apple.com",
        "updates.cdn-apple.com", "updates-http.cdn-apple.com", "gdmf.apple.com", "mesu.apple.com",
        "appldnld.apple.com", "oscdn.apple.com", "osrecovery.apple.com", "devimages-cdn.apple.com",
    ]
}
