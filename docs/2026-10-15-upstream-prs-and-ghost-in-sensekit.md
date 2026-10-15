# 2026-10-15/16: build pipeline, ghost controllers in SenseKit, upstream PR sweep

What changed in one session, why, and what is still to be verified on the headset.

## 1. Build and TestFlight

- **Hub product renamed** `KleptonHub` → `AVPGameHub` (`klepton/visionos/targets.py`, hub row,
  `product`). The product name is what names the generated `.xcodeproj`, the scheme, the `.app`,
  DerivedData and the archive. Display name was already "AVP Game Hub"; bundle id unchanged, so
  installs and the game-data container are untouched. Open `klepton/visionos/AVPGameHub.xcodeproj`.
- `Info.plist` carries `ITSAppUsesNonExemptEncryption=false` (no "Missing Compliance" hold).
- **Two TestFlight builds** of 0.1.0 uploaded (`20261015.1946`, `20261015.2029`, the second with
  the new product name). `./build_run_vpro.sh hub --archive --upload` does archive + export +
  `asc` upload in one go. "Upload Symbols Failed" warnings are the translated frameworks' missing
  dSYMs; harmless.
- **`mkguest.sh` is incremental** (klepton `d7fee53`). It used to retranslate every game library
  with `klepton-ld` on every build: the hub's seven games are ~200 libraries, 8–10 of the ~12
  minutes an archive took. Now a slice is reused when it is newer than its `.so` and than
  `klepton-ld` (which bakes the TSD slot and the guest patch table, so a new translator still
  invalidates everything); the `.xcframework` is rewrapped only when a slice changed or the set of
  fresh slices on disk differs from what it carries (device and simulator builds no longer undo
  each other). Libraries that left a target's list are pruned. Knobs: `KL_FORCE_GUEST=1` wipes and
  retranslates; `KL_SKIP_GUEST=1` skips even the check; `KL_GUEST_PATCH_OFF` forces too.
  Measured on ktane: unchanged → 0.5 s; new simulator slice → translates only that one. An archive
  that touched only Swift or a plist should take ~3 minutes.

## 2. Ghost controllers moved into SenseKit

The "ghost" (the in-code PSVR2 Sense model drawn at a resting controller's real pose so it can be
found in full VR) lived in `KleptonHUD.swift`. It is now in the SenseKit package so another
visionOS app can use it (SenseKit `cf4febc`, klepton `42046f7`, design doc
`docs/2026-10-13-sensekit-design.md` has the dated section).

| SenseKit type | What |
|---|---|
| `SenseGhostConfiguration` | every threshold, timing, fade, the model's `fit` onto the real plastic, colours, rim width |
| `SenseGhostHandState` / `SenseGhosts` | the held-vs-resting decision with hysteresis and fade, pure and unit-tested; `logger` hook |
| `SenseGhostHands.palm(HandAnchor)` | palm centre used as "hand near" evidence |
| `SenseGhostMesh.sense(right:)` | pure geometry (8 floats per vertex, UInt16 triangles) — usable from RealityKit |
| `SenseGhostRenderer` | its own Metal pipeline and depth states; `encode(enc, views:, recenter:, ghosts:, depthOverScene:)` |

Klepton keeps only the adapter: `KL_GHOST_*` env → configuration, `[ghost]` log prefix, same draw
slot (after the fade, before the toast). Behaviour is meant to be byte-identical; 38 package tests
pass in the visionOS simulator; `make swiftcheck` passes. SenseKit's `main` also carries the
gamepad/input-hub work from the other app; the ghost commit is rebased on top of it.

## 3. Upstream Klepton PR sweep

Upstream `shinyquagsire23/Klepton` `main` has not moved since 2026-09-03 and we have all of it;
our fork is ~200 commits ahead. But 18 PRs from other forks were open and unmerged. Four
read-only triage agents compared each against our tree (no PR commit was patch-identical to
ours). Full triage detail per PR (what we have vs lack, conflict files, order to
resume) is in `2026-10-15-klepton-upstream-pr-triage.md`. Verdicts and status:

| PR | Author | Verdict | Status |
|---|---|---|---|
| 18 JNI: missing methods, pinning of cached host objects | fayep | take whole | **merged** (7 commits) |
| 17 OVR: guardian boundary, silent `ovr_Microphone_*`, headphones, room invites | fayep | take whole | **merged** |
| 8 ue4: detect Unreal 4.25 by exported natives | johnrtipton | take whole (Metro stays 4.26+, verified) | **merged** |
| 19 libc: `/sdcard/Android/obb/<package>`; sem table 65536 | fayep | take whole | **merged** |
| 14 Unity GLES on ANGLE: texture units ≥32, no compute, CPU skinning | fayep | take whole; our offset-poke rows can go to `use=0` once the mask is confirmed | **merged** |
| 21 gl: `KL_VRR_FLOOR`, feather-blit fix, int precision, indexed state, extensions, shader-cache guard | rebelancap | take whole | **merged** (10 commits) |
| 16 visionOS: honour Unity `Application.Quit` | fayep | take; add `kl_steam_shutdown()` before `_exit` | **merged** |
| 15 OVRPlugin: touch bits; product name follows headset type | fayep | only the product-name commit (our touch bits are a superset) | **merged** (1 of 2) |
| 7 Run Ancient Dungeon (JNI, bHaptics, user proof) | johnrtipton | only `XR_META_performance_metrics` and the `connect()` errno fix | **merged** (hand-port) |
| 13 OVRPlugin/XR layer: Beat Saber stale frame, one pose per frame, protocol | rebelancap | three pieces: eye-FBO-map release (the Beat Saber menu fix), OpenXR constants (62/63/45) + larger pools, compositor env knobs read once | **merged** (rest skipped: double pose-pinning risk against our RECORD_INDEXED path) |
| 11 libc/pthread: sync-object identity, side tables, signal/errno/path, fault handler | rebelancap | take whole as a merge; QoS default off; drop our `KL_PTHREAD_WIDE_HASH` knob; sems at 65536 with generations | **in progress** |
| 12 Audio: float/PCM_EX, OpenSL+AAudio arbitration, AAudio seams, haptics | rebelancap | formats/arbitration/AAudio commits (Batman: Wwise/Oboe needs `AAudio_getMMapPolicy`, `PCM_EX`, `GetConfiguration`); haptics backoff by hand into `SenseHaptics.swift` | pending |
| 20 Unreal/JNI: JNI_OnLoad chain, EOS/FMOD, GameActivity surface, bHaptics, NDK | rebelancap | by commit: object model, framework families (**HashMap ctor bug we share**), `AudioManager.getDevices`, NDK door (+ drop `libandroid.so` from core-shim list), UE5/GameActivity surface for Metro; skip multiview/haptics/FMOD rewrite | pending |
| 5 battery levels (headset + controllers) | SBudarin | C side whole; Swift side re-done through SenseKit (we no longer poll `GCController` in the app) | pending |
| 10 x18 veneers (klepton-ld) | rebelancap | only `cbz` guard, `blr x18` via x16, REFUSED line; skip jump-table rewrite and SPLIT (no library we ship needs them: 0 refusals measured) — last, it retranslates everything | pending |
| 9 fixed foveation for Vulkan guests via Metal rate maps | rebelancap | skip for now: 4k lines of unverified swizzling that collides with our MoltenVK-FDM path on Alyx; evaluate on Batman later with a guard | skipped |
| 6 "visionOS 27 capabilities crash" | Cmoi20 | skip: no crash fix inside; ANGLE flags we already have or unmotivated | skipped |
| 22 Red Matter 2 `Build.MODEL` | fayep | skip: game-specific, not ours | skipped |

Each merged PR is its own commit (cherry-picks keep upstream authorship, `-x`); hand-ports say
which commit they come from. Verification per batch: `make -s check` (host tests), `make
swiftcheck`, `make xros` (device + simulator runtime link).

## 4. What to verify on the headset (next build)

- Beat Saber: main-menu picture no longer stale after the eye swapchain is recreated (PR 13);
  peripheral blur gone with `KL_VRR_FLOOR` (PR 21); "Invalid texture unit!" textures (PR 14 mask —
  check the `[patch]` log says applied, not refused, on 2022.3.33).
- Any Unity title: in-game Exit now ends the app (PR 16); GPU cost with the newly exposed GL
  extensions — A/B `KL_GL_NO_BACKEND_EXT=1`.
- First launch after the merge deletes shader caches once (PR 21 cache guard): slower first boot.
- Ghost controllers look and behave as before (SenseKit renderer).
- Batman audio, once PR 12/20 parts are in.
- Metro: boot unchanged (OpenXR constants/pools).

## 5. Rolling back

Every PR is a separate commit or merge on klepton `main`: `git revert <sha>` (or `-m 1` for the
PR 11 merge), bump the submodule, archive (~3 min with the incremental translations).
