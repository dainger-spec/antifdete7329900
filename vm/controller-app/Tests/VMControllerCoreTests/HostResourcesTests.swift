import Foundation
import XCTest
@testable import VMControllerCore

final class HostResourcesTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("res-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testDirectorySize() throws {
        try Data(count: 1000).write(to: dir.appendingPathComponent("a.bin"))
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(count: 2345).write(to: sub.appendingPathComponent("b.bin"))
        XCTAssertEqual(HostResources.directorySize(at: dir), 3345)
        XCTAssertEqual(HostResources.directorySize(at: dir.appendingPathComponent("missing")), 0)
    }

    func testProfilesDiskBytes() throws {
        let vms = dir.appendingPathComponent("vms")
        let p1 = Profile(id: "a", name: "one")
        let p2 = Profile(id: "b", name: "two")
        try FileManager.default.createDirectory(at: vms.appendingPathComponent(p1.vmName), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 500).write(to: vms.appendingPathComponent(p1.vmName).appendingPathComponent("d"))
        // p2 has no VM dir yet → contributes 0. Allocation rounds up to blocks.
        let used = HostResources.profilesDiskBytes([p1, p2], vmsDirectory: vms)
        XCTAssertGreaterThanOrEqual(used, 500)
        XCTAssertLessThan(used, 1 << 20)
    }

    /// A sparse 1 GiB disk image takes almost nothing until written: count
    /// what is allocated, not the logical size.
    func testSparseDiskCountsWhatIsAllocated() throws {
        let vms = dir.appendingPathComponent("vms")
        let profile = Profile(id: "s", name: "sparse")
        let vmDir = vms.appendingPathComponent(profile.vmName)
        try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)
        let disk = vmDir.appendingPathComponent("disk.img")
        FileManager.default.createFile(atPath: disk.path, contents: nil)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        XCTAssertEqual(HostResources.directorySize(at: vmDir), 1 << 30, "logical size")
        XCTAssertLessThan(HostResources.profilesDiskBytes([profile], vmsDirectory: vms), 1 << 20)
    }

    func testParseFreeRAM() {
        let sample = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                               40000.
        Pages active:                             30000.
        Pages inactive:                           20000.
        Pages speculative:                         5000.
        Pages wired down:                         25000.
        """
        // (40000 + 20000 + 5000) * 16384 = 1064960000
        XCTAssertEqual(HostResources.parseFreeRAM(sample), 1_064_960_000)
        XCTAssertNil(HostResources.parseFreeRAM("not vm_stat output"))
    }

    func testLowRAM() {
        XCTAssertTrue(HostResources.isLowRAM(1_000_000_000))        // ~1 GB
        XCTAssertFalse(HostResources.isLowRAM(4_000_000_000))       // ~4 GB
        XCTAssertFalse(HostResources.isLowRAM(nil), "unknown free RAM is not a warning")
        XCTAssertEqual(HostResources.lowRAMThreshold, 2 * 1024 * 1024 * 1024)
    }
}
