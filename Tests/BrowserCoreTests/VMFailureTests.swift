import Foundation
import XCTest
@testable import BrowserCore

/// What a machine's failure is said as (`VMFailureKind`): the kind the app has words for, decided
/// from the system's error — its domain and code, and those of the errors under it — and from the
/// helper's own; how the helper's events carry it; and what is said before a start onto a disk
/// that is nearly full (`VMStartRoom`).
final class VMFailureTests: XCTestCase {
    private func error(_ domain: String, _ code: Int, under: NSError? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let under { info[NSUnderlyingErrorKey] = under }
        return NSError(domain: domain, code: code, userInfo: info)
    }

    // MARK: - The kind of an error

    func testVirtualizationsErrorsAreKindsByTheirCodes() {
        let expected: [Int: VMFailureKind] = [
            2: .configuration, 5: .disk, 6: .limit, 8: .noRoom, 10: .notSupportedHere,
            10001: .catalog, 10002: .catalog, 10003: .nothingOffered, 10004: .image, 10005: .image,
            10006: .needsUpdate, 10007: .installation,
        ]
        for (code, kind) in expected {
            XCTAssertEqual(VMFailureKind(domain: "VZErrorDomain", code: code), kind, "VZErrorDomain \(code)")
        }
        // An internal error, a state it was not in, a cancelled operation, a save or a restore:
        // nothing the app can say more of than the system does.
        for code in [1, 3, 4, 7, 9, 11, 12, 20001, 30001, 0, -1] {
            XCTAssertNil(VMFailureKind(domain: "VZErrorDomain", code: code), "VZErrorDomain \(code)")
        }
    }

    func testAFullDiskAndMissingFilesAreKindsWhicheverPartOfTheSystemSaysSo() {
        XCTAssertEqual(VMFailureKind(domain: "NSPOSIXErrorDomain", code: 28), .noRoom)
        XCTAssertEqual(VMFailureKind(domain: "NSPOSIXErrorDomain", code: 69), .noRoom)
        XCTAssertEqual(VMFailureKind(domain: "NSCocoaErrorDomain", code: 640), .noRoom)
        XCTAssertEqual(VMFailureKind(domain: "NSPOSIXErrorDomain", code: 2), .files)
        XCTAssertEqual(VMFailureKind(domain: "NSPOSIXErrorDomain", code: 13), .files)
        XCTAssertEqual(VMFailureKind(domain: "NSCocoaErrorDomain", code: 260), .files)
        XCTAssertEqual(VMFailureKind(domain: "NSCocoaErrorDomain", code: 257), .files)
        XCTAssertEqual(VMFailureKind(domain: "NSCocoaErrorDomain", code: 4), .files)
        // The same number in another domain is another error.
        XCTAssertNil(VMFailureKind(domain: "NSURLErrorDomain", code: 28))
        XCTAssertNil(VMFailureKind(domain: "NSCocoaErrorDomain", code: 8))
        XCTAssertNil(VMFailureKind(domain: "NSPOSIXErrorDomain", code: 6))
        XCTAssertNil(VMFailureKind(domain: "", code: 640))
    }

    func testAFullDiskUnderAnotherErrorIsTheReason() {
        // "The installation failed", and under it the disk that was full.
        let installation = error("VZErrorDomain", 10007, under: error("NSPOSIXErrorDomain", 28))
        XCTAssertEqual(VMFailureKind.of(installation), .noRoom)
        // A state that was not saved (no kind of its own) because the disk was full, two deep.
        let save = error("VZErrorDomain", 11, under: error("NSCocoaErrorDomain", 512, under: error("NSPOSIXErrorDomain", 28)))
        XCTAssertEqual(VMFailureKind.of(save), .noRoom)
        XCTAssertEqual(VMFailureKind.causes(of: save),
                       [.init(domain: "VZErrorDomain", code: 11), .init(domain: "NSCocoaErrorDomain", code: 512),
                        .init(domain: "NSPOSIXErrorDomain", code: 28)])
        // Otherwise the outermost error the app has words for.
        XCTAssertEqual(VMFailureKind.of(error("VZErrorDomain", 10007, under: error("NSPOSIXErrorDomain", 2))), .installation)
        XCTAssertEqual(VMFailureKind.of(error("VZErrorDomain", 1, under: error("VZErrorDomain", 6))), .limit)
        // Nothing known anywhere: no kind, and the system's words stand alone.
        XCTAssertNil(VMFailureKind.of(error("VZErrorDomain", 1, under: error("NSMachErrorDomain", 5))))
        XCTAssertNil(VMFailureKind.of([]))
    }

    func testAChainThatNeverEndsIsReadSixDeep() {
        var deepest = error("NSPOSIXErrorDomain", 28)
        for _ in 0..<10 { deepest = error("VZErrorDomain", 1, under: deepest) }
        XCTAssertEqual(VMFailureKind.causes(of: deepest).count, 6)
        XCTAssertNil(VMFailureKind.of(deepest), "a reason ten errors down is not looked for")
    }

    func testTheHelpersOwnFailuresCarryTheirKind() {
        let own = VMFailure(.noBase, "The base system is not installed.")
        XCTAssertEqual(VMFailureKind.of(own), .noBase)
        XCTAssertEqual(own.errorDescription, "The base system is not installed.")
        XCTAssertEqual(own, VMFailure(.noBase, "The base system is not installed."))
    }

    func testEveryKindHasAWordOfItsOwn() {
        XCTAssertEqual(Set(VMFailureKind.allCases.map(\.rawValue)),
                       ["noRoom", "limit", "disk", "files", "notSupportedHere", "configuration", "noBase", "catalog",
                        "nothingOffered", "image", "needsUpdate", "installation"])
    }

    // MARK: - What the helper says

    func testAFailureAndAStateNotKeptSayTheirKind() throws {
        let failed = VMHelperEvent(kind: .failed, message: "The operation couldn’t be completed. No space left on device",
                                   failure: VMFailureKind.noRoom.rawValue)
        let read = try XCTUnwrap(VMHelperEvent.parse(failed.line()))
        XCTAssertEqual(read, failed)
        XCTAssertEqual(read.failureKind, .noRoom)
        XCTAssertFalse(failed.line().contains("\n"))
        // A failure of no kind the app knows — or of a kind a later helper names — has none.
        XCTAssertNil(VMHelperEvent(kind: .failed, message: "Internal Virtualization error.").failureKind)
        XCTAssertNil(VMHelperEvent.parse(#"{"kind":"failed","message":"x","failure":"a later kind"}"#)?.failureKind)
        XCTAssertNil(VMHelperEvent.parse(#"{"kind":"failed","message":"x"}"#)?.failure)
        // A machine with instant wake whose state was not saved: said, with why.
        let notKept = VMHelperEvent(kind: .notKept, message: "The virtual machine’s state could not be saved.", failure: "noRoom")
        let said = try XCTUnwrap(VMHelperEvent.parse(notKept.line()))
        XCTAssertEqual(said.kind, .notKept)
        XCTAssertEqual(said.failureKind, .noRoom)
        XCTAssertEqual(VMHelperEvent.parse(#"{"kind":"notKept"}"#)?.kind, .notKept)
        XCTAssertNil(VMHelperEvent.parse(#"{"kind":"notKept"}"#)?.failureKind)
    }

    // MARK: - Room for a start

    func testAMachineIsNotStartedOntoADiskThatIsNearlyFull() {
        let gigabyte = VMRequirements.gibibyte
        XCTAssertEqual(VMStartRoom.floorBytes, 2 * gigabyte)
        // Room enough: nothing in the way, made or not, cloning or not known.
        XCTAssertNil(VMStartRoom.problem(free: 40 * gigabyte, isMade: true, volumeClones: true, baseDiskBytes: 0))
        XCTAssertNil(VMStartRoom.problem(free: 40 * gigabyte, isMade: false, volumeClones: nil, baseDiskBytes: 22 * gigabyte))
        XCTAssertNil(VMStartRoom.problem(free: 2 * gigabyte, isMade: true, volumeClones: true, baseDiskBytes: 0))
        // Less than the floor: said with the numbers.
        XCTAssertEqual(VMStartRoom.problem(free: 2 * gigabyte - 1, isMade: true, volumeClones: true, baseDiskBytes: 0),
                       .full(needed: 2 * gigabyte, free: 2 * gigabyte - 1))
        XCTAssertEqual(VMStartRoom.problem(free: 0, isMade: false, volumeClones: true, baseDiskBytes: 22 * gigabyte),
                       .full(needed: 2 * gigabyte, free: 0))
        // What the system does not say is not guessed at.
        XCTAssertNil(VMStartRoom.problem(free: nil, isMade: true, volumeClones: true, baseDiskBytes: 0))
        XCTAssertNil(VMStartRoom.problem(free: nil, isMade: false, volumeClones: false, baseDiskBytes: 22 * gigabyte))
    }

    func testAMachineNotMadeYetNeedsRoomForAWholeCopyOnlyWhereTheVolumeCannotClone() {
        let gigabyte = VMRequirements.gibibyte
        // A volume that clones: the new machine's disk takes no room until it differs.
        XCTAssertNil(VMStartRoom.problem(free: 5 * gigabyte, isMade: false, volumeClones: true, baseDiskBytes: 22 * gigabyte))
        // One that cannot: the base's whole disk, and the floor.
        XCTAssertEqual(VMStartRoom.problem(free: 5 * gigabyte, isMade: false, volumeClones: false, baseDiskBytes: 22 * gigabyte),
                       .copy(needed: 24 * gigabyte, free: 5 * gigabyte))
        XCTAssertEqual(VMStartRoom.problem(free: 24 * gigabyte - 1, isMade: false, volumeClones: false, baseDiskBytes: 22 * gigabyte),
                       .copy(needed: 24 * gigabyte, free: 24 * gigabyte - 1))
        XCTAssertNil(VMStartRoom.problem(free: 24 * gigabyte, isMade: false, volumeClones: false, baseDiskBytes: 22 * gigabyte))
        // A machine that has its disk is not copied again.
        XCTAssertNil(VMStartRoom.problem(free: 5 * gigabyte, isMade: true, volumeClones: false, baseDiskBytes: 22 * gigabyte))
        // Where the system does not say whether the volume clones, it is taken as cloning.
        XCTAssertNil(VMStartRoom.problem(free: 5 * gigabyte, isMade: false, volumeClones: nil, baseDiskBytes: 22 * gigabyte))
    }
}

/// Where a machine's window opens (`VMWindowPlacement`): where the person left it, while that
/// place is still a place — and as a new window otherwise.
final class VMWindowPlacementTests: XCTestCase {
    private typealias Rect = VMWindowPlacement.Rect
    /// A MacBook's screen under the menu bar, and a display to its right.
    private let laptop = Rect(x: 0, y: 0, width: 1470, height: 923)
    private let external = Rect(x: 1470, y: -100, width: 2560, height: 1415)

    private func kept(_ frame: Rect, pixels: (Int, Int) = (2940, 1912)) -> VMWindowPlacement {
        VMWindowPlacement(frame: frame, pixelsWide: pixels.0, pixelsHigh: pixels.1)
    }

    func testTheWindowOpensWhereItWasLeft() {
        let onLaptop = Rect(x: 60, y: 80, width: 1100, height: 743)
        XCTAssertEqual(kept(onLaptop).restored(onScreens: [laptop], pixelsWide: 2940, pixelsHigh: 1912), onLaptop)
        // On the second display, as large as the person made it there.
        let onExternal = Rect(x: 1600, y: -60, width: 1960, height: 1303)
        XCTAssertEqual(kept(onExternal).restored(onScreens: [laptop, external], pixelsWide: 2940, pixelsHigh: 1912), onExternal)
        // Its title bar above the display's top would be out of reach: not gone back to.
        XCTAssertNil(kept(Rect(x: 1600, y: 40, width: 1960, height: 1303)).restored(onScreens: [laptop, external], pixelsWide: 2940, pixelsHigh: 1912))
        // Partly off a screen's edge is still where it was left, while its title bar is in reach.
        let overTheEdge = Rect(x: 1000, y: -300, width: 1100, height: 743)
        XCTAssertEqual(kept(overTheEdge).restored(onScreens: [laptop], pixelsWide: 2940, pixelsHigh: 1912), overTheEdge)
    }

    func testAPlaceThatIsNoLongerOneIsNotGoneBackTo() {
        let onExternal = Rect(x: 1600, y: -60, width: 1960, height: 1303)
        // The display it was on is not connected: nothing of it is on the screen there is.
        XCTAssertNil(kept(onExternal).restored(onScreens: [laptop], pixelsWide: 2940, pixelsHigh: 1912))
        XCTAssertNil(kept(onExternal).restored(onScreens: [], pixelsWide: 2940, pixelsHigh: 1912))
        // Larger than the screen it would be on (kept on a larger display, which now stands where the small one did).
        let large = Rect(x: 0, y: 0, width: 1960, height: 1303)
        XCTAssertNil(kept(large).restored(onScreens: [laptop], pixelsWide: 2940, pixelsHigh: 1912))
        // Only a corner on a screen: its title bar could not be taken hold of.
        let corner = Rect(x: 1400, y: 100, width: 1100, height: 743)
        XCTAssertNil(kept(corner).restored(onScreens: [laptop], pixelsWide: 2940, pixelsHigh: 1912))
        let below = Rect(x: 60, y: -735, width: 1100, height: 743)
        XCTAssertNil(kept(below).restored(onScreens: [laptop], pixelsWide: 2940, pixelsHigh: 1912))
        // The machine has another screen now: the window's proportions are no longer its own.
        let onLaptop = Rect(x: 60, y: 80, width: 1100, height: 743)
        XCTAssertNil(kept(onLaptop).restored(onScreens: [laptop], pixelsWide: 3024, pixelsHigh: 1964))
        // What is no window's frame.
        XCTAssertNil(kept(Rect(x: 60, y: 80, width: 120, height: 90)).restored(onScreens: [laptop], pixelsWide: 2940, pixelsHigh: 1912))
        XCTAssertNil(kept(Rect(x: .nan, y: 80, width: 1100, height: 743)).restored(onScreens: [laptop], pixelsWide: 2940, pixelsHigh: 1912))
        XCTAssertNil(kept(Rect(x: 60, y: 80, width: .infinity, height: 743)).restored(onScreens: [laptop], pixelsWide: 2940, pixelsHigh: 1912))
    }

    func testTheNoteIsTheMachinesOwnAndReadsBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-vmwindow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = VMLibrary.MachineFiles(directory: root)
        XCTAssertEqual(files.window.deletingLastPathComponent().path, files.disk.deletingLastPathComponent().path, "beside the machine's disk")
        XCTAssertNil(VMWindowPlacement.read(from: files.window))
        let placement = kept(Rect(x: 60.5, y: 80, width: 1100, height: 743))
        try placement.write(to: files.window)
        XCTAssertEqual(VMWindowPlacement.read(from: files.window), placement)
        // What is not a note is none; nor is a file far larger than one.
        try Data("not a note".utf8).write(to: files.window)
        XCTAssertNil(VMWindowPlacement.read(from: files.window))
        try Data(repeating: 0x20, count: 10_000).write(to: files.window)
        XCTAssertNil(VMWindowPlacement.read(from: files.window))
    }
}
