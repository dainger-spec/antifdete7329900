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
