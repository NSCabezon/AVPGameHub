#!/usr/bin/env python3
"""Generate the visionOS host app's .xcodeproj with no Xcode GUI needed.

Grown from spikes/device-probe/gen_xcodeproj.py, but data-driven: the guest
libraries are a list, not seven hand-written object ids each. That list — and
the product name, bundle id and display name that go with it — now comes from
visionos/targets.py, keyed on KLEPTON_TARGET. There are two guests, and two apps
built from one tree must not collide: a bundle ID separates the INSTALLED apps
and nothing about their build outputs, so the target carries the product name
(hence the .xcodeproj, the .app and the derived-data directory) and the
Frameworks/ subdirectory its translations were staged into.

What the app links, and why it comes from three places:

  Klepton.xcframework   the C runtime, built by `make xros` (both slices).
                        Static, so it is inside the app binary and carries no
                        load-time cost of its own.
  <guest>.xcframework   the five klepton-ld translations, built by mkguest.sh.
                        Embedded and signed-on-copy, NOT linked — nothing
                        references their symbols; the runtime dlopens them by
                        path. Linking them would make dyld resolve an exports
                        trie that klepton-ld deliberately does not emit.
  ANGLE_*.xcframework   ANGLE retargeted to visionOS, built by mkangle.sh.
                        Embedded the same way and for the same reason: kl_glfb
                        dlopens libEGL/libGLESv2 by path, and linking a renderer
                        the app never names would only make dyld load it on
                        every run, including the ones that stay on the null
                        driver.
  Sources/              the Swift app layer and kl_app.c.
"""
import os, pathlib, subprocess, sys, re

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import targets as targets_mod

HERE = os.path.dirname(os.path.abspath(__file__))
# Quiet about hub games left out for missing files: run.sh already said which, and why.
os.environ.setdefault("KL_HUB_QUIET", "1")
KLT = targets_mod.resolve(os.environ.get("KLEPTON_TARGET") or targets_mod.DEFAULT)
# The PRODUCT name, which is also the .xcodeproj's, the .app's and the scheme's.
# The Swift sources are still Klepton*.swift whatever the product is called —
# they are the app layer, shared by every target, and renaming them per build
# would be five file copies to say one thing.
NAME = KLT["product"]
# `or`, not a default: a config file may set KLEPTON_BUNDLE_ID to "" (an empty
# PRODUCT_BUNDLE_IDENTIFIER makes the pbxproj unreadable), like the shells' ${…:-…}.
BUNDLE_ID = os.environ.get("KLEPTON_BUNDLE_ID") or KLT["bundle"]

# Klepton.entitlements — the two memory capabilities (see that file for what
# they buy and why this app wants them). **On by default: they fixed the
# loading-transition kills on device, so a build without them is the unusual
# one.**
#
# KLEPTON_ENTITLEMENTS=0 detaches them, and the reason to keep that escape hatch
# is that this is an account setting as much as a build setting. Both keys need
# an EXPLICIT App ID with the capabilities enabled on it; the team's *wildcard*
# profile cannot carry capabilities at all, and attaching them to one does not
# degrade — it fails the build outright:
#
#   error: Provisioning profile "iOS Team Provisioning Profile: *" doesn't
#          support the Extended Virtual Addressing and Increased Memory Limit
#          capability.
#   error: Failed Registering Bundle Identifier: the app identifier
#          "…dev.klepton.target.beatsaber" cannot be registered to your
#          development team
#
# That pair of errors means the App ID is not set up, not that the entitlements
# are wrong. Enable both capabilities on it (Xcode > Settings > Accounts, or the
# developer portal) — or build with KLEPTON_ENTITLEMENTS=0 to get moving without
# them, at the cost of the memory headroom.
#
# The SECOND error has another cause worth telling apart, and it is why the id
# carries $USER (targets.py, bundle_for): an App ID belongs to exactly one team,
# so an UNSCOPED id is registered by whoever builds first and refused to everyone
# else — the same sentence, about a name already spoken for rather than about
# capabilities. If it appears with a scoped id, it really is the App ID setup.
ENTITLEMENTS = os.environ.get("KLEPTON_ENTITLEMENTS", "1") != "0"

# ...and the keys that are NOT self-service, each with its own escape hatch.
#
# The two memory keys above are safe to attach unconditionally: Xcode's own
# capability database knows them, they are enabled by ticking a box, and
# automatic signing adds them to the App ID on the next build. A key that is
# granted by REQUEST — or that the toolchain does not recognise at all — is on a
# completely different footing, because attaching one does not degrade. It fails
# the whole signing step, which takes the memory keys down with it, and those
# are what stopped the loading-transition kills. That is why
# `com.apple.developer.networking.multicast` was removed outright once the
# broadcast fan-out in kl_shim.c made it unnecessary.
#
# So a risky key gets a knob rather than a second authored file — two entitlement
# files that have to agree is exactly how they stop agreeing. The authored file
# is the union; the knob FILTERS a generated copy.
#
#   com.apple.developer.low-latency-streaming (off unless KLEPTON_LOW_LATENCY=1)
#       Added at the user's request while chasing a streaming regression. Note
#       honestly what is and is not known about it: this key does not appear in
#       the XROS SDK or in Xcode's Library tree — but neither do the two memory
#       keys, which certainly do work, so that search is INCONCLUSIVE and not
#       evidence the key is wrong. If the build starts failing with "doesn't
#       include the com.apple.developer.low-latency-streaming entitlement" (a
#       grant you must be given) or with an unknown-entitlement error (a key the
#       platform does not know), set KLEPTON_LOW_LATENCY=0 and the memory keys
#       survive. Do not diagnose a stream problem from its presence alone —
#       runtime/xr/kl_openxr.c's KL_XR_PROFILE is the A/B for the change that
#       actually altered what the client publishes.
OPTIONAL_ENTITLEMENTS = {
    "com.apple.developer.low-latency-streaming": "KLEPTON_LOW_LATENCY",
}
ENTITLEMENTS_FILE = "Klepton.entitlements"
# What an unset knob means: OFF in AVP Game Hub. The key is unverified and not
# self-service, and a team that was never granted it fails signing outright (taking
# the memory keys with it). KLEPTON_LOW_LATENCY=1 (local/config.env) attaches it.
OPTIONAL_ENTITLEMENTS_DEFAULT = "0"
_dropped = [k for k, env in OPTIONAL_ENTITLEMENTS.items()
            if (os.environ.get(env) or OPTIONAL_ENTITLEMENTS_DEFAULT) == "0"]
if ENTITLEMENTS and _dropped:
    import plistlib
    src = pathlib.Path(__file__).with_name("Klepton.entitlements")
    d = plistlib.loads(src.read_bytes())
    for k in _dropped:
        d.pop(k, None)
    out = pathlib.Path(__file__).with_name("build") / "Klepton-filtered.entitlements"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(plistlib.dumps(d))
    ENTITLEMENTS_FILE = "build/Klepton-filtered.entitlements"

ENTITLEMENTS_SETTING = (f"\t\t\t\tCODE_SIGN_ENTITLEMENTS = {ENTITLEMENTS_FILE};\n"
                        if ENTITLEMENTS else "")
# The HUB (targets.py kind "hub") embeds several guests at once, each into its
# OWN Frameworks/<game>/ subfolder of the .app, so same-named translations from
# two games (libunity, libUE4, libc++_shared) cannot collide. kl_app.c looks in
# Frameworks/<selected game>/ first. A single-target build is unchanged: its
# guest lands flat in Frameworks/, exactly as before.
#
# KLEPTON_HUB_NO_GUESTS=1 leaves the games' frameworks out — a UI-only build
# (the library, for the simulator, where the device-only translations have no
# slice). Such an app can show the library and cannot boot a game.
#
# A hub game whose inputs are not on this Mac (or that KLEPTON_HUB_GAMES leaves
# out) is not embedded either: targets.py hub_games() is the list this build
# carries, the same one run.sh translated; HUB_ALL is every game the row lists,
# which the library shows (the left-out ones as "not in this build").
IS_HUB = KLT["kind"] == "hub"
HUB_ALL = targets_mod.hub_games_all(KLT["name"]) if IS_HUB else []
HUB_GAMES = targets_mod.hub_games(KLT["name"], quiet=True) if IS_HUB else []
HUB_NO_GUESTS = IS_HUB and os.environ.get("KLEPTON_HUB_NO_GUESTS", "") not in ("", "0")
# [(game, libs)] — one entry, the target itself, for a single-target build.
if IS_HUB:
    GUEST_SETS = [(g, [] if HUB_NO_GUESTS else targets_mod.resolve(g)["libs"].split())
                  for g in HUB_GAMES]
else:
    GUEST_SETS = [(KLT["name"], KLT["libs"].split())]
GUEST = [l for _, libs in GUEST_SETS for l in libs]
# The runtime's compile-time default: the target itself, or a hub's first game
# (the library sets KL_TARGET to the one the player picks before configuring).
# A hub carrying no game still needs a name here; nothing boots it.
TARGET_DEFAULT = (HUB_GAMES or HUB_ALL)[0] if IS_HUB else KLT["name"]
ANGLE = ["ANGLE_libEGL", "ANGLE_libGLESv2"]
# ...and the OTHER renderer, for a guest whose graphics API is Vulkan (BONELAB).
# Same treatment as ANGLE for the same reasons: one driver for every guest that
# asks, dlopened by path at runtime (runtime/gfx/kl_vulkan.c), and 4.6 MB a slice —
# so making it per-target would cost a table row to save less than the row.
#
# OPTIONAL, unlike ANGLE, and that is the only difference: MoltenVK is a
# vendored prebuilt (`make mvk`) that a bare checkout does not have, and three of
# the four targets never ask for Vulkan. Absent, kl_vulkan.c's __has_include stub
# refuses BY NAME, which is the right answer for those three; making it mandatory
# would stop everyone's build for a dependency most targets do not use.
MVK = ["MoltenVK"] if os.path.isdir(
    os.path.join(HERE, "Frameworks", "MoltenVK.xcframework")) else []
# Where each set is staged on the SOURCE side. The guest's is per-target so the
# two apps do not overwrite each other's translations in place; ANGLE's is not,
# because it is the same renderer for every guest. Inside the built .app both
# land flat in Frameworks/, which is why kl_app.c needs to know nothing about it.
GUEST_DIR = f"Frameworks/{KLT['name']}"
ANGLE_DIR = "Frameworks"
def guest_dir(game): return f"Frameworks/{game}"
# Both sets are embedded-not-linked, so the pbxproj treatment is identical and
# the generator stays data-driven — the two lists differ only in what a missing
# one means, which is why main() reports them separately.
EMBED = GUEST + ANGLE + MVK


def detect_team():
    if os.environ.get("KLEPTON_TEAM"):
        return os.environ["KLEPTON_TEAM"]
    try:
        pem = subprocess.run(["security", "find-certificate", "-c", "Apple Development",
                              "-p"], capture_output=True, text=True).stdout
        subj = subprocess.run(["openssl", "x509", "-noout", "-subject"],
                              input=pem, capture_output=True, text=True).stdout
        m = re.search(r"OU\s*=\s*([A-Z0-9]{10})", subj)
        if m:
            return m.group(1)
    except Exception:
        pass
    return ""


TEAM = detect_team()

_n = [0]
def oid(tag):
    _n[0] += 1
    return ("KLEPT0N" + f"{_n[0]:04d}" + tag).upper().ljust(24, "0")[:24]


PROJ    = oid("PROJ");  TARGET = oid("TGT");   PRODUCT = oid("PROD")
G_ROOT  = oid("GROOT"); G_SRC  = oid("GSRC");  G_FW    = oid("GFW");  G_PROD = oid("GPRODS")
BP_SRC  = oid("BPSRC"); BP_FRM = oid("BPFRM"); BP_EMB  = oid("BPEMB")
CL_PROJ = oid("CLPRJ"); CL_TGT = oid("CLTGT")
C_PRJ_D = oid("CPRJD"); C_PRJ_R = oid("CPRJR")
C_TGT_D = oid("CTGTD"); C_TGT_R = oid("CTGTR")
F_C = oid("FC"); F_H = oid("FH"); F_BRIDGE = oid("FBRDG")
B_C = oid("BC")
# The app icon: an asset catalog holding one solid-image-stack per target that
# has one (AppIcon-<name>.solidimagestack). Targets without one build exactly
# as before - the catalog compiles empty for them and no APPICON setting is
# emitted, so the icon is strictly additive.
F_ASSETS = oid("FASSET"); B_ASSETS = oid("BASSET"); BP_RES = oid("BPRES")
import os as _os
# Compile-time launcher opt-in (also drives LAUNCHER_COND + the display name below).
_launcher_on = _os.environ.get("KL_CUSTOM_LAUNCHER", "").strip().lower() in ("1", "true", "yes", "on")
# NB: the bundle id is deliberately NOT switched by the launcher flag. It is a SIGNING
# identity, and forcing an unregistered id (e.g. com.noosphere.hl1vr) makes every local
# device build fail code-signing and silently relaunch the old app. For the neutral
# store id, register the App ID first, then archive with an explicit
# KLEPTON_BUNDLE_ID=com.noosphere.hl1vr. Local launcher builds keep the dev id and sign.
_assets_dir = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "Assets.xcassets")
def _stack_exists(n): return _os.path.isdir(_os.path.join(_assets_dir, n + ".solidimagestack"))
# With the launcher on, a trademark-free monogram icon (AppIcon-<t>-launcher) replaces
# the target's normal icon when one is present; otherwise the normal icon stands. Both
# are gitignored, so this is strictly local/opt-in.
_icon_base = f"AppIcon-{KLT['name']}"
_icon_name = (f"{_icon_base}-launcher"
              if _launcher_on and _stack_exists(f"{_icon_base}-launcher")
              else _icon_base)
HAS_ICON = _stack_exists(_icon_name)
ASSETCATALOG_SETTING = ((f"\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = \"{_icon_name}\";\n"
                         if HAS_ICON else "")
                        # Info.plist's CFBundleIconName is $(KL_APPICON_NAME) —
                        # always defined so expansion never leaves a literal
                        # "$(...)" in the bundle; the placeholder names no stack
                        # and behaves exactly like the old no-icon build.
                        + f"\t\t\t\tKL_APPICON_NAME = \"{_icon_name if HAS_ICON else 'AppIcon'}\";\n"
                        # Per-target defaults (targets.py), adapted from avp-play
                        # (MIT, github.com/myMartek/avp-play) visionos/gen_xcodeproj.py.
                        # A hub build bakes the hub row's (neutral) values; its
                        # games' own defaults come from KLGameSettings.
                        # Same route for the target's hand-matting default
                        # (targets.py "hand_matting"): Info.plist's
                        # KLHandMattingDefault is $(KL_HAND_MATTING_DEFAULT).
                        + f"\t\t\t\tKL_HAND_MATTING_DEFAULT = {1 if KLT['hand_matting'] else 0};\n"
                        # The target's gamepad face-button layout (targets.py
                        # "gamepad_map"), KLGamepadMap in Info.plist. Quoted: the
                        # value carries '=' and ','.
                        + f"\t\t\t\tKL_GAMEPAD_MAP = \"{KLT['gamepad_map']}\";\n"
                        # ...and its render-scale default (targets.py
                        # "render_scale"), KLRenderScaleDefault in Info.plist.
                        + f"\t\t\t\tKL_RENDER_SCALE_DEFAULT = {float(KLT['render_scale']):.2f};\n"
                        # ...and whether in-game video is tried by default
                        # (targets.py "video"), KLVideoDefault in Info.plist.
                        + f"\t\t\t\tKL_VIDEO_DEFAULT = {1 if KLT['video'] else 0};\n"
                        # ...whether the guest boots by itself or waits for the
                        # Start button (targets.py "autoboot"), and what the
                        # foveated-rendering setting starts at ("foveation").
                        + f"\t\t\t\tKL_AUTOBOOT_DEFAULT = {1 if KLT['autoboot'] else 0};\n"
                        + f"\t\t\t\tKL_FOVEATION_DEFAULT = {1 if KLT['foveation'] else 0};\n")

# The privacy strings, as BUILD SETTINGS and from here. Adapted from avp-play
# (MIT, github.com/myMartek/avp-play) visionos/gen_xcodeproj.py.
#
# They used to live only in Info.plist, and that is not a safe place for them:
# open the generated project in Xcode, touch the target's Info tab, and Xcode
# MOVES every usage description it recognises out of the plist and into the
# project file as INFOPLIST_KEY_* (it is consolidating them where
# GENERATE_INFOPLIST_FILE reads them). The plist is left without them — and the
# project file is rewritten by this script on the next build. So the strings
# vanish from both, nothing fails, and the app is killed by TCC two seconds
# after launch the moment it asks for accessory tracking (twice now: Beat Saber
# 1.40, then batman). Emitted here, they are in every project this writes,
# wherever else they do or do not survive. visionos/run.sh checks the product.
USAGE_DESCRIPTIONS = {
    "NSMicrophoneUsageDescription": "Klepton uses the microphone only when you turn on the Microphone toggle, so a running app (such as Steam Link voice chat) can hear you.",
    "NSWorldSensingUsageDescription": "Klepton reads the headset's own pose, which is the head pose the guest renders from.",
    "NSHandsTrackingUsageDescription": "Klepton maps your hands onto the guest's two Touch controllers.",
    "NSAccessoryTrackingUsageDescription": "Klepton maps PSVR2 Sense controllers onto the guest's two Touch controllers.",
    "NSBluetoothAlwaysUsageDescription": "Klepton connects to spatial controllers that are not visible to the system as standard game controllers.",
    "NSLocalNetworkUsageDescription": "Finds the Mac that streams your game to the headset (Play from Mac), and the PCs Steam Link streams from.",
}
_usage_settings = "".join(
    '\t\t\t\tINFOPLIST_KEY_%s = "%s";\n' % (k, v.replace("\\", "\\\\").replace('"', '\\"'))
    for k, v in USAGE_DESCRIPTIONS.items())
ASSETCATALOG_SETTING += _usage_settings

# Trim the asset catalog to THIS target. The shared Assets.xcassets holds one icon
# stack per target (~26), and actool compiles ALL of them into the app's Assets.car
# (~75 MB of icons the app never uses). So build a per-target catalog under build/
# (gitignored) carrying only this target's normal + launcher stacks, and reference
# THAT below instead of the full catalog. Iconless targets get an empty catalog,
# which builds exactly as the shared one did for them.
import shutil as _shutil
_appicon_catalog = f"build/appicon/{KLT['name']}.xcassets"
_cat_abs = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), _appicon_catalog)
_shutil.rmtree(_cat_abs, ignore_errors=True)
_os.makedirs(_cat_abs, exist_ok=True)
_src_contents = _os.path.join(_assets_dir, "Contents.json")
if _os.path.exists(_src_contents):
    _shutil.copy(_src_contents, _os.path.join(_cat_abs, "Contents.json"))
else:
    open(_os.path.join(_cat_abs, "Contents.json"), "w").write(
        '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n')
for _stack in (_icon_base, f"{_icon_base}-launcher"):
    _s = _os.path.join(_assets_dir, _stack + ".solidimagestack")
    if _os.path.isdir(_s):
        _shutil.copytree(_s, _os.path.join(_cat_abs, _stack + ".solidimagestack"))

# The Swift half of the language split: the App/UI, and the Compositor Services
# renderer adds. A list rather than an id pair each, for the same reason
# the guest libraries are one.
SWIFT = ["KleptonApp.swift", "KleptonCompositor.swift", "KleptonControllers.swift",
         "KleptonAudio.swift", "KleptonShell.swift", "KleptonTuning.swift",
         "KleptonChroma.swift", "KleptonMic.swift",
         "KleptonLauncher.swift", "KleptonHL1.swift", "KleptonHUD.swift",
         "KleptonStreamClient.swift"]
swift = [{"name": s, "ref": oid(f"FS{i}"), "bld": oid(f"BS{i}")} for i, s in enumerate(SWIFT)]

# The alyx build downloads its own game content from Steam (Sources/KleptonSteamContent.swift)
# through the SteamDepot Swift package, which lives in the AVP Game Hub checkout beside this
# tree (klepton/visionos -> ../../packages/SteamDepot), like the alyx srcdir does. Local package
# reference, alyx only; KL_STEAMDEPOT_PKG overrides the path (relative to visionos/). Fixed
# object ids rather than oid(): the counter would renumber every later object, and a kept,
# hand-edited project is diffed against this output.
def _fixed(tag): return ("KLEPT0N" + tag).upper().ljust(24, "0")[:24]
STEAMDEPOT_PKG = os.environ.get("KL_STEAMDEPOT_PKG", "../../packages/SteamDepot")
STEAMDEPOT = KLT["name"] == "alyx" or IS_HUB
if STEAMDEPOT and not os.path.isfile(os.path.join(HERE, STEAMDEPOT_PKG, "Package.swift")):
    print(f"!! alyx: no SteamDepot package at {os.path.join(HERE, STEAMDEPOT_PKG)} "
          "(set KL_STEAMDEPOT_PKG) - the in-app Steam download is left out", file=sys.stderr)
    STEAMDEPOT = False
PKG_REF, PKG_PROD, B_PKG = _fixed("SDPKGREF"), _fixed("SDPKGPROD"), _fixed("SDPKGBLD")
# The hub's Meta store source (Sources/KleptonMetaContent.swift): the MetaStore Swift package,
# a sibling of SteamDepot in the AVP Game Hub checkout (packages/). Hub only; KL_METASTORE_PKG overrides the path
# (relative to visionos/). Without it the hub has no Meta source (Steam and the catalog still work).
METASTORE_PKG = os.environ.get("KL_METASTORE_PKG", "../../packages/MetaStore")
METASTORE = IS_HUB
if METASTORE and not os.path.isfile(os.path.join(HERE, METASTORE_PKG, "Package.swift")):
    print(f"!! hub: no MetaStore package at {os.path.join(HERE, METASTORE_PKG)} "
          "(set KL_METASTORE_PKG) - the Meta store source is left out", file=sys.stderr)
    METASTORE = False
if STEAMDEPOT:
    swift.append({"name": "KleptonSteamContent.swift", "ref": _fixed("SDSWIFTF"), "bld": _fixed("SDSWIFTB")})
    # ...and the guest's Steamworks stand-in answered from the real account
    # (kl_steam_bridge.h's backend, over SteamDepot's SteamBridgeService).
    swift.append({"name": "KleptonSteamBridge.swift", "ref": _fixed("SDBRIDGEF"), "bld": _fixed("SDBRIDGEB")})
# The hub's library UI, plus a Swift file GENERATED here from targets.py naming the
# games this build carries (so the app's list and the embedded frameworks are the
# same list). The library works without SteamDepot (no download, no cover check),
# but the hub always has it unless the package is missing.
HUB_MANIFEST_REL = "build/hub/KleptonHubManifest.swift"
if IS_HUB:
    swift.append({"name": "KleptonHub.swift", "ref": _fixed("HUBSWIFTF"), "bld": _fixed("HUBSWIFTB")})
    # Derives what an APK game's runtime reads (<game>.apk, <tree>/assets, the
    # metadata below) from the data the headset downloaded, before boot.
    swift.append({"name": "KleptonHubPrep.swift", "ref": _fixed("HUBPREPF"), "bld": _fixed("HUBPREPB")})
    # Steam Cloud saves per game (experimental, off by default); compiled out without SteamDepot.
    swift.append({"name": "KleptonCloudSaves.swift", "ref": _fixed("HUBCLOUDF"), "bld": _fixed("HUBCLOUDB")})
    # The closed catalog of games and their store sources (Steam / Meta), and the Meta source
    # itself (compiled out without the MetaStore package).
    swift.append({"name": "KleptonCatalog.swift", "ref": _fixed("HUBCATF"), "bld": _fixed("HUBCATB")})
    swift.append({"name": "KleptonMetaContent.swift", "ref": _fixed("HUBMETAF"), "bld": _fixed("HUBMETAB")})
    swift.append({"name": "../" + HUB_MANIFEST_REL, "ref": _fixed("HUBMANF"), "bld": _fixed("HUBMANB")})
# Per-session performance summary (the compositor measures, the hub shows it).
# Every target: the compositor calls it. Fixed ids, so the numbering above is kept.
swift.append({"name": "KleptonSessionStats.swift", "ref": _fixed("SESSTATF"), "bld": _fixed("SESSTATB")})
# The in-game performance overlay and quick settings menu (drawn by KleptonHUD,
# driven by the controllers). Every target: the compositor and HUD call it.
swift.append({"name": "KleptonQuickSettings.swift", "ref": _fixed("QSETF"), "bld": _fixed("QSETB")})
# Siri / Shortcuts for the running game (App Intents), and the Spanish phrase
# catalog for them — hub only: the phrases name the hub ("AVP Game Hub").
# Localizable.xcstrings carries the Spanish intent titles / short titles (what the
# Shortcuts app lists); AppShortcuts.xcstrings only the phrases.
if IS_HUB:
    swift.append({"name": "KleptonIntents.swift", "ref": _fixed("INTENTSF"), "bld": _fixed("INTENTSB")})
_CATALOGS = ([("AppShortcuts.xcstrings", _fixed("APPSCSTRF"), _fixed("APPSCSTRB")),
              ("Localizable.xcstrings", _fixed("LOCSTRF"), _fixed("LOCSTRB"))] if IS_HUB else [])
SHORTCUTS_BUILDFILE = "".join(f'\t\t{b} /* {n} in Resources */ = {{isa = PBXBuildFile; fileRef = {f}; }};\n'
                              for n, f, b in _CATALOGS)
SHORTCUTS_FILEREF = "".join(f'\t\t{f} = {{isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; '
                            f'path = {n}; sourceTree = "<group>"; }};\n' for n, f, b in _CATALOGS)
SHORTCUTS_CHILD = "".join(f"\t\t\t\t{f},\n" for n, f, b in _CATALOGS)
SHORTCUTS_RES = "".join(f"\t\t\t\t{b},\n" for n, f, b in _CATALOGS)

# The two files apktool leaves beside assets/ — apktool.yml (versionCode /
# versionName) and the decoded AndroidManifest.xml (package, <meta-data>,
# permissions) — which the runtime reads through <assets>/../ (kl_jni_services.c).
# They are metadata, not game data, and decoding the APK's binary manifest on the
# headset would be a second apktool, so they are baked into the manifest here
# from the Mac's apktool tree and written beside the derived assets/ on device
# (Sources/KleptonHubPrep.swift). Base64, so no file content can end a Swift
# literal. A tree without them (a glibc guest) carries none.
HUB_META_FILES = ("apktool.yml", "AndroidManifest.xml")
def hub_meta(t):
    import base64
    out = []
    for m in HUB_META_FILES:
        p = os.path.join(HERE, "..", t["tree"], m)
        if t["kind"] != "glibc" and os.path.isfile(p):
            with open(p, "rb") as f:
                out.append('"%s": "%s"' % (m, base64.b64encode(f.read()).decode()))
    return "[" + (", ".join(out) if out else ":") + "]"

def hub_manifest():
    rows = []
    for g in HUB_ALL:
        t = targets_mod.TARGETS[g]
        rows.append('    KLHubGameRow(target: "%s", display: "%s", kind: "%s", entry: "%s", bundled: %s,\n'
                    '                 tree: "%s", apk: "%s", renderScale: %.2f, foveation: %s, glFoveation: %s, meta: %s),'
                    % (g, t["display"].replace('"', '\\"'), t["kind"], t["entry"],
                       "true" if g in HUB_GAMES and not HUB_NO_GUESTS else "false", t["tree"], t["apk"],
                       # The game's own render-scale and foveation defaults
                       # (targets.py "render_scale" / "foveation"); the hub bakes
                       # neutral Info.plist values.
                       float(t.get("render_scale", 1.0)),
                       "true" if t.get("foveation", True) else "false",
                       # "gl_foveation": False for a Vulkan guest (no GL rate map).
                       "true" if t.get("gl_foveation", True) else "false", hub_meta(t)))
    return ("// GENERATED by visionos/gen_xcodeproj.py from visionos/targets.py (hub \"%s\")"
            " - do not edit.\n// Add a game to the hub's \"games\" list in targets.py and regenerate.\n"
            "let klHubGameRows: [KLHubGameRow] = [\n%s\n]\n"
            "/// A UI-only build (KLEPTON_HUB_NO_GUESTS): no game is bundled, by choice.\n"
            "let klHubNoGuests = %s\n"
            "/// The checkout this build came from (KleptonSessionStats' build stamp).\n"
            "let klHubBuildCommit = \"%s\"\n" % (KLT["name"], "\n".join(rows), "true" if HUB_NO_GUESTS else "false", git_commit()))

def git_commit():
    import subprocess
    try:
        return subprocess.run(["git", "describe", "--always", "--dirty"], cwd=HERE, capture_output=True,
                              text=True, timeout=10).stdout.strip() or "unknown"
    except Exception:
        return "unknown"
# Local Swift packages linked into the app: (name, relative path, ref id, product id, build-file id).
PACKAGES = []
if STEAMDEPOT:
    PACKAGES.append(("SteamDepot", STEAMDEPOT_PKG, PKG_REF, PKG_PROD, B_PKG))
if METASTORE:
    PACKAGES.append(("MetaStore", METASTORE_PKG, _fixed("MSPKGREF"), _fixed("MSPKGPROD"), _fixed("MSPKGBLD")))
PKG_BUILDFILE = "".join(f'\t\t{b} /* {n} in Frameworks */ = {{isa = PBXBuildFile; productRef = {prod}; }};\n'
                        for n, _, _, prod, b in PACKAGES)
PKG_FRAMEWORK = "".join(f'\t\t\t\t{b} /* {n} in Frameworks */,\n' for n, _, _, _, b in PACKAGES)
PKG_TARGET_DEPS = ('\t\t\tpackageProductDependencies = (\n'
                   + "".join(f'\t\t\t\t{prod} /* {n} */,\n' for n, _, _, prod, _ in PACKAGES)
                   + '\t\t\t);\n') if PACKAGES else ""
PKG_PROJECT_REFS = ('\t\t\tpackageReferences = (\n'
                    + "".join(f'\t\t\t\t{ref} /* XCLocalSwiftPackageReference "{n}" */,\n' for n, _, ref, _, _ in PACKAGES)
                    + '\t\t\t);\n') if PACKAGES else ""
PKG_SECTIONS = ("/* Begin XCLocalSwiftPackageReference section */\n"
                + "".join(f'\t\t{ref} /* XCLocalSwiftPackageReference "{n}" */ = {{\n'
                          f'\t\t\tisa = XCLocalSwiftPackageReference;\n'
                          f'\t\t\trelativePath = "{path}";\n'
                          f'\t\t}};\n' for n, path, ref, _, _ in PACKAGES)
                + "/* End XCLocalSwiftPackageReference section */\n\n"
                + "/* Begin XCSwiftPackageProductDependency section */\n"
                + "".join(f'\t\t{prod} /* {n} */ = {{\n'
                          f'\t\t\tisa = XCSwiftPackageProductDependency;\n'
                          f'\t\t\tpackage = {ref} /* XCLocalSwiftPackageReference "{n}" */;\n'
                          f'\t\t\tproductName = {n};\n'
                          f'\t\t}};\n' for n, _, ref, prod, _ in PACKAGES)
                + "/* End XCSwiftPackageProductDependency section */\n") if PACKAGES else ""

swift_buildfiles = "\n".join(
    f'\t\t{s["bld"]} /* {s["name"]} in Sources */ = {{isa = PBXBuildFile; fileRef = {s["ref"]}; }};'
    for s in swift)
swift_filerefs = "\n".join(
    f'\t\t{s["ref"]} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
    f'path = {s["name"]}; sourceTree = "<group>"; }};' for s in swift)
swift_children = "\n".join(f'\t\t\t\t{s["ref"]},' for s in swift)
swift_sources  = "\n".join(f'\t\t\t\t{s["bld"]},' for s in swift)
F_RT    = oid("FRT");   B_RT_LNK = oid("BRTLK")

# One file ref + one embed build-file per embedded framework.
if IS_HUB:
    # Per game: its own copy phase (dstPath = the game's name, under Frameworks/).
    # Fixed ids keyed on the game's position, for the same reason as the package's.
    _pairs = [(l, g) for g, libs in GUEST_SETS for l in libs] + [(a, None) for a in ANGLE + MVK]
    guest = [{"name": n, "ref": oid(f"FG{i}"), "emb": oid(f"BG{i}"),
              "dir": guest_dir(g) if g else ANGLE_DIR, "game": g}
             for i, (n, g) in enumerate(_pairs)]
else:
    guest = [{"name": g, "ref": oid(f"FG{i}"), "emb": oid(f"BG{i}"),
              "dir": GUEST_DIR if g in GUEST else ANGLE_DIR, "game": None}
             for i, g in enumerate(EMBED)]

buildfiles = "\n".join(
    f'\t\t{g["emb"]} /* {g["name"]} in Embed */ = {{isa = PBXBuildFile; fileRef = {g["ref"]}; '
    f'settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};'
    for g in guest)

# Quoted, and it is not decoration: a pbxproj value may go unquoted only if it
# is alphanumerics, `_`, `.`, `/` and `-`. `libc++_shared` has a `+` in it, and
# the failure is not a bad reference — the whole project becomes unreadable,
# `xcodebuild` says "damaged ... due to a parse error" and names no file.
#
# A HUB game's frameworks are referenced as the platform SLICE's .framework, not
# as the .xcframework. Xcode first "processes" every xcframework into one flat
# BUILT_PRODUCTS_DIR/<name>.framework, so two games shipping a library of the
# same name (alyx and superhot both carry libphonon) fail the build with
# "Multiple commands produce .../libphonon.framework" before the per-game copy
# phases ever run. A plain .framework is copied (and signed) straight from its
# source into Frameworks/<game>/, so same-named ones never meet. The slice is the
# one this run builds for (run.sh exports XROS_PLATFORMS; device by default).
def hub_slice(xcfw):
    import plistlib
    want_sim = os.environ.get("XROS_PLATFORMS", "xros").split()[0] == "xrsim"
    with open(os.path.join(HERE, xcfw, "Info.plist"), "rb") as f:
        libs = plistlib.load(f).get("AvailableLibraries", [])
    for lib in libs:
        if (lib.get("SupportedPlatformVariant") == "simulator") == want_sim:
            return f'{xcfw}/{lib["LibraryIdentifier"]}/{lib["LibraryPath"]}', lib["LibraryPath"]
    return None

def fileref(g):
    xcfw = f'{g["dir"]}/{g["name"]}.xcframework'
    sl = hub_slice(xcfw) if g["game"] and os.path.isfile(os.path.join(HERE, xcfw, "Info.plist")) else None
    if sl:
        return (f'\t\t{g["ref"]} = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; '
                f'name = "{sl[1]}"; path = "{sl[0]}"; sourceTree = "<group>"; }};')
    return (f'\t\t{g["ref"]} = {{isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; '
            f'name = "{g["name"]}.xcframework"; path = "{xcfw}"; sourceTree = "<group>"; }};')
filerefs = "\n".join(fileref(g) for g in guest)

embeds = "\n".join(f'\t\t\t\t{g["emb"]},' for g in guest if not g["game"])
# The hub's per-game embed phases (none for a single-target build).
HUB_PHASES = [(game, _fixed(f"HUBEMB{i}")) for i, game in enumerate(HUB_GAMES) if not HUB_NO_GUESTS]
HUB_PHASE_IDS = "".join(f"\t\t\t\t{pid} /* Embed {game} */,\n" for game, pid in HUB_PHASES)
HUB_PHASE_SECTIONS = "".join(f"""\t\t{pid} /* Embed {game} */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "{game}";
\t\t\tdstSubfolderSpec = 10;
\t\t\tfiles = (
""" + "".join(f'\t\t\t\t{g["emb"]},\n' for g in guest if g["game"] == game) + f"""\t\t\t);
\t\t\tname = "Embed {game}";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
""" for game, pid in HUB_PHASES)
fwchildren = "\n".join(f'\t\t\t\t{g["ref"]},' for g in guest)

# Compile-time opt-in for the custom "configure, then Start" launcher (hl1/hl2/
# portal). Only when this project is generated with KL_CUSTOM_LAUNCHER set does the
# build carry the KL_CUSTOM_LAUNCHER Swift active-compilation condition that
# klLauncherTitle() (Sources/KleptonLauncher.swift) gates on — so a shipping build
# bakes the launcher in with no runtime env. Default builds (and visionos/run.sh)
# omit it and keep the original autoboot / "Boot"-button shape. Applies to both
# Debug and Release (this is the target-level COMMON block); $(inherited) preserves
# the project-level DEBUG condition.
# With the launcher on, the game builds present a compact trademark-free name; every
# other build (and every other target) keeps its normal display name from targets.py.
_launcher_display = {"hl1": "HL1VR", "hl2": "HL2VR", "portal": "P1VR"}
_display = (_launcher_display.get(KLT['name'], KLT['display']) if _launcher_on
            else KLT['display'])
# Trailing newline, glued at line-start to the next setting — the same shape as
# ENTITLEMENTS_SETTING / ASSETCATALOG_SETTING above, so it lands on its own line in
# the output and expands to nothing (no blank line) when the flag is off.
# KL_HUB likewise marks the hub build (Sources/KleptonHub.swift and the library
# gate in KleptonApp.swift); a single-target build carries neither.
_conds = (["KL_CUSTOM_LAUNCHER"] if _launcher_on else []) + (["KL_HUB"] if IS_HUB else [])
LAUNCHER_COND = (f'\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "{" ".join(_conds)} $(inherited)";\n'
                 if _conds else "")

# What the installed app says about itself (adapted from avp-play, MIT,
# github.com/myMartek/avp-play visionos/gen_xcodeproj.py): CFBundleShortVersionString and
# CFBundleVersion. An installer sets these (KLEPTON_APP_VERSION — the guest's own
# version — and KLEPTON_APP_BUILD — which build of it this is), because the app
# list of a headset is the only place a Mac can ask what is installed, and "1.0
# (1)" for every guest answers nothing. Up to three dot-separated integers each,
# which is all the two keys take; anything else keeps the old constant.
import re as _re
def _plist_version(env, dflt):
    v = os.environ.get(env, "")
    return v if _re.fullmatch(r"\d{1,9}(\.\d{1,9}){0,2}", v) else dflt
APP_VERSION = _plist_version("KLEPTON_APP_VERSION", "1.0")
APP_BUILD = _plist_version("KLEPTON_APP_BUILD", "1")

# The hub's Info.plist: visionos/Info.plist plus INAlternativeAppNames, so Siri also
# takes "… en Hub" / "… en Game Hub" for \(.applicationName) in the App Shortcut
# phrases (KleptonIntents.swift). An array of dicts has no INFOPLIST_KEY_ form, so
# the hub reads a generated copy; every other target reads Info.plist as before.
INFOPLIST_PATH = "Info.plist"
HUB_ALT_NAMES = ["Hub", "Game Hub"]
if IS_HUB:
    import plistlib
    _ip = plistlib.loads(pathlib.Path(__file__).with_name("Info.plist").read_bytes())
    _ip["INAlternativeAppNames"] = [{"INAlternativeAppName": n} for n in HUB_ALT_NAMES]
    _out = pathlib.Path(__file__).with_name("build") / "Info-hub.plist"
    _out.parent.mkdir(parents=True, exist_ok=True)
    _out.write_bytes(plistlib.dumps(_ip))
    INFOPLIST_PATH = "build/Info-hub.plist"

COMMON = f"""
				CLANG_ENABLE_MODULES = YES;
{ENTITLEMENTS_SETTING}				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = {APP_BUILD};
				DEVELOPMENT_TEAM = "{TEAM}";
				ENABLE_PREVIEWS = NO;
				GENERATE_INFOPLIST_FILE = YES;
{ASSETCATALOG_SETTING}				INFOPLIST_FILE = {INFOPLIST_PATH};
				// One entry per runtime source directory: a runtime header is
				// included by BARE NAME everywhere, including from
				// Klepton-Bridging-Header.h, so each directory holding one has
				// to be on the search path. Same list as the Makefile's
				// RUNTIME_INC; a new runtime/<area>/ needs a line in both.
				//
				// **The source tree comes BEFORE $(inherited)**, which carries
				// $(BUILT_PRODUCTS_DIR)/include — a directory Xcode copies
				// headers into and never removes them from. A header that MOVED
				// between runtime directories therefore leaves a copy at its old
				// bare path there for the life of the derived data, and with
				// $(inherited) first that stale copy shadows the real one: the
				// build fails on a symbol the header plainly declares, naming a
				// Swift line and not a header. Measured after runtime/<area>/
				// existed, on the per-target derived data that predated it.
				HEADER_SEARCH_PATHS = (
					"$(SRCROOT)/../runtime",
					"$(SRCROOT)/../runtime/jni",
					"$(SRCROOT)/../runtime/libc",
					"$(SRCROOT)/../runtime/gfx",
					"$(SRCROOT)/../runtime/xr",
					"$(SRCROOT)/../runtime/net",
					"$(SRCROOT)/../runtime/media",
					"$(SRCROOT)/../runtime/guest",
					"$(SRCROOT)/../runtime/diag",
					"$(SRCROOT)/../runtime/net",
					"$(inherited)",
				);
				// Two levels of escaping, and the first attempt had one. The
				// pbxproj layer eats a backslash, and the build system then
				// unquotes the setting VALUE the way a shell would — so a
				// single \" here reaches clang as -DKL_TARGET_DEFAULT=beatsaber
				// and fails with "use of undeclared identifier 'beatsaber'",
				// which names the target and says nothing about quoting.
				GCC_PREPROCESSOR_DEFINITIONS = (
					"$(inherited)",
					"KL_TARGET_DEFAULT=\\\\\\"{TARGET_DEFAULT}\\\\\\"",
				);
				INFOPLIST_KEY_CFBundleDisplayName = "{_display}";
				INFOPLIST_KEY_GCSupportsControllerUserInteraction = YES;
				// NOT UIApplicationSceneManifest_Generation. Setting it makes Xcode
				// GENERATE the scene manifest and overwrite the one in Info.plist —
				// with UISceneConfigurations as an EMPTY dict, i.e. the window role
				// and no immersive-space role at all. The app then has no immersive
				// scene session, and the failure is invisible from inside: the space
				// "opens", a LayerRenderer runs, drawables arrive fully formed and
				// every frame presents, into nothing. Apple's own template does not
				// set this and declares the manifest by hand; so do we now
				// (visionos/Info.plist). This was the black immersive space.
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = {APP_VERSION};
				// VideoToolbox/CoreMedia/CoreVideo are kl_vtdec's, and
				// they were missing here for the whole of the Steam Link arc:
				// kl_vtdec joined RUNTIME_SHIP, `make xros` kept passing because
				// its own link line has them, and nothing built the APP until a
				// second target needed one. The failure is a link error naming
				// VTDecompressionSession*, which reads as a missing SDK rather
				// than as a build setting that was never updated.
				// -lc++: Fossilize (kl_fossilize.cpp) rides in the runtime archive
				// when vendored (make fossilize); harmless when it does not.
				OTHER_LDFLAGS = "-lz -lc++ -framework AudioToolbox -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework IOSurface";
				PRODUCT_BUNDLE_IDENTIFIER = "{BUNDLE_ID}";
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = xros;
				SUPPORTED_PLATFORMS = "xros xrsimulator";
				SWIFT_OBJC_BRIDGING_HEADER = "Sources/Klepton-Bridging-Header.h";
{LAUNCHER_COND}				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = 7;
				// visionOS 26, not 2.0. The device runs 27 and the SDK is 26, and an
				// app declaring a 2.0 minimum is asking the system for five-major-
				// versions-ago behaviour — which for Compositor Services is not a
				// detail: 26 reworked the drawable model (queryDrawables,
				// Drawable.Target, CompositorContent, Metal 4 residency), and the
				// pre-26 path is what a 2.0 app gets. It also makes those APIs
				// unavailable at compile time, which is how it was noticed at all.
				XROS_DEPLOYMENT_TARGET = 26.0;
"""

PBX = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{}};
	objectVersion = 60;
	objects = {{

/* Begin PBXBuildFile section */
{swift_buildfiles}
		{B_C} /* kl_app.c in Sources */ = {{isa = PBXBuildFile; fileRef = {F_C}; }};
		{B_ASSETS} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {F_ASSETS}; }};
		{B_RT_LNK} /* Klepton.xcframework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {F_RT}; }};
{PKG_BUILDFILE}{SHORTCUTS_BUILDFILE}{buildfiles}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		{PRODUCT} /* {NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};
{swift_filerefs}
		{F_C} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = kl_app.c; sourceTree = "<group>"; }};
		{F_H} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = kl_app.h; sourceTree = "<group>"; }};
		{F_BRIDGE} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = "Klepton-Bridging-Header.h"; sourceTree = "<group>"; }};
		{F_ASSETS} = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = {_appicon_catalog}; sourceTree = "<group>"; }};
		{F_RT} = {{isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; name = Klepton.xcframework; path = ../build/Klepton.xcframework; sourceTree = "<group>"; }};
{SHORTCUTS_FILEREF}{filerefs}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{BP_FRM} = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{B_RT_LNK},
{PKG_FRAMEWORK}			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXCopyFilesBuildPhase section */
		{BP_EMB} /* Embed Frameworks */ = {{
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = "";
			dstSubfolderSpec = 10;
			files = (
{embeds}
			);
			name = "Embed Frameworks";
			runOnlyForDeploymentPostprocessing = 0;
		}};
{HUB_PHASE_SECTIONS}/* End PBXCopyFilesBuildPhase section */

/* Begin PBXGroup section */
		{G_ROOT} = {{
			isa = PBXGroup;
			children = (
				{G_SRC},
				{G_FW},
				{G_PROD},
				{F_ASSETS},
			);
			sourceTree = "<group>";
		}};
		{G_SRC} /* Sources */ = {{
			isa = PBXGroup;
			children = (
{swift_children}
				{F_C},
				{F_H},
				{F_BRIDGE},
{SHORTCUTS_CHILD}			);
			path = Sources;
			sourceTree = "<group>";
		}};
		{G_FW} /* Frameworks */ = {{
			isa = PBXGroup;
			children = (
				{F_RT},
{fwchildren}
			);
			name = Frameworks;
			sourceTree = "<group>";
		}};
		{G_PROD} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{PRODUCT},
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{TARGET} /* {NAME} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {CL_TGT};
			buildPhases = (
				{BP_SRC},
				{BP_FRM},
				{BP_RES},
				{BP_EMB},
{HUB_PHASE_IDS}			);
			buildRules = ();
			dependencies = ();
			name = {NAME};
{PKG_TARGET_DEPS}			productName = {NAME};
			productReference = {PRODUCT};
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{PROJ} = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {{
					{TARGET} = {{ CreatedOnToolsVersion = 16.0; }};
				}};
			}};
			buildConfigurationList = {CL_PROJ};
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (en, es, Base, );
			mainGroup = {G_ROOT};
			productRefGroup = {G_PROD};
{PKG_PROJECT_REFS}			projectDirPath = "";
			projectRoot = "";
			targets = (
				{TARGET},
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{BP_RES} = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{B_ASSETS},
{SHORTCUTS_RES}			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{BP_SRC} = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{swift_sources}
				{B_C},
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{C_PRJ_D} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = ( "DEBUG=1", "$(inherited)", );
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		{C_PRJ_R} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				SWIFT_COMPILATION_MODE = wholemodule;
			}};
			name = Release;
		}};
		{C_TGT_D} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{COMMON}			}};
			name = Debug;
		}};
		{C_TGT_R} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{COMMON}			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{CL_PROJ} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{C_PRJ_D},
				{C_PRJ_R},
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{CL_TGT} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{C_TGT_D},
				{C_TGT_R},
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */

{PKG_SECTIONS}	}};
	rootObject = {PROJ};
}}
"""


def main():
    # A device build cannot sign without a team, and Xcode's own error for that is a
    # page of provisioning noise; say what to do instead (run.sh sets KL_REQUIRE_TEAM
    # for device builds; the simulator signs ad hoc and needs none).
    if not TEAM and os.environ.get("KL_REQUIRE_TEAM", "") not in ("", "0"):
        print("!! no signing team: sign in under Xcode › Settings › Accounts (creates the Apple "
              "Development certificate) or set KLEPTON_TEAM", file=sys.stderr)
        return 1
    for g, d, how in [(l, guest_dir(game) if IS_HUB else GUEST_DIR,
                       f"KLEPTON_TARGET={game} visionos/mkguest.sh")
                      for game, libs in GUEST_SETS for l in libs] + \
                     [(a, ANGLE_DIR, "visionos/mkangle.sh") for a in ANGLE]:
        p = os.path.join(HERE, d, f"{g}.xcframework")
        if not os.path.isdir(p):
            print(f"!! missing {p} — run {how} first", file=sys.stderr)
            return 1
    if not os.path.isdir(os.path.join(HERE, "..", "build", "Klepton.xcframework")):
        print("!! missing build/Klepton.xcframework — run `make xros` first", file=sys.stderr)
        return 1

    if IS_HUB:
        mp = os.path.join(HERE, HUB_MANIFEST_REL)
        os.makedirs(os.path.dirname(mp), exist_ok=True)
        with open(mp, "w") as f:
            f.write(hub_manifest())

    proj = os.path.join(HERE, f"{NAME}.xcodeproj")
    os.makedirs(proj, exist_ok=True)
    with open(os.path.join(proj, "project.pbxproj"), "w") as f:
        f.write(PBX)
    print(f"wrote {proj}")
    print(f"  KLEPTON_TARGET            = {KLT['name']}")
    print(f"  DEVELOPMENT_TEAM = {TEAM or '(NOT DETECTED - set KLEPTON_TEAM)'}")
    # ENTITLEMENTS_FILE, not the literal name: this used to print
    # "Klepton.entitlements" unconditionally, so a build that was actually
    # signing against a FILTERED copy said it was signing against the authored
    # one. A summary that contradicts what went into the pbxproj is worse than
    # no summary — it is the line you would check to rule the filter out.
    print(f"  CODE_SIGN_ENTITLEMENTS = "
          f"{ENTITLEMENTS_FILE if ENTITLEMENTS else '(none - KLEPTON_ENTITLEMENTS=0)'}"
          + (f"  (dropped: {', '.join(_dropped)})" if ENTITLEMENTS and _dropped else ""))
    print(f"  PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID}")
    if STEAMDEPOT:
        print(f"  Swift package SteamDepot: {STEAMDEPOT_PKG} (in-app Steam content download)")
    if METASTORE:
        print(f"  Swift package MetaStore: {METASTORE_PKG} (in-app Meta store download)")
    if IS_HUB:
        for game, libs in GUEST_SETS:
            print(f"  hub game {game:<14} -> Frameworks/{game}/: "
                  + (f"{len(libs)} frameworks" if libs else "(none - KLEPTON_HUB_NO_GUESTS)"))
        for game in HUB_ALL:
            if game not in HUB_GAMES:
                print(f"  hub game {game:<14} -> not in this build (listed, cannot be played)")
    else:
        print(f"  embedded guest frameworks: {', '.join(GUEST)}")
    print(f"  embedded ANGLE:            {', '.join(ANGLE)}")
    # Named either way. An absent MoltenVK is legitimate for three of the four
    # targets and fatal for the fourth, and the difference is invisible until a
    # Vulkan guest is on a headset — so the build says which one it made.
    print(f"  embedded MoltenVK:         "
          + (', '.join(MVK) if MVK else "(none - run 'make mvk' for a Vulkan guest)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
