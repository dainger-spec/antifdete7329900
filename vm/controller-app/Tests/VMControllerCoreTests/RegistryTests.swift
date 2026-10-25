import Foundation
import XCTest
@testable import VMControllerCore

final class RegistryTests: XCTestCase {

    // MARK: - OCIReference parsing

    func testParsesRegistryRepositoryTag() {
        let ref = OCIReference("ghcr.io/cirruslabs/macos-sonoma-base:latest")
        XCTAssertEqual(ref?.registry, "ghcr.io")
        XCTAssertEqual(ref?.repository, "cirruslabs/macos-sonoma-base")
        XCTAssertEqual(ref?.tag, "latest")
    }

    func testDefaultsTagToLatest() {
        XCTAssertEqual(OCIReference("ghcr.io/cirruslabs/base")?.tag, "latest")
    }

    func testDigestReference() {
        let ref = OCIReference("ghcr.io/x/base@sha256:abc123")
        XCTAssertEqual(ref?.repository, "x/base")
        XCTAssertEqual(ref?.tag, "sha256:abc123")
    }

    func testBareNameDefaultsToDockerHub() {
        let ref = OCIReference("ubuntu:22.04")
        XCTAssertEqual(ref?.registry, "docker.io")
        XCTAssertEqual(ref?.repository, "ubuntu")
        XCTAssertEqual(ref?.tag, "22.04")
    }

    func testHostWithPortIsNotMistakenForTag() {
        // "localhost:5000/base" — the colon is a port on the host, not a tag.
        let ref = OCIReference("localhost:5000/base:v1")
        XCTAssertEqual(ref?.registry, "localhost:5000")
        XCTAssertEqual(ref?.repository, "base")
        XCTAssertEqual(ref?.tag, "v1")
    }

    func testEmptyIsNil() {
        XCTAssertNil(OCIReference("   "))
    }

    func testManifestAndTokenURLs() {
        let ref = OCIReference("ghcr.io/cirruslabs/base:latest")
        XCTAssertEqual(ref?.manifestURL?.absoluteString,
                       "https://ghcr.io/v2/cirruslabs/base/manifests/latest")
        XCTAssertEqual(ref?.tokenURL?.absoluteString,
                       "https://ghcr.io/token?service=ghcr.io&scope=repository:cirruslabs/base:pull")
    }

    // MARK: - Token parsing

    func testParsesTokenField() {
        let data = Data(#"{"token":"abc"}"#.utf8)
        XCTAssertEqual(RegistryClient.parseToken(data), "abc")
    }

    func testFallsBackToAccessToken() {
        let data = Data(#"{"access_token":"xyz"}"#.utf8)
        XCTAssertEqual(RegistryClient.parseToken(data), "xyz")
    }

    func testInvalidTokenResponseIsNil() {
        XCTAssertNil(RegistryClient.parseToken(Data("not json".utf8)))
    }

    // MARK: - Update state

    func testUpToDateWhenDigestsMatch() {
        XCTAssertEqual(BaseImagePolicy.updateState(stored: "sha256:a", remote: "sha256:a"), .upToDate)
    }

    func testUpdateAvailableWhenDigestsDiffer() {
        XCTAssertEqual(BaseImagePolicy.updateState(stored: "sha256:a", remote: "sha256:b"), .updateAvailable)
    }

    func testUnknownWhenEitherMissing() {
        XCTAssertEqual(BaseImagePolicy.updateState(stored: nil, remote: "sha256:b"), .unknown)
        XCTAssertEqual(BaseImagePolicy.updateState(stored: "sha256:a", remote: nil), .unknown)
        XCTAssertEqual(BaseImagePolicy.updateState(stored: "", remote: "sha256:b"), .unknown)
    }
}
