import XCTest
@testable import BrowserCore

final class DownloadLogTests: XCTestCase {
    func testADownloadIsListedFromItsDestinationToItsEnd() {
        var log = DownloadLog()
        XCTAssertFalse(log.isRunning)
        let report = log.begin(name: "report.pdf", folder: "/Users/me/Downloads")
        let archive = log.begin(name: "archive.zip", folder: "/Volumes/Work")
        XCTAssertTrue(log.isRunning)
        XCTAssertEqual(log.entries.map(\.name), ["report.pdf", "archive.zip"], "oldest first")
        XCTAssertEqual(log.entries[0].state, .running(fraction: nil))
        log.progress(report, fraction: 0.4)
        XCTAssertEqual(log.entries[0].state, .running(fraction: 0.4))
        log.progress(report, fraction: 7)
        XCTAssertEqual(log.entries[0].state, .running(fraction: 1), "never past the whole of it")
        XCTAssertEqual(log.unseen, 0, "nothing has ended yet")

        log.finish(report, bytes: 2_400_000)
        log.fail(archive, reason: "The network connection was lost.")
        XCTAssertEqual(log.entries.map(\.state), [.finished(bytes: 2_400_000), .failed("The network connection was lost.")])
        XCTAssertEqual(log.unseen, 2)
        XCTAssertFalse(log.isRunning)

        // A download ends once: what comes after its end changes nothing.
        log.fail(report, reason: "late")
        log.progress(report, fraction: 0.1)
        log.finish(archive, bytes: 1)
        XCTAssertEqual(log.entries.map(\.state), [.finished(bytes: 2_400_000), .failed("The network connection was lost.")])
        XCTAssertEqual(log.unseen, 2)

        log.markSeen()
        XCTAssertEqual(log.unseen, 0)
        XCTAssertEqual(log.entries.count, 2, "looking at the list removes nothing")
    }

    func testACancelledSaveWasNeverADownload() {
        var log = DownloadLog()
        let asked = log.begin(name: "setup.dmg", folder: "/Users/me/Downloads")
        log.cancel(asked)
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(log.unseen, 0)
        let saved = log.begin(name: "kept.txt", folder: "/Users/me/Downloads")
        log.finish(saved, bytes: nil)
        log.cancel(saved)
        XCTAssertEqual(log.entries.map(\.name), ["kept.txt"], "a file that was saved stays listed")
        log.finish(UUID(), bytes: 3)
        XCTAssertEqual(log.unseen, 1, "a download nobody began is not counted")
    }

    func testClearingLeavesWhatIsStillComing() {
        var log = DownloadLog()
        let done = log.begin(name: "done.txt", folder: "/d")
        let failed = log.begin(name: "failed.txt", folder: "/d")
        _ = log.begin(name: "coming.iso", folder: "/d")
        log.finish(done, bytes: 10)
        log.fail(failed, reason: "no")
        log.clearEnded()
        XCTAssertEqual(log.entries.map(\.name), ["coming.iso"])
        XCTAssertEqual(log.unseen, 0)
    }

    func testTheListIsBounded() {
        var log = DownloadLog()
        let running = log.begin(name: "running", folder: "/d")
        for index in 0..<(DownloadLog.maximumEntries + 20) {
            log.finish(log.begin(name: "file \(index)", folder: "/d"), bytes: 1)
        }
        XCTAssertLessThanOrEqual(log.entries.count, DownloadLog.maximumEntries + 1)
        XCTAssertEqual(log.entries.first?.id, running, "a download still coming is never dropped for a newer one")
        XCTAssertEqual(log.entries.last?.name, "file \(DownloadLog.maximumEntries + 19)")
    }

    func testAnAttachmentIsWhatWebKitTakesForOne() {
        for header in ["attachment", "Attachment; filename=\"a.txt\"", "  ATTACHMENT ;filename=a", "attachment;filename*=UTF-8''%D1%84.pdf",
                       "form-data; name=x", "something-new"] {
            XCTAssertTrue(DownloadPolicy.isAttachment(contentDisposition: header), header)
        }
        for header in [nil, "", "inline", "INLINE; filename=\"a.pdf\"", " inline ", "filename=\"a.txt\"", "; filename=\"a.txt\"",
                       "name=\"file\"", "вложение; filename=a", "attach ment"] as [String?] {
            XCTAssertFalse(DownloadPolicy.isAttachment(contentDisposition: header), header ?? "nil")
        }
    }

    func testWhatCannotBeShownOrIsSentToBeSavedIsADownload() {
        XCTAssertTrue(DownloadPolicy.isDownload(canShow: false, contentDisposition: nil))
        XCTAssertTrue(DownloadPolicy.isDownload(canShow: true, contentDisposition: "attachment; filename=\"page.html\""))
        XCTAssertFalse(DownloadPolicy.isDownload(canShow: true, contentDisposition: nil))
        XCTAssertFalse(DownloadPolicy.isDownload(canShow: true, contentDisposition: "inline; filename=\"doc.pdf\""))
        XCTAssertTrue(DownloadPolicy.isDownload(canShow: false, contentDisposition: "inline"))
    }
}
