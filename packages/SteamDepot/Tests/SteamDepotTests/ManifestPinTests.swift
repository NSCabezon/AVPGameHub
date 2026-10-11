import XCTest
@testable import SteamDepot

final class ManifestPinTests: XCTestCase {
    private let pins = ManifestPins(buildID: 25_487_405, manifests: [
        546_561: 1_436_897_171_613_240_821,
        546_564: 9_198_205_754_520_568_813,
    ])

    func testNoPinsResolvesToBranch() {
        let t = SupportedTitle(target: "alyx", usesSteamBuild: true)
        XCTAssertEqual(t.manifestSelection(depot: 546_564), .branch("public"))
        XCTAssertNil(t.manifestSelection(depot: 546_564).pinnedGID)
    }

    func testPinsResolveToPinnedGID() {
        let t = SupportedTitle(target: "alyx", usesSteamBuild: true, pinned: pins)
        XCTAssertEqual(t.manifestSelection(depot: 546_564), .pinned(9_198_205_754_520_568_813))
        XCTAssertEqual(t.manifestSelection(depot: 546_561).pinnedGID, 1_436_897_171_613_240_821)
        // Unpinned depot and non-public branches follow the branch.
        XCTAssertEqual(t.manifestSelection(depot: 1), .branch("public"))
        XCTAssertEqual(t.manifestSelection(depot: 546_564, branch: "beta"), .branch("beta"))
    }

    func testNoTitleIsPinnedYet() {
        XCTAssertTrue(SupportedTitles.byAppID.values.allSatisfy { $0.pinned == nil })
    }

    func testUpdateStatus() throws {
        func appInfo(_ m564: String) throws -> KeyValue {
            try KeyValue.parse(text: """
            "appinfo" { "depots" {
              "546561" { "manifests" { "public" { "gid" "1436897171613240821" } } }
              "546564" { "manifests" { "public" { "gid" "\(m564)" } } }
              "branches" { "public" { "buildid" "25500000" } }
            } }
            """)
        }
        let same = ManifestUpdateStatus.check(pins: pins, appInfo: try appInfo("9198205754520568813"))
        XCTAssertFalse(same.updateAvailable)
        let newer = ManifestUpdateStatus.check(pins: pins, appInfo: try appInfo("42"))
        XCTAssertTrue(newer.updateAvailable)
        XCTAssertEqual(newer.drifted.map(\.depotID), [546_564])
        XCTAssertEqual(newer.drifted.first?.latest, 42)
        XCTAssertEqual(newer.latestBuildID, 25_500_000)
        XCTAssertEqual(newer.pinnedBuildID, 25_487_405)
    }
}
