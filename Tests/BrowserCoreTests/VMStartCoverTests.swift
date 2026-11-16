import Foundation
import XCTest
@testable import BrowserCore

/// The cover over a profile's machine's screen while its start puts the profile's settings in
/// place (`VMStartCover`, the helper's `MachineRunner`): what the guest's status says of it
/// (tools 13: `LUMEN_STAGE`, `LUMEN_READY_REVISION`), and when the cover goes — for this start's
/// settings only, for an older script by what it writes last, and never later than its limits.
final class VMStartCoverTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let revision = "9f3a2b1c"

    /// The cover `seconds` after the start, with `text` in the status file written `written`
    /// seconds after the start (nil: no file).
    private func cover(_ text: String?, written: TimeInterval? = 5, at seconds: TimeInterval,
                       browserMode: Bool = false) -> VMStartCover.State {
        VMStartCover.state(status: text.map(VMGuestStatus.init(text:)), written: written.map { start.addingTimeInterval($0) },
                           startedAt: start, revision: revision, browserMode: browserMode, now: start.addingTimeInterval(seconds))
    }

    // MARK: - What the guest says

    func testTheStepAndTheReadySettingsAreRead() {
        let said = VMGuestStatus(text: "LUMEN_TOOLS_VERSION=13\nLUMEN_STAGE=wallpaper\nLUMEN_READY_REVISION=9f3a2b1c\nLUMEN_SETUP_DONE=1\n")
        XCTAssertEqual(said.toolsVersion, 13)
        XCTAssertEqual(said.stage, .wallpaper)
        XCTAssertEqual(said.readyRevision, "9f3a2b1c")
        XCTAssertNil(said.appliedRevision)
        // Every step the script writes reads as itself.
        for stage in ["signin", "locale", "look", "wallpaper", "safari", "ready"] {
            XCTAssertEqual(VMGuestStatus(text: "LUMEN_STAGE=\(stage)\n").stage?.rawValue, stage)
        }
        // A word that is no step is none; an older script writes neither.
        XCTAssertNil(VMGuestStatus(text: "LUMEN_STAGE=reboot\n").stage)
        XCTAssertNil(VMGuestStatus(text: "LUMEN_STAGE=Locale\n").stage)
        let older = VMGuestStatus(text: "LUMEN_TOOLS_VERSION=12\nLUMEN_APPLIED_REVISION=9f3a2b1c\n")
        XCTAssertNil(older.stage)
        XCTAssertNil(older.readyRevision)
        // What is not printable is not taken.
        XCTAssertNil(VMGuestStatus(text: "LUMEN_READY_REVISION=9f\u{7}\n").readyRevision)
    }

    func testTheStepsAreInOrderAndCounted() {
        XCTAssertEqual(VMSetupStage.allCases, [.boot, .signin, .locale, .look, .wallpaper, .safari, .ready])
        XCTAssertLessThan(VMSetupStage.boot, .signin)
        XCTAssertLessThan(VMSetupStage.wallpaper, .safari)
        XCTAssertEqual(max(VMSetupStage.look, .signin), .look)
        XCTAssertEqual(VMSetupStage.boot.stepsDone, 0)
        XCTAssertEqual(VMSetupStage.locale.stepsDone, 2)
        XCTAssertEqual(VMSetupStage.safari.stepsDone, 5)
        XCTAssertEqual(VMSetupStage.ready.stepsDone, VMSetupStage.steps.count)
    }

    // MARK: - When the cover goes

    func testTheCoverGoesWhenTheGuestSaysThisStartsSettingsAreIn() {
        XCTAssertEqual(cover(nil, at: 10), VMStartCover.State(stage: .boot))
        XCTAssertEqual(cover("LUMEN_TOOLS_VERSION=13\nLUMEN_STAGE=signin\n", at: 25), VMStartCover.State(stage: .signin))
        XCTAssertEqual(cover("LUMEN_TOOLS_VERSION=13\nLUMEN_STAGE=look\n", at: 35), VMStartCover.State(stage: .look))
        // Before Safari: the settings are in, and the person is let in.
        XCTAssertEqual(cover("LUMEN_TOOLS_VERSION=13\nLUMEN_STAGE=safari\nLUMEN_READY_REVISION=9f3a2b1c\n", at: 40),
                       VMStartCover.State(stage: .ready, reveal: .ready))
        XCTAssertEqual(cover("LUMEN_TOOLS_VERSION=13\nLUMEN_STAGE=ready\nLUMEN_READY_REVISION=9f3a2b1c\nLUMEN_APPLIED_REVISION=9f3a2b1c\n",
                             at: 41).reveal, .ready)
        // Other settings than this start's are not these.
        XCTAssertEqual(cover("LUMEN_TOOLS_VERSION=13\nLUMEN_STAGE=safari\nLUMEN_READY_REVISION=0bad\n", at: 40),
                       VMStartCover.State(stage: .safari))
        // A script that says it is at work but names no step is taken as signing in.
        XCTAssertEqual(cover("LUMEN_TOOLS_VERSION=13\n", at: 20), VMStartCover.State(stage: .signin))
        XCTAssertEqual(cover("LUMEN_TOOLS_VERSION=13\nLUMEN_STAGE=boot\n", at: 20), VMStartCover.State(stage: .signin))
    }

    /// A status written before this start is of a macOS that has since shut down: what it says
    /// "ready" for is that start's, whatever its revision.
    func testAStatusFromBeforeThisStartSaysNothingOfIt() {
        let before = "LUMEN_TOOLS_VERSION=13\nLUMEN_STAGE=ready\nLUMEN_READY_REVISION=9f3a2b1c\nLUMEN_APPLIED_REVISION=9f3a2b1c\n"
        XCTAssertEqual(cover(before, written: -300, at: 20), VMStartCover.State(stage: .boot))
        XCTAssertEqual(cover(before, written: nil, at: 20), VMStartCover.State(stage: .boot))
        XCTAssertEqual(cover(before, written: 18, at: 20).reveal, .ready)
        // And nothing to compare with: no revision, no going.
        XCTAssertNil(VMStartCover.state(status: VMGuestStatus(text: before), written: start, startedAt: start, revision: "",
                                        now: start.addingTimeInterval(20)).reveal)
    }

    /// An older script (before tools 13) says neither its steps nor "ready": it writes the
    /// settings it applied when it has applied them — after it opened Safari — and that is when
    /// the cover goes. (Tools 7 and on take tools 13 at the start, from the Mac's read-only folder:
    /// this is for a machine that did not.)
    func testAnOlderScriptIsWaitedForUntilItSaysItApplied() {
        XCTAssertEqual(cover("LUMEN_TOOLS_VERSION=12\nLUMEN_SETUP_DONE=1\n", at: 30), VMStartCover.State(stage: .signin))
        XCTAssertEqual(cover("LUMEN_TOOLS_VERSION=12\nLUMEN_APPLIED_REVISION=9f3a2b1c\n", at: 50),
                       VMStartCover.State(stage: .ready, reveal: .applied))
        XCTAssertEqual(cover("LUMEN_TOOLS_VERSION=12\nLUMEN_APPLIED_REVISION=0bad\n", at: 50), VMStartCover.State(stage: .signin))
        // A "ready" an older script cannot have written is not taken; a step it cannot say is not shown.
        XCTAssertEqual(cover("LUMEN_TOOLS_VERSION=12\nLUMEN_STAGE=safari\nLUMEN_READY_REVISION=9f3a2b1c\n", at: 50),
                       VMStartCover.State(stage: .signin))
        XCTAssertEqual(cover("LUMEN_APPLIED_REVISION=9f3a2b1c\n", at: 50).reveal, .applied)
    }

    /// Nobody is kept out for good: "Show the screen" after a minute; the cover goes by itself
    /// after two minutes of silence from the guest, or three while its script says it is at work.
    func testNobodyIsKeptOutForGood() {
        XCTAssertFalse(cover(nil, at: 59).offersReveal)
        XCTAssertTrue(cover(nil, at: 60).offersReveal)
        XCTAssertNil(cover(nil, at: 119.9).reveal)
        XCTAssertEqual(cover(nil, at: 120), VMStartCover.State(stage: .boot, offersReveal: true, reveal: .timedOut))
        let working = "LUMEN_TOOLS_VERSION=13\nLUMEN_STAGE=locale\n"
        XCTAssertEqual(cover(working, at: 150), VMStartCover.State(stage: .locale, offersReveal: true))
        XCTAssertEqual(cover(working, at: 180), VMStartCover.State(stage: .locale, offersReveal: true, reveal: .timedOut))
        // A machine at its sign-in window (automatic sign-in did not happen) waits the same.
        XCTAssertEqual(cover("LUMEN_TOOLS_VERSION=13\nLUMEN_STAGE=signin\n", at: 90),
                       VMStartCover.State(stage: .signin, offersReveal: true))
        // An old status, of the start before, counts as silence.
        XCTAssertEqual(cover(working, written: -10, at: 120).reveal, .timedOut)
    }

    /// A machine shown as a browser is let in once Safari is open — the helper then puts it over
    /// the machine's whole screen: what the script writes after opening it.
    func testAMachineShownAsABrowserWaitsForSafari() {
        let settingsIn = "LUMEN_TOOLS_VERSION=13\nLUMEN_STAGE=safari\nLUMEN_READY_REVISION=9f3a2b1c\n"
        XCTAssertEqual(cover(settingsIn, at: 40, browserMode: true), VMStartCover.State(stage: .safari))
        let opened = settingsIn + "LUMEN_APPLIED_REVISION=9f3a2b1c\n"
        XCTAssertEqual(cover(opened, at: 42, browserMode: true), VMStartCover.State(stage: .ready, reveal: .ready))
        XCTAssertEqual(cover("LUMEN_TOOLS_VERSION=11\nLUMEN_APPLIED_REVISION=9f3a2b1c\n", at: 42, browserMode: true).reveal, .applied)
        XCTAssertEqual(cover(settingsIn, at: 180, browserMode: true).reveal, .timedOut)
    }

    // MARK: - Which starts are covered

    /// A profile's machine started anew is covered; the base (no settings) and a machine woken as
    /// it was closed are not. Settings changed while it slept: its state was saved for the old
    /// ones, the machine starts anew, and that start is covered until the new settings are in.
    func testOnlyAProfilesMachineStartedAnewIsCovered() throws {
        XCTAssertTrue(VMStartCover.covers(settingsRevision: "9f", woken: false))
        XCTAssertFalse(VMStartCover.covers(settingsRevision: "9f", woken: true))
        XCTAssertFalse(VMStartCover.covers(settingsRevision: nil, woken: false))
        XCTAssertFalse(VMStartCover.covers(settingsRevision: "", woken: false))
        // Put to sleep before its settings were in: the wake is covered until they are.
        let midway = VMGuestStatus(text: "LUMEN_TOOLS_VERSION=13\nLUMEN_STAGE=locale\n")
        XCTAssertTrue(VMStartCover.covers(settingsRevision: "9f", woken: true, asleepWith: midway))
        let settled = VMGuestStatus(text: "LUMEN_TOOLS_VERSION=13\nLUMEN_STAGE=ready\nLUMEN_READY_REVISION=9f\n")
        XCTAssertFalse(VMStartCover.covers(settingsRevision: "9f", woken: true, asleepWith: settled))
        XCTAssertFalse(VMStartCover.covers(settingsRevision: "9f", woken: true,
                                           asleepWith: VMGuestStatus(text: "LUMEN_TOOLS_VERSION=12\n")), "an older script cannot say")

        let library = VMLibrary(root: URL(fileURLWithPath: "/tmp/lib"))
        let profile = VMProfile(name: "A", language: "de-DE", instantWake: true)
        let request = VMHelperRequest.run(profile: profile, library: library, hostCores: 8, texts: [:])
        XCTAssertEqual(request.settingsRevision, VMGuestSettings(profile: profile).revision)
        XCTAssertEqual(try VMHelperRequest.parse(try request.line()).settingsRevision, request.settingsRevision)
        XCTAssertNil(VMHelperRequest(mode: .run, machineDirectory: "/tmp/lib/base", network: .absent).settingsRevision)

        var changed = profile
        changed.language = "fr-FR"
        let after = VMHelperRequest.run(profile: changed, library: library, hostCores: 8, texts: [:])
        XCTAssertNotEqual(after.settingsRevision, request.settingsRevision)
        let disk = FileManager.default.temporaryDirectory.appendingPathComponent("cover-disk-\(UUID().uuidString)")
        try Data(count: 64).write(to: disk)
        defer { try? FileManager.default.removeItem(at: disk) }
        let mark = try XCTUnwrap(VMSavedState.mark(ofDisk: disk))
        let saved = VMSavedState(stamp: try XCTUnwrap(request.stateStamp), diskLength: mark.length, diskModified: mark.modified)
        XCTAssertNil(saved.refusal(stamp: request.stateStamp, disk: disk), "the same settings: woken, no cover")
        XCTAssertEqual(saved.refusal(stamp: after.stateStamp, disk: disk), .changed, "other settings: started anew, covered")
    }
}
