# Next session: resume here (written 2026-10-28)

Supersedes the "where things are" part of `2026-10-16-next-session.md`. Its smoke list, rollback
recipe and pending upstream PRs (step 2) still apply.

## Where things are

- Committed, **not pushed**: hub `89c2988` (RE4 in the hub) and `010a0f3` (submodule bump);
  klepton `fe1712d` (RE4 hub row) and `35ff6a7` (plain `open()` through the OBB read-through).
- TestFlight build **0.1.0 (20261028.1549)** archived from hub `89c2988` / klepton `fe1712d`.
  It carries the whole 2026-10-15/16 upstream PR sweep (never run on the headset before) **and**
  Resident Evil 4. It does **not** carry `35ff6a7` (Bink movies), on purpose: that fix rides the
  next build.

## Resident Evil 4 VR (new)

Meta app 2637179839719680, `com.Armature.VR4` 2.3 / versionCode 203: the same build upstream
Klepton ported. Owned by the account (`metastore owns 2637179839719680` → owned).

- **Hub recipe** `re4` (`packages/MetaStore/Sources/MetaStore/BuiltinRecipes.swift`): APK to
  `games/re4/meta/`, `main.203` + `patch.203` OBBs (8.5 GB) to
  `android-files/Android/obb/com.Armature.VR4` (UE4 builds that path itself; Metro's layout). Ids
  from avp-play's `store-2637179839719680.json`; sizes and sha256 of all three re-checked against
  a copy pulled from the owner's Quest.
- **Row defaults** (`klepton/visionos/targets.py`): `render_scale` 0.6 (a guess, Metro's value),
  `hand_matting` off (the game draws its own hands), `gl_foveation` off (Vulkan).
- **Mac host**: `KL_UE4_WAIT=300 ./build/m_boot re4` and `./build_run_viewer.sh re4` both run: menus,
  hands, audio, ~100 fps in the viewer window. The first run is black for about a minute while
  the game builds its shaders. That is expected (`DEBUG_ENV_VARS.md`, `KL_UE4_WAIT`).
- **Bink movies were black** (e.g. the Comfort Mode preview): `klh_open` skipped
  `kl_obbmap_open`, so `.bk2` files stored in the OBB were `stat` ok but `open` ENOENT. Fixed in
  `35ff6a7`; the symptom and every file-open entry point the OBB map must cover are documented in
  `klepton/BUILDING.md` (OBB section).
- **Viewer fades to black when walking**: not a bug. WASD moves the *head* (room-scale), not the
  character; RE4 fades when the head leaves the body or enters geometry. Locomotion is the left
  stick, which the Mac viewer does not map (arrows = right stick).
- **Known gaps**: `make check TARGET=re4` stops at the Unity-only "il2cpp runtime" step (Makefile
  assumes `libil2cpp.so`); every gate before it passes. "Precompile graphics" covers only Alyx
  and Metro. The first 300 s host run spent ~165 s compiling 3,989 Vulkan pipelines (704 stalls
  of 130–650 ms); a later viewer run showed 1 stall, so caching seems to work on the Mac, but the
  headset is unmeasured.

## Step 1: headset (first thing)

1. Install the TestFlight build above. Run the smoke list from `2026-10-16-next-session.md`
   (Beat Saber, a Vulkan Unity title, Metro, Alyx, ghost controllers). That checks the PR sweep.
2. **RE4 from the hub**: Download (8.6 GB, from Meta in the hub), first launch (about a minute of
   near-black while the shaders build), then the menus, the Comfort Mode choice, the shooting
   range, and a real stretch of the campaign. Watch for:
   - stutter from pipeline compiles. Fix: add RE4 to the precompile path (Fossilize) the way
     Metro was;
   - fps at `render_scale` 0.6. Raise it with the in-app slider if there is headroom;
   - hand/weapon tracking and grip/trigger mapping on the Sense controllers;
   - cutscene audio: upstream notes MP4 cutscene audio is not decoded ("says so once");
   - movie panels are black in this build (expected, fixed in `35ff6a7`).
3. Next build (`./build_run_vpro.sh hub --archive --upload`) picks up `35ff6a7`.

## Housekeeping

- Data on the Mac for RE4: `klepton/re4.apk` + `klepton/re4/` (needed by every hub build) and
  8.5 GB of OBBs in `~/Library/Application Support/Klepton/userdata/re4/`, which only host runs
  need. Delete those OBBs or move them to `local/game/re4` with symlinks (Metro's pattern).
  Still the owner's call.
- Push hub and klepton when the headset run is green (klepton: grep for personal data first,
  never push tags).
