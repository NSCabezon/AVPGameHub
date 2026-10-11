import XCTest
@testable import SteamDepot

/// Classification against trimmed real PICS app info (common, config.launch, depots) taken
/// from api.steamcmd.net on 2026-10-07. No network.
final class SteamLibraryTests: XCTestCase {
    func testAlyxIsPlayableWithKnownARMLinuxDepot() throws {
        let e = try XCTUnwrap(SteamLibrary.classify(appID: 546560, appInfo: try KeyValue.parse(text: Fixtures.alyx)))
        XCTAssertEqual(e.name, "Half-Life: Alyx")
        XCTAssertEqual(e.status, .playable)
        XCTAssertEqual(e.kleptonTarget, "alyx")
        XCTAssertEqual(e.portUsesSteamBuild, true)
        XCTAssertTrue(e.isVR)
        // 546564 is only "oslist linux" in PICS; the override table marks it ARM64.
        // 1295040 (Workshop Tools DLC) and 228983/... (redistributables) are skipped.
        XCTAssertEqual(e.armDepots, [ARMDepot(depotID: 546564, kind: .linuxARM64, size: 637913859)])
        XCTAssertEqual(e.headerImageURL.absoluteString,
                       "https://shared.steamstatic.com/store_item_assets/steam/apps/546560/header.jpg")
    }

    func testAlyxWithoutPortIsCandidate() throws {
        let e = try XCTUnwrap(SteamLibrary.classify(appID: 546560, appInfo: try KeyValue.parse(text: Fixtures.alyx), supported: [:]))
        XCTAssertEqual(e.status, .candidate)
        XCTAssertNil(e.kleptonTarget)
    }

    func testAndroidDepotIsCandidate() throws {
        let e = try XCTUnwrap(SteamLibrary.classify(appID: 448280, appInfo: try KeyValue.parse(text: Fixtures.jobSimulator)))
        XCTAssertEqual(e.status, .candidate)
        XCTAssertTrue(e.isVR)
        XCTAssertEqual(e.armDepots, [ARMDepot(depotID: 448282, kind: .android, size: 1007320619)])
    }

    func testX86OnlyVRGameIsUnsupported() throws {
        let e = try XCTUnwrap(SteamLibrary.classify(appID: 571740, appInfo: try KeyValue.parse(text: Fixtures.golfIt)))
        XCTAssertEqual(e.name, "Golf It!")
        XCTAssertEqual(e.status, .unsupported)
        XCTAssertTrue(e.isVR) // flat game with an optional VR mode
        XCTAssertEqual(e.armDepots, []) // windows + macos depots only
    }

    func testArmLinuxOsarchAndNonGames() throws {
        let kv = try KeyValue.parse(text: """
        "appinfo" { "common" { "name" "Flat" "type" "Game" } "depots" {
          "11" { "config" { "oslist" "linux" "osarch" "arm64" } "manifests" { "public" "123" } }
          "12" { "config" { "oslist" "linux" "osarch" "64" } }
          "13" { "config" { "oslist" "android" } "depotfromapp" "99" } } }
        """)
        let e = try XCTUnwrap(SteamLibrary.classify(appID: 10, appInfo: kv, supported: [:]))
        XCTAssertEqual(e.armDepots, [ARMDepot(depotID: 11, kind: .linuxARM64, size: nil)])
        XCTAssertFalse(e.isVR)
        XCTAssertEqual(e.headerImageURL.absoluteString, "https://cdn.cloudflare.steamstatic.com/steam/apps/10/header.jpg")

        let dlc = try KeyValue.parse(text: #""appinfo" { "common" { "name" "Tools" "type" "DLC" } }"#)
        XCTAssertNil(SteamLibrary.classify(appID: 1295040, appInfo: dlc))
    }

    func testLibraryOrder() throws {
        let entries = [(571740, Fixtures.golfIt), (448280, Fixtures.jobSimulator), (546560, Fixtures.alyx)]
            .compactMap { SteamLibrary.classify(appID: UInt32($0.0), appInfo: try! KeyValue.parse(text: $0.1)) }
            .sorted(by: LibraryEntry.libraryOrder)
        XCTAssertEqual(entries.map(\.appID), [546560, 448280, 571740])
    }

    func testCacheRoundTripAndSupportedTableAppliedOnLoad() throws {
        // Cached entries are classified without the supported table; applying it later
        // turns Alyx from candidate into playable without a refetch.
        let raw = try XCTUnwrap(SteamLibrary.classify(appID: 546560, appInfo: try KeyValue.parse(text: Fixtures.alyx), supported: [:]))
        var cache = LibraryCache(steamID: 42, changeNumber: 100)
        cache.apps[546560] = .init(changeNumber: 7, entry: raw)
        cache.apps[1295040] = .init(changeNumber: 3, entry: nil)
        cache.packages[1] = .init(changeNumber: 9, appIDs: [546560, 1295040])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sd-cache-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try cache.save(url)
        XCTAssertNil(LibraryCache.load(url, steamID: 43)) // other account
        let back = try XCTUnwrap(LibraryCache.load(url, steamID: 42))
        XCTAssertEqual(back.packages[1]?.appIDs, [546560, 1295040])
        XCTAssertNil(back.apps[1295040]?.entry)
        let e = try XCTUnwrap(back.apps[546560]?.entry)
        XCTAssertEqual(e.status, .candidate)
        XCTAssertEqual(e.applying(SupportedTitles.byAppID).status, .playable)
        XCTAssertEqual(e.applying(SupportedTitles.byAppID).kleptonTarget, "alyx")
    }

    func testStaleFromChangeList() async throws {
        // With a change list no request is made: uncached ids and changed cached ids are stale.
        let stale = try await SteamLibrary.stale(ids: [1, 2, 3], cached: [1: 5, 2: 5], changed: [2, 99],
                                                 session: SteamSession(), packages: nil)
        XCTAssertEqual(stale, [2, 3])
    }

    func testBinaryPackageInfo() throws {
        // Package buffer layout after its 4-byte header: subtree "<id>" { int packageid,
        // subtree appids { int "0" ... } } end end.
        var b: [UInt8] = []
        func s(_ x: String) { b += Array(x.utf8) + [0] }
        func i32(_ name: String, _ v: UInt32) { b.append(2); s(name); b += withUnsafeBytes(of: v.littleEndian, Array.init) }
        b.append(0); s("123")
        i32("packageid", 123)
        b.append(1); s("billingtype"); s("10")
        b.append(0); s("appids"); i32("0", 546560); i32("1", 1295040); b.append(8)
        b.append(8); b.append(8)
        let kv = try KeyValue.parseBinary(Data(b))
        XCTAssertEqual(kv.name, "123")
        XCTAssertEqual(kv["packageid"]?.value, "123")
        XCTAssertEqual(kv["billingtype"]?.value, "10")
        XCTAssertEqual(SteamLibrary.appIDs(inPackage: kv), [546560, 1295040])
    }
}

enum Fixtures {
    static let alyx = #"""
    "appinfo" {
      "appid" "546560"
      "common" {
        "name" "Half-Life: Alyx"
        "type" "Game"
        "oslist" "windows,linux"
        "osarch" "64"
        "openvrsupport" "1"
        "controllervr" { "oculus" "1" "steamvr" "1" }
        "playareavr" { "roomscale" { "360_required" "0" "depth" "1.5" "width" "2" } "seated" "1" "standing" "1" }
        "category" { "category_13" "1" "category_17" "1" "category_2" "1" "category_22" "1" "category_30" "1" "category_31" "1" "category_52" "1" "category_54" "1" "category_62" "1" "category_65" "1" "category_68" "1" "category_69" "1" "category_70" "1" "category_78" "1" "category_79" "1" }
        "header_image" { "english" "header.jpg" }
      }
      "config" { "launch" {
        "0" { "arguments" "-vr -steam -noasserts -nopassiveasserts +map startup" "config" { "osarch" "64" "oslist" "windows" } "executable" "game/bin/win64/hlvr.exe" "type" "vr" }
        "1" { "arguments" "-steam -retail" "config" { "osarch" "64" "oslist" "windows" "ownsdlc" "1295040" } "description" "Workshop Tools" "executable" "game/bin/win64/hlvrcfg.exe" "type" "editor" "workingdir" "game/bin/win64/" }
        "2" { "arguments" "-vr -steam -noasserts -nopassiveasserts +map startup -vulkan" "config" { "osarch" "64" "oslist" "linux" } "executable" "game/hlvr.sh" "type" "vr" }
      } }
      "depots" {
        "1295040" { "config" { "language" "" "optionaldlc" "1295040" "osarch" "64" "oslist" "windows" } "dlcappid" "1295040" "manifests" { "previous_release" { "download" "699360336" "gid" "5726991073612952032" "size" "2667347898" } "public" { "download" "709507056" "gid" "6424030958142696855" "size" "2671879787" } } }
        "228983" { "config" { "oslist" "windows" } "depotfromapp" "228980" "sharedinstall" "1" }
        "228989" { "config" { "oslist" "windows" } "depotfromapp" "228980" "sharedinstall" "1" }
        "228990" { "config" { "oslist" "windows" } "depotfromapp" "228980" "sharedinstall" "1" }
        "546561" { "config" { "language" "" } "manifests" { "previous_release" { "download" "53448313376" "gid" "6340340699246199351" "size" "71955575627" } "public" { "download" "53809695232" "gid" "1436897171613240821" "size" "72480814167" } } }
        "546563" { "config" { "language" "" "oslist" "windows" } "manifests" { "previous_release" { "download" "584725232" "gid" "8142939566738022382" "size" "945180895" } "public" { "download" "609875392" "gid" "1898649366808652836" "size" "995599013" } } }
        "546564" { "config" { "language" "" "oslist" "linux" } "manifests" { "previous_release" { "download" "57369040" "gid" "1905868265862275921" "size" "214244652" } "public" { "download" "189713488" "gid" "9198205754520568813" "size" "637913859" } } }
        "appmanagesdlc" "1"
        "privatebranches" "1"
        "workshopdepot" "546560"
      }
    }
    """#

    static let jobSimulator = #"""
    "appinfo" {
      "appid" "448280"
      "common" {
        "name" "Job Simulator"
        "type" "Game"
        "oslist" "windows,android"
        "osarch" ""
        "openvrsupport" "1"
        "openxrsupport" "1"
        "controllervr" { "oculus" "1" "steamvr" "1" }
        "playareavr" { "roomscale" { "360_required" "0" "depth" "1.5" "width" "2" } }
        "category" { "category_13" "1" "category_2" "1" "category_22" "1" "category_29" "1" "category_31" "1" "category_40" "1" "category_52" "1" "category_54" "1" "category_62" "1" }
        "header_image" { "english" "header.jpg" }
      }
      "config" { "launch" {
        "0" { "config" { "oslist" "windows" } "description" "Job Simulator" "executable" "JobSimulator.exe" "type" "vr" }
        "1" { "config" { "oslist" "android" } "description" "Job Simulator" "description_loc" { "english" "Job Simulator" } "executable" "JobSimulator.apk" "type" "openxr" }
      } }
      "depots" {
        "448281" { "config" { "oslist" "windows" } "manifests" { "gfxtesting" { "download" "689958832" "gid" "3222154004461051493" "size" "1897311178" } "indexishere" { "download" "773891312" "gid" "4015798959743664104" "size" "1949485053" } "public" { "download" "790763712" "gid" "1769322319708578555" "size" "2103737890" } "touch-mousefix" { "download" "690113168" "gid" "943596449646619414" "size" "1898855938" } } }
        "448282" { "config" { "oslist" "android" } "manifests" { "public" { "download" "999586688" "gid" "7402932893341220786" "size" "1007320619" } } }
        "privatebranches" "1"
      }
    }
    """#

    static let golfIt = #"""
    "appinfo" {
      "appid" "571740"
      "common" {
        "name" "Golf It!"
        "type" "Game"
        "oslist" "windows,macos"
        "osarch" "64"
        "openvrsupport" "1"
        "controllervr" { "oculus" "1" "steamvr" "1" }
        "playareavr" { "seated" "1" "standing" "1" }
        "category" { "category_1" "1" "category_15" "1" "category_17" "1" "category_18" "1" "category_2" "1" "category_22" "1" "category_23" "1" "category_25" "1" "category_27" "1" "category_29" "1" "category_30" "1" "category_36" "1" "category_37" "1" "category_41" "1" "category_42" "1" "category_44" "1" "category_49" "1" "category_52" "1" "category_53" "1" "category_62" "1" }
        "header_image" { "english" "header.jpg" }
      }
      "config" { "launch" {
        "0" { "arguments" "-nohmd" "config" { "oslist" "windows" } "description" "DirectX11" "executable" "GolfIt.exe" "type" "default" }
        "1" { "arguments" "-d3d10 -nohmd" "config" { "oslist" "windows" } "description" "DirectX10" "executable" "GolfIt.exe" "type" "option1" }
        "3" { "arguments" "-vulkan -nohmd" "config" { "oslist" "windows" } "description" "Vulkan - experimental" "executable" "GolfIt.exe" "type" "option3" }
        "4" { "arguments" "-vr" "config" { "osarch" "64" "oslist" "windows" } "description" "VR" "description_loc" { "english" "VR" } "executable" "GolfIt.exe" "type" "vr" }
        "6" { "arguments" "-vr" "config" { "osarch" "64" "oslist" "windows" } "description" "VR Oculus" "description_loc" { "english" "VR Oculus" } "executable" "GolfIt.exe" "type" "othervr" }
        "8" { "config" { "oslist" "macos" } "executable" "GolfIt-Mac-Shipping.app\\Contents\\MacOS\\GolfIt-Mac-Shipping" "type" "default" }
      } }
      "depots" {
        "228984" { "config" { "oslist" "windows" } "depotfromapp" "228980" "sharedinstall" "1" }
        "228985" { "config" { "oslist" "windows" } "depotfromapp" "228980" "sharedinstall" "1" }
        "228986" { "config" { "oslist" "windows" } "depotfromapp" "228980" "sharedinstall" "1" }
        "228987" { "config" { "oslist" "windows" } "depotfromapp" "228980" "sharedinstall" "1" }
        "228988" { "config" { "oslist" "windows" } "depotfromapp" "228980" "sharedinstall" "1" }
        "228990" { "config" { "oslist" "windows" } "depotfromapp" "228980" "sharedinstall" "1" }
        "571741" { "config" { "osarch" "64" "oslist" "windows" } "manifests" { "beta" { "download" "6191764464" "gid" "319977511471128810" "size" "18950677796" } "legacy" { "download" "3742176640" "gid" "8449571964449759195" "size" "11519231643" } "public" { "download" "6191764464" "gid" "319977511471128810" "size" "18950677796" } } }
        "571742" { "config" { "oslist" "macos" } "manifests" { "beta" { "download" "6616323408" "gid" "6838836579646131202" "size" "20214652249" } "legacy" { "download" "4510137696" "gid" "3054868429790070529" "size" "14434282344" } "public" { "download" "6616323408" "gid" "6838836579646131202" "size" "20214652249" } } }
        "baselanguages" "english,german"
        "privatebranches" "1"
        "workshopdepot" "571740"
      }
    }
    """#
}
