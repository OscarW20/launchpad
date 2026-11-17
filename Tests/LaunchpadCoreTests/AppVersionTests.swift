import XCTest
@testable import LaunchpadCore

final class AppVersionTests: XCTestCase {
    func testATaggedReleaseShowsVersionAndBuild() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "57",
                                   AppVersion.describeKey: "v0.2.0"]
        XCTAssertEqual(AppVersion.label(info: info), "0.2.0 (57)")
    }

    func testABuildBetweenTagsNamesTheCommit() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "60",
                                   AppVersion.describeKey: "v0.2.0-3-gabc1234"]
        XCTAssertEqual(AppVersion.label(info: info), "0.2.0 (60, v0.2.0-3-gabc1234)")
    }

    func testBeforeTheFirstTagTheCommitIsShown() {
        let version = AppVersion(short: "0.1.0", build: "42", describe: "abc1234-dirty")
        XCTAssertEqual(version.label, "0.1.0 (42, abc1234-dirty)")
    }

    func testMissingPartsAreLeftOut() {
        XCTAssertEqual(AppVersion.label(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]), "0.1.0 (1)")
        XCTAssertEqual(AppVersion.label(info: ["CFBundleShortVersionString": "0.1.0", AppVersion.describeKey: ""]), "0.1.0")
    }

    func testOutsideTheAppBundleItIsADevelopmentBuild() {
        XCTAssertEqual(AppVersion.label(info: nil), "Development build")
        XCTAssertEqual(AppVersion.label(info: ["CFBundleName": "Launchpad"]), "Development build")
    }
}
