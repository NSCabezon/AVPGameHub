#!/bin/bash
# Stage Half-Life: Alyx's game content (depot 546561, ~72 GB) into the alyx
# app's data container on a physical Vision Pro — resumably.
#
# stage_assets.sh is the wrong tool for this, on purpose: it is idempotent but
# not incremental (it replaces what is there), and one `devicectl copy` of a
# 72 GB tree is an hours-long transfer that a sleeping headset, a Wi-Fi blip or
# a Ctrl-C throws away whole. Here the unit of work is a FILE (or a batch of
# small files sharing a directory), and every unit that lands is recorded in a
# local manifest keyed on size+mtime, so a re-run picks up where the last one
# stopped and a file the download later rewrites is re-sent on its own.
#
#   ./stage_alyx.sh --dry-run            # what would go, how many bytes, nothing sent
#   ./stage_alyx.sh                      # stage (resumes from the manifest)
#   ./stage_alyx.sh --verify             # also list the device's files and trust THAT:
#                                        #   re-sends anything missing/short there,
#                                        #   adopts anything already the right size
#   ./stage_alyx.sh --only hlvr/gameinfo.gi   # one path (or prefix) — a smoke test
#   ./stage_alyx.sh --list-excluded      # every file left behind, and why
#
# Options: --device <id> (else KLEPTON_DEVICE, else the first paired physical
# Vision Pro), --src <dir> (else KL_ALYX_CONTENT, else ../local/game/content/game
# in this checkout), --include-extras (keep the editor/workshop-sample
# exclusions below off), --free-gb <n> (the device's free space when it cannot
# be read — Settings > General > Storage), --skip-space-check, --reset (forget
# the manifest for this device), --settle <s> (default 600; see below).
#
# WHERE IT LANDS, and why the binaries depot is not part of it. kl_app.c, for
# a glibc target, makes the game ROOT <Documents>/android-files/<stage_files>/game
# = android-files/alyx/game (Source 2 finds its install by looking for a
# directory named game/ above the executable), and the executable "lives" in
# <root>/bin/linuxsteamrtarm64, which it mkdirs itself: every library there
# (and hlvr/bin/linuxsteamrtarm64, the mod dir) is a translated FRAMEWORK in the
# signed bundle, found by stem through KL_DYLIB_DIR, and KL_GLIBC_MODDIRS is
# pinned to that one directory. KL_GLIBC_CONTENT is not set on device, so there
# is no overlay: the content must sit DIRECTLY under the root — core/, hlvr/,
# laid out exactly as the depot's game/ directory. So the two depots merge
# trivially: binaries -> bundle (mkguest.sh), content -> here, and no ELF is
# ever pushed into the container (AMFI would not load it anyway). The engine's
# writes (cfg/, logs, shader caches) go to the door's userdata write layer, not
# into this tree.
#
# EXCLUDED (never staged; --list-excluded shows each file):
#   bin/**, */bin/**          code — the bundle carries it as frameworks
#   win64, linuxsteamrt64, linux64, osx64, win32 dirs; *.dll *.exe *.pdb *.dbg
#   *.sym *.so *.so.*; vfxcompile*   other-platform / shader-compiler binaries
#   .DS_Store, ._*, .DepotDownloader  host/downloader junk
#   core/tools/**             Source 2 editor UI (Hammer &c, ~14 MB)
#   hlvr/maps/workshop_examples/**   modder sample maps (~0.7 GB)
#   (the last two come back with --include-extras)
#
# STILL-DOWNLOADING files are held back: anything modified in the last
# --settle seconds is skipped and named, because DepotDownloader writes chunks
# into preallocated files — a full-size file can still be mostly zeros. It is
# picked up by the next run (its mtime will differ from nothing in the manifest).
#
# The app must be installed first (it owns the container): ./build_run_vpro.sh alyx
set -euo pipefail
cd "$(dirname "$0")"
. ./local_config.sh   # <repo>/local/config.env
ROOT=".."
eval "$(python3 targets.py alyx | grep -v '^KLT_LIBS=')"
BUNDLE_ID="${KLEPTON_BUNDLE_ID:-$KLT_BUNDLE}"
kl_require_bundle_id "$BUNDLE_ID"
DEST_REL="Documents/android-files/${KLT_STAGE_FILES:-alyx}/game"

DRY=0; VERIFY=0; LIST_EXCL=0; EXTRAS=0; RESET=0; SKIP_SPACE=0
FREE_GB=""; ONLY=""; SKIP=""; SETTLE="${KL_STAGE_SETTLE:-600}"; JOBS="${KL_STAGE_JOBS:-1}"
DEVID="${KLEPTON_DEVICE:-}"
SRC="${KL_ALYX_CONTENT:-$ROOT/../local/game/content/game}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n)       DRY=1; shift ;;
    --verify)           VERIFY=1; shift ;;
    --list-excluded)    LIST_EXCL=1; DRY=1; shift ;;
    --include-extras)   EXTRAS=1; shift ;;
    --reset)            RESET=1; shift ;;
    --skip-space-check) SKIP_SPACE=1; shift ;;
    --free-gb)          FREE_GB="$2"; shift 2 ;;
    --only)             ONLY="$2"; shift 2 ;;
    --skip)             SKIP="${SKIP:+$SKIP,}$2"; shift 2 ;;
    --settle)           SETTLE="$2"; shift 2 ;;
    --jobs)             JOBS="$2"; shift 2 ;;
    --device)           DEVID="$2"; shift 2 ;;
    --src)              SRC="$2"; shift 2 ;;
    -h|--help)          sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "!! unknown argument $1 (--help)"; exit 2 ;;
  esac
done

[ -d "$SRC" ] || { echo "!! no content at $SRC — download depot 546561 there, or pass --src / KL_ALYX_CONTENT"; exit 1; }
SRC=$(cd "$SRC" && pwd -P)
[ -d "$SRC/hlvr" ] || echo "!! [stage] warning: $SRC has no hlvr/ — is --src the depot's game/ directory?"
if [ -d "$SRC/../.DepotDownloader/staging" ] && [ -n "$(ls -A "$SRC/../.DepotDownloader/staging" 2>/dev/null)" ]; then
  echo "[stage] note: DepotDownloader's staging dir is not empty — the download looks unfinished;"
  echo "        files written in the last ${SETTLE}s are held back, re-run when it is done"
fi

# Same JSON route as build_run_vpro.sh: device names carry non-breaking spaces.
find_device() {
  local json; json=$(mktemp)
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
  python3 -c '
import json, sys
try:
    devs = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit(0)
phys = [d for d in devs
        if d.get("hardwareProperties", {}).get("reality") == "physical"
        and d.get("hardwareProperties", {}).get("platform") == "visionOS"
        and d.get("connectionProperties", {}).get("pairingState", "paired") == "paired"]
phys.sort(key=lambda d: d.get("connectionProperties", {}).get("tunnelState") != "connected")
for d in phys:
    # "unavailable" in `list devices` = not reachable right now (asleep, off, other network)
    if d.get("connectionProperties", {}).get("tunnelState") in ("connected", "disconnected") \
       or d.get("deviceProperties", {}).get("bootState") == "booted":
        print(d["identifier"]); break
' "$json"
  rm -f "$json"
}
[ -n "$DEVID" ] || DEVID=$(find_device || true)
if [ -z "$DEVID" ]; then
  if [ "$DRY" = 1 ]; then
    echo "[stage] no reachable Vision Pro — dry run against the local tree only (nothing counted as already staged)"
  else
    echo "!! no reachable physical Vision Pro — wake it, keep it on the same network, pair it in Xcode,"
    echo "!! or set KLEPTON_DEVICE / --device. (--dry-run works without one.)"
    exit 1
  fi
fi

STATE_DIR="$ROOT/build/staged"
mkdir -p "$STATE_DIR"
MANIFEST="$STATE_DIR/alyx-content-${BUNDLE_ID}-${DEVID:-nodevice}.tsv"
[ "$RESET" = 1 ] && { rm -f "$MANIFEST"; echo "[stage] manifest reset: $MANIFEST"; }
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

dctl() { xcrun devicectl "$@"; }

REMOTE_JSON=""
FREE_BYTES=""
if [ -n "$DEVID" ]; then
  # The container must exist, i.e. the app is installed. Listing the root of
  # Documents is the definitive test: it is exactly the access the copies need.
  if ! dctl device info files --device "$DEVID" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" --subdirectory Documents --no-recurse \
        -q -j "$TMPD/docs.json" >/dev/null 2>&1; then
    msg=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["error"]["userInfo"]["NSLocalizedDescription"]["string"])
except Exception: print("")' "$TMPD/docs.json" 2>/dev/null)
    echo "!! cannot open the data container of $BUNDLE_ID on $DEVID${msg:+: $msg}"
    echo "!! Install the app first — ./build_run_vpro.sh alyx — then re-run this."
    echo "!! (A locked headset gives the same error: put it on and unlock it.)"
    exit 1
  fi
  if [ "$VERIFY" = 1 ]; then
    echo "[stage] listing $DEST_REL on the device (--verify)…"
    if dctl device info files --device "$DEVID" --domain-type appDataContainer \
          --domain-identifier "$BUNDLE_ID" --subdirectory "$DEST_REL" --recurse \
          -q -j "$TMPD/remote.json" >/dev/null 2>&1; then
      REMOTE_JSON="$TMPD/remote.json"
    else
      echo "[stage] nothing at $DEST_REL yet (or it could not be listed) — treating the device as empty"
      echo '{}' > "$TMPD/remote.json"; REMOTE_JSON="$TMPD/remote.json"
    fi
  fi
  # Free space. devicectl's details carry the capacity but, on current builds,
  # not the free bytes — scan for any field that looks like it anyway, then ask
  # lockdown through pymobiledevice3 if it is installed, then give up loudly.
  if [ -n "$FREE_GB" ]; then
    FREE_BYTES=$(python3 -c "print(int(float('$FREE_GB')*1e9))")
  elif [ "$SKIP_SPACE" = 0 ]; then
    dctl device info details --device "$DEVID" -q -j "$TMPD/details.json" >/dev/null 2>&1 || true
    FREE_BYTES=$(python3 - "$TMPD/details.json" <<'PY' 2>/dev/null || true
import json, re, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
best = None
def walk(o, path):
    global best
    if isinstance(o, dict):
        for k, v in o.items(): walk(v, path + [k])
    elif isinstance(o, (int, float)) and not isinstance(o, bool):
        k = path[-1].lower() if path else ""
        if re.search(r"(free|available|remaining)", k) and re.search(r"(byte|capacity|space|storage|disk)", k) and o > 1e8:
            best = int(o) if best is None else min(best, int(o))
walk(d.get("result", {}), [])
if best: print(best)
PY
)
    if [ -z "$FREE_BYTES" ] && command -v pymobiledevice3 >/dev/null 2>&1; then
      FREE_BYTES=$( (timeout 45 pymobiledevice3 lockdown get --native --udid "$DEVID" \
          --domain com.apple.disk_usage --key TotalDataAvailable 2>/dev/null || true) \
          | grep -Eo '^[0-9]{6,}$' | head -1 || true)
    fi
  fi
fi

# ---- plan (and, unless --dry-run, transfer) ---------------------------------
export SRC DEST_REL MANIFEST DEVID BUNDLE_ID DRY VERIFY LIST_EXCL EXTRAS ONLY SKIP SETTLE JOBS \
       REMOTE_JSON FREE_BYTES SKIP_SPACE TMPD
rc=0
python3 - <<'PY' || rc=$?
import fnmatch, json, os, shutil, signal, subprocess, sys, threading, time
from concurrent.futures import ThreadPoolExecutor

E = os.environ
SRC, DEST = E["SRC"], E["DEST_REL"]
MANIFEST, DEVID, BUNDLE = E["MANIFEST"], E.get("DEVID", ""), E["BUNDLE_ID"]
DRY, VERIFY, LIST_EXCL = E["DRY"] == "1", E["VERIFY"] == "1", E["LIST_EXCL"] == "1"
EXTRAS, ONLY, SETTLE = E["EXTRAS"] == "1", E.get("ONLY", "").strip("/"), int(E["SETTLE"])
SKIP = [x.strip("/") for x in E.get("SKIP", "").split(",") if x.strip("/")]
REMOTE_JSON, FREE = E.get("REMOTE_JSON", ""), E.get("FREE_BYTES", "")
SKIP_SPACE, TMPD = E["SKIP_SPACE"] == "1", E["TMPD"]
JOBS = max(1, int(E.get("JOBS", "1") or 1))
SMALL = 16 << 20            # files under this ride in per-directory batches
BATCH_BYTES, BATCH_FILES = 256 << 20, 400
MARGIN = 2 << 30            # headroom left free on the device

def gb(n): return f"{n / 1e9:.2f} GB"

# (reason, predicate on the lower-cased relative path)
PLATFORM_DIRS = {"win64", "win32", "linuxsteamrt64", "linux64", "osx64"}
EXCLUDES = [
    ("code (bundle frameworks)", lambda p, parts: parts[0] == "bin" or (len(parts) > 2 and parts[1] == "bin")),
    ("other-platform dir",       lambda p, parts: any(x in PLATFORM_DIRS for x in parts[:-1])),
    ("binary/debug file",        lambda p, parts: any(fnmatch.fnmatch(parts[-1], g) for g in
                                   ("*.dll", "*.exe", "*.pdb", "*.dbg", "*.sym", "*.so", "*.so.*", "vfxcompile*"))),
    ("host junk",                lambda p, parts: parts[-1] in (".ds_store",) or parts[-1].startswith("._")
                                   or ".depotdownloader" in parts),
]
if not EXTRAS:
    EXCLUDES += [
        ("editor tools (--include-extras)",   lambda p, parts: p.startswith("core/tools/")),
        ("workshop samples (--include-extras)", lambda p, parts: p.startswith("hlvr/maps/workshop_examples/")),
    ]

def excluded(rel):
    p = rel.lower(); parts = p.split("/")
    for why, f in EXCLUDES:
        if f(p, parts): return why
    return None

# ---- walk the local tree
now = time.time()
files, excl, settling = [], {}, []
for dp, dns, fns in os.walk(SRC):
    dns.sort(); fns.sort()
    for fn in fns:
        full = os.path.join(dp, fn)
        rel = os.path.relpath(full, SRC)
        if os.path.islink(full):
            full = os.path.realpath(full)       # devicectl would copy a link AS a link
        try: st = os.stat(full)
        except OSError: continue
        why = excluded(rel)
        if why:
            excl.setdefault(why, []).append((rel, st.st_size)); continue
        if ONLY and not (rel == ONLY or rel.startswith(ONLY + "/")): continue
        if any(rel == k or rel.startswith(k + "/") for k in SKIP):
            excl.setdefault("--skip", []).append((rel, st.st_size)); continue
        if now - st.st_mtime < SETTLE:
            settling.append((rel, st.st_size)); continue
        files.append((rel, full, st.st_size, int(st.st_mtime)))

if LIST_EXCL:
    for why, lst in sorted(excl.items()):
        print(f"# {why}: {len(lst)} files, {gb(sum(s for _, s in lst))}")
        for r, s in lst: print(f"{s:>14}  {r}")
    sys.exit(0)

# ---- what is already there
done = {}
if os.path.exists(MANIFEST):
    for line in open(MANIFEST, encoding="utf-8", errors="replace"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 3:
            done[parts[0]] = (int(parts[1]), int(parts[2]))

remote = None
if REMOTE_JSON:
    # devicectl's JSON is not documented; take any object under "result" that
    # pairs a path-ish key with a byte count, and make the path relative to DEST.
    remote = {}
    try: rj = json.load(open(REMOTE_JSON))
    except Exception: rj = {}
    # The size may sit beside the path or one level down (a "metadata" /
    # "attributes" object), and may be serialized as a float or a string —
    # the first parser accepted only an int beside the path and listed 0 files.
    SIZE_KEYS = ("size", "fileSize", "sizeInBytes", "byteCount", "logicalSize", "totalSize")
    def as_int(v):
        if isinstance(v, bool): return None
        if isinstance(v, (int, float)): return int(v)
        if isinstance(v, str) and v.strip().isdigit(): return int(v)
        return None
    def size_of(o):
        for k in SIZE_KEYS:
            n = as_int(o.get(k))
            if n is not None: return n
        for v in o.values():
            if isinstance(v, dict):
                for k in SIZE_KEYS:
                    n = as_int(v.get(k))
                    if n is not None: return n
        return None
    def walk(o):
        if isinstance(o, dict):
            path = next((o[k] for k in ("relativePath", "path", "name") if isinstance(o.get(k), str)), None)
            size = size_of(o) if path is not None else None
            if path is not None and size is not None:
                p = path.lstrip("/")
                i = p.find(DEST + "/")
                if i >= 0: p = p[i + len(DEST) + 1:]
                elif p.startswith(DEST.split("/", 1)[-1] + "/"): p = p[len(DEST.split("/", 1)[-1]) + 1:]
                remote[p] = size
            for v in o.values(): walk(v)
        elif isinstance(o, list):
            for v in o: walk(v)
    walk(rj.get("result", {}))
    print(f"[stage] device lists {len(remote)} file(s) under {DEST}")

todo, have, adopted = [], 0, 0
for rel, full, size, mtime in files:
    if remote is not None:
        if remote.get(rel) == size:
            if done.get(rel) != (size, mtime):
                done[rel] = (size, mtime); adopted += 1
            have += size; continue
        done.pop(rel, None)            # missing or wrong size on the device: resend
        todo.append((rel, full, size, mtime)); continue
    if done.get(rel) == (size, mtime):
        have += size; continue
    todo.append((rel, full, size, mtime))

def rewrite_manifest():
    tmp = MANIFEST + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for r, (s, m) in sorted(done.items()): f.write(f"{r}\t{s}\t{m}\n")
    os.replace(tmp, MANIFEST)
if remote is not None and DEVID and not DRY:
    rewrite_manifest()

need = sum(t[2] for t in todo)
total = sum(f[2] for f in files)
print(f"[stage] source   : {SRC}")
print(f"[stage] dest     : {DEVID or '(no device)'}:{BUNDLE}/{DEST}")
print(f"[stage] content  : {len(files)} files, {gb(total)}"
      + (f" (only '{ONLY}')" if ONLY else ""))
for why, lst in sorted(excl.items()):
    print(f"[stage] excluded : {len(lst):>5} files, {gb(sum(s for _, s in lst)):>10}  {why}")
if settling:
    print(f"[stage] held back: {len(settling):>5} files, {gb(sum(s for _, s in settling)):>10}  "
          f"modified < {SETTLE}s ago (still downloading?) e.g. {settling[0][0]}")
print(f"[stage] staged   : {len(files) - len(todo)} files, {gb(have)}"
      + (f" ({adopted} adopted from the device listing)" if adopted else ""))
print(f"[stage] TO SEND  : {len(todo)} files, {gb(need)}  ({need} bytes)")

# top-level breakdown of what is to be sent
by = {}
for rel, _, s, _ in todo:
    k = "/".join(rel.split("/")[:2]) if rel.count("/") >= 2 else rel.split("/")[0]
    by[k] = by.get(k, 0) + s
for k, s in sorted(by.items(), key=lambda kv: -kv[1])[:12]:
    print(f"           {gb(s):>10}  {k}")

# free space
if DEVID and need:
    if FREE:
        free = int(FREE)
        print(f"[stage] device free: {gb(free)} (need {gb(need)} + {gb(MARGIN)} headroom)")
        if free < need + MARGIN:
            print(f"!! not enough space on the Vision Pro: {gb(free)} free, {gb(need + MARGIN)} needed.")
            print("!! Free some (Settings > General > Storage) or stage less (--only <dir>).")
            sys.exit(1)
    elif not SKIP_SPACE and not DRY:
        print("!! could not read the device's free space (devicectl does not report it here and")
        print("!! pymobiledevice3 could not reach it). Check Settings > General > Storage and pass")
        print("!! --free-gb <n>, or --skip-space-check to go ahead regardless.")
        sys.exit(1)
    elif not SKIP_SPACE:
        print("[stage] device free: unknown (a real run will ask for --free-gb or --skip-space-check)")

if DRY or not todo:
    if not todo: print("[stage] nothing to do")
    sys.exit(0)

# ---- units: big files alone, small files batched per directory
units = []
bydir = {}
for t in todo:
    d = os.path.dirname(t[0])
    if t[2] >= SMALL or not d: units.append(("F", d, [t]))
    else: bydir.setdefault(d, []).append(t)
for d, lst in bydir.items():
    if len(lst) == 1: units.append(("F", d, lst)); continue
    cur, cb = [], 0
    for t in lst:
        if cur and (cb + t[2] > BATCH_BYTES or len(cur) >= BATCH_FILES):
            units.append(("D", d, cur)); cur, cb = [], 0
        cur.append(t); cb += t[2]
    if cur: units.append(("D", d, cur))
units.sort(key=lambda u: u[2][0][0])   # path order: core/, then hlvr/ (gameinfo early)

mf = open(MANIFEST, "a", encoding="utf-8")
def record(lst):
    for rel, _, s, m in lst:
        done[rel] = (s, m); mf.write(f"{rel}\t{s}\t{m}\n")
    mf.flush(); os.fsync(mf.fileno())

def devicectl_copy(source, dest, nbytes):
    # Generous: ~4 MB/s worst case over Wi-Fi, never under 10 minutes.
    to = max(600, int(nbytes / (4 << 20)) + 300)
    cmd = ["xcrun", "devicectl", "device", "copy", "to", "--device", DEVID,
           "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
           "--source", source, "--destination", dest, "--timeout", str(to), "-q"]
    for attempt in range(1, 4):
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode == 0: return True
        err = (r.stderr or r.stdout).strip().splitlines()
        print(f"   !! attempt {attempt} failed: {err[-1] if err else r.returncode}", flush=True)
        if attempt < 3: time.sleep(5 * attempt)
    return False

stop = False
def on_int(*_):
    global stop
    if stop: sys.exit(130)
    stop = True
    print("\n[stage] stopping after the current unit (Ctrl-C again to abort it — it will be resent)", flush=True)
signal.signal(signal.SIGINT, on_int)

sent, nfiles, t0, failed = 0, 0, time.time(), 0
lock = threading.Lock()

def run_unit(i, kind, d, lst):
    # One unit per worker; with --jobs N several devicectl copies overlap,
    # which hides the fixed per-copy setup cost on the many ~110 MB pak01s.
    global sent, nfiles, failed, stop
    if stop: return
    nb = sum(t[2] for t in lst)
    if kind == "F":
        rel, full = lst[0][0], lst[0][1]
        label, src, dst = rel, full, f"{DEST}/{rel}"
    else:
        # A directory copy, from a scratch mirror holding exactly this batch
        # (APFS clones: free, and the source tree is not touched). Same basename
        # as the destination, the pattern stage_assets.sh's directory copies use.
        mirror = os.path.join(TMPD, f"u{i}", os.path.basename(d))
        os.makedirs(mirror)
        for rel, full, _, _ in lst:
            out = os.path.join(mirror, os.path.basename(rel))
            if subprocess.run(["cp", "-c", full, out], capture_output=True).returncode != 0:
                shutil.copy2(full, out)
        label, src, dst = f"{d}/ ({len(lst)} files)", mirror, f"{DEST}/{d}"
    with lock:
        el = time.time() - t0
        rate = sent / el if el > 1 and sent else 0
        eta = f", ETA {int((need - sent) / rate / 60)} min" if rate and sent > (256 << 20) else ""
        print(f"[stage] [{i}/{len(units)}] {gb(sent)}/{gb(need)}{eta}  {label} ({gb(nb)})", flush=True)
    ok = devicectl_copy(src, dst, nb)
    with lock:
        if ok:
            record(lst); sent += nb; nfiles += len(lst)
        else:
            failed += 1
            print(f"   !! giving up on {label} for this run", flush=True)
            if failed >= 5 and not stop:
                print("!! five units failed — the device is probably gone (asleep? locked?). Re-run to resume.")
                stop = True
    if kind == "D": shutil.rmtree(os.path.dirname(src), ignore_errors=True)

# --jobs only applies to small units (< BIG): the per-copy setup cost is what
# parallelism hides, and a big file is bandwidth-bound anyway. Big units then
# go one at a time.
BIG = 256 << 20
numbered = list(enumerate(units, 1))
small = [(i, u) for i, u in numbered if sum(t[2] for t in u[2]) < BIG]
big = [(i, u) for i, u in numbered if sum(t[2] for t in u[2]) >= BIG]
if JOBS > 1: print(f"[stage] {len(small)} small unit(s) {JOBS} at a time, then {len(big)} big one(s) one at a time", flush=True)
with ThreadPoolExecutor(max_workers=JOBS) as pool:
    for f in [pool.submit(run_unit, i, *u) for i, u in small]:
        f.result()
for i, u in big:
    run_unit(i, *u)

mf.close()
rewrite_manifest()
el = max(time.time() - t0, 1)
print(f"[stage] sent {nfiles} files, {gb(sent)} in {int(el // 60)}m{int(el % 60)}s "
      f"({sent / el / 1e6:.1f} MB/s); manifest {MANIFEST}")
left = len(todo) - nfiles
if left or settling:
    print(f"[stage] {left} file(s) not sent" + (f", {len(settling)} held back" if settling else "")
          + " — re-run to resume")
    sys.exit(1 if left else 0)
print("[stage] done")
PY
exit $rc
