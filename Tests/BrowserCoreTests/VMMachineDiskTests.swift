#if canImport(Darwin)
import BrowserCore
import Foundation
import XCTest

final class VMMachineDiskTests: XCTestCase {
    func testExistingMachineSurvivesRepeatedPreparationAndMissingMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VMLibrary(root: root)
        let base = library.base
        try FileManager.default.createDirectory(at: base.directory, withIntermediateDirectories: true)
        for file in [base.disk, base.auxiliaryStorage, base.hardwareModel, base.machineIdentifier] {
            try Data(file.lastPathComponent.utf8).write(to: file)
        }
        let machine = library.machine(for: UUID())
        try machine.prepareDisk(baseDirectory: base.directory) {
            do {
                try machine.prepareDisk(baseDirectory: base.directory) { Data([2]) }
                XCTFail("overlapping initialization succeeded")
            } catch {
                XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            }
            return Data([1])
        }
        let guestData = Data("guest changes".utf8)
        try guestData.write(to: machine.disk)
        for _ in 0..<3 {
            try machine.prepareDisk(baseDirectory: nil) { XCTFail("identity recreated"); return Data() }
        }
        XCTAssertEqual(try Data(contentsOf: machine.disk), guestData)
        XCTAssertEqual(try Data(contentsOf: base.disk), Data("disk.img".utf8))
        try FileManager.default.removeItem(at: machine.hardwareModel)
        XCTAssertThrowsError(try machine.prepareDisk(baseDirectory: base.directory) { Data([2]) })
        XCTAssertEqual(try Data(contentsOf: machine.disk), guestData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.machinesDirectory.path).count, 1)
    }
}
#endif
