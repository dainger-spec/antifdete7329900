import Foundation
import XCTest
@testable import BrowserCore

/// The guest's boot script (Resources/VMGuest/lumen-guest.sh) run as it is, from its first line to
/// the shutdown, by /bin/sh — on a machine that is not a guest. Every command it calls by its full
/// path is one of the test's own instead, which writes down how it was called and answers what the
/// real one would; every place it reads or writes is a folder of the test's. What the app writes
/// for a profile (`VMGuestSettings`) goes in; what the script would have done to a machine's macOS
/// comes out, command by command.
///
/// What this cannot show is what macOS then does with those commands: that is seen in a machine.
final class VMGuestScriptTests: XCTestCase {
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/VMGuest", isDirectory: true)

    private var root: URL!
    private var share: URL { root.appendingPathComponent("share") }
    private var guest: URL { root.appendingPathComponent("guest") }
    private var own: URL { root.appendingPathComponent("own") }
    /// The tools' folder the Mac shares read-only, where the script mounts it.
    private var tools: URL { root.appendingPathComponent("tools") }
    /// Where tools 6 and before kept the pictures (anyone in the guest can write there).
    private var old: URL { root.appendingPathComponent("old") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-guest-\(UUID().uuidString)", isDirectory: true)
        for name in ["bin", "share", "guest", "own", "zoneinfo/Europe", "run", "tools", "old"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("zoneinfo/Europe/Berlin"))
        try writeStubs()
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    // MARK: - The script, on the test's own ground

    /// The commands the script calls and what stands for each: the real tool where it only reads
    /// or works on the test's own files, a recorder where it would change a system.
    private static let passedOn = ["sed", "head", "ls", "mkdir", "cksum", "cut", "tr", "cp", "chmod", "rm", "mv", "mktemp", "grep"]
    private static let recorded = ["defaults", "scutil", "systemsetup", "osascript", "open", "killall", "shutdown", "chown", "ln",
                                   "mount", "mount_virtiofs", "sysadminctl", "pmset", "mdutil", "softwareupdate", "sntp"]
    private static let answered = ["sh", "sleep", "launchctl", "sudo", "stat", "id", "pgrep", "sw_vers", "logger",
                                   "sysctl", "fdesetup", "stty", "readlink"]

    private func writeStubs() throws {
        let bin = root.appendingPathComponent("bin")
        let log = root.appendingPathComponent("calls.log").path
        func stub(_ name: String, _ body: String) throws {
            let url = bin.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        for name in Self.passedOn { try stub(name, "exec /usr/bin/env \(name) \"$@\"") }
        // One line a call: who made it (root, or the person the script took it to), the command,
        // its arguments — a line break inside one written as a space.
        let record = """
            { printf '%s %s' "${LUMEN_TEST_USER:-root}" "$(basename "$0")"
              for argument in "$@"; do printf ' %s' "$(printf '%s' "$argument" | /usr/bin/env tr '\\n' ' ')"; done
              printf '\\n'; } >> '\(log)'
            """
        for name in Self.recorded where name != "defaults" && name != "osascript" { try stub(name, record) }
        try stub("defaults", record + """

            if [ "$1" = read ]; then
              case "$2 $3" in
                "/Applications/Safari.app/Contents/Info CFBundleShortVersionString") echo 27.2 ;;
                "/Library/Preferences/com.apple.loginwindow autoLoginUser") [ -z "${AUTOLOGIN_USER-tester}" ] && exit 1; echo "${AUTOLOGIN_USER-tester}" ;;
                "MobileMeAccounts Accounts") [ -z "$APPLE_ID" ] && exit 1; printf '(\n    {\n        AccountID = "%s";\n    }\n)\n' "$APPLE_ID" ;;
                "com.apple.dock orientation") [ -z "$DOCK_ORIENTATION" ] && exit 1; echo "$DOCK_ORIENTATION" ;;
                "com.apple.dock autohide") [ -z "$DOCK_AUTOHIDE" ] && exit 1; echo "$DOCK_AUTOHIDE" ;;
                "com.apple.dock tilesize") [ -z "$DOCK_TILESIZE" ] && exit 1; echo "$DOCK_TILESIZE" ;;
                "-g AppleLocale") [ -z "$APPLE_LOCALE" ] && exit 1; echo "$APPLE_LOCALE" ;;
                "-g AppleLanguages") [ -z "$APPLE_LANGUAGES" ] && exit 1; printf '(\n    "%s",\n    "ru-RU"\n)\n' "$APPLE_LANGUAGES" ;;
                "io.lumenbrowser.guest keyboard") [ -z "$KEYBOARD_NOTED" ] && exit 1; echo "$KEYBOARD_NOTED" ;;
                "io.lumenbrowser.guest locale") [ -z "$LOCALE_NOTED" ] && exit 1; echo "$LOCALE_NOTED" ;;
                "io.lumenbrowser.guest browser") [ -z "$BROWSER_NOTED" ] && exit 1; echo "$BROWSER_NOTED" ;;
                *) exit 1 ;;
              esac
            fi
            """)
        // What the program returned on its output; what the system printed beside it, and an
        // error's words, on the other one — as osascript has them.
        try stub("osascript", record + """

            [ -z "$OSASCRIPT_NOISE" ] || echo "$OSASCRIPT_NOISE" >&2
            if [ -n "$OSASCRIPT_ERROR" ]; then echo "$OSASCRIPT_ERROR" >&2; exit 1; fi
            echo "${OSASCRIPT_ANSWER-set}"
            """)
        try stub("sh", "exec /bin/sh \"$@\"")
        // No waiting: and after as many waits as the test says, Lumen's request to shut down.
        let sleeps = root.appendingPathComponent("sleeps").path
        try stub("sleep", """
            echo x >> '\(sleeps)'
            if [ "$(/usr/bin/env wc -l < '\(sleeps)')" -ge "${SLEEPS_BEFORE_SHUTDOWN:-1}" ]; then
              : > '\(share.path)/lumen-shutdown'
              : > '\(root.appendingPathComponent("run").path)/lumen-shutdown'
            fi
            """)
        try stub("launchctl", "[ \"$1\" = asuser ] || exit 1\nshift 2\nexec \"$@\"")
        try stub("sudo", "[ \"$1\" = -u ] || exit 1\nLUMEN_TEST_USER=\"$2\"\nexport LUMEN_TEST_USER\nshift 2\nexec \"$@\"")
        // Who is at the console; and the device a folder is on — the shared folder's another than
        // its parent's when a volume is mounted there.
        try stub("stat", """
            if [ "$2" = %d ]; then
              if [ "$3" = '\(share.path)' ] && [ "${SHARE_MOUNTED:-1}" = 1 ]; then echo 2; else echo 1; fi
            else
              printf '%s\n' "${CONSOLE_USER-tester}"
            fi
            """)
        try stub("id", "case \"$1\" in -un) echo \"${INSTALL_USER-tester}\" ;; -u) [ \"$2\" = tester ] && echo 501 ;; *) exit 1 ;; esac")
        // The installer's: a virtual Mac, FileVault as the test says, no terminal to set.
        try stub("sysctl", "[ \"$2\" = hw.model ] && echo \"${HW_MODEL-VirtualMac2,1}\"")
        try stub("fdesetup", "[ \"$1\" = isactive ] && echo \"${FILEVAULT-false}\"")
        try stub("stty", "exit 0")
        // Where /etc/localtime points: the time zone the system has.
        try stub("readlink", "[ -n \"$LOCALTIME\" ] && echo \"$LOCALTIME\"")
        try stub("pgrep", "exit 1")
        try stub("sw_vers", "case \"$1\" in -productVersion) echo 27.2.1 ;; -buildVersion) echo 26B131 ;; esac")
        try stub("logger", "exit 0")
    }

    /// The script's text with its commands and its places turned to the test's.
    private func onTestGround(_ text: String) throws -> String {
        var text = text
        for (place, mine) in [("/Volumes/My Shared Files", share.path), ("/Library/Application Support/Lumen", guest.path),
                              ("/Users/Shared/Lumen", old.path),
                              ("/usr/local/lumen", own.path), ("/var/db/timezone/zoneinfo", root.appendingPathComponent("zoneinfo").path),
                              ("/var/run/lumen-share", root.appendingPathComponent("run").path), ("/var/run/lumen-tools", tools.path)] {
            text = text.replacingOccurrences(of: place, with: mine)
        }
        let pattern = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_./$-])/(?:usr/bin|usr/sbin|bin|sbin)/([A-Za-z_]+)"#)
        let range = NSRange(text.startIndex..., in: text)
        var called: Set<String> = []
        for match in pattern.matches(in: text, range: range) {
            if let name = Range(match.range(at: 1), in: text) { called.insert(String(text[name])) }
        }
        // A command the script has learnt to call and this test has no word for would run for
        // real, or not at all: named here, so that it is given one.
        let known = Set(Self.passedOn + Self.recorded + Self.answered)
        XCTAssertEqual(called.subtracting(known), [], "the boot script calls commands this test does not stand in for")
        return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: root.path) + "/bin/$1")
    }

    private struct Run {
        var status: Int32
        /// What the script called, in order: "root scutil --set HostName Mac", "tester open -a Safari".
        var calls: [String]

        func has(_ call: String) -> Bool { calls.contains(call) }
        func count(_ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }
    }

    /// Runs the boot script to its end with `settings` in the shared folder (nil: none).
    @discardableResult
    private func boot(settings: String?, environment: [String: String] = [:], script: String? = nil) throws -> Run {
        let text = try onTestGround(try script ?? String(contentsOf: Self.folder.appendingPathComponent("lumen-guest.sh"), encoding: .utf8))
        let file = root.appendingPathComponent("boot.sh")
        try Data(text.utf8).write(to: file)
        if let settings { try Data(settings.utf8).write(to: share.appendingPathComponent(VMGuestSettings.fileName)) }
        for name in ["calls.log", "sleeps"] { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
        try? FileManager.default.removeItem(at: share.appendingPathComponent("lumen-shutdown"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [file.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(environment) { _, mine in mine }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // The script ends by itself; one that does not is ended, and the test says so.
        let limit = Date().addingTimeInterval(60)
        while process.isRunning, Date() < limit { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            XCTFail("the boot script did not come to its end")
        }
        process.waitUntilExit()
        let log = (try? String(contentsOf: root.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return Run(status: process.terminationStatus, calls: log.split(separator: "\n").map(String.init))
    }

    private func status() -> VMGuestStatus {
        VMGuestStatus(text: (try? String(contentsOf: share.appendingPathComponent(VMGuestSettings.statusFileName), encoding: .utf8)) ?? "")
    }

    // MARK: - What a profile's settings do

    func testEverySettingBecomesTheCommandThatSetsIt() throws {
        let profile = VMProfile(name: "Vienna", timeZoneIdentifier: "Europe/Berlin", language: "de-DE", localeFollowsProxy: false,
                                startURL: "https://a.example/", appearance: "dark", accent: "purple",
                                computerName: "Anna's MacBook Air", regionCode: "AT", hourCycle: "24", firstWeekday: 2,
                                dockPosition: "left", dockAutohide: true, dockSize: "small", scrollBars: "whenScrolling",
                                moreStartURLs: ["https://b.example/x?y=1&z=2", "https://c.example/"])
        XCTAssertNoThrow(try profile.validate())
        let settings = VMGuestSettings(profile: profile)
        try Data("PNG".utf8).write(to: share.appendingPathComponent(VMGuestSettings.wallpaperFileName))
        let run = try boot(settings: settings.text)
        XCTAssertEqual(run.status, 0)

        // The system's own, as root: the time zone and the names.
        XCTAssertTrue(run.has("root defaults write /Library/Preferences/com.apple.timezone.auto Active -bool false"), "\(run.calls)")
        XCTAssertTrue(run.has("root systemsetup -settimezone Europe/Berlin"))
        for name in ["ComputerName", "LocalHostName", "HostName"] {
            XCTAssertTrue(run.has("root scutil --set \(name) Annas-MacBook-Air"), name)
        }
        XCTAssertTrue(run.has("root scutil --set ComputerName Anna's MacBook Air"))
        // The person's, as the person: language and region, the clock and the week.
        XCTAssertTrue(run.has("tester defaults write -g AppleLanguages -array de-DE"))
        XCTAssertTrue(run.has("tester defaults write -g AppleLocale -string de_AT"))
        XCTAssertTrue(run.has("tester defaults write -g AppleICUForce24HourTime -bool true"))
        XCTAssertTrue(run.has("tester defaults delete -g AppleICUForce12HourTime"))
        XCTAssertTrue(run.has("tester defaults write -g AppleFirstWeekday -dict gregorian -int 2"))
        // The look.
        XCTAssertTrue(run.has("tester defaults write -g AppleInterfaceStyle -string Dark"))
        XCTAssertTrue(run.has("tester defaults write -g AppleAccentColor -int 5"))
        XCTAssertTrue(run.has("tester defaults write -g AppleHighlightColor -string 0.968627 0.831373 1.000000 Purple"))
        XCTAssertTrue(run.has("tester defaults write -g AppleShowScrollBars -string WhenScrolling"))
        // The Dock, started again because it was changed.
        XCTAssertTrue(run.has("tester defaults write com.apple.dock orientation -string left"))
        XCTAssertTrue(run.has("tester defaults write com.apple.dock autohide -bool true"))
        XCTAssertTrue(run.has("tester defaults write com.apple.dock tilesize -int 36"))
        XCTAssertTrue(run.has("root killall Dock"))
        // The picture: copied into the machine under its checksum's name and set in the person's session.
        let pictures = try FileManager.default.contentsOfDirectory(atPath: guest.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(pictures.count, 1)
        let picture = guest.appendingPathComponent(try XCTUnwrap(pictures.first)).path
        let setting = try XCTUnwrap(run.calls.first { $0.hasPrefix("tester osascript -l JavaScript -e ") })
        XCTAssertTrue(setting.hasSuffix(" " + picture), setting)
        XCTAssertTrue(setting.contains("setDesktopImageURLForScreenOptionsError"), setting)
        // Safari, with every page — after the look was set.
        let opening = "tester open -a Safari https://a.example/ https://b.example/x?y=1&z=2 https://c.example/"
        XCTAssertTrue(run.has(opening), "\(run.calls)")
        let opened = try XCTUnwrap(run.calls.firstIndex(of: opening))
        for earlier in ["tester defaults write -g AppleInterfaceStyle -string Dark", "tester defaults write -g AppleShowScrollBars -string WhenScrolling",
                        "root killall Dock", setting] {
            XCTAssertLessThan(try XCTUnwrap(run.calls.firstIndex(of: earlier)), opened, earlier)
        }
        // Lumen's request to shut down is taken, and is the last thing done.
        XCTAssertEqual(run.calls.last, "root shutdown -h now")
        XCTAssertFalse(FileManager.default.fileExists(atPath: share.appendingPathComponent("lumen-shutdown").path))

        // And what it says back is what the app reads.
        let said = status()
        XCTAssertEqual(said.toolsVersion, VMGuestTools.version)
        XCTAssertEqual(said.systemVersion, "27.2.1")
        XCTAssertEqual(said.systemBuild, "26B131")
        XCTAssertEqual(said.safariVersion, "27.2")
        XCTAssertEqual(said.appliedRevision, settings.revision)
        XCTAssertEqual(said.wallpaperState, "set")
        XCTAssertTrue(said.setupDone)
    }

    func testWhatAProfileDoesNotSetIsLeftAsItIs() throws {
        let profile = VMProfile(name: "Plain", lumenWallpaper: false)
        let run = try boot(settings: VMGuestSettings(profile: profile).text)
        XCTAssertEqual(run.status, 0)
        for untouched in ["AppleInterfaceStyle", "AppleAccentColor", "AppleICUForce", "AppleFirstWeekday", "AppleShowScrollBars",
                          "com.apple.dock orientation -string", "com.apple.dock autohide -bool", "com.apple.dock tilesize -int",
                          "write -g AppleLanguages", "write -g AppleLocale", "settimezone", "osascript"] {
            XCTAssertFalse(run.calls.contains { $0.contains(untouched) }, "\(untouched): \(run.calls)")
        }
        XCTAssertFalse(run.has("root killall Dock"))
        // Its name by its screen, Safari as it was left, and no screen saver.
        XCTAssertTrue(run.has("root scutil --set ComputerName MacBook-Air"))
        XCTAssertTrue(run.has("tester open -a Safari"))
        XCTAssertTrue(run.has("tester defaults -currentHost write com.apple.screensaver idleTime -int 0"))
        XCTAssertEqual(status().wallpaperState, "off")
    }

    func testAMachineThatDoesNotOpenSafariStartsAtItsDesktop() throws {
        let run = try boot(settings: VMGuestSettings(profile: VMProfile(name: "A", startURL: "https://a.example/", opensSafari: false)).text)
        XCTAssertFalse(run.calls.contains { $0.contains(" open ") }, "\(run.calls)")
    }

    func testTwelveHoursAndTheOtherDockAndScrollBarChoices() throws {
        let profile = VMProfile(name: "A", hourCycle: "12", firstWeekday: 1, dockPosition: "right", dockAutohide: false,
                                dockSize: "large", scrollBars: "always")
        let run = try boot(settings: VMGuestSettings(profile: profile).text, environment: ["DOCK_AUTOHIDE": "1"])
        XCTAssertTrue(run.has("tester defaults write -g AppleICUForce12HourTime -bool true"))
        XCTAssertTrue(run.has("tester defaults delete -g AppleICUForce24HourTime"))
        XCTAssertTrue(run.has("tester defaults write -g AppleFirstWeekday -dict gregorian -int 1"))
        XCTAssertTrue(run.has("tester defaults write -g AppleShowScrollBars -string Always"))
        XCTAssertTrue(run.has("tester defaults write com.apple.dock orientation -string right"))
        XCTAssertTrue(run.has("tester defaults write com.apple.dock autohide -bool false"))
        XCTAssertTrue(run.has("tester defaults write com.apple.dock tilesize -int 72"))
    }

    /// A Dock that already is as the profile has it is not written to, and not started again:
    /// every start of a machine would otherwise blink its Dock.
    func testADockThatIsAlreadySoIsLeftRunning() throws {
        let profile = VMProfile(name: "A", dockPosition: "left", dockAutohide: true, dockSize: "medium")
        let run = try boot(settings: VMGuestSettings(profile: profile).text,
                           environment: ["DOCK_ORIENTATION": "left", "DOCK_AUTOHIDE": "1", "DOCK_TILESIZE": "52"])
        XCTAssertFalse(run.calls.contains { $0.contains("defaults write com.apple.dock") }, "\(run.calls)")
        XCTAssertFalse(run.has("root killall Dock"))
    }

    // MARK: - The picture

    /// A machine's first start is a Mac its macOS has not seen: the picture is looked at again in
    /// the first minute and a half, then marked as set and left alone — at later starts too.
    func testThePictureIsLookedAtAgainAndThenLeftForGood() throws {
        try Data("PNG".utf8).write(to: share.appendingPathComponent(VMGuestSettings.wallpaperFileName))
        let settings = VMGuestSettings(profile: VMProfile(name: "A")).text
        let first = try boot(settings: settings, environment: ["SLEEPS_BEFORE_SHUTDOWN": "60"])
        // At sign-in and four seconds on, then four more times.
        XCTAssertEqual(first.count("tester osascript "), 6, "\(first.calls)")
        XCTAssertEqual(status().wallpaperState, "set")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: guest.path).filter { $0.hasSuffix(".png.set") }.count, 1)

        let second = try boot(settings: settings, environment: ["SLEEPS_BEFORE_SHUTDOWN": "60"])
        XCTAssertEqual(second.count("tester osascript "), 0, "a person's own picture would have been put back: \(second.calls)")
        XCTAssertEqual(status().wallpaperState, "kept")

        // Another picture (another screen) is a new one: set again.
        try Data("PNG, another".utf8).write(to: share.appendingPathComponent(VMGuestSettings.wallpaperFileName))
        let third = try boot(settings: settings)
        XCTAssertEqual(third.count("tester osascript "), 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: guest.path).filter { $0.hasSuffix(".png") }.count, 1)
    }

    func testAPictureTheSystemDidNotTakeIsSaidWithItsWords() throws {
        try Data("PNG".utf8).write(to: share.appendingPathComponent(VMGuestSettings.wallpaperFileName))
        try boot(settings: VMGuestSettings(profile: VMProfile(name: "A")).text,
                 environment: ["OSASCRIPT_ERROR": "execution error: Error: \"oops\" $(id) `id` (-2700)", "SLEEPS_BEFORE_SHUTDOWN": "60"])
        let said = status()
        XCTAssertEqual(said.wallpaperState, "failed")
        XCTAssertTrue(said.wallpaperFailed)
        XCTAssertEqual(said.wallpaperNote, "execution error: Error: oops (id) id (-2700)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: guest.path).filter { $0.hasSuffix(".set") }.count, 0)

        // What the program itself answered when it did not set the picture.
        try boot(settings: VMGuestSettings(profile: VMProfile(name: "A")).text, environment: ["OSASCRIPT_ANSWER": "the system refused the picture"])
        XCTAssertEqual(status().wallpaperNote, "the system refused the picture")

        // No picture in the shared folder at all.
        try FileManager.default.removeItem(at: share.appendingPathComponent(VMGuestSettings.wallpaperFileName))
        try boot(settings: VMGuestSettings(profile: VMProfile(name: "A")).text)
        XCTAssertEqual(status().wallpaperState, "none")
    }

    // MARK: - What the script does not trust

    /// The settings file is the app's, and the script still takes nothing from it on trust: a
    /// value that is not what its key may hold reaches no command.
    func testValuesThatAreNotSettingsReachNoCommand() throws {
        let marker = root.appendingPathComponent("owned").path
        let hostile = """
            LUMEN_REVISION=abc; touch \(marker)
            LUMEN_TIMEZONE=../../etc/passwd
            LUMEN_LANGUAGE=de-DE; touch \(marker)
            LUMEN_LOCALE=de_DE$(touch \(marker))
            LUMEN_HOSTNAME=Mac`touch \(marker)`
            LUMEN_COMPUTER_NAME=Anna"; touch \(marker); "
            LUMEN_APPEARANCE=dark; touch \(marker)
            LUMEN_ACCENT=7
            LUMEN_OPEN_SAFARI=1
            LUMEN_WALLPAPER=1; touch \(marker)
            LUMEN_HOURS=25
            LUMEN_FIRST_WEEKDAY=8
            LUMEN_DOCK_POSITION=top
            LUMEN_DOCK_AUTOHIDE=yes
            LUMEN_DOCK_SIZE=9999
            LUMEN_SCROLLBARS=Always; touch \(marker)
            LUMEN_START_URL=https://a.example/$(touch \(marker))
            LUMEN_START_URL_2=javascript:alert(1)
            LUMEN_START_URL_3=https://ok.example/ ; touch \(marker)

            """
        let run = try boot(settings: hostile)
        XCTAssertEqual(run.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "a value was run as a command")
        for refused in ["write -g AppleLanguages", "write -g AppleLocale", "settimezone", "AppleInterfaceStyle", "AppleAccentColor", "AppleICUForce",
                        "AppleFirstWeekday", "AppleShowScrollBars", "com.apple.dock orientation -string", "com.apple.dock autohide -bool",
                        "com.apple.dock tilesize -int", "scutil", "osascript", "example", "touch", "passwd"] {
            XCTAssertFalse(run.calls.contains { $0.contains(refused) }, "\(refused): \(run.calls)")
        }
        // Safari is opened, with no page of the file's.
        XCTAssertTrue(run.has("tester open -a Safari"))
        XCTAssertNil(status().appliedRevision)
    }

    func testWithNobodySignedInNothingOfAPersonsIsTouched() throws {
        for nobody in ["", "root", "loginwindow", "_mbsetupuser"] {
            let run = try boot(settings: VMGuestSettings(profile: VMProfile(name: "A", appearance: "dark")).text,
                               environment: ["CONSOLE_USER": nobody])
            XCTAssertEqual(run.status, 0, nobody)
            // Nothing of a person's — but macOS's panes for a new Mac, marked seen before any sign-in.
            XCTAssertFalse(run.calls.contains { $0.hasPrefix("tester ") && !$0.contains("com.apple.SetupAssistant") }, "\(nobody): \(run.calls)")
            XCTAssertFalse(run.calls.contains { $0.contains("AppleInterfaceStyle") || $0.contains(" open ") }, "\(nobody): \(run.calls)")
            // The system's own is set all the same, and the status says which system this is.
            XCTAssertTrue(run.has("root scutil --set HostName MacBook-Air"), nobody)
            XCTAssertEqual(status().systemVersion, "27.2.1", nobody)
            XCTAssertNil(status().appliedRevision, nobody)
        }
    }

    /// Each machine is a Mac its macOS has never seen: its panes for a new Mac — the "Welcome"
    /// screen whose button did not answer in a client's machine — are marked seen for the person
    /// who signs in by themselves, before anything else, and so before the sign-in.
    func testMacOSsPanesForANewMacAreMarkedSeenBeforeTheSignIn() throws {
        let run = try boot(settings: VMGuestSettings(profile: VMProfile(name: "A")).text)
        for key in ["DidSeeCloudSetup", "DidSeePrivacy", "DidSeeIntelligence", "DidSeeWelcome", "DidSeeScreenTime"] {
            XCTAssertTrue(run.has("tester defaults write com.apple.SetupAssistant \(key) -bool true"), "\(key): \(run.calls)")
        }
        XCTAssertTrue(run.has("tester defaults write com.apple.SetupAssistant LastSeenCloudProductVersion -string 27.2.1"))
        XCTAssertTrue(run.has("tester defaults write com.apple.SetupAssistant LastSeenBuddyBuildVersion -string 26B131"))
        XCTAssertTrue(run.has("tester defaults write com.apple.SetupAssistant LastPrivacyBundleVersion -string 9999"))
        // First of all: before the shared folder is looked for, before any setting of the person's.
        let marked = try XCTUnwrap(run.calls.firstIndex { $0.contains("com.apple.SetupAssistant") })
        let firstOther = try XCTUnwrap(run.calls.firstIndex { !$0.contains("com.apple.SetupAssistant") && !$0.contains("loginwindow autoLoginUser") })
        XCTAssertLessThan(marked, firstOther)

        // No one signs in by themselves, or a name that is no account's: nothing is written.
        for who in ["", "nobody-here", "a b; touch x"] {
            let quiet = try boot(settings: VMGuestSettings(profile: VMProfile(name: "A")).text, environment: ["AUTOLOGIN_USER": who])
            XCTAssertFalse(quiet.calls.contains { $0.contains("com.apple.SetupAssistant") }, "\(who): \(quiet.calls)")
        }
    }

    // MARK: - The installer

    /// The installer (install.sh) on the test's ground, beside the files it installs, with nothing
    /// on its input (no password typed): what it said, and what it called.
    private func install(environment: [String: String] = [:]) throws -> (status: Int32, said: String, calls: [String]) {
        let folder = root.appendingPathComponent("installer", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["lumen-guest.sh", "io.lumenbrowser.guest.plist"] {
            try Data(contentsOf: Self.folder.appendingPathComponent(name)).write(to: folder.appendingPathComponent(name))
        }
        let text = try onTestGround(try String(contentsOf: Self.folder.appendingPathComponent("install.sh"), encoding: .utf8))
        let file = folder.appendingPathComponent("install.sh")
        try Data(text.utf8).write(to: file)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("calls.log"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [file.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(environment) { _, mine in mine }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let log = (try? String(contentsOf: root.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return (process.terminationStatus, said, log.split(separator: "\n").map(String.init))
    }

    /// The choices of macOS's setup that would make a poor base — an Apple ID, which would be in
    /// every machine; FileVault, with which none signs in by itself — stop the installer before it
    /// changes anything or asks for the password, said in both languages with what to do.
    func testTheInstallerStopsOnAnAppleIDOrFileVaultAndSaysWhatToDo() throws {
        let signedIn = try install(environment: ["APPLE_ID": "someone@example.com"])
        XCTAssertEqual(signedIn.status, 1)
        XCTAssertTrue(signedIn.said.contains("signed in to an Apple ID"), signedIn.said)
        XCTAssertTrue(signedIn.said.contains("выполнен вход в Apple ID"), signedIn.said)
        XCTAssertTrue(signedIn.said.contains("Sign Out"), signedIn.said)
        XCTAssertFalse(signedIn.said.contains("Password of"), "asked for the password first")
        XCTAssertFalse(signedIn.calls.contains { $0.contains("sysadminctl") || $0.contains("pmset") }, "\(signedIn.calls)")

        let encrypted = try install(environment: ["FILEVAULT": "true"])
        XCTAssertEqual(encrypted.status, 1)
        XCTAssertTrue(encrypted.said.contains("FileVault is on"), encrypted.said)
        XCTAssertTrue(encrypted.said.contains("включён FileVault"), encrypted.said)
        XCTAssertFalse(encrypted.said.contains("Password of"))

        // Neither: on to the password (none is typed here, and it stops there).
        let fine = try install()
        XCTAssertTrue(fine.said.contains("Password of \"tester\""), fine.said)
        XCTAssertTrue(fine.said.contains("an empty password"), fine.said)
        XCTAssertFalse(fine.said.contains("Остановлено"), fine.said)

        // Not a virtual Mac, or as root: refused as before.
        XCTAssertTrue(try install(environment: ["HW_MODEL": "Mac15,3"]).said.contains("for a Lumen virtual machine"))
        XCTAssertTrue(try install(environment: ["INSTALL_USER": "root"]).said.contains("not as root"))
    }

    func testAMachineWithoutSettingsKeepsWhatItHas() throws {
        let run = try boot(settings: nil)
        XCTAssertEqual(run.status, 0)
        XCTAssertFalse(run.calls.contains { $0.contains("scutil") || $0.contains(" open ") || $0.contains("write -g AppleLanguages") }, "\(run.calls)")
        XCTAssertEqual(status().toolsVersion, VMGuestTools.version)
        XCTAssertEqual(run.calls.last, "root shutdown -h now")
    }

    // MARK: - The shared folder

    /// What the system prints beside the program's answer (it prints warnings of its own) is not
    /// the answer: a picture that was set is set.
    func testWhatTheSystemPrintsBesideTheAnswerIsNotTheAnswer() throws {
        try Data("PNG".utf8).write(to: share.appendingPathComponent(VMGuestSettings.wallpaperFileName))
        try boot(settings: VMGuestSettings(profile: VMProfile(name: "A")).text,
                 environment: ["OSASCRIPT_NOISE": "osascript[77:1234] +[NSXPCSharedListener endpointForReply:]: an error occurred"])
        XCTAssertEqual(status().wallpaperState, "set")
        XCTAssertNil(status().wallpaperNote)
    }

    /// A folder of the share's name that a start cut short left behind is not the share: macOS
    /// mounts the real one beside it, and what was written into the leftover would keep it there.
    func testAFolderLeftBehindIsNotTakenForTheShare() throws {
        // No volume mounted there, and none of Lumen's settings in it.
        let run = try boot(settings: nil, environment: ["SHARE_MOUNTED": "0", "SLEEPS_BEFORE_SHUTDOWN": "30"])
        XCTAssertEqual(run.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: share.appendingPathComponent(VMGuestSettings.statusFileName).path),
                       "the leftover was written into")
        // The script mounts the share itself, and goes on with that.
        let mount = root.appendingPathComponent("run")
        XCTAssertTrue(run.has("root mount_virtiofs com.apple.virtio-fs.automount \(mount.path)"), "\(run.calls)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mount.appendingPathComponent(VMGuestSettings.statusFileName).path))
        XCTAssertEqual(run.calls.last, "root shutdown -h now")
    }

    /// Lumen's settings in a folder make it the share whatever the system says of its device:
    /// only Lumen writes that file.
    func testAFolderWithLumensSettingsIsTheShare() throws {
        let run = try boot(settings: VMGuestSettings(profile: VMProfile(name: "A")).text, environment: ["SHARE_MOUNTED": "0"])
        XCTAssertFalse(run.calls.contains { $0.contains("mount_virtiofs com.apple.virtio-fs.automount") }, "\(run.calls)")
        XCTAssertTrue(run.has("tester open -a Safari"))
        XCTAssertEqual(status().toolsVersion, VMGuestTools.version)
    }

    // MARK: - A newer script

    /// A later Lumen's boot script, in the tools' folder the Mac shares read-only, takes this one's
    /// place and runs in its stead; one that is not newer, or is not a script, does not.
    func testANewerScriptInTheToolsFolderTakesThisOnesPlace() throws {
        let installed = own.appendingPathComponent("lumen-guest.sh")
        let offered = tools.appendingPathComponent("lumen-guest.sh")
        let ran = root.appendingPathComponent("the-newer-one-ran").path
        let settings = VMGuestSettings(profile: VMProfile(name: "A")).text

        try Data("#!/bin/sh\nTOOLS_VERSION=\(VMGuestTools.version + 1)\nprintf '%s' \"$LUMEN_GUEST_SHARE\" > '\(ran)'\n".utf8).write(to: offered)
        var run = try boot(settings: settings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ran), "the newer script was not run")
        // And it is handed the shared folder this one found, which it may not find again (one
        // this script mounted itself is not where the newer one looks first).
        XCTAssertEqual(try String(contentsOfFile: ran, encoding: .utf8), share.path)
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), try String(contentsOf: offered, encoding: .utf8))
        XCTAssertFalse(run.calls.contains { $0.contains(" open ") }, "the older script went on after handing over: \(run.calls)")
        XCTAssertTrue(run.calls.contains { $0.hasPrefix("root chown root:wheel ") })
        // The folder is mounted by root, by its own tag, where the script looks.
        XCTAssertTrue(run.has("root mount_virtiofs \(VMGuestSettings.toolsShareTag) \(tools.path)"), "\(run.calls)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: own.path), ["lumen-guest.sh"], "a temporary file was left")

        // The same version, an older one, and a file that is no script: this one stays and works.
        for (text, what) in [("#!/bin/sh\nTOOLS_VERSION=\(VMGuestTools.version)\n: > '\(ran)'\n", "the same version"),
                             ("#!/bin/sh\nTOOLS_VERSION=1\n: > '\(ran)'\n", "an older one"),
                             ("#!/bin/sh\nTOOLS_VERSION=\(VMGuestTools.version + 1)\nif then fi (\n", "not a script")] {
            try? FileManager.default.removeItem(atPath: ran)
            try? FileManager.default.removeItem(at: installed)
            try Data(text.utf8).write(to: offered)
            run = try boot(settings: settings)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ran), what)
            XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path), what)
            XCTAssertTrue(run.has("tester open -a Safari"), what)
        }
    }

    /// The shared folder is writable from inside the machine, by anything that runs there: a newer
    /// script left in it is not taken (it would run as root), whatever its version.
    func testANewerScriptInTheSharedFolderIsNotTaken() throws {
        let ran = root.appendingPathComponent("the-planted-one-ran").path
        try Data("#!/bin/sh\nTOOLS_VERSION=\(VMGuestTools.version + 1)\n: > '\(ran)'\n".utf8)
            .write(to: share.appendingPathComponent("lumen-guest.sh"))
        let run = try boot(settings: VMGuestSettings(profile: VMProfile(name: "A")).text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran), "a script from the shared folder was run")
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.appendingPathComponent("lumen-guest.sh").path))
        XCTAssertTrue(run.has("tester open -a Safari"))
        XCTAssertEqual(status().toolsVersion, VMGuestTools.version)
    }

    /// What anything in the machine left in the shared folder in the place of the files the
    /// script reads and writes as root — links to the guest's own files and folders — is not
    /// followed: the status replaces the link, a linked picture or settings file is not read.
    func testLinksInTheSharedFolderAreNotFollowed() throws {
        let precious = root.appendingPathComponent("precious")
        try Data("root's own\n".utf8).write(to: precious)
        let statusFile = share.appendingPathComponent(VMGuestSettings.statusFileName)
        try FileManager.default.createSymbolicLink(at: statusFile, withDestinationURL: precious)
        try FileManager.default.createSymbolicLink(at: share.appendingPathComponent(VMGuestSettings.wallpaperFileName), withDestinationURL: precious)
        // A picture the profile wants, but a link in its place: not read, not set.
        let run = try boot(settings: VMGuestSettings(profile: VMProfile(name: "A")).text)
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(try String(contentsOf: precious, encoding: .utf8), "root's own\n", "written through a link")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: statusFile.path), "the status is still a link")
        XCTAssertEqual(status().toolsVersion, VMGuestTools.version)
        XCTAssertEqual(status().wallpaperState, "none")
        XCTAssertFalse(run.calls.contains { $0.contains("osascript") }, "a linked picture was set: \(run.calls)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: guest.path).filter { $0.hasSuffix(".png") }, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: share.path).filter { $0.hasPrefix(".lumen-status.") }, [],
                       "a temporary file was left")

        // The status's place a link to a folder: nothing is moved into the folder.
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: statusFile)
        try FileManager.default.createSymbolicLink(at: statusFile, withDestinationURL: folder)
        try boot(settings: VMGuestSettings(profile: VMProfile(name: "A")).text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "written into the linked folder")
        XCTAssertEqual(status().toolsVersion, VMGuestTools.version)

        // The settings file a link: not read.
        let elsewhere = root.appendingPathComponent("elsewhere.env")
        try Data(VMGuestSettings(profile: VMProfile(name: "A", appearance: "dark")).text.utf8).write(to: elsewhere)
        let settings = share.appendingPathComponent(VMGuestSettings.fileName)
        try FileManager.default.removeItem(at: settings)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: elsewhere)
        let linked = try boot(settings: nil)
        XCTAssertEqual(linked.status, 0)
        XCTAssertNil(status().appliedRevision, "a linked settings file was read")
        XCTAssertFalse(linked.calls.contains { $0.contains("AppleInterfaceStyle") }, "\(linked.calls)")
    }

    /// The pictures are kept in a folder of root's; a picture tools 6 marked as set where it kept
    /// them is taken as set — the person's own choice since is not overridden.
    func testAPictureMarkedSetByAnOlderScriptIsKept() throws {
        let picture = Data("PNG".utf8)
        try picture.write(to: share.appendingPathComponent(VMGuestSettings.wallpaperFileName))
        let settings = VMGuestSettings(profile: VMProfile(name: "A")).text
        // The checksum's name, as the script gives it.
        let first = try boot(settings: settings, environment: ["SLEEPS_BEFORE_SHUTDOWN": "60"])
        XCTAssertGreaterThan(first.count("tester osascript "), 0)
        XCTAssertTrue(first.has("root chown root:wheel \(guest.path)"), "\(first.calls)")
        let marker = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: guest.path).first { $0.hasSuffix(".png.set") })
        try FileManager.default.removeItem(at: guest)
        try Data().write(to: old.appendingPathComponent(marker))
        let second = try boot(settings: settings)
        XCTAssertEqual(second.count("tester osascript "), 0, "\(second.calls)")
        XCTAssertEqual(status().wallpaperState, "kept")
    }

    // MARK: - The keyboard, the region's leftovers, and what the system has

    private static func layout(_ id: Int, _ name: String) -> String {
        "<dict><key>InputSourceKind</key><string>Keyboard Layout</string><key>KeyboardLayout ID</key><integer>\(id)</integer>"
            + "<key>KeyboardLayout Name</key><string>\(name)</string></dict>"
    }

    /// The layouts that go with the machine's language are written once, the first the one in
    /// use; macOS takes them at the next sign-in, and the status says so.
    func testTheKeyboardsLayoutsAreWrittenOnceAndAreInUseFromTheNextStart() throws {
        let american = VMGuestSettings(profile: VMProfile(name: "A", language: "en-US", localeFollowsProxy: false, lumenWallpaper: false,
                                                          keyboard: VMKeyboardLayout.automatic))
        XCTAssertTrue(american.text.contains("LUMEN_KEYBOARD=us\n"), american.text)
        let first = try boot(settings: american.text)
        let us = Self.layout(0, "U.S.")
        XCTAssertTrue(first.has("tester defaults write com.apple.HIToolbox AppleEnabledInputSources -array \(us)"), "\(first.calls)")
        XCTAssertTrue(first.has("tester defaults write com.apple.HIToolbox AppleSelectedInputSources -array \(us)"))
        XCTAssertTrue(first.has("tester defaults write com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID -string com.apple.keylayout.US"))
        XCTAssertTrue(first.has("tester defaults write io.lumenbrowser.guest keyboard -string us"))
        XCTAssertEqual(status().keyboardState, "next")
        XCTAssertTrue(status().keyboardFromNextStart)

        // The same choice at the next start: nothing is written again — what the person added
        // in the machine since stays.
        let second = try boot(settings: american.text, environment: ["KEYBOARD_NOTED": "us"])
        XCTAssertFalse(second.calls.contains { $0.contains("defaults write com.apple.HIToolbox") }, "\(second.calls)")
        XCTAssertEqual(status().keyboardState, "set")

        // A layout that types no Latin letters comes with the plain Latin one, and is the one in use.
        let russian = VMGuestSettings(profile: VMProfile(name: "A", lumenWallpaper: false, keyboard: "russian"))
        XCTAssertTrue(russian.text.contains("LUMEN_KEYBOARD=russian,abc\n"), russian.text)
        let third = try boot(settings: russian.text, environment: ["KEYBOARD_NOTED": "us"])
        XCTAssertTrue(third.has("tester defaults write com.apple.HIToolbox AppleEnabledInputSources -array "
                                + "\(Self.layout(19456, "Russian")) \(Self.layout(252, "ABC"))"), "\(third.calls)")
        XCTAssertTrue(third.has("tester defaults write com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID -string com.apple.keylayout.Russian"))

        // No choice: the base's layouts are left, and nothing is said of them.
        let plain = try boot(settings: VMGuestSettings(profile: VMProfile(name: "A", language: "en-US", localeFollowsProxy: false,
                                                                          lumenWallpaper: false)).text)
        XCTAssertFalse(plain.calls.contains { $0.contains("HIToolbox") || $0.contains("guest keyboard") }, "\(plain.calls)")
        XCTAssertNil(status().keyboardState)

        // And what is no layout of Lumen's reaches no command, whole or in part.
        for hostile in ["us;reboot", "us,klingon", "$(reboot)", "US"] {
            let run = try boot(settings: "LUMEN_REVISION=1\nLUMEN_HOSTNAME=Mac\nLUMEN_KEYBOARD=\(hostile)\n")
            XCTAssertFalse(run.calls.contains { $0.contains("HIToolbox") }, "\(hostile): \(run.calls)")
        }
    }

    /// A machine given another region than it had loses what macOS wrote down for the old one —
    /// once: what the person changes in the machine afterwards is kept.
    func testAMachineThatComesToAnotherRegionLosesWhatTheOldOneLeftBehind() throws {
        let settings = VMGuestSettings(profile: VMProfile(name: "A", language: "en-US", localeFollowsProxy: false, lumenWallpaper: false,
                                                          hourCycle: "24")).text
        let first = try boot(settings: settings, environment: ["LOCALE_NOTED": "ru_RU"])
        for key in ["AppleMeasurementUnits", "AppleMetricUnits", "AppleTemperatureUnit", "AppleICUDateFormatStrings",
                    "AppleICUNumberSymbols", "AppleFirstWeekday", "AppleICUForce12HourTime"] {
            XCTAssertTrue(first.has("tester defaults delete -g \(key)"), "\(key): \(first.calls)")
        }
        XCTAssertTrue(first.has("tester defaults write io.lumenbrowser.guest locale -string en_US"))
        // What the profile sets of them is written after, and stands.
        let removed = try XCTUnwrap(first.calls.firstIndex(of: "tester defaults delete -g AppleICUForce24HourTime"))
        let written = try XCTUnwrap(first.calls.firstIndex(of: "tester defaults write -g AppleICUForce24HourTime -bool true"))
        XCTAssertLessThan(removed, written)

        let second = try boot(settings: settings, environment: ["LOCALE_NOTED": "en_US"])
        XCTAssertTrue(second.has("tester defaults write -g AppleLocale -string en_US"))
        XCTAssertFalse(second.calls.contains { $0.contains("AppleMeasurementUnits") || $0.contains("AppleTemperatureUnit")
            || $0.contains("defaults delete -g AppleICUForce24HourTime") || $0.contains("guest locale -string") }, "\(second.calls)")
    }

    /// The script reads the time zone, the language and the locale back from the system, and
    /// Lumen compares them with what it asked for.
    func testWhatTheSystemHasIsReadBackAndComparedWithWhatWasAsked() throws {
        let settings = VMGuestSettings(profile: VMProfile(name: "A", timeZoneIdentifier: "Europe/Berlin", language: "de-DE",
                                                          localeFollowsProxy: false, lumenWallpaper: false, regionCode: "AT"))
        let zones = root.appendingPathComponent("zoneinfo").path
        try boot(settings: settings.text, environment: ["LOCALTIME": zones + "/Europe/Berlin", "APPLE_LANGUAGES": "de-DE",
                                                        "APPLE_LOCALE": "de_AT"])
        var said = status()
        XCTAssertEqual(said.timeZoneNow, "Europe/Berlin")
        XCTAssertEqual(said.languageNow, "de-DE")
        XCTAssertEqual(said.localeNow, "de_AT")
        XCTAssertEqual(said.differences(from: settings), [])

        // A system that took none of it: each is named, with what was asked and what there is.
        try boot(settings: settings.text, environment: ["LOCALTIME": zones + "/Europe/Moscow", "APPLE_LANGUAGES": "ru-RU",
                                                        "APPLE_LOCALE": "ru_RU@calendar=gregorian"])
        said = status()
        XCTAssertEqual(said.differences(from: settings), [
            VMGuestStatus.Difference(what: .timeZone, asked: "Europe/Berlin", has: "Europe/Moscow"),
            VMGuestStatus.Difference(what: .language, asked: "de-DE", has: "ru-RU"),
            VMGuestStatus.Difference(what: .locale, asked: "de_AT", has: "ru_RU"),
        ])

        // What the system says that is no time zone or language is not passed on.
        try boot(settings: settings.text, environment: ["LOCALTIME": "/etc/../x y", "APPLE_LANGUAGES": "de DE;", "APPLE_LOCALE": "$(x)"])
        said = status()
        XCTAssertNil(said.timeZoneNow)
        XCTAssertNil(said.localeNow)
        XCTAssertEqual(said.differences(from: settings).map(\.what), said.languageNow == nil ? [] : [.language])
    }

    // MARK: - A machine shown as a browser, and one woken from a saved state

    func testAMachineShownAsABrowserHidesItsMenuBarAndDockAndGetsThemBack() throws {
        let browser = VMGuestSettings(profile: VMProfile(name: "A", lumenWallpaper: false, browserMode: true))
        XCTAssertTrue(browser.text.contains("LUMEN_BROWSER_MODE=1\n"), browser.text)
        let first = try boot(settings: browser.text)
        XCTAssertTrue(first.has("tester defaults write -g _HIHideMenuBar -bool true"), "\(first.calls)")
        XCTAssertTrue(first.has("tester defaults write com.apple.dock autohide -bool true"))
        XCTAssertTrue(first.has("tester defaults write io.lumenbrowser.guest browser -string 1"))
        XCTAssertTrue(first.has("root killall Dock"))

        // So already: nothing is written again, and the Dock is left running.
        let second = try boot(settings: browser.text, environment: ["BROWSER_NOTED": "1", "DOCK_AUTOHIDE": "1"])
        XCTAssertFalse(second.calls.contains { $0.contains("_HIHideMenuBar") || $0.contains("write com.apple.dock") || $0.contains("killall Dock") },
                       "\(second.calls)")

        // No longer shown so: the menu bar is back, and the Dock too — unless the profile hides it.
        let plain = VMGuestSettings(profile: VMProfile(name: "A", lumenWallpaper: false))
        XCTAssertFalse(plain.text.contains("LUMEN_BROWSER_MODE"))
        let third = try boot(settings: plain.text, environment: ["BROWSER_NOTED": "1", "DOCK_AUTOHIDE": "1"])
        XCTAssertTrue(third.has("tester defaults delete -g _HIHideMenuBar"), "\(third.calls)")
        XCTAssertTrue(third.has("tester defaults delete io.lumenbrowser.guest browser"))
        XCTAssertTrue(third.has("tester defaults write com.apple.dock autohide -bool false"))
        let hidden = VMGuestSettings(profile: VMProfile(name: "A", lumenWallpaper: false, dockAutohide: true))
        let fourth = try boot(settings: hidden.text, environment: ["BROWSER_NOTED": "1", "DOCK_AUTOHIDE": "1"])
        XCTAssertTrue(fourth.has("tester defaults delete -g _HIHideMenuBar"))
        XCTAssertFalse(fourth.calls.contains { $0.contains("write com.apple.dock autohide") }, "\(fourth.calls)")

        // A machine never shown so: none of it is touched.
        let fifth = try boot(settings: plain.text)
        XCTAssertFalse(fifth.calls.contains { $0.contains("_HIHideMenuBar") || $0.contains("write com.apple.dock") }, "\(fifth.calls)")
    }

    func testAMachineWokenFromASavedStateAsksForTheTimeOnce() throws {
        let settings = VMGuestSettings(profile: VMProfile(name: "A", lumenWallpaper: false)).text
        let woke = share.appendingPathComponent(VMGuestSettings.wokeFileName)
        try Data("abc123".utf8).write(to: woke)
        let asked = "root sntp -sS time.apple.com"
        let first = try boot(settings: settings)
        XCTAssertEqual(first.count(asked), 1, "\(first.calls)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: woke.path), "the word is taken once")
        // The clock is set before the machine is asked anything else: before its shutdown here.
        XCTAssertLessThan(try XCTUnwrap(first.calls.firstIndex(of: asked)), try XCTUnwrap(first.calls.firstIndex(of: "root shutdown -h now")))

        // Not woken: the time is not asked for.
        XCTAssertEqual(try boot(settings: settings).count(asked), 0)
        // What is no word of Lumen's, or a link left in its place, asks for nothing.
        try Data("$(reboot) ;".utf8).write(to: woke)
        XCTAssertEqual(try boot(settings: settings).count(asked), 0)
        try? FileManager.default.removeItem(at: woke)
        let secret = root.appendingPathComponent("secret")
        try Data("abc123".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: woke, withDestinationURL: secret)
        XCTAssertEqual(try boot(settings: settings).count(asked), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))
    }
}
