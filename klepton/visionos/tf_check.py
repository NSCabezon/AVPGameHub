#!/usr/bin/env python3
"""Local App Store Connect pre-flight for a built visionOS .app (or an .ipa).

    python3 visionos/tf_check.py <App.app | App.ipa> [--bundle-id ID] [--team T]
                                 [--distribution] [--json out.json]

Everything here runs offline, with no Apple account: it is what can be known
about an upload before `altool --validate-app` (which needs an App Store Connect
record and credentials) or the upload itself. Each check prints PASS / WARN /
FAIL with the reason; the exit status is 1 if anything FAILed.

--distribution adds the checks that only make sense on the EXPORTED (App Store
signed) app: no get-task-allow, beta-reports-active, an App Store profile with
no device list, and the profile's entitlements covering the app's.

What the checks are, and the App Store error each one stands in for:

  Info.plist        ids, versions, MinimumOSVersion, the encryption answer
                    (ITSAppUsesNonExemptEncryption), the icon, and every usage
                    description for a permission the app's code requests.
  PrivacyInfo       an app-level privacy manifest at the bundle root (ITMS-91053).
  stray files       .so / .py / __pycache__ / .DS_Store / headers / .debug.dylib
                    / __preview.dylib / loose dylibs (ITMS-90171, 90206...).
  Frameworks/ dir   nothing directly in it but *.framework bundles and *.dylib
                    files — no subfolders, no loose files (ITMS-90432) — and no
                    framework anywhere but directly in it (90205).
  frameworks        a complete Info.plist each, unique and well-formed
                    CFBundleIdentifiers (90046, 90685), an executable that exists,
                    is named legally (90121) and is named like the framework, a
                    MinimumOSVersion not above the app's (90208), no framework
                    nested in a framework (90205).
  Mach-O            every binary arm64-only, built for the visionOS DEVICE
                    platform (not the simulator), minos <= the app's, __TEXT
                    under the 500 MB per-binary limit.
  signature         codesign --verify --deep --strict on the app and on every
                    entry of Frameworks/ one by one (so a failure names it).
  size              the uncompressed app against the 4 GB limit.
"""
import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

RESULTS = []


def rec(level, what, detail=""):
    RESULTS.append((level, what, detail))
    print(f"  {level:<4} {what}" + (f" — {detail}" if detail else ""))


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def load_plist(path):
    with open(path, "rb") as f:
        return plistlib.load(f)


def vtuple(v):
    try:
        return tuple(int(x) for x in str(v).split("."))
    except ValueError:
        return (999,)


def is_macho(path):
    try:
        with open(path, "rb") as f:
            m = f.read(4)
    except OSError:
        return False
    return m in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xce\xfa\xed\xfe")


# The usage descriptions the app's code needs, keyed on what requests them. A
# missing one is a SIGKILL from TCC on visionOS (see Info.plist), and an upload
# warning or rejection (ITMS-90683) from App Store Connect.
REQUIRED_USAGE = {
    "NSMicrophoneUsageDescription": "AVAudioApplication.requestRecordPermission (KleptonMic)",
    "NSWorldSensingUsageDescription": "WorldTrackingProvider (KleptonCompositor)",
    "NSHandsTrackingUsageDescription": "HandTrackingProvider (KleptonCompositor)",
    "NSAccessoryTrackingUsageDescription": "AccessoryTrackingProvider (KleptonControllers)",
    "NSBluetoothAlwaysUsageDescription": "spatial controllers over GameController",
    "NSLocalNetworkUsageDescription": "NWBrowser / Steam Link broadcast fan-out",
}

STRAY = [
    (re.compile(r"\.so$"), "an unpacked ELF .so"),
    (re.compile(r"\.pyc?$"), "a Python file"),
    (re.compile(r"(^|/)__pycache__(/|$)"), "a __pycache__ directory"),
    (re.compile(r"(^|/)\.DS_Store$"), ".DS_Store"),
    (re.compile(r"(^|/)\.git(/|$)"), "a .git directory"),
    (re.compile(r"\.debug\.dylib$"), "a Debug-build .debug.dylib"),
    (re.compile(r"(^|/)__preview\.dylib$"), "a Debug-build __preview.dylib"),
    (re.compile(r"\.(h|hpp|modulemap)$"), "a header"),
    (re.compile(r"\.swiftmodule(/|$)"), "a .swiftmodule"),
    (re.compile(r"\.dSYM(/|$)"), "a dSYM inside the bundle"),
    (re.compile(r"\.xcframework(/|$)"), "an .xcframework inside the bundle"),
    (re.compile(r"\.a$"), "a static archive"),
    (re.compile(r"\.apk$"), "an APK"),
]
BAD_EXE_CHARS = set('\\[]{}()+*')
ID_RE = re.compile(r"^[A-Za-z0-9.-]+$")
TEXT_LIMIT = 500 * 1024 * 1024
APP_LIMIT = 4_000_000_000


def macho_info(path):
    """(archs, [(platform, minos)], text_bytes) for a Mach-O file."""
    _, out, _ = run(["lipo", "-archs", path])
    archs = out.split()
    _, out, _ = run(["xcrun", "vtool", "-show-build", path])
    plats = []
    cur_plat = None
    for line in out.splitlines():
        line = line.strip()
        m = re.match(r"platform\s+(\S+)", line)
        if m:
            cur_plat = m.group(1)
        m = re.match(r"minos\s+(\S+)", line)
        if m and cur_plat:
            plats.append((cur_plat, m.group(1)))
            cur_plat = None
    _, out, _ = run(["size", "-m", path])
    text = 0
    seg = None
    for line in out.splitlines():
        m = re.match(r"Segment (\S+): (\d+)", line)
        if m:
            seg = m.group(1)
            if seg == "__TEXT":
                text += int(m.group(2))
    return archs, plats, text


def check_app(app, bundle_id, team, distribution):
    print(f"== {app}")
    info_path = os.path.join(app, "Info.plist")
    info = load_plist(info_path)
    app_min = info.get("MinimumOSVersion", "?")

    # ---- Info.plist
    print("-- Info.plist")
    bid = info.get("CFBundleIdentifier", "")
    if bundle_id and bid != bundle_id:
        rec("FAIL", "CFBundleIdentifier", f"{bid!r}, expected {bundle_id!r}")
    elif bid.startswith("com.example."):
        rec("FAIL", "CFBundleIdentifier", f"{bid!r} is the public placeholder — set KLEPTON_BUNDLE_ID")
    else:
        rec("PASS", "CFBundleIdentifier", bid)
    ver, short = str(info.get("CFBundleVersion", "")), str(info.get("CFBundleShortVersionString", ""))
    rec("PASS" if re.fullmatch(r"\d+(\.\d+){0,2}", ver) and len(ver) <= 18 else "FAIL", "CFBundleVersion", ver)
    rec("PASS" if re.fullmatch(r"\d+(\.\d+){0,2}", short) else "FAIL", "CFBundleShortVersionString", short)
    rec("PASS" if info.get("CFBundleDisplayName") else "WARN", "CFBundleDisplayName", str(info.get("CFBundleDisplayName")))
    rec("PASS" if "XROS" in info.get("CFBundleSupportedPlatforms", []) else "FAIL",
        "CFBundleSupportedPlatforms", str(info.get("CFBundleSupportedPlatforms")))
    rec("PASS" if app_min != "?" else "FAIL", "MinimumOSVersion", app_min)
    enc = info.get("ITSAppUsesNonExemptEncryption")
    rec("PASS" if enc is not None else "WARN", "ITSAppUsesNonExemptEncryption",
        str(enc) if enc is not None else "absent: every build waits on the compliance question")
    for k, why in REQUIRED_USAGE.items():
        v = info.get(k, "")
        rec("PASS" if v and "$(" not in v else "FAIL", k, why if v else f"missing ({why})")
    rec("PASS" if info.get("NSBonjourServices") else "WARN", "NSBonjourServices", str(info.get("NSBonjourServices")))
    icon = info.get("CFBundleIconName", "")
    has_car = os.path.isfile(os.path.join(app, "Assets.car"))
    if icon and icon != "AppIcon" and has_car:
        rec("PASS", "app icon", f"{icon} in Assets.car")
    else:
        rec("FAIL", "app icon", f"CFBundleIconName={icon!r}, Assets.car={'yes' if has_car else 'no'} — "
            "run visionos/mk_hub_icon.py (or add AppIcon-<target>.solidimagestack)")
    for k in ("UIApplicationSceneManifest", "GCSupportedGameControllers"):
        rec("PASS" if k in info else "WARN", k)
    for k in ("DTPlatformName", "DTSDKName", "DTXcode"):
        rec("PASS" if k in info else "WARN", k, str(info.get(k)))

    # ---- privacy manifest
    print("-- privacy manifest")
    pm = os.path.join(app, "PrivacyInfo.xcprivacy")
    if os.path.isfile(pm):
        try:
            d = load_plist(pm)
            cats = [t.get("NSPrivacyAccessedAPIType", "?").replace("NSPrivacyAccessedAPICategory", "")
                    for t in d.get("NSPrivacyAccessedAPITypes", [])]
            rec("PASS", "PrivacyInfo.xcprivacy", ", ".join(cats))
        except Exception as e:  # noqa: BLE001
            rec("FAIL", "PrivacyInfo.xcprivacy", f"unreadable: {e}")
    else:
        rec("FAIL", "PrivacyInfo.xcprivacy", "missing at the bundle root (ITMS-91053)")

    # ---- stray files
    print("-- stray files")
    stray = []
    for root, dirs, files in os.walk(app):
        for n in dirs + files:
            rel = os.path.relpath(os.path.join(root, n), app)
            for rx, what in STRAY:
                if rx.search(rel):
                    stray.append((rel, what))
                    break
    if stray:
        for rel, what in stray[:30]:
            rec("FAIL", "stray file", f"{rel} ({what})")
        if len(stray) > 30:
            rec("FAIL", "stray file", f"...and {len(stray) - 30} more")
    else:
        rec("PASS", "no stray files", ".so/.py/__pycache__/.DS_Store/headers/.debug.dylib/__preview.dylib")

    # ---- Frameworks/ itself
    # ITMS-90432: "the Swift runtime libraries are the only files permitted in that
    # directory" besides frameworks — so every entry directly in Frameworks/ is a
    # *.framework bundle or a *.dylib, never a subfolder (the hub's old per-game
    # Frameworks/<game>/ layout, rejected at processing) or a loose file.
    print("-- Frameworks/ directory")
    fwdir = os.path.join(app, "Frameworks")
    fw_entries = sorted(os.listdir(fwdir)) if os.path.isdir(fwdir) else []
    odd = []
    for n in fw_entries:
        p = os.path.join(fwdir, n)
        if n.endswith(".framework") and os.path.isdir(p) and not os.path.islink(p):
            continue
        if n.endswith(".dylib") and os.path.isfile(p) and not os.path.islink(p):
            continue
        odd.append(n + ("/" if os.path.isdir(p) else ""))
    for n in odd:
        rec("FAIL", f"Frameworks/{n}", "not a .framework or .dylib — App Store allows nothing else "
            "directly in Frameworks/ (ITMS-90432)")
    if not odd:
        rec("PASS", f"Frameworks/: {len(fw_entries)} entries", "every one a .framework or a .dylib, no subfolders")

    # ---- frameworks
    print("-- frameworks")
    fws = []
    for root, dirs, _ in os.walk(app):
        for n in dirs:
            if n.endswith(".framework"):
                fws.append(os.path.join(root, n))
    ids = {}
    bad = 0
    framework_exes = set()
    for fw in sorted(fws):
        rel = os.path.relpath(fw, app)
        probs = []
        if ".framework/" in rel[:-len(".framework")] and rel.count(".framework") > 1:
            probs.append("nested inside another framework (ITMS-90205)")
        elif os.path.dirname(rel) != "Frameworks":
            probs.append("not directly in Frameworks/ (ITMS-90432 / 90205)")
        ip = os.path.join(fw, "Info.plist")
        if not os.path.isfile(ip):
            rec("FAIL", rel, "no Info.plist")
            bad += 1
            continue
        d = load_plist(ip)
        exe = d.get("CFBundleExecutable", "")
        if not exe or not os.path.isfile(os.path.join(fw, exe)):
            probs.append(f"CFBundleExecutable {exe!r} missing")
        elif BAD_EXE_CHARS & set(exe):
            probs.append(f"CFBundleExecutable {exe!r} has a character App Store rejects (90121)")
        else:
            framework_exes.add(os.path.realpath(os.path.join(fw, exe)))
            if exe != os.path.basename(fw)[:-len(".framework")]:
                probs.append(f"CFBundleExecutable {exe!r} is not named like the framework")
        fid = d.get("CFBundleIdentifier", "")
        if not ID_RE.match(fid):
            probs.append(f"CFBundleIdentifier {fid!r} invalid")
        ids.setdefault(fid, []).append(rel)
        for k in ("CFBundleVersion", "CFBundleShortVersionString"):
            if not d.get(k):
                probs.append(f"no {k}")
        if d.get("CFBundlePackageType") != "FMWK":
            probs.append(f"CFBundlePackageType {d.get('CFBundlePackageType')!r}")
        mos = d.get("MinimumOSVersion")
        if not mos:
            probs.append("no MinimumOSVersion")
        elif vtuple(mos) > vtuple(app_min):
            probs.append(f"MinimumOSVersion {mos} above the app's {app_min} (ITMS-90208)")
        sp = d.get("CFBundleSupportedPlatforms")
        if sp is not None and "XROS" not in sp:
            probs.append(f"CFBundleSupportedPlatforms {sp}")
        if probs:
            bad += 1
            rec("FAIL", rel, "; ".join(probs))
    dup = {k: v for k, v in ids.items() if len(v) > 1}
    for k, v in dup.items():
        bad += 1
        rec("FAIL", "duplicate framework CFBundleIdentifier", f"{k}: {', '.join(v)}")
    if not bad:
        rec("PASS", f"{len(fws)} frameworks", "complete Info.plists, unique ids, legal names, minos <= app")

    # ---- Mach-O
    print("-- Mach-O slices")
    main_exe = os.path.realpath(os.path.join(app, info.get("CFBundleExecutable", "")))
    machos = []
    for root, _, files in os.walk(app):
        for n in files:
            p = os.path.join(root, n)
            if not os.path.islink(p) and is_macho(p):
                machos.append(p)
    loose = [p for p in machos if os.path.realpath(p) not in framework_exes and os.path.realpath(p) != main_exe]
    for p in loose:
        rec("FAIL", "standalone binary", f"{os.path.relpath(p, app)} is not a bundle executable (ITMS-90171)")
    mbad = 0
    biggest = []
    for p in machos:
        rel = os.path.relpath(p, app)
        archs, plats, text = macho_info(p)
        biggest.append((text, rel))
        probs = []
        if archs != ["arm64"]:
            probs.append(f"archs {archs}")
        if not plats:
            probs.append("no LC_BUILD_VERSION")
        for plat, mos in plats:
            if plat not in ("XROS", "VISIONOS", "11"):
                probs.append(f"platform {plat} (want XROS — a simulator slice?)")
            if vtuple(mos) > vtuple(app_min):
                probs.append(f"minos {mos} above the app's {app_min}")
        if text > TEXT_LIMIT:
            probs.append(f"__TEXT {text / 1e6:.0f} MB over the 500 MB limit")
        if probs:
            mbad += 1
            rec("FAIL", rel, "; ".join(probs))
    if not mbad:
        rec("PASS", f"{len(machos)} Mach-O files", "all arm64-only, platform XROS (device), minos <= app, __TEXT < 500 MB")
    biggest.sort(reverse=True)
    for text, rel in biggest[:3]:
        print(f"         largest __TEXT: {text / 1e6:7.1f} MB  {rel}")

    # ---- signature
    print("-- code signature")
    rc, out, err = run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
    rec("PASS" if rc == 0 else "FAIL", "codesign --verify --deep --strict (app)",
        (err.strip().splitlines() or [""])[-1][:200])
    # Every framework wherever it is, plus every entry of Frameworks/ (the .dylibs too).
    signed = sorted(set(fws) | {os.path.join(fwdir, n) for n in fw_entries})
    sbad = 0
    for fw in signed:
        rc, _, err = run(["codesign", "--verify", "--strict", fw])
        if rc != 0:
            sbad += 1
            rec("FAIL", f"signature {os.path.relpath(fw, app)}", err.strip()[:200])
    if not sbad:
        rec("PASS", f"signature of each of the {len(signed)} frameworks / Frameworks/ entries")
    rc, out, _ = run(["codesign", "-d", "--entitlements", ":-", app])
    ent = {}
    try:
        ent = plistlib.loads(out.encode()) if out.strip() else {}
    except Exception:  # noqa: BLE001
        pass
    print("         entitlements: " + ", ".join(sorted(ent)))
    _, _, err = run(["codesign", "-dvv", app])
    auth = [l.split("=", 1)[1] for l in err.splitlines() if l.startswith("Authority=")]
    print(f"         signed by   : {auth[0] if auth else '?'}")
    if team:
        tid = [l.split("=", 1)[1] for l in err.splitlines() if l.startswith("TeamIdentifier=")]
        rec("PASS" if tid and tid[0] == team else "FAIL", "TeamIdentifier", tid[0] if tid else "?")
    for k in ("com.apple.developer.kernel.increased-memory-limit",
              "com.apple.developer.kernel.extended-virtual-addressing"):
        rec("PASS" if ent.get(k) else "WARN", k, "present" if ent.get(k) else "ABSENT — less memory headroom")
    if distribution:
        rec("PASS" if not ent.get("get-task-allow") else "FAIL", "get-task-allow absent (distribution signing)")
        rec("PASS" if ent.get("beta-reports-active") else "FAIL", "beta-reports-active (TestFlight)")
        rec("PASS" if auth and auth[0].startswith("Apple Distribution") else "FAIL", "Apple Distribution identity",
            auth[0] if auth else "?")
        prof = os.path.join(app, "embedded.mobileprovision")
        rc, out, _ = run(["security", "cms", "-D", "-i", prof])
        if rc != 0:
            rec("FAIL", "embedded.mobileprovision", "missing or unreadable")
        else:
            pd = plistlib.loads(out.encode())
            app_store = not pd.get("ProvisionedDevices") and not pd.get("ProvisionsAllDevices")
            rec("PASS" if app_store else "FAIL", "App Store profile (no device list)", pd.get("Name", "?"))
            pe = pd.get("Entitlements", {})
            missing = [k for k in ent if k not in pe and k not in ("com.apple.developer.team-identifier",)]
            rec("PASS" if not missing else "FAIL", "profile covers the app's entitlements",
                ", ".join(missing) if missing else f"profile expires {pd.get('ExpirationDate')}")

    # ---- size
    print("-- size")
    total = 0
    for root, _, files in os.walk(app):
        for n in files:
            p = os.path.join(root, n)
            if not os.path.islink(p):
                total += os.path.getsize(p)
    rec("PASS" if total < APP_LIMIT else "FAIL", "uncompressed app size",
        f"{total / 1e9:.2f} GB ({total:,} bytes) of the 4 GB limit")
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--bundle-id")
    ap.add_argument("--team")
    ap.add_argument("--distribution", action="store_true")
    ap.add_argument("--json")
    a = ap.parse_args()
    tmp = None
    path = a.path
    ipa_size = None
    if path.endswith(".ipa"):
        ipa_size = os.path.getsize(path)
        tmp = tempfile.mkdtemp(prefix="tfcheck-")
        # ditto, not zipfile: it keeps symlinks and permissions, which the
        # signature check depends on.
        subprocess.run(["ditto", "-x", "-k", path, tmp], check=True)
        apps = [os.path.join(tmp, "Payload", n) for n in os.listdir(os.path.join(tmp, "Payload"))
                if n.endswith(".app")]
        if len(apps) != 1:
            print(f"!! expected one .app in {path}'s Payload, found {apps}")
            return 1
        path = apps[0]
        with zipfile.ZipFile(a.path) as z:
            top = sorted({n.split("/")[0] for n in z.namelist()})
        print(f"   ipa: {a.path} ({ipa_size / 1e9:.2f} GB compressed); top level: {', '.join(top)}")
    try:
        total = check_app(path, a.bundle_id, a.team, a.distribution)
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
    fails = [r for r in RESULTS if r[0] == "FAIL"]
    warns = [r for r in RESULTS if r[0] == "WARN"]
    print(f"== {len(RESULTS) - len(fails) - len(warns)} passed, {len(warns)} warnings, {len(fails)} FAILED")
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"results": RESULTS, "app_bytes": total, "ipa_bytes": ipa_size}, f, indent=1)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
