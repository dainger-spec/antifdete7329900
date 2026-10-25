import Foundation
import XCTest
@testable import VMControllerCore

final class BaseImagePolicyTests: XCTestCase {
    func testPullBaseArgv() {
        XCTAssertEqual(ProfilePlan.pullBase("ghcr.io/x/base:latest"), ["pull", "ghcr.io/x/base:latest"])
    }

    func testProfilesOnOtherBase() {
        let current = "ghcr.io/x/base:latest"
        let a = Profile(name: "a", baseImage: current)
        let b = Profile(name: "b", baseImage: "ghcr.io/x/base:2023")
        let c = Profile(name: "c", baseImage: current)
        let stale = BaseImagePolicy.profilesOnOtherBase([a, b, c], currentBase: current)
        XCTAssertEqual(stale.map(\.name), ["b"])
        XCTAssertTrue(BaseImagePolicy.profilesOnOtherBase([a, c], currentBase: current).isEmpty)
    }

    func testMigrationNoteMentionsRecreation() {
        XCTAssertTrue(BaseImagePolicy.migrationNote.contains("пересозда"))
    }
}
