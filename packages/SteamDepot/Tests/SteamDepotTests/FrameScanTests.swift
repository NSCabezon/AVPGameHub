import XCTest
@testable import SteamDepot

/// Steam Frame / ARM detection against trimmed real PICS app info (this account's PICS,
/// 2026-10-11) and file lists. No network.
final class FrameScanTests: XCTestCase {
    func kv(_ s: String) throws -> KeyValue { try KeyValue.parse(text: s) }

    func testSuperhotAndroidDepotLaunchAndLeptonRuntime() throws {
        let c = try XCTUnwrap(FrameScan.detect(appID: 617830, appInfo: try kv(FrameFixtures.superhot)))
        XCTAssertEqual(c.name, "SUPERHOT VR")
        XCTAssertTrue(c.isVR)
        XCTAssertTrue(c.hasARMBuild)
        XCTAssertEqual(c.support, .hub)
        XCTAssertEqual(c.kleptonTarget, "superhot")
        XCTAssertEqual(c.frameCategory, 3)
        XCTAssertEqual(c.frameRuntime, "lepton-stable")
        XCTAssertEqual(c.hints, ["common.oslist android", "lepton runtime (lepton-stable)"])
        // 617831 (windows,linux) is a probe target (VR game), 617833 the APK depot; 1049301
        // (depotfromapp) and 617832 (empty) are skipped.
        XCTAssertEqual(c.depots.map(\.depotID), [617831, 617833])
        let apk = try XCTUnwrap(c.depots.first { $0.depotID == 617833 })
        XCTAssertEqual(apk.kind, .android)
        XCTAssertEqual(apk.size, 646111372)
        XCTAssertEqual(apk.publicGID, 4045995471582008843)
        XCTAssertEqual(apk.branches, ["public", "legacy-ovr"])
        XCTAssertEqual(c.launches.map(\.executable), ["shvr.apk"])
        XCTAssertEqual(c.launches.first?.type, "openxr")
        XCTAssertEqual(c.armSize, 646111372)
    }

    func testMetroAndroidAPKIsUnrealFromLaunchName() throws {
        let c = try XCTUnwrap(FrameScan.detect(appID: 2669410, appInfo: try kv(FrameFixtures.metro)))
        XCTAssertEqual(c.support, .hub) // in the hub's catalog since the metro port
        XCTAssertNil(c.frameRuntime) // no steam_frame_compatibility block
        XCTAssertEqual(c.depots.map(\.depotID), [2669412]) // windows depot, shared redist and DLC skipped
        XCTAssertEqual(c.depots[0].kind, .android)
        XCTAssertEqual(c.engine, .unreal) // "<Project>-Android-Shipping-arm64.apk"
        XCTAssertEqual(c.launches.map(\.betakey), ["jenkins_ext,jenkins_ext_nightly", nil])
    }

    func testAlyxLinuxDepotNeedsKnownTableOrManifest() throws {
        let c = try XCTUnwrap(FrameScan.detect(appID: 546560, appInfo: try kv(Fixtures.alyx)))
        XCTAssertEqual(c.support, .hub)
        XCTAssertEqual(c.depots.map(\.depotID), [546564])
        XCTAssertEqual(c.depots[0].kind, .linuxARM64)
        XCTAssertEqual(c.depots[0].reasons, ["known arm64 linux depot"])
        XCTAssertTrue(c.launches.isEmpty) // game/hlvr.sh says nothing about the arch

        // Without the known table entry PICS alone only makes it a probe target; the manifest decides.
        var probe = try XCTUnwrap(FrameScan.detect(appID: 546560, appInfo: try kv(Fixtures.alyx.replacingOccurrences(of: "546564", with: "546569"))))
        XCTAssertEqual(probe.depots[0].kind, .linuxProbe)
        XCTAssertFalse(probe.hasARMBuild)
        FrameScan.apply(fileNames: ["game/hlvr.sh", "game/bin/linuxsteamrt64/hlvr", "game/bin/linuxsteamrtarm64/hlvr",
                                    "game/bin/linuxsteamrtarm64/libengine2.so"], depot: 546569, to: &probe)
        XCTAssertEqual(probe.depots[0].kind, .linuxARM64)
        XCTAssertTrue(probe.hasARMBuild)
        XCTAssertEqual(probe.engine, .source2)
        XCTAssertEqual(probe.depots[0].evidence, ["game/bin/linuxsteamrtarm64/hlvr", "game/bin/linuxsteamrtarm64/libengine2.so"])
    }

    func testFrameNativeGameWithArm64OnNewerBranch() throws {
        var c = try XCTUnwrap(FrameScan.detect(appID: 224760, appInfo: try kv(FrameFixtures.fez)))
        XCTAssertFalse(c.isVR)
        XCTAssertEqual(c.frameRuntime, "native")
        XCTAssertEqual(c.depots.map(\.depotID), [224762])
        // public (2016) and 1.11 (older) are not probed beyond public; beta and sdl3 are newer;
        // "secret" needs a password.
        XCTAssertEqual(c.depots[0].newerBranchGIDs, ["beta": 3203639762093675261, "sdl3": 5543701006814028900])

        FrameScan.apply(fileNames: ["FEZ.exe", "FNA.dll", "lib64/libSDL2-2.0.so.0"], depot: 224762, to: &c)
        XCTAssertEqual(c.depots[0].kind, .linuxX86)
        XCTAssertFalse(c.hasARMBuild)
        XCTAssertEqual(c.engine, .fna)

        FrameScan.apply(fileNames: ["FEZ.exe", "FNA.dll", "lib64/libSDL3.so.0", "libaarch64/libSDL3.so.0", "libaarch64/libFNA3D.so.0"],
                        depot: 224762, branch: "sdl3", to: &c)
        XCTAssertEqual(c.depots[0].kind, .linuxARM64)
        XCTAssertTrue(c.hasARMBuild)
        XCTAssertEqual(c.depots[0].evidence, ["[sdl3] libaarch64/libSDL3.so.0", "[sdl3] libaarch64/libFNA3D.so.0"])
        XCTAssertEqual(c.depots[0].reasons.last, "branch sdl3 manifest has arm64 binaries")
    }

    func testX86FrameRatingAloneIsNotACandidate() throws {
        // Cyberpunk 2077: Frame category 2 under proton-stable, windows/macos depots only.
        XCTAssertNil(FrameScan.detect(appID: 1091500, appInfo: try kv(FrameFixtures.protonOnly)))
        // The Lab: "proton-experimental-arm64" is Proton's own arch (FEX), the game is win64.
        XCTAssertNil(FrameScan.detect(appID: 450390, appInfo: try kv(FrameFixtures.protonOnly
            .replacingOccurrences(of: "proton-stable", with: "proton-experimental-arm64"))))
    }

    func testOsarchNameHintsAndSkippedTypes() throws {
        let c = try XCTUnwrap(FrameScan.detect(appID: 10, appInfo: try kv("""
        "appinfo" { "common" { "name" "Flat" "type" "Game" } "depots" {
          "11" { "config" { "oslist" "linux" "osarch" "arm64" } "manifests" { "public" { "gid" "5" "size" "100" } } }
          "12" { "name" "Steam Frame build" "manifests" { "public" { "gid" "6" "size" "50" } } }
          "13" { "config" { "oslist" "linux" "osarch" "64" } "manifests" { "public" { "gid" "7" } } }
          "14" { "config" { "oslist" "android" } "depotfromapp" "99" } }
          "config" { "launch" { "0" { "executable" "bin/linuxarm64/game" "config" { "oslist" "linux" } } } } }
        """)))
        XCTAssertEqual(c.depots.map(\.depotID), [11, 12]) // 13: x86 linux of a flat game, not probed by default
        XCTAssertEqual(c.depots.map(\.kind), [.linuxARM64, .android])
        XCTAssertEqual(c.depots[1].reasons, ["name mentions frame"])
        XCTAssertEqual(c.launches.map(\.executable), ["bin/linuxarm64/game"])
        XCTAssertEqual(c.armSize, 150)

        let all = try XCTUnwrap(FrameScan.detect(appID: 10, appInfo: try kv("""
        "appinfo" { "common" { "name" "Flat" "type" "Game" } "depots" {
          "13" { "config" { "oslist" "linux" } "manifests" { "public" { "gid" "7" } } } } }
        """), probeAllLinux: true))
        XCTAssertEqual(all.depots.map(\.kind), [.linuxProbe])

        XCTAssertNil(FrameScan.detect(appID: 11, appInfo: try kv(#""appinfo" { "common" { "name" "x" "type" "DLC" "oslist" "android" } }"#)))
    }

    func testEngineGuessAndArmPaths() {
        XCTAssertEqual(FrameScan.guessEngine(["Game_Data/il2cpp_data/Metadata/global-metadata.dat", "GameAssembly.so"]), .unityIL2CPP)
        XCTAssertEqual(FrameScan.guessEngine(["Game_Data/Managed/Assembly-CSharp.dll", "UnityPlayer.so"]), .unity)
        XCTAssertEqual(FrameScan.guessEngine(["Proj/Content/Paks/Proj-LinuxNoEditor.pak"]), .unreal)
        XCTAssertEqual(FrameScan.guessEngine(["game/hlvr/pak01_dir.vpk"]), .source2)
        XCTAssertEqual(FrameScan.guessEngine(["game.pck"]), .godot)
        XCTAssertEqual(FrameScan.guessEngine(["shvr.apk"]), .unknown)
        XCTAssertEqual(FrameScan.guessEngine(["Borderlands2/WillowGame/CookedPCConsole/English(US)/Startup.pck"]), .unknown) // not Godot
        let files = ["lib64/libSDL2.so", "libaarch64/libSDL2.so", "x.apk", "bin/libfoo.arm64.so", "readme.txt",
                     "drivers/vrlink/resources/android-steamlinkvr-release.apk"]
        XCTAssertEqual(FrameScan.armPaths(files), ["libaarch64/libSDL2.so", "x.apk"])
        XCTAssertEqual(FrameScan.strayARMLibraries(files), ["bin/libfoo.arm64.so", "drivers/vrlink/resources/android-steamlinkvr-release.apk"])
    }

    func testStrayArm64PluginDoesNotMakeABuild() throws {
        // Old World: x86_64 Unity player + an arm64 EOS SDK plugin in the same folder.
        var c = try XCTUnwrap(FrameScan.detect(appID: 597180, appInfo: try kv("""
        "appinfo" { "common" { "name" "Old World" "type" "Game" } "depots" {
          "597183" { "config" { "oslist" "linux" } "manifests" { "public" { "gid" "9" "size" "7" } } } } }
        """), probeAllLinux: true))
        FrameScan.apply(fileNames: ["OldWorld.x86_64", "UnityPlayer.so", "OldWorld_Data/Plugins/libEOSSDK-LinuxArm64-Shipping.so",
                                    "OldWorld_Data/Plugins/libEOSSDK-Linux-Shipping.so"], depot: 597183, to: &c)
        XCTAssertEqual(c.depots[0].kind, .linuxX86)
        XCTAssertFalse(c.hasARMBuild)
        XCTAssertEqual(c.depots[0].evidence, ["stray: OldWorld_Data/Plugins/libEOSSDK-LinuxArm64-Shipping.so"])
        XCTAssertEqual(c.engine, .unity)
    }

    func testEffortOrder() throws {
        let cs = [FrameFixtures.metro, FrameFixtures.superhot, FrameFixtures.fez]
            .enumerated().compactMap { FrameScan.detect(appID: [2669410, 617830, 224760][$0.offset], appInfo: try! kv($0.element)) }
            .sorted(by: FrameCandidate.effortOrder)
        // ARM builds first (hub before unported), the unprobed FEZ last.
        XCTAssertEqual(cs.map(\.appID), [617830, 2669410, 224760])
    }
}

enum FrameFixtures {
    static let superhot = #"""
    "appinfo"
    {
        "appid" "617830"
        "common"
        {
            "name" "SUPERHOT VR"
            "type" "Game"
            "controllervr" { "steamvr" "1" "oculus" "1" }
            "oslist" "windows,android"
            "osarch" ""
            "openvrsupport" "1"
            "openxrsupport" "1"
            "steam_frame_compatibility"
            {
                "category" "3"
                "tested_build_id" "24221542"
                "configuration" { "supported_input" "other" "recommended_runtime" "lepton-stable" "tso_enable" "0" }
            }
        }
        "config"
        {
            "installdir" "SUPERHOT VR"
            "launch"
            {
                "0" { "executable" "SUPERHOTVR.exe" "type" "vr" "config" { "oslist" "windows" "betakey" "legacy-ovr,qa-test2" } }
                "7" { "executable" "shvr.apk" "type" "openxr" "config" { "oslist" "android" } }
                "8" { "executable" "SUPERHOT_VR.exe" "type" "openxr" "config" { "oslist" "windows" } }
            }
        }
        "depots"
        {
            "hasdepotsindlc" "0"
            "617831"
            {
                "config" { "oslist" "windows,linux" }
                "manifests"
                {
                    "public" { "gid" "43145839185200379" "size" "1695768427" "download" "510094912" }
                    "legacy-ovr" { "gid" "3690464461302585406" "size" "2112747310" "download" "643443792" }
                }
            }
            "1049301" { "manifests" { "public" { "gid" "2851457324418590631" "size" "2657796057" } } "depotfromapp" "1049300" }
            "617832" { }
            "617833"
            {
                "config" { "oslist" "android" }
                "manifests"
                {
                    "public" { "gid" "4045995471582008843" "size" "646111372" "download" "521945968" }
                    "legacy-ovr" { "gid" "9118561561795529904" "size" "647071331" "download" "522039392" }
                }
            }
            "branches"
            {
                "public" { "buildid" "25664086" "timebuildupdated" "1790893873" }
                "legacy-ovr" { "buildid" "24841806" "description" "Legacy version using the OVR backend" "timebuildupdated" "1787234932" }
            }
        }
    }
    """#

    static let metro = #"""
    "appinfo"
    {
        "common" { "name" "Metro Awakening" "type" "Game" "oslist" "windows,android" "osarch" "64" "openxrsupport" "1" }
        "config"
        {
            "launch"
            {
                "0" { "executable" "Impact.exe" "type" "vr" "config" { "oslist" "windows" "osarch" "64" } }
                "1" { "executable" "Impact-Android-Test-arm64.apk" "type" "openxr" "config" { "oslist" "android" "betakey" "jenkins_ext,jenkins_ext_nightly" } }
                "2" { "executable" "Impact-Android-Shipping-arm64.apk" "type" "openxr" "config" { "oslist" "android" } }
            }
        }
        "depots"
        {
            "228989" { "config" { "oslist" "windows" } "depotfromapp" "228980" "sharedinstall" "1" }
            "2669411" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "6925264499529975413" "size" "30141890044" } } }
            "2669412" { "config" { "oslist" "android" } "manifests" { "public" { "gid" "1647016831183633253" "size" "19156854521" } } }
            "2841900" { "dlcappid" "2841900" }
            "branches" { "public" { "buildid" "23640767" "timebuildupdated" "1781006937" } }
        }
    }
    """#

    static let fez = #"""
    "appinfo"
    {
        "common"
        {
            "name" "FEZ" "type" "Game" "oslist" "windows,macos,linux"
            "steam_frame_compatibility" { "category" "3" "configuration" { "recommended_runtime" "native" } }
        }
        "depots"
        {
            "224761" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "1" "size" "400000000" } } }
            "224762"
            {
                "config" { "oslist" "linux" }
                "manifests"
                {
                    "public" { "gid" "5672754372855605298" "size" "441317193" }
                    "1.11" { "gid" "806695957621298636" "size" "427020412" }
                    "beta" { "gid" "3203639762093675261" "size" "430032964" }
                    "sdl3" { "gid" "5543701006814028900" "size" "434152737" }
                    "secret" { "gid" "42" "size" "1" }
                }
            }
            "branches"
            {
                "public" { "buildid" "1493264" "timebuildupdated" "1480639231" }
                "1.11" { "buildid" "306353" "description" "1.11 (MonoGame)" "timebuildupdated" "1403592182" }
                "beta" { "buildid" "15155093" "timebuildupdated" "1721939926" }
                "sdl3" { "buildid" "24436282" "description" "SDL 3.0 Testing, UNSTABLE" "timebuildupdated" "1785257659" }
                "secret" { "buildid" "2" "pwdrequired" "1" "timebuildupdated" "1790000000" }
            }
        }
    }
    """#

    static let protonOnly = #"""
    "appinfo"
    {
        "common"
        {
            "name" "Cyberpunk 2077" "type" "Game" "oslist" "windows,macos"
            "steam_frame_compatibility" { "category" "2" "configuration" { "recommended_runtime" "proton-stable" } }
        }
        "config" { "launch" { "0" { "executable" "bin/x64/Cyberpunk2077.exe" "config" { "oslist" "windows" } } } }
        "depots"
        {
            "1091501" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "1" "size" "2" } } }
            "1091502" { "config" { "oslist" "macos" } "manifests" { "public" { "gid" "3" "size" "4" } } }
        }
    }
    """#
}
