# Klepton upstream PR triage, 2026-10-15

Full notes from the four read-only triage passes over the 18 PRs open on
`shinyquagsire23/Klepton` (base `ce74582`, our fork ~200 commits ahead). Status and the short
table are in `2026-10-15-upstream-prs-and-ghost-in-sensekit.md`; this file keeps the detail
needed to resume the pending ones (12, 20, 5, 10). PR refs are fetched locally as
`origin/pr/N` in `klepton/` (`git fetch origin '+refs/pull/*/head:refs/remotes/origin/pr/*'`).

Game facts used throughout (from `visionos/targets.py`, `KleptonCatalog.swift`): Alyx = Source 2
glibc, Vulkan via our MoltenVK-FDM fork, mostly Mac-streamed; Metro Awakening = UE 5.2.1
(`libUnreal`, `kind: ue4`), Vulkan, OpenXR, OpenSL-only audio, ships `libbhaptics-native-lib.so`,
no FMOD/EOS/Sentry; Batman = Unity 2022, Vulkan required, OVRPlugin, Wwise
(`libAkSoundEngine.so`, `libMetaXRAudioWwise.so` importing AAudio + OpenSL, `PCM_EX`); SUPERHOT VR
1.72 (Steam Frame) = Unity, Vulkan; Beat Saber 1.40.8 = Unity 2022.3.33, GLES/ANGLE, OVRPlugin;
I Expect You To Die = Unity 2019.4.21, GLES (told ES 3.0); Keep Talking = Unity 2022.3.62, GLES.
Our klepton-ld on the real libraries: 0 x18 refusals everywhere, no library needs a split pool;
every Unity libunity has 2 `br x18`, Alyx libs have `blr x18` (31 sites), Metro none.

---

## Group A: gfx / XR (PRs 9, 13, 21, 14)

### PR 9 — fixed foveation for Vulkan guests via Metal rate maps (7 commits, +5598) — SKIPPED

New `runtime/gfx/kl_fove.m/.h` (3004 lines ObjC) swizzles MoltenVK's `MTLDevice`/
`MTLCommandBuffer`, attaches an `MTLRasterizationRateMap` to every render encoder drawing a
registered eye target, text-patches every SPIRV-Cross fragment entry point reading `[[position]]`,
expands the physical region back before anything reads the eye. `kl_vulkan.c` (+1029) recognises
eye passes at `vkCmdBeginRenderPass[2]` only (direct eye image, eye-size MSAA resolve, eye-size
intermediate), shadow tables, `KL_FOVE_AREA_SNAP`. Plus `kl_ovrp_eye_tangents`/`eye_layer_fov`
accessors (`4eeabb8`, 33 lines), `Documents/klepton-env.txt` (`cddb096`, uses `setenv(...,1)` so
it would override hub prefs), `tests/t_fove.c`, `docs/FOVEATION.md`. Does not handle
`vkCmdBeginRendering` nor the OpenVR double-wide shape, so Alyx passes are never recognised.

Ours: no `kl_fove*`. Different design: `KL_FOVEATE` + `vendor-moltenvk-fdm` foveates only passes
the guest attaches a `VK_EXT_fragment_density_map` to (spoof in `kl_vulkan.c:4176-4260`) — Alyx
only. Batman/Metro/SUPERHOT have no Vulkan foveation today (`render_scale 0.7` lever). Our
`KL_VK_WIDEN_AREA` is the PR's AREA_SNAP for dynamic rendering. Risk if both run in one process
(Alyx with KL_FOVEATE=1 + KL_FOVEATION set): double shader remap, "clobber" detector trips.

Verdict: skip for now. Evaluate later on the headset with Batman first, gating `fove_install` off
when `klvk_foveate()` is on. Cheap independent picks: `4eeabb8`, `cddb096` (change to
`setenv(...,0)`). Conflicts: Makefile (RUNTIME_SHIP, `check:`), `kl_ovrp.h` (adjacent decls),
`kl_vulkan.c` 6 keep-both hunks (DestroyImage/CreateImageView/CmdBeginRenderPass[2]/
BeginCommandBuffer/header stubs) but eye logic must be re-verified against our 9990-line file.
Benefits: Batman (prime), Metro, SUPERHOT. Alyx/GLES titles nothing.

### PR 13 — OVRPlugin/XR layer (6 commits, +6400) — THREE PIECES MERGED, REST SKIPPED

Upstream's big pose/presentation wave. Our fork already solved most of it under other names:
per-frame-index pose records (`KL_OVRP_RECORD_INDEXED/LATE` vs their `POSE_KEY`), stage+GL-fence
pairing (`kl_ovrp_complete_stage_fenced`, `KL_STAGE_FENCE` vs `last_complete_record`+`stage_epoch`
+`KL_PRESENT_ORDER`), time-keyed DeviceAnchor ring + system reprojection
(`KL_REPROJECT_DEPTH_MODE=1` vs `KL_WARP=system`), EyeLevel rebase (`KL_OVRP_EYE_ORIGIN` +
`KL_OVRP_EYELEVEL`/`RECENTER_YAW` vs `ORIGIN_REBASE`), quad origin, `KL_OVRP_FILE_AFTER_GPU`
(= `FRAME_SYNC_FIRST`), guest pacing in C (= `KL_GUEST_FPS_DIV`), 0xb0/0xbc quad size,
GetUserEyeHeight2, ~45 of their ~120 protocol names. Their `KL_OVRP_ONE_POSE`/`POSE_BOUNDARY` is a
second pose-pin layer above the `KL_OVRP_LATCH` both trees have and collides with our
RECORD_INDEXED path.

Merged (klepton `5d16234`, `faa61e4`): `6e86e9a` glfb eye-FBO-map release (our `kl_glfb.c` was
byte-identical to upstream there; Beat Saber main-menu stale picture); from `65fd34e` the
XR_TYPE constants (`BOUND_SOURCES_FOR_ACTION_ENUMERATE_INFO`=62,
`INPUT_SOURCE_LOCALIZED_NAME_GET_INFO`=63, `VIEW_CONFIGURATION_PROPERTIES`=45, verified against
openxr.h) + action/path pools 256/512; from `bf5285a` the compositor env knobs read once
(`KL_CP_AMPLIFY`, `KL_HEAD_MIDPOINT` were per-frame `ProcessInfo` reads — the Batman crash shape)
and eye stages cleared at allocation.

Still not taken, possibly wanted later (re-implement by hand against our functions, from
`be18669`): `KL_OVRP_EYE_MAX` bounding the eye desc inside `klovrp_fill_eye_desc` (ours multiplies
by Unity's render scale with no cap — jetsam shape; mind our ADAPTIVE_RES answer); `DROP_NO_EYE` +
`VIEWPORT_CARRY` for Vulkan frames naming no eye layer (we only have `KL_OVRP_DROP_REPEAT`);
GetAppPerfStats via real sret (`kl_ovrp_sret.S` merges clean; ours returns a static 0x120
buffer); v5/v6 controller-state memset sizes (ours zeroes 0x60, PR 0x64/0x6c);
SetControllerLocalizedVibration routed to haptics (ours a dropped stub); GetDominantHand,
GetHandTrackingEnabled, four Tracking*2 predicates, GetNodeFrustum v1, three tracking-transform
identities, alpha-mode getter; boot gate / honest head (needs two small kl_ovrp exports) only if
Metro shows a tilted first frame. Skip ONE_POSE/POSE_BOUNDARY/POSE_KEY/ORIGIN_REBASE/FLOOR_OFFSET/
SUBMIT_FOV/diagnostics/UE4.27 bulk. Whole-file merge of `kl_ovrp.c` is impractical (34 blocks).

### PR 21 — GL path: KL_VRR_FLOOR + GLES fixes (10 commits, +883) — MERGED WHOLE

`KL_VRR_FLOOR` (default 0.50) clamps every zone of the guest rate map (periphery mip bias
~+3.3 → +1.0; Beat Saber menu looking down showed a blurred band); feather-blit bug fix
(`TEXTURE_BINDING_2D` read under the guest's active unit, restored onto unit 0 — our
`klfb_feather_blit` had the exact bug); depth texture LINEAR+compare NONE → NEAREST; per-stage
`int` precision rewrite; indexed draw-buffer calls served for buffer 0; blend/depth/cull pnames
forwarded, unhandled-pname log deduped; `GL_OES_vertex_array_object` named,
`EGL_KHR_create_context` advertised, backend extensions adopted from ANGLE (DXT, anisotropic,
BGRA8888; `KL_GL_NO_BACKEND_EXT=1` A/B), exts buffer 256→768; `glProgramBinary` wrapped
(`KL_GLFB_PROGRAM_BINARY=0`); `shader_cache_guard` deleting program-binary caches when
`kern.osversion`/`hw.model`/`KL_GLFB_REWRITE_GEN` moves; `KL_GLFB_NOMIP` opt-in.

Watch on the headset: anisotropic filtering now real for Unity (GPU cost), cache guard deletes
`ShaderCache`/`UnityShaderCache`/`GPUCache`/… under the files dir once after an OS update. Our
`KL_XR_FOVEA_FEATHER` path: check it is used on the OVRPlugin path, else the blit fix is latent.

### PR 14 — Unity GLES on ANGLE: texture units ≥32, no compute, CPU skinning — MERGED WHOLE

Three FOUND (pattern-matched) patches on `libunity.so` in `kl_guestpatch.c`, applied at load and
offline by klepton-ld: `unity-texunit-mask` (`and wU, wArg, #31` before Unity's "Invalid texture
unit!" check; `kl_glfb` masks sampler uniforms ≥32 when `kl_texunit_mask_active()`),
`unity-no-compute` (`supportsComputeShaders` false while still ES 3.2), `unity-cpu-skinning`
(2021.3 and 2019.4 shapes; 2019.4 measured on IEYTD 2019.4.21, our build). Refused by name when
unmatched; `KL_GUEST_PATCH_OFF=<name>`.

Ours was a different fix: raising Unity's cap to 64 via per-build singleton pokes in
`kl_guestpoke.c` (rows for ieytd 2019.4.21 and ktane 2022.3.62, `use=1`; Beat Saber row `use=0`
because the raise crashes it — so Beat Saber lives with stale unit-0 textures). Our own TODO
says the mask is the real fix. IEYTD handled by describing ES 3.0 (`kl_egl.c:305-310`).

Follow-up: once the `[patch] unity-texunit-mask` log says applied on 2022.3.x, set the ieytd/
ktane `k_poke_caps` rows to `use=0`. Keep ieytd at ES 3.0 initially; optional A/B ES 3.2 + the
two patches.

---

## Group B: translator / libc / audio (PRs 10, 11, 19, 12)

### PR 10 — x18 veneers (7 commits) — PENDING, TAKE 3 COMMITS LAST

Commits: `3f0eff5` `cbz` guard on the `br x18` veneer; `6cdc943` rewrite recognised `br x18`
jump tables to dispatch through x16 into per-target thunks and repoint the `.rodata` table;
`e432c44` rebuild `adr x18`/`ldr x18,literal` writes instead of refusing; `9aa63b8` `blr x18`
through x16 (sets x30, `br x16`); `7ffbff0` loader second arena below the image + 32 MB slices +
reach check; `04e200a` klepton-ld SPLIT placement for libraries no single pool reaches;
`df9ddf4` per-library "N REFUSED" at load + `kl_x18_refusals()` on the heartbeat.

Ours (`runtime/kl_x18.c` 786-1155): `blr x18` served with a shape that branches *through x18*
(the window PR 10 moves to x16); `adr x18` rebuilt; plus stp/ldp x18 pair, CASP, CTR_EL0 that the
PR lacks. `klepton_ld.c` 351-466: two-attempt pool placement (above, else below), enough for all
our libraries.

Take, each as its own retranslate + `make check` + headset smoke (one Unity title + Alyx):
1. `3f0eff5` — closes the load-use window on the 2 `br x18` sites every Unity libunity has.
2. `9aa63b8` — Alyx only (its 31 `blr x18` sites; the PR's motivating crash was Alyx mpg123).
3. `df9ddf4` — reporting only (our `kl_image.c` reads `__klstat` into `img->stats`, prints nothing).
4. optional `e432c44` (0 refusals today; shares `enc_adrp_to` with 2).
Skip `6cdc943` (heuristic `.rodata` rewrite, silent wrong branch risk for 2 sites/library) unless
a Unity title dies with pc=0 after (1); skip `7ffbff0`+`04e200a` (nothing wider than one `b`
window; Metro text 76.5 MB, pool below).
Conflicts: `kl_x18.c` 4 hunks/283 lines (both sides add cases to the same `if` chain —
mechanical), `tools/klepton_ld.c` 5/169 (only if SPLIT taken), Makefile 2/18, `kl_app.c` 1/16
(heartbeat line). Any change here retranslates every library (mkguest keys on klepton-ld mtime).

### PR 11 — libc/pthread (14 commits) — MERGED (`0ee8685`, see the session notes for the resolutions)

Fault handler reads `KL_FAULT_PEEK/WAIT` at install (`f798253`; ours called `kl_env_*` inside the
handler at `kl_fault.c:381,515` — Batman crash-with-no-report); mutex map tombstones/`MTX_CLAIM`/
hash fix (`03be7d9`; our `klb_pthread_mutex_destroy` wrote 0 — chain-breaking, Unity churns
mutexes per frame; supersedes our `KL_PTHREAD_WIDE_HASH` knob); rwlocks address-keyed map with
holder tracking (ours same design, poorer); barriers on a growable chunked side table (`16ace27`;
we had none); semaphore generations + destroy wakes waiters + 16384 slots (`d1b48fd`; SUPERHOT
"sharedassets corrupted" story; reconcile with PR 19's 65536: slot bits 16, gen mask shrinks);
`KL_MUTEX_POLICY=fairshare` (off by default); guest threads USER_INITIATED QoS by default
(`0776f63`; we keep `KL_GUEST_QOS` default OFF until a Metro/Beat Saber A/B; our
`KL_UE_THREAD_QOS` untouched); guest errno writes survive `__errno()` (`61a8bf4`); tgkill/tkill
real liveness (`05807f9`; replaces our unconditional yes + `KL_TKILL_PROBE`), raw
`sched_getaffinity`, self `process_vm_readv`; SIGUSR2<->SIGSYS swap on every signal entry point
(`2f48a79`; must not undo our 4553be3 "fatal signals stay unblocked" for glibc); path family
through `kl_guest_path` (rmdir … utimensat, fstatat struct translation, faccessat, mkdtemp,
freopen) (`8cd23b2`); F_SETLK flock translation; 4 KiB-aligned mprotect widening for the unaligned
case (coexist with our 16K-page work from 4228a83 in `kl_libc.c:3134+`); `EFD_SEMAPHORE`;
`_SC_AVPHYS_PAGES`; small names; tests t_sem/t_mtx/t_tgkill.

Conflicts: `kl_pthread.c` 6 hunks/384 lines (rwlock map, mutex hash, sem table, QoS block);
`kl_libc.c` 2/65 (tgkill door; `clock_nanosleep`/`sched_setscheduler` duplicates — ours in
`kl_shim.c:2102`, theirs in `kl_libc.c`, keep one); `kl_va_thunks.S` 1/70 additive; Makefile
2/60. Not flagged by merge-tree: duplicate E() rows in `kl_shim.c` for `sched_setscheduler`,
`clock_nanosleep`, `__poll_chk`, `fesetround`, `mkdtemp` (theirs via `kl_guest_path`),
`wcscasecmp`, `pthread_attr_setinheritsched` — a duplicate entry shadows one implementation.
Benefits: Alyx (signals, errno, paths, flock, eventfd, affinity), all Unity (mutex tombstones,
sem generations, fault handler), Metro (rwlock report, barriers, QoS).

### PR 19 — OBB path + sem table (2 commits) — MERGED WHOLE

`/sdcard/Android/obb/<package>` → `kl_jni_obb_dir()` (no-op for Metro whose row already sets the
UE layout; fix for Unity titles spelling the path, Batman split APK with two OBBs); `KL_MAX_SEMS`
1024 → 65536 with a high-water log. Reconciled inside the PR 11 merge.

### PR 12 — Audio (6 commits, +3190) — PENDING, TAKE PARTS (Batman enabler)

`3fc48c9` sink widens every guest encoding (s16/u8/s24/s32/f32) to float before the resampler
(ours int16-only, `kl_audio.c:598`); tagged sources with one owner (first non-silent claims,
revocable after `KL_AUDIO_STEAL_MS`, `KL_AUDIO_SOURCE`/`_MIX_SOURCES`); OpenSL parses `PCM_EX` and
`GetConfiguration` answers (ours refuses at `kl_opensl.c:646` — Oboe treats that as fatal); live
15 s report. `975cad6` AAudio burst 240 → 256 (`KL_AUDIO_NATIVE_FRAMES`, shared with JNI — our
`KLJ_AUDIO_FRAMES 256` is hard-coded separately, the drift), block-seam waiting out of the sink's
lead, `dlsym` returns NULL for unserved names (ours an aborting stub at `kl_aaudio.c:1154` —
Batman's Wwise/Oboe probes `AAudio_getMMapPolicy` and dies there), `requestPause`, output
`getFramesRead`, `setSamplesPerFrame`, attribute getters. `eab213b` crown-press silence latch
(`setSilenced`, missing in our KleptonAudio.swift), heartbeats, bounded self-closing WAV captures
(our `KL_AUDIO_DUMP` is unbounded). `571d145` haptics on a serial queue with rebuild backoff —
ours already moved into SenseKit (`SenseHaptics.swift:43` serial queue) but `dropEngine`/
`releaseAll` call `engine.stop()` synchronously and there is no rebuild backoff: port the
2 s→30 s backoff and queued `stop()` by hand into `SenseHaptics.swift`; take its `t_haptics.c`
timing fix. `b07f341` `[bank]` probe (diagnostic, strrchr per path open) — optional while
bringing Batman's Wwise banks up. Docs commit: hunks for what is taken.

Decide at merge: our `KL_SL_SILENT_YIELD`/`KL_SL_TAKE_DEVICE` per-target hacks (Max Mustard /
Deadpool, not ours) should be subsumed by owner arbitration. Unity GLES titles' OpenSL player
goes through the new arbitration (silence never claims could delay first sound by one buffer;
A/B `KL_AUDIO_MIX_SOURCES=1`). Alyx bypasses AAudio via the SDL seam (`kl_glibc_sdl.c:468`).
Conflicts: `kl_aaudio.c` 5/95 and `kl_opensl.c` 5/89 (our `mixes`/`g_device_rate`/
`kl_aaudio_output_rate` coupling vs their per-source model — take theirs, delete our rate gate);
`kl_audio.c` 2/27; `KleptonCompositor.swift` 1/13 (haptics census line — drop);
`KleptonControllers.swift` 3/337 (all in code we deleted — keep ours); Makefile 2/12.
Needs a Batman device run to confirm sound.

---

## Group C: small ones (PRs 5, 6, 8, 15, 16, 17, 22)

### PR 5 — battery levels — PENDING, TAKE PARTS

Really 2 patches (its two merge commits repeat the feature commits). `8097c86`: `KleptonBattery`
in `KleptonApp.swift` enables `UIDevice` battery monitoring and pushes level/charging into the
existing `kl_ovrp_set_battery_level/charging` seam (KL_BATTERY_* stay overrides); doc tweaks.
`ae4512a`: per-hand seam `kl_ovrp_set_controller_battery / _level / _state` (+
`KL_CONTROLLER_BATTERY_*` enum) in `kl_ovrp.c/.h`; `fill_controller_state` v4 fills
`b[0x40]/b[0x41]` from it (fallback 100); OpenXR advertises
`XR_EXT_interaction_profile_battery_state_display` and fills `XrBatteryStateDisplayEXT` on the
`xrGetCurrentInteractionProfile` chain (+ selftest); `kl_slink.c` interposes Steam Link's
`QSVLXRInput::GetPowerProps` so SteamVR shows controller battery; `KleptonControllers.swift`
reads `GCController.battery` per Sense half.

Ours: only the seam (`kl_ovrp.c:1122-1151`), fed by nothing: `g_battery_level = 95` fiction,
`b[0x40]/[0x41] = 100` hard-coded (`:5074/5084`), no battery anywhere in `visionos/` or
SenseKit. Take `8097c86` whole (trivial conflict in `KleptonApp.swift` init) and the C side of
`ae4512a` (`kl_ovrp.c/.h`, `kl_openxr.c`, `kl_slink.c`, `kl_jni_window.c`) as-is; the Swift half
must be re-done: add a battery callback/published property to SenseKit (`SenseControllers` keeps
`tracked: [GCController]` private) and call `kl_ovrp_set_controller_battery` from the wrapper.
Benefits: all titles indirectly (SteamVR headset battery → Alyx; Unity
`OVRInput.GetControllerBattery`).

### PR 6 — "visionOS 27 capabilities crash" — SKIPPED

No crash fix inside: `-framework CoreAudio` (we have), `use_lld=false` (we have on all three
ANGLE targets since 21a310a), `use_custom_libcxx=false`/`treat_warnings_as_errors=false`/
`use_thin_archive=false` gn args (unmotivated; the sim hunk would even drop `use_lld=false`),
`./update_depot_tools` auto-run in `angle-debug` (one-liner if wanted), BUILDING.md note
(duplicate of ours), BEATSABER.md (duplicates BUILDING.md), `mkdir 0777` (meaningless under the
sandbox).

### PR 8 — UE 4.25 by exported natives — MERGED

If not `re4` and the guest exports none of `nativeOnTrimMemory`,
`nativeOnThermalStatusChangedListener`, `nativeSetMemoryAdvisorState`, use the 4.25 shape.
Metro's libUnreal exports the first two → stays 4.26+.

### PR 15 — touch bits; product name — PRODUCT NAME MERGED (`4c5e602`)

`768693a` touch conversion skipped: ours (`kl_ovrp_touch_word/neartouch_word`) is per-hand, named
constants, thumbrests, near-touch arming pulse, selftest. `4c5e602`: "Oculus Quest" when
`klovrp_headset_type()==8` else "Oculus Quest 2" (A Fisherman's Tale keys on the exact name).

### PR 16 — honour Unity `Application.Quit` — MERGED

`kl_app_frame()` returning false after once true → log and `_exit(0)`; `KL_UNITY_QUIT=0`
restores. We added `kl_steam_shutdown()` (idempotent) before `fflush(NULL)`/`_exit`. Our
`kl_driver_frame` already returned nativeRender's int8 but the loop only tested `< 0`. The Swift
background path (`Lifecycle.scenePhaseChanged`) is not C-callable; stats line is still lost on
this path.

### PR 17 — guardian boundary, silent microphone, headphones, room invites — MERGED

`ovrp_GetSystemHeadphonesPresent` false; `ovrp_GetBoundaryGeometry3/Dimensions2/
TestBoundaryNode2/TestBoundaryPoint2` → `OVRP_FAIL_UNSUPPORTED` zeroed; `Get/SetBoundaryVisible2`;
`ovr_Notification_GetRoomInvites` request; `ovr_Microphone_Create` cookie, other
`ovr_Microphone_*` void no-ops. All were fatal unknowns in our tables.

### PR 22 — Red Matter 2 `Build.MODEL` "Quest" — SKIPPED

Target-specific (`redmatter2` exists in our `kl_ue4.c:837` but is not a hub game); same
per-target mechanism as our batman/metro rows in `kl_jni.c:1543-1583`. 9 lines if ever wanted.

---

## Group D: JNI / Unreal (PRs 7, 18, 20)

### PR 7 — Run Ancient Dungeon (1 commit) — TWO HUNKS MERGED

Taken by hand (klepton `94804a3`): `kl_openxr.c` `XR_META_performance_metrics` four entry points
as zero counters; `kl_shim.c` `connect()` errno save around `clock_gettime` + first 8 failures
logged. Not taken: `IsAssignableFrom` (take PR 20's version instead: PR 7's name-only tier picks
the first table row, wrong on overloads), `kl_jni_bhaptics.c` (PR 20's `kl_jni_haptics.c` is the
better twin; none of our titles ship the wrapper), `ovr_User_GetUserProof`/`Message_GetUserProof`/
`UserProof_GetNonce` (only for Beat Saber online sign-in experiments), Ancient Dungeon package
default.

### PR 18 — JNI missing methods + pinning (7 commits) — MERGED WHOLE

Pin every host-cached static jobject (`getDeviceIds`, `getObbDirs`, `Display.getSupportedModes`,
MediaRouter route, ContentResolver, ClassLoader, manifest Bundle, PlayAssetDelivery singleton,
`splitSourceDirs`, UE4 refresh-rate array) so a guest `PopLocalFrame` cannot retire them (ours
pinned none); `newProxyInstance(JLjava/lang/Class;)`; `Handler.obtainMessage(III)` with arg1/arg2
(Unity AndroidVideoMedia); `registerInputDeviceListener` dotted spelling;
`View.add/removeOnLayoutChangeListener` (every one of our five libunity references it);
`Class.forName(String)` both return spellings; `GameActivity.AndroidThunkJava_GetAndroidId`
(Metro references it); `g_supers` GameActivity → NativeActivity (without it
`GameActivity.getPackageName()` falls to `java/lang/Object` and aborts); `VRFL.vrFL` (Red Matter,
harmless). If PR 20's `d282ccf` is taken, its `klj_host_cache()` supersedes the same ten pin
sites (let 20's version win).

### PR 20 — Unreal/JNI sweep (10 commits, 26 files, +4347) — PENDING, TAKE PARTS BY COMMIT

Family table (PR 20 vs ours):

| PR 20 change | Ours | Relevance |
|---|---|---|
| `libandroid.so` dlopen → NDK table (`kl_ndk_dlopen`) | core-shim handle in `kl_dl.c`; `dlsym` goes to `kl_shim_lookup`, not `kl_ndk_lookup`, so `AAssetManager_*` via dlopen resolve NULL | Batman's Wwise libs reference `libandroid.so` |
| `AAsset_getRemainingLength[64]`, `isAllocated`, 18-name AInput family | missing | Metro imports 5 `AInputQueue_*` (not called yet) |
| `openDir` always returns an (empty) handle | gated to target `x5812519008825194` (AC Nexus); Batman gets NULL | **Batman** Wwise `SetBasePath` probe |
| `klj_host_cache` + pinning sweep | PR 18 pins | all Unity |
| assignability tier (`klj_class_is_a`, subclass args widen, erased Object, ambiguity refused) | partial (`klj_reflect_args`: erased Object + generic return, not subclass widening; we work around with literal dotted rows e.g. `FMOD.init(Lcom.unity3d.player.UnityPlayerActivity;)V`) | generic |
| no-signature tier (unique-by-name, interned under real signature) | missing | bHaptics-SDK2 titles only |
| JNI_OnLoad for whole `UE4_CHAIN`, libEOSSDK in chain | only libfmod (twice: `kl_dl.c` hook + `kl_ue4.c`) | Metro ships neither |
| `com/epicgames/unreal/` fold at intern funnel | we alias in `klj_resolve_binding` (works; `klj_class_name`/`g_supers`/Electra keep the unreal spelling) | Metro; after the fold our Electra rows must be respelled `ue4/` (the PR does) |
| `ue4_native_symbol` `_unreal_` retry | only `nativeInitHMDs`; `g_native_prefix` per dialect | Metro keyboard natives |
| `klj_ue5_meta_alias` | only `displaymetrics.dpi` | Metro refresh-rate/vsync keys |
| `PREVIEW_SDK_INT`, `getWindowManager().getDefaultDisplay()` | missing; **Metro references both** | Metro |
| ~60 `AndroidThunkJava_*` rows (intent extras, GetAndroidId, refresh rate, orientation, Vibrate, GetInputDeviceInfo, notifications, clipboard, screen capture, IAP/Google/Ads/PAD, ForceQuit knobs, virtual keyboard ×4 with `make uevk`) | we bind 28; **Metro references 49 of the new ones** (looked up, not yet called — each is fatal on first call) | Metro |
| Sentry sink / GvrPermissionHelper with `onAcquirePermissions` delivered | no-ops; no callback (Metro resolves both statics; a Blueprint waiting on the delegate hangs) | Metro |
| mobile-multiview clear on GL guests (`f92b942`) | missing | **skip**: Metro is Vulkan |
| FMOD whole surface, KL_FMOD_AAUDIO (`29c88e1`) | 12 rows + `getAssetManager` | **skip** the rewrite: no title ships fmod.jar |
| `AudioManager.getDevices` → one `AudioDeviceInfo` + 7 getters + `TYPE_*` table + `GET_DEVICES_INPUTS/ALL` (`29c88e1` hunks in `kl_jni_net.c`, `kl_jni.c` g_fields) | empty array, no rows/fields | **Batman**: `libMetaXRAudioWwise` walks this list ("failed to get default device"); all libunity reference it |
| HashMap rewrite (`51780e0`): ctor allocates, pins keys/values, `remove/isEmpty/clear`, `(I)`/`(IF)` ctors | **our ctor has the same bug**: `klj_HashMap_init` stores the map into `self`, which for `NewObject` is the jclass → every HashMap is the shared class object | all Unity |
| Locale +13 per-object parts | 5 methods reading host parts | IEYTD (`getISO3Language`, `getDisplayLanguage`, `forLanguageTag`) |
| StatFs via `statvfs` + ancestor walk + int forms | Long forms only, zeroes if path missing | generic |
| Byte/Short/Character/Double boxes with Number widening | missing (every libil2cpp names `java/lang/Character`) | all Unity |
| `Settings.Global/System` + `getInt/getFloat` | missing (every libunity names them) | all Unity |
| `unregisterReceiver`, `isWiredHeadsetOn`, `isSpeakerphoneOn`, `InputDevice.hasKeys`, `unregisterInputDeviceListener` | missing | IEYTD / all Unity |
| one `UnityPlayer` singleton, `mUnityPlayer` field, `getView` | `kl_driver.c` news two players | Unity plugins |
| `identityHashCode`, `MetricsService`, `setNativeExceptionOnProxy`, SDL `HIDDeviceManager`, KL_APK | missing | all Unity / hl2 |
| `kl_jni_haptics.c` + `make jniobj` (`3cb25e2`) | missing | **skip** (no title ships the wrapper; t_jniobj depends on it) |

Order (each cherry-pick with hand resolution, `make check` after each):
1. `d282ccf` object model — conflict `kl_jni.c` (1 hunk, 141 lines: their `klj_find_binding`
   tiers vs our `klj_reflect_args` block — keep theirs, drop ours, superset), pin sites in
   `kl_jni_net.c`/`kl_jni_android.c`. Medium.
2. `51780e0` framework families — conflicts `kl_jni_services.c` (3/185: our avp-play StatFs vs
   theirs, Locale rows, table tail), `kl_jni_android.c` (HashMap moved), `kl_jni_lang.c`
   (loadClass rows we already have). Medium.
3. `29c88e1` only the `getDevices`/`AudioDeviceInfo`/`TYPE_*` hunks (`kl_jni_net.c` 2/66 around
   `getDevices` and `Settings.Secure`, `kl_jni.c` g_fields). Easy. Skip the FMOD rewrite.
4. `b96f7f8` NDK — `kl_ndk_dlopen` door, `openDir` ungated (drop the AC Nexus gate), 32-bit
   names, open-miss log, AInput family. Conflicts `kl_ndk.c` (2/44), `kl_dl.c` (1/7) **plus
   remove `libandroid.so` from `kl_core_shim_libs`** or the core-shim door claims it first
   (merge-tree cannot see that).
5. `6d1ed6c` + `4fb9fb0` UE5/GameActivity surface — conflicts `kl_jni_ue4.c` (3/102: our
   orientation/refresh handlers, Sentry/ForceQuit, table tail), `kl_ue4.c` (1/37:
   `ue4_native_symbol` + dialect vs our `g_native_prefix` configure block — keep both; their
   `JNI_OnLoad` loop replaces our explicit libfmod call; our `kl_dl.c` libfmod hook stays —
   check `kl_maybe_jni_onload` is not reached twice in the UE4 chain path), `kl_jni.c` (fold at
   intern must coexist with our `klj_resolve_binding` alias, which becomes redundant),
   `kl_jni_electra.c` (auto-merges but our Electra rows must be respelled `ue4/`), Makefile
   (`make uevk`, `kl_jni_softinput.c` routing auto-merges). Medium-high.
6. `fa335da` JNI_OnLoad loop + EOS — low value; take if 5 is taken (5 builds on it).
7. Skip `f92b942`, `3cb25e2`; `0a0f319` docs only for what is taken.
Benefits: Batman (getDevices + Wwise openDir + libandroid door — plausibly silent vs audible;
verify on headset), all Unity (HashMap, pins, boxes, Settings, hasKeys, identityHashCode,
unregisterInputDeviceListener, Locale), Metro (49 thunks, PREVIEW_SDK_INT, getWindowManager,
permission delivery, keyboard, meta aliases). Alyx nothing.

---

## Suggested resume order

PR 12 parts (Batman audio; needs a Batman headset run) → PR 20 parts in
the order above → PR 5 (C side + SenseKit battery hook) → PR 10 commits 1–3 last (each with full
`make check` + retranslate + headset smoke). Then the PR 13 leftovers (eye desc cap, DROP_NO_EYE)
and PR 14's poke rows to `use=0`. PR 9 only after a Batman foveation evaluation with a guard
against both foveation systems running.
