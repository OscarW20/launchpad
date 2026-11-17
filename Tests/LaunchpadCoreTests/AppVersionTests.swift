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

    // MARK: Build stamps

    func testTheBuildStampNamesTheCommitAndCheckout() {
        let info: [String: Any] = [BuildStamp.commitKey: "155c7581f0", BuildStamp.sourceKey: "/Users/me/launchpad"]
        let stamp = BuildStamp(info: info)
        XCTAssertEqual(stamp?.commit, "155c7581f0")
        XCTAssertEqual(stamp?.source.path, "/Users/me/launchpad")
        XCTAssertEqual(stamp?.updateScript.path, "/Users/me/launchpad/scripts/update.sh")
    }

    func testNoBuildStampWithoutBothParts() {
        XCTAssertNil(BuildStamp(info: nil))
        XCTAssertNil(BuildStamp(info: [BuildStamp.commitKey: "155c758"]))
        XCTAssertNil(BuildStamp(info: [BuildStamp.commitKey: "", BuildStamp.sourceKey: "/Users/me/launchpad"]))
    }

    // MARK: Update log

    func testTheUpdateLogsLastProgressLineIsTheState() {
        XCTAssertNil(UpdateLog.state(of: ""))
        XCTAssertNil(UpdateLog.state(of: "Compiling LaunchpadCore\n"))
        let log = "==> Checking for updates\n==> Building Launchpad 0.1.0 (48)\n[3/9] Compiling\n"
        XCTAssertEqual(UpdateLog.state(of: log), .running("Building Launchpad 0.1.0 (48)"))
        XCTAssertEqual(UpdateLog.state(of: log + "==> Done: Launchpad is up to date at 155c758\n"),
                       .done("Launchpad is up to date at 155c758"))
        XCTAssertEqual(UpdateLog.state(of: log + "error: x\n==> Failed: couldn't reach GitHub.\n"),
                       .failed("couldn't reach GitHub."))
    }
}
