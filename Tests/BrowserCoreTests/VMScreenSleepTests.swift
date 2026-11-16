import Foundation
import XCTest
@testable import BrowserCore

/// When a machine's display is put to sleep while its window is out of sight, and woken
/// (`VMScreenSleep`): the helper only tells it the window's sight and the time.
final class VMScreenSleepTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testOnlyAProfilesMachineThatChoseItSleepsItsDisplay() {
        let library = VMLibrary(root: URL(fileURLWithPath: "/tmp/lib"))
        func request(_ profile: VMProfile) -> VMHelperRequest {
            VMHelperRequest.run(profile: profile, library: library, hostCores: 8, texts: [:])
        }
        XCTAssertFalse(VMScreenSleep(request: request(VMProfile(name: "A"))).enabled, "off unless chosen")
        XCTAssertTrue(VMScreenSleep(request: request(VMProfile(name: "A", sleepsScreenWhenHidden: true))).enabled)
        // The base during its setup has no settings of a profile's: its window is the person's to work in.
        var base = request(VMProfile(name: "A", sleepsScreenWhenHidden: true))
        base.settingsRevision = nil
        XCTAssertFalse(VMScreenSleep(request: base).enabled)
        XCTAssertFalse(VMScreenSleep(request: VMHelperRequest(mode: .install, sleepsScreenWhenHidden: true)).enabled)

        // Off: nothing is ever due, however long the window is out of sight.
        var off = VMScreenSleep(enabled: false)
        XCTAssertNil(off.window(seen: false, at: at(0)))
        XCTAssertNil(off.due)
        XCTAssertNil(off.check(at: at(3600), busy: false))
    }

    func testTheDisplaySleepsAfterHalfAMinuteOutOfSightAndWakesWhenTheWindowIsSeen() {
        var sleep = VMScreenSleep(enabled: true)
        XCTAssertNil(sleep.due, "in sight: nothing due")
        XCTAssertNil(sleep.window(seen: false, at: at(0)))
        // Told again that it is out of sight: the half minute counts from the first time.
        XCTAssertNil(sleep.window(seen: false, at: at(10)))
        XCTAssertEqual(sleep.due, at(VMScreenSleep.after))
        XCTAssertEqual(VMScreenSleep.after, 30)
        XCTAssertNil(sleep.check(at: at(29), busy: false), "not yet")
        XCTAssertEqual(sleep.check(at: at(30), busy: false), .sleep)
        XCTAssertTrue(sleep.asked)
        XCTAssertNil(sleep.due, "asked once")
        XCTAssertNil(sleep.check(at: at(90), busy: false))
        // In sight again: woken at once — once.
        XCTAssertEqual(sleep.window(seen: true, at: at(100)), .wake)
        XCTAssertFalse(sleep.asked)
        XCTAssertNil(sleep.window(seen: true, at: at(101)))
        // And out of sight again: another half minute.
        XCTAssertNil(sleep.window(seen: false, at: at(200)))
        XCTAssertEqual(sleep.due, at(230))
    }

    func testAGlanceAwayIsNotEnough() {
        var sleep = VMScreenSleep(enabled: true)
        XCTAssertNil(sleep.window(seen: false, at: at(0)))
        XCTAssertNil(sleep.window(seen: true, at: at(20)), "never asked: nothing to wake")
        XCTAssertNil(sleep.due)
        // A look that was waiting finds nothing due.
        XCTAssertNil(sleep.check(at: at(30), busy: false))
        XCTAssertFalse(sleep.asked)
    }

    /// Starting behind its cover (its script is at its settings), being woken or being closed:
    /// the display is left as it is, and looked at again a half minute later.
    func testABusyMachineIsLookedAtAgainLater() {
        var sleep = VMScreenSleep(enabled: true)
        _ = sleep.window(seen: false, at: at(0))
        XCTAssertNil(sleep.check(at: at(30), busy: true))
        XCTAssertFalse(sleep.asked)
        XCTAssertEqual(sleep.due, at(60))
        XCTAssertNil(sleep.check(at: at(45), busy: false))
        XCTAssertEqual(sleep.check(at: at(60), busy: false), .sleep)
    }

    /// The guest left its display on — its screen lock is on, and waking would ask for the
    /// password: the word is taken back, and the machine is not asked again while it runs.
    func testAMachineWhoseScreenLockIsOnIsNotAskedAgain() {
        var sleep = VMScreenSleep(enabled: true)
        _ = sleep.window(seen: false, at: at(0))
        XCTAssertNil(sleep.guestSaid(VMGuestStatus(text: "LUMEN_SCREEN_SLEEP=locks\n")), "not asked yet: nothing to take back")
        XCTAssertEqual(sleep.check(at: at(30), busy: false), .sleep)
        XCTAssertNil(sleep.guestSaid(VMGuestStatus(text: "LUMEN_TOOLS_VERSION=13\n")), "an older script says nothing")
        XCTAssertNil(sleep.guestSaid(VMGuestStatus(text: "LUMEN_SCREEN_SLEEP=asleep\n")))
        XCTAssertTrue(sleep.asked)
        XCTAssertEqual(sleep.guestSaid(VMGuestStatus(text: "LUMEN_SCREEN_SLEEP=locks\nLUMEN_SCREEN_SLEEP_NOTE=screenLock delay is immediate\n")),
                       .wake)
        XCTAssertTrue(sleep.refused)
        XCTAssertFalse(sleep.asked)
        XCTAssertNil(sleep.window(seen: true, at: at(40)), "the word is already back")
        _ = sleep.window(seen: false, at: at(50))
        XCTAssertNil(sleep.due)
        XCTAssertNil(sleep.check(at: at(500), busy: false))
    }

    func testWhatTheGuestSaysOfItsDisplayIsRead() {
        let said = VMGuestStatus(text: "LUMEN_TOOLS_VERSION=14\nLUMEN_SCREEN_SLEEP=locks\nLUMEN_SCREEN_SLEEP_NOTE=2026-11-16 sysadminctl screenLock delay is immediate\n")
        XCTAssertEqual(said.screenSleep, "locks")
        XCTAssertTrue(said.screenSleepWouldLock)
        XCTAssertEqual(said.screenSleepNote, "2026-11-16 sysadminctl screenLock delay is immediate")
        XCTAssertFalse(VMGuestStatus(text: "LUMEN_SCREEN_SLEEP=asleep\n").screenSleepWouldLock)
        XCTAssertNil(VMGuestStatus(text: "LUMEN_TOOLS_VERSION=13\n").screenSleep)
        // The word's place, as the helper and the boot script name it.
        let files = VMLibrary.MachineFiles(directory: URL(fileURLWithPath: "/m", isDirectory: true))
        XCTAssertEqual(files.screenSleep.path, "/m/share/lumen-screen-sleep")
        XCTAssertEqual(VMGuestSettings.screenSleepFileName, "lumen-screen-sleep")
    }
}
