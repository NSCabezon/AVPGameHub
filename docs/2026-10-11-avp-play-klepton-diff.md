# avp-play's Klepton fork vs ours: inventory and port (2026-10-11)

Source: avp-play (github.com/myMartek/avp-play, MIT), the Klepton fork shipped as source in toolchain 232
(commit 8073c5e). Upstream base for both forks: shinyquagsire23/Klepton `ce74582` (2026-09-03).
`git fetch origin`: upstream has **no commits after ce74582**, so nothing newer to take from there.

Port lives in worktree `vendor/Klepton-avpgames` (branch `avp-games`, from `alyx` e497979). **Not committed.**
Every adapted block carries `Adapted from avp-play (MIT, github.com/myMartek/avp-play) <path>`;
the MIT notice is in `THIRD_PARTY_NOTICES.md`.

## Size of their delta vs ce74582

~27k diff lines over 100 files (excluding vendor/). Roughly:

| Area | Lines (approx.) | Category | Decision |
|---|---|---|---|
| `runtime/linux/*`, `kl_linuxproc.*`, `mains/m_linux.c`, `tools/lx_*`, `gen_vk_names.py`, `audit_elf.py`, `visionos/lx*`, `mklxguest.py`, `stage_sync.py`, `KleptonAlyx.swift`, `tests/t_lx.c` | ~6.5k | their Alyx as a whole Linux process (xrizer, SteamCMD) | **skipped**: our glibc kind + OpenVR shim + SteamDepot is ahead |
| `kl_vulkan.c` | 3.4k | mostly diagnostics + their Alyx (async pipes, pass barriers, widen area) + per-game (Alien, AC Nexus, Walkabout/Batman) + a few generic fixes | ported; every alyx default removed; per-game gated |
| `kl_mtl_foveate.m` | 0.7k | Metal rate-map foveation via swizzling (their Alyx) | **skipped**: we have the MoltenVK FDM fork (KL_FOVEATE); swizzles would fight our compositor/GPU-time |
| `kl_ovrp.c`, `kl_ovrplat.c`, `kl_openxr.c` | 3.8k | OVRPlugin/platform/OpenXR gaps (generic fixes) + per-game (AC Nexus, Alien, Walkabout, Doom3Quest…) | ported; behaviour changes gated to avp-play titles |
| `kl_glfb.c`, `kl_egl.c`, `angle-patches/klepton.patch` | 1.6k | GL fixes (staged MSAA resolve, ESSL compat), Doom3Quest multiview + foveation, ANGLE OVR_multiview | ported; multiview only for doom3quest (needs an ANGLE rebuild to take effect) |
| libc / x18 / klepton-ld | 1.3k | generic fixes (rwlocks, swprintf, %S, clock_nanosleep, >128 MB .text relink) + their Linux ABI | ported fixes; Linux ABI skipped; our CASP veneer kept |
| JNI / media / guest doors | 2.0k | generic JNI gaps, audio device hand-off, video NV12/custom data source, Doom3Quest door, per-game rows | ported; risky audio/video defaults gated |
| `kl_songs.c` | 0.6k | Beat Saber custom levels (list only) | ported, on only for beatsaber128/140 |
| `visionos/*` (targets.py, Swift, run.sh, gen_xcodeproj.py) | 3k | per-game rows, generic `x<store id>` row, gamepad map, input fixes, rendering settings, start screen, in-app Meta download panel | rows + input + settings ported; start screen and Meta download panel (`KleptonGameData.swift`, `KleptonText.swift`) **skipped** (our hub is the UX; see docs/2026-10-08-metastore-hub-design.md: Meta download should be a separate app) |
| Makefile ANGLE gn args | — | tooling | ours kept (`use_lld=false` already) |

## Rules applied

1. Their code gates defaults on the target **name** `alyx`; ours is also `alyx` but a different guest kind.
   All such defaults were removed (KL_VK_ASYNC_PIPES, KL_VK_WIDEN_AREA, KL_VK_PASS_BARRIERS, KL_STALL_MS, MVK heap,
   eye max, display Hz). Our Alyx path is unchanged with no knob set (host boot verified, below).
2. Behaviour changes for existing targets are either behind a knob that defaults to the old behaviour, gated to
   avp-play's own titles (`kl_ovrp_avpplay_title()` / `klAvpPlayTarget()`: wrath2, batman, beatsaber140/128, moss,
   walkabout, steamlink-vr, doom3quest, and `x<store id>` rows), or are fixes on paths that previously aborted/failed.
3. DRM ethic kept: nothing claims content that is not on disk. Walkabout course purchases are reported only for a
   course whose real bundle is on disk *and* the store confirmed (stricter than avp-play). Download/Delete/Consume
   still abort; checkout aborts except for avp-play titles (error completion).

## Behaviour changes that do reach existing targets (justified as fixes)

- `kl_env.c`: knobs read by walking `environ` instead of `getenv` (fixes an IL2CPP stop-the-world deadlock in
  getenv's lock; Beat Saber/SUPERHOT are IL2CPP). Rollback: `KL_ENV_LOCKED=1`.
- libc: rwlocks keyed by address (old init could reuse a live lock's slot → deadlock; affects Alyx too — boot OK);
  `sem_post` no longer reads env in a signal handler; `link` path translation; `swprintf`/`vswprintf` were broken;
  `%S`/`%C` dropped args. New imports that used to be unresolved.
- x18: single-register CAS decode fix (Rs was missed). Byte-identical decoder output on all 62 Alyx libs and 36
  SUPERHOT/Metro/Beat Saber libs.
- OVRPlugin/platform: entry points that used to abort now return unsupported/error (body/face tracking,
  parametric haptics → NULL so callers fall back to PCM, leaderboards, durable-cache purchases, user fields).
- OpenXR: GLES `sampleCount>1` served single-sample (was FEATURE_UNSUPPORTED); array-swapchain per-eye publish;
  projection `imageRect` honoured (identical for full-texture rects).
- Vulkan: `rasterizationSamples 0→1`; destroyed device/instance no longer reused (record kept, not freed).
- GL: staged MSAA resolve only after the guest's blit failed (`KL_GLFB_RESOLVE_STAGE`); ESSL compat rewrites only
  for shaders ANGLE refuses (`KL_GLFB_ESSL_COMPAT`).
- JNI: `Looper.myLooper()` on a HandlerThread returns its own looper (Android semantics; **check VRChat/Bonelab
  video**); SDL audio thread raises its priority (cs1/hl2/portal/Steam Link); AAudio/OpenSL device hand-off only when
  both hold the device.
- visionOS input: haptics off the render thread; a hand standing in for a dropped controller pose no longer
  pinches; thumbstick touch bit and right Options pill → Start (`KL_SENSE_STICK_TOUCH`/`KL_SENSE_RIGHT_START`, on
  except `alyx`). Plain gamepad merged with hand input (`KL_GAMEPAD*`), only with a pad connected.

## Beat Saber 1.40.8 (what Meta sells today, versionCode 1716)

- Our `beatsaber` target already covers 1.40.x: almost all 1.40 support was upstream (ce74582) and is
  version-agnostic. The OBB name is derived from `apktool.yml`'s `versionCode` (`main.<code>.com.beatgames.beatsaber.obb`),
  so **one `beatsaber` target handles 1.40.8 by unpacking its APK into `beatsaber/`** (1.40.4/1598 keeps working the
  same way). avp-play's `beatsaber140` row is only a second bundle id/container for side-by-side installs; it is
  ported too (no hub entry).
- Build-specific bits to re-check with the 1.40.8 APK: the guest-poke row is keyed on the Unity version
  (2022.3.33f1 for 1.40.4; if 1.40.8 differs, add a row); the `liminal-touch-connected` patch already self-skips on
  a non-matching build; rerun `make check` (libc import union) once the APK is unpacked.
- Purchased song packs: ported `ovr_AssetFile_GetList` "store-delivered add-ons": the runtime lists a pack as
  installed/owned only if `<files>/klepton-assets/index.txt` names it (`asset <store asset id> <name>`) **and** the file
  is on disk. Nothing in our code writes that index yet: **the Meta store client must download the owned DLC asset
  files (avp-play's recipe `beatsaber140.json` lists sku/name/asset id per pack, e.g. P1S1 boundless 30506605242320047)
  into `android-files/klepton-assets/` and write `index.txt`.** The store itself refuses unowned packs.
- `ovr_User_GetImageUrl`/`GetSmallImageUrl` answer `""` (our Beat Saber fix, uncommitted in the main checkout
  `vendor/Klepton`, reproduced here) instead of avp-play's NULL.
- Custom levels (`kl_songs.c`, list only) are on for beatsaber128/140, off for `beatsaber` (`KL_SONGS=1` to try).
- avp-play's BEATSABER.md notes: stage `files/PlayerData.dat` to skip the language/explicit-content screens on
  device; we already pass those with `KL_PLAT_USER=1`.

## New targets now buildable (none added to the hub list)

All resolve in `targets.py` and the C table; none was run (no APKs here). Each needs files from the user's own Meta
account (APK + data), unpacked with apktool into `<target>/`, APK at the row's `apk` name:

| Target | Game | Needs |
|---|---|---|
| `beatsaber` / `beatsaber140` / `beatsaber128` | Beat Saber 1.40.8 / 1.28 | APK + `main.1716…obb` (1.40); 1.28 APK only |
| `walkabout` | Walkabout Mini Golf 6.7 | APK + `main.60366…obb` + course bundles in `Android/obb/<pkg>` (or `tools/walkabout_stub_bundles.py` stubs) |
| `batman` | Arkham Shadow 1.4.1 (Quest 3) | APK + loose OBB dir (audio OBBs, 69 bundles, DRM mp4s; `batman-required-bundles.txt`), ~19 GB |
| `wrath2` | Asgard's Wrath 2 | APK + `main.5513` + patch OBBs (tens of GB) |
| `moss` | Moss | APK + `main.151047…obb` |
| `doom3quest` | Doom3Quest 1.4.8 (Team Beef, free APK on GitHub) | APK + `pak000-008.pk4` from Steam Doom 3 (app 9050) or the bundled demo; **needs ANGLE rebuilt** with the new patch (multiview) |
| `steamlink-vr` | Steam Link (existing row) | APK |
| `x7527722310622065` | Cave Crave | APK + asset bundles |
| `KLEPTON_GENERIC_TARGET=x<id>` | AC Nexus `x5812519008825194`, Alien `x24882487241367228`, Deadpool `x3240283705987790`, Eye of the Temple `x5361030930653377` | APK + OBB/content bundles; engine read off the APK (UE4 vs UE5 unknown from recipes, so no static rows) |

SUPERHOT: ours (Steam Frame build) wins; their Quest build row was not needed.

## Verification

- `make check`: pass (beatsaber 1.40.4 guest; haptics passed in the same run).
- `make xros`: pass (xcframework + swiftcheck), one pre-existing unused-function warning.
- Alyx host boot (`m_boot alyx`, private TMPDIR, PLAN env): reaches `Idle (mainmenu)`, 0 unresolved imports.
- Not done: any run of the new games (no data), device runs, ANGLE rebuild.

## Follow-ups

- Rebuild ANGLE (`make angle-all`) only from a checkout whose `vendor/` is not shared, then test Beat Saber + Doom3Quest.
  Don't run `make angle-save` before `vendor/` carries the new patch (it would drop the multiview hunks).
- A/B on Alyx: `KL_VK_INPUT_ATT_FIX=1` (their exposure-meter fix), off here.
- Check VRChat/Bonelab video after the Looper change.

---

# Per-group inventories (from the port)


## A-vulkan inventory (runtime/gfx/kl_vulkan.c, kl_vulkan.h, kl_mtl_foveate.m)

Conflicts resolved (9 blocks, `ooobobbb` + block 8 by hand). No markers left. kl_vulkan.h was a clean merge (their 3 decls + ours), unchanged by me.
Note: their Alyx defaults are NOT in kl_vulkan.c (all knobs default off/1 there). They live in **runtime/guest/kl_driver.c** (`setenv KL_VK_PASS_BARRIERS 0`, `KL_VK_WIDEN_AREA 1`, `KL_VK_ASYNC_PIPES 1` for "alyx"). Whoever owns kl_driver.c must drop them.

| file | area | category | had equivalent? | decision | changes existing targets? |
|---|---|---|---|---|---|
| kl_vulkan.c | Linux WSI ext list (blk 0-2): their k_synth_wsi + headless, CreateInstance filter, vkCreate{Headless,Xcb,Xlib,Wayland}Surface table entries | their-alyx-linux | yes (our g_linux_wsi -> metal_surface) | skipped, ours kept; their table entries + ext_is_synth_wsi call removed | no |
| kl_vulkan.c | feature surgery klvk_feature_surgery (blk 4) | generic-fix | yes (our sanitize_features) | skipped (def + call removed) | no |
| kl_vulkan.c | devinfo (ours) + instance parking/g_insts/forget (blk 3) | per-game:walkabout,batman,x5269080709783454 | no | ported (parking target-gated, KL_VK_PARK_INSTANCE) | no (gated); g_insts bookkeeping is a fix |
| kl_vulkan.c | DestroyInstance / DestroyDevice hooks (records leave g_instance/g_devs) | generic-fix | partial (our klvk_retire_device for prewarm) | ported, but DestroyDevice does NOT free the record (UAF guard); klvk_retire_device now calls klvk_forget_instance | only after a guest destroys its instance/device, where g_devs[0]/g_instance used to be a freed MoltenVK object — fix |
| kl_vulkan.c | cache_display_luid refresh + kl_vulkan_display_phys | generic (OVRPlugin adapter handle) | no | ported (API kept for kl_ovrp.c) | no |
| kl_vulkan.c | kl_vulkan_spacewarp_image | per-game:x5812519008825194 (via kl_ovrp knob) | no | ported (API kept) | no |
| kl_vulkan.c | kl_vulkan_xr_image_capture, KL_VK_FRAME_EVENTS | tooling | no | ported; KFE counters gated on the knob | no |
| kl_vulkan.c | eye brightness check at frames 300/1200/2400 (KL_VK_EYE_CHECK) | tooling | no | ported-gated (KL_VK_EYE_CHECK, default **0**; theirs 1) | no |
| kl_vulkan.c | KL_OVERLAY_TEXL off for AC Nexus | per-game:x5812519008825194 | no | ported | no |
| kl_vulkan.c | stub section additions (no-MoltenVK build) | generic | — | ported | no |
| kl_vulkan.c | KL_VK_PROFILE, image/memory census, FreeMemory hook | tooling | partial (our KL_PERF_* logs, KL_GPU_TIME) | ported, both kept; per-draw prof atomics gated on KL_VK_PROFILE | no |
| kl_vulkan.c | in-rendering table + KL_VK_PASS_BARRIERS (0/1/2) + CmdEndRendering hook | tooling/their-alyx | no | ported-gated (default 1 = keep barrier = old behaviour) | no (logs first 4 in-pass barriers) |
| kl_vulkan.c | KL_VK_FS_STATS/SKIP_FS, PIPE_REC, DESC_TRACE, AFTER_SUBPASS_TRACE, SUBPASS_NOKILL/PROBE/DUMP, subpass-reader detection | tooling | no | ported (all off) | no |
| kl_vulkan.c | KL_VK_VIN_FILL (zero vertex inputs for refused pipelines) | per-game:x24882487241367228 | no | ported (default on only for that target) | no |
| kl_vulkan.c | rasterizationSamples 0 -> 1 | generic-fix | no | ported | only pipelines Metal would refuse — fix |
| kl_vulkan.c | KL_VK_ASYNC_PIPES (+ Destroy{Pipeline,ShaderModule,PipelineLayout}, debug-name hooks) | their-alyx/generic | yes for Alyx (Fossilize prewarm) | ported-gated (default 0 everywhere; alyx default lives in kl_driver.c) | no |
| kl_vulkan.c | CreateGraphicsPipelines split: their outer wrapper -> ...0 (fix-ups + our Fossilize hook) | — | — | merged; Fossilize recording stays in ...0, replay re-enters outer | no |
| kl_vulkan.c | CreateShaderModule chain (blk 8): ours outer (PIPE_HOOK) -> their wrapper renamed `klvk_CreateShaderModule_inner` -> `klvk_CreateShaderModule0` | — | — | merged | no (subpass SPIR-V scan per module, cheap) |
| kl_vulkan.c | KL_VK_WIDEN_AREA (+ WIDEN_TRACE), msaa image/view tables | their-alyx | no | ported-gated (default 0) | no (pass unchanged when off) |
| kl_vulkan.c | blk 5/6/7: our perf/FDM code + their profile hooks | — | — | both kept, ours first | no |
| kl_vulkan.c | draw/query/blend/sample-location hooks (CmdDraw*, ClearAttachments, Begin/EndQuery, CreateQueryPool, GetQueryPoolResults, SetBlendConstants, SetSampleLocations*) incl. KL_VK_NO_QUERY, QUERY_TRACE, BLEND_CONST(_TRACE), NO_SAMPLE_LOCATIONS, SAMPLE_LOC_TRACE | tooling | no | ported; passthrough by default; atomics gated; CreateQueryPool log moved to VKT | no (one extra call frame per draw) |
| kl_vulkan.c | KL_VK_MAX_SAMPLES (sample-count mask) | per-game:x5812519008825194 | no | ported (2 for that target, else 0) | no |
| kl_vulkan.c | KL_VK_SPOOF_DRIVER/API | tooling | no | ported (off) | no |
| kl_vulkan.c | KL_VK_HEAP_MB | generic knob | no | ported-gated (default 0) | no |
| kl_vulkan.c | KL_VK_INPUT_ATT_FIX + template input-attachment registry | their-alyx | no | ported-gated (default **0**; theirs 1); 1x1 image/view tracking only when on | no. Candidate A/B for our Alyx exposure (KL_VK_INPUT_ATT_FIX=1) |
| kl_vulkan.c | VKT capability-query traces | tooling | — | ported | no |
| kl_mtl_foveate.m | Metal rate-map foveation via ObjC swizzles of the command-buffer class (KL_VK_FOVEATE, KL_MTL_PROFILE, KL_MTL_TEX_TRACE) | their-alyx | yes (our KL_FOVEATE MoltenVK FDM fork; KL_GPU_TIME) | **skipped: file deleted**, call in CreateDevice removed, `g_klvk_scene_view_w/h` removed | no |

Other fixes made while merging: their `KLVK_REAL` statement macro collided with ours (expression macro) -> theirs renamed `KLVK_REAL_DEV`.

Knobs added (from theirs) and their defaults here: KL_VK_PARK_INSTANCE (walkabout/batman/x5269080709783454), KL_VK_VIN_FILL (x24882487241367228), KL_VK_MAX_SAMPLES (2 for x5812519008825194), KL_OVERLAY_TEXL (0 for x5812519008825194, else 1 as before); off by default: KL_VK_ASYNC_PIPES (+_WAIT_MS 8, _DELAY_MS), KL_VK_PASS_BARRIERS (1), KL_VK_WIDEN_AREA, KL_VK_HEAP_MB, KL_VK_NO_QUERY, KL_VK_INPUT_ATT_FIX (0, theirs 1), KL_VK_EYE_CHECK (0, theirs 1), KL_VK_PROFILE, KL_VK_FRAME_EVENTS, KL_VK_PIPE_REC, KL_VK_FS_STATS, KL_VK_SKIP_FS, KL_VK_DESC_TRACE, KL_VK_AFTER_SUBPASS_TRACE, KL_VK_SUBPASS_NOKILL/PROBE/DUMP, KL_VK_WIDEN_TRACE, KL_VK_QUERY_TRACE, KL_VK_BLEND_CONST(_TRACE), KL_VK_NO_SAMPLE_LOCATIONS, KL_VK_SAMPLE_LOC_TRACE, KL_VK_SPOOF_DRIVER/API.
Knobs dropped: KL_VK_FOVEATE, KL_VK_FOVEATE_INNER, KL_VK_FOVEATE_TRACE, KL_MTL_PROFILE, KL_MTL_TEX_TRACE (all kl_mtl_foveate.m). Docs owner: mark those as not in this fork; INPUT_ATT_FIX and EYE_CHECK default 0 here.
Exported API dropped: `kl_mtl_foveate_install()` (only caller was kl_vulkan.c), globals `g_klvk_scene_view_w/h` (only kl_mtl_foveate.m). **Do NOT add kl_mtl_foveate.o or `-framework Metal` for it to the Makefile.** All other APIs of theirs kept with their names (kl_vulkan_display_phys, kl_vulkan_spacewarp_image, kl_vulkan_xr_image_capture, klvk_ap_drain_all, stubs). Ours kept (kl_vulkan_advertise_linux_wsi, kl_foz_*, klvk_retire_device, klvk_set_pipe_hooks).
Compile check: `clang -fsyntax-only` with Makefile CFLAGS (-Wall -Wextra, MVK include) and also without MoltenVK headers (stub build) and with -DKL_HAVE_FOSSILIZE: 0 errors; 1 warning, pre-existing in ours (unused klvk_fdm_is_map).

## B-xr inventory (avp-play -> our Klepton fork)

Gating convention: new `kl_ovrp_avpplay_title()` (kl_ovrp.c/.h) = 1 for avp-play's titles: wrath2, batman, beatsaber140, beatsaber128, moss, walkabout, steamlink-vr, doom3quest, x24882487241367228, x3240283705987790, x5812519008825194, x5361030930653377, x7527722310622065, x6323807174332876, x5269080709783454, x5841245619310585. Not alyx/beatsaber/superhot. SUPERHOT's store row x1921533091289407 is left out so it keeps our superhot behaviour. "default=avp" below means default on for that list only, env knob overrides.

| file | area | category | we had equiv? | decision | changes existing targets? |
|---|---|---|---|---|---|
| kl_ovrp.c | 3 conflicts (head/hand pose writers) | generic | ours adds `t` field | merged: their origin_y lines + our 15-field initialisers | no |
| kl_ovrp.c | ADAPTER_PHYS (adapter id = VkPhysicalDevice) | per-game walkabout/batman/MaxMustard | no | ported (target-gated) | no |
| kl_ovrp.c | GetEnvironmentDepthFrameDesc writes IsValid=0 | generic-fix | shared success stub | ported | no: wanderer's local was already 0; fixes the uninitialised read |
| kl_ovrp.c | KL_OVRP_ADAPTIVE_RES + GetLayerRecommendedResolution scaling | per-game Alien | no | ported (target-gated) | no |
| kl_ovrp.c | KL_OVRP_RENDER_SCALE + kl_ovrp_set_render_scale_default | generic (frontend setting) | no | ported | no: default 1.0. Only batman 0.7 / doom3quest 1.0 set it in targets.py |
| kl_ovrp.c | KL_OVRP_EYE_MAX per-target cap (doom3quest 4000, AC Nexus 3840) | per-game | no | ported | no |
| kl_ovrp.c | unify list + walkabout; comment about their kl_linuxproc removed | per-game walkabout | — | ported | no |
| kl_ovrp.c | KL_OVRP_EYE_TAN_MAX, eye_display/told_tangents, eye_texture_size_for_cone | generic API | no | ported | no: default 0, and identical output when unify is off (it is off for every existing OpenXR guest) |
| kl_ovrp.c | EyeLevel origin shift (poses lowered/raised by captured head height) | generic | no | ported-gated `KL_OVRP_EYE_ORIGIN`, default=avp | no (off) |
| kl_ovrp.c | GetTrackingTransformRelativePose origin heights | generic | no | ported-gated `KL_OVRP_ORIGIN_HEIGHTS`, default=avp | no (off = identity, as before) |
| kl_ovrp.c | KL_OVRP_HEAD headless pose | tooling/diag | no | ported, comment reworded | no: inert unless set and no frontend head |
| kl_ovrp.c | per-frame-index samples (g_fs) + before-render late sample | generic | no | ported-gated: `KL_OVRP_RECORD_INDEXED` and `KL_OVRP_RECORD_LATE` were default 1, now default=avp | no (off) |
| kl_ovrp.c | KL_OVRP_POSE_TRACE, KL_OVRP_TEST_BR_YAW | diag | no | ported | no (env-only) |
| kl_ovrp.c | KL_OVRP_STAGES=2 for AC Nexus | per-game | no | ported | no |
| kl_ovrp.c | EndFrame4: file the record and overlays after the Vulkan GPU wait, plus GPU-wait stats | generic | no | ported-gated: new `KL_OVRP_FILE_AFTER_GPU`, default=avp. Off keeps the old order exactly | no (off) |
| kl_ovrp.c | Start carried from the right Touch word to the left | input | no | ported | no in C. Inert while the right hand never publishes START (true of our e497979 Swift). The merged KleptonControllers.swift now publishes it on the right Options pill, so that is the Swift owner's call |
| kl_ovrp.c | loading-video skybox follows Equirect submits | per-game AC Nexus | no | ported-gated: `KL_LOADVID_FOLLOW_SUBMIT` was default 1, now default=avp | no (off) |
| kl_ovrp.c | KL_OVRP_ENQ_OWNS_OVERLAYS | per-game AC Nexus | no | ported | no |
| kl_ovrp.c | overlay/stage pose origin_y conversion | generic | no | ported | no: 0 unless EYE_ORIGIN is on |
| kl_ovrp.c | KL_OVRP_VIEWPORT_TOP | per-game Alien | no | ported | no |
| kl_ovrp.c | SpaceWarp mv textures (7-arg GetLayerTextureSpaceWarp, mv size) | per-game AC Nexus | no | ported (target-gated) | no: the extra args are read only when the gate is on |
| kl_ovrp.c | EnqueueSubmitLayer2: boundary by layer id only, skip hidden 0x200, publish empty set, 1.34 srcRect via vm_read, Vulkan origin obeys layer flag 0x8 | generic | no | ported-gated: new `KL_OVRP_ENQ_STRICT`, default=avp. Off restores the old frameIndex boundary, no hidden skip, no rect, old origin | no (off) |
| kl_ovrp.c | GetLayerTexturePtr indirect (VkImage*) | per-game AC Nexus | no | ported | no |
| kl_ovrp.c | KL_OVRP_POSE_TIME (ovrpPoseStatef.Time) | per-game AC Nexus | no | ported | no |
| kl_ovrp.c | body/face tracking (Supported/Enabled), GetBodyState4 etc. UNSUPPORTED, parametric props, SetEyeOcclusionMeshEnabled | generic-fix | no | ported | fix: these used to resolve to the aborting named stub |
| kl_ovrp.c | g_ovrp_absent (SetControllerHapticsParametric, ...StreamingTimingProperties resolve to NULL) | generic-fix | PCM haptics already in ours | ported | fix: any caller of these used to abort. Beat Saber's haptics run through PCM, so it never called them |
| kl_ovrp.h | eq_hscale, proj_layer.rect, new API decls | generic | — | ported | no |
| kl_ovrp.h | kl_interstitial struct, kl_interstitial_get/_done | their-alyx-linux | — | **dropped** | — |
| kl_ovrp.h | `kl_ovrp_avpplay_title()` | tooling | — | added (new API) | — |
| kl_openxr.c | XR_FB_foveation(+config), XR_FB_swapchain_update_state(+gles) stubs and entry points | per-game doom3quest/steamlink | no | ported. Extensions advertised under new `KLXR_GATE_AVPPLAY` (`KL_XR_AVPPLAY_EXTS`, default=avp). Entry points always resolvable | no |
| kl_openxr.c | XR_KHR_visibility_mask + xrGetVisibilityMaskKHR (KL_XR_VISMASK) | generic (motivated by their Alyx) | no | ported, extension behind the same KLXR_GATE_AVPPLAY | no |
| kl_openxr.c | equirect2 layer composited as an overlay (shape 5, eq_hscale) | generic (their Alyx loading) | no | ported-gated: new `KL_XR_EQUIRECT`, default=avp. Off keeps it ignored, as before | no (off) |
| kl_openxr.c | cylinder drawn as its chord, not on the axis | generic | ours: 53-degree cap | ported-gated: new `KL_XR_CYL_CHORD`, default=avp. Off keeps the old capped code (cs1/hl1) | no (off) |
| kl_openxr.c | xrGetViewConfigurationViews uses eye_texture_size_for_cone | generic | — | ported | no (identical unless unify or TAN_MAX) |
| kl_openxr.c | GLES sampleCount>1 served as single-sample | generic-fix | no | ported | fix: this used to fail with FEATURE_UNSUPPORTED |
| kl_openxr.c | vk_pub per-eye mask for array swapchains, said_eyes, destroy releases both eyes | generic-fix | no | ported | fix only for array swapchains, which used to thrash and leave dangling textures. Per-eye swapchains behave the same |
| kl_openxr.c | projection imageRect into pl.rect, "drawing WxH" log | generic-fix | no | ported | no for full-rect guests (same picture). Fixes partial rects |
| kl_openxr.c | KL_VK_OUT Vulkan eye/equirect capture (kl_vulkan_xr_image_capture) | diag | no | ported | no |
| kl_openxr.c | shouldRender change log | diag | no | ported | no |
| kl_openxr.c | KL_XR_GL_FINISH (doom3quest, Tea For God) | per-game | no | ported | no |
| kl_openxr.c | LOCAL height latch (Cave Crave) | per-game | no | ported | no |
| kl_openxr.c | kl_stall_frame() heartbeat in xrEndFrame | diag | no | ported | no (KL_STALL_MS default 0) |
| kl_openxr.c/.h | kl_openxr_name(), kl_interstitial_done() call | their-alyx-linux | — | **dropped** | — |
| kl_ovrplat.c/.h | Walkabout courses from real on-disk bundles (>=1 MiB, stubs ignored), AssetDetails/Purchase/Product readers | per-game walkabout | no | ported, **tightened**: a purchase is reported only for a course that is both on disk and store-confirmed (klepton-entitlements.txt). avp-play also reported every confirmed SKU with nothing on disk; that half is not ported. Download/Delete/Consume still abort | no |
| kl_ovrplat.c | store-delivered add-ons (klepton-assets/index.txt; only files on disk) | generic | no | ported | no: no index means an empty list and the DRM abort, as before. Nothing in our hub writes that index |
| kl_ovrplat.c | KL_PLAT_LANGPACK_LIST (AC Nexus .lang list), batman OBB language-pack status | per-game | no | ported | no |
| kl_ovrplat.c | LaunchCheckoutFlow error completion | generic | no | ported-gated: new `KL_PLAT_CHECKOUT_ERROR`, default=avp. Off = DRM abort, as before (brief: checkout keeps aborting) | no (off) |
| kl_ovrplat.c | GetViewerPurchasesDurableCache returns request 0 | generic-fix | no | ported | fix: it used to abort. Grants nothing |
| kl_ovrplat.c | Leaderboard Get/Write and CancelAppDownload as error completions; Message_GetError/Error_* | generic-fix | no | ported | fix: these used to abort. Grants nothing |
| kl_ovrplat.c | User model fields (image/presence/ManagedInfo) answered 0 | generic-fix | no | ported | fix: these used to abort |
| kl_ovrplat.c | GetLoggedInUser list + walkabout, moss, AC Nexus, Maestro x6963344583787383 | per-game | no | ported | no |
| m_boot.c | DRM-guard self-test text (Walkabout carve-out) | tooling | — | ported. Guard semantics unchanged: DownloadById must abort, GetList must return | no |
| m_boot.c | GLES3JNI + KL_LIFECYCLE uses native_door_run | tooling | — | ported | no (env-only) |
| kl_reproject.c/.h, kl_view_mtl.m | projection-layer grid (kl_proj_layer_grid, grid_per_eye=1) for partial rects | generic-fix | no | ported. Dead klvm_identity_grid removed (unused-function warning) | no: the grid is the identity for a full rect |
| kl_mprobe.c/.h | KL_PROBE_METHODS/FIELDS/XFORM probes | diag | no | ported | no (env-only) |
| kl_mprobe.c/.h | kl_mprobe_nexus_frame_budget (KL_NEXUS_FRAME_BUDGET[_MS]) | per-game AC Nexus | no | ported | no |
| kl_stall.c | stall watcher (new file) | diag | no | kept, attribution added, Linux-audio comment removed. KL_STALL_MS default 0 in the file | no |
| tools/ovrp_abi.py | stop disassembly at the next symbol | tooling | — | ported | — |

## Knobs added (ours)
`KL_OVRP_EYE_ORIGIN`, `KL_OVRP_ORIGIN_HEIGHTS`, `KL_OVRP_FILE_AFTER_GPU`, `KL_OVRP_ENQ_STRICT`, `KL_XR_EQUIRECT`, `KL_XR_CYL_CHORD`, `KL_XR_AVPPLAY_EXTS` (gate for XR_FB_foveation*, XR_FB_swapchain_update_state*, XR_KHR_visibility_mask), `KL_PLAT_CHECKOUT_ERROR`. All default on only for kl_ovrp_avpplay_title() targets.
Their knobs whose default I changed from 1 to avp-only: `KL_OVRP_RECORD_LATE`, `KL_OVRP_RECORD_INDEXED`, `KL_LOADVID_FOLLOW_SUBMIT`.
Their target-gated knobs kept as-is: KL_OVRP_ADAPTER_PHYS, KL_OVRP_ADAPTIVE_RES(+_GPU_MS), KL_OVRP_VIEWPORT_TOP, KL_OVRP_TEXPTR_INDIRECT, KL_OVRP_SPACEWARP_TEX, KL_OVRP_ENQ_OWNS_OVERLAYS, KL_OVRP_POSE_TIME, KL_OVRP_STAGES (2 for AC Nexus), KL_OVRP_EYE_MAX (doom3quest 4000, AC Nexus 3840), KL_OVRP_EYE_TAN_MAX (0), KL_OVRP_RENDER_SCALE, KL_OVRP_HEAD, KL_OVRP_POSE_TRACE, KL_OVRP_TEST_BR_YAW, KL_XR_GL_FINISH, KL_XR_VISMASK, KL_PLAT_LANGPACK_LIST, KL_NEXUS_FRAME_BUDGET(_MS), KL_STALL_MS (0).
Not in my files: KL_OVERLAY_TEXL (kl_vulkan.c) is already default 1 in base and ours. Theirs only adds a default of 0 for AC Nexus, so existing targets do not change. KL_GUEST_FRESH_POSE is in kl_app.c, KL_OVERLAY_SUBMIT_ORDER in KleptonCompositor.swift. KL_STALL_MS=250 for "alyx" is set in their runtime/guest/kl_driver.c:159. The worktree copy does not have it now; it must stay out.

## Dropped knobs/API
- Dropped: `kl_interstitial` type, `kl_interstitial_get()`, `kl_interstitial_done()` (kl_ovrp.h) and `kl_openxr_name()` (kl_openxr.h/.c), all for their Linux Alyx. **The merged visionos/Sources/KleptonCompositor.swift still calls `kl_interstitial_get` (~line 2925, makeLoadingCard)**, so the Swift owner must remove that or it won't compile.
- Added API: `int kl_ovrp_avpplay_title(void)`.
- My files call into other groups (names kept as theirs, and they compile against the current headers): `kl_vulkan_display_phys`, `kl_vulkan_spacewarp_image`, `kl_vulkan_xr_image_capture`, `kl_vulkan_frame_done`, `kl_vulkan_capture_layers`.
- Swift must keep `kl_proj_layer_grid` beside `kl_proj_layer_build`, since the build now selects per-eye grid blocks. The merged KleptonCompositor.swift already does.

## Makefile
**Add `runtime/diag/kl_stall.c` to RUNTIME_SHIP.** kl_openxr.c calls `kl_stall_frame()`, so leaving it out is a link error. It is inert unless KL_STALL_MS>0.

## Compile check
`clang -fsyntax-only -Wall -Wextra -Wno-unused-parameter` (Makefile includes): kl_ovrp.c, kl_ovrplat.c, kl_openxr.c, m_boot.c, kl_reproject.c, kl_view_mtl.m (-fobjc-arc), kl_mprobe.c, kl_stall.c all have 0 errors and 0 warnings. ovrp_abi.py py_compile OK. No conflict markers. Nothing git-added or committed.

## C-gl inventory (kl_glfb.c/.h, kl_egl.c, angle-patches/klepton.patch, kl_gles3jni.c, kl_guestpoke.c)

| file | area | category | had equiv? | decision | changes existing targets? |
|---|---|---|---|---|---|
| kl_glfb.c | ESSL fixups: GL_EXT_clip_cull_distance -> GL_APPLE_clip_distance, fma() #define for ESSL 3.00, trim whitespace before `#version` | generic-fix (Tea For God, Doom3Quest) | no | ported-gated: new knob KL_GLFB_ESSL_COMPAT (default 1). Added guard: fma macro NOT inserted if the shader defines its own fma() | no in practice: only touches shaders ANGLE refuses today (exception: a shader with `#ifdef GL_EXT_clip_cull_distance` would now take its clip branch). KL_GLFB_ESSL_COMPAT=0 = old behaviour |
| kl_glfb.c | `invariant gl_Position` injection | per-game:doom3quest | no | ported (KL_GLFB_INVARIANT, default on only doom3quest) | no |
| kl_glfb.c | glFramebufferTextureMultiviewOVR hook + g_fbo_multiview tracking; BindFramebuffer calls rate_rule/resync | per-game:doom3quest (multiview) | no | ported; I additionally gated klfb_resync_fbo on klfb_mirror_vrr() (theirs only checked mirroring) | no: all early-return unless KL_VRR_MIRROR (doom3quest) |
| kl_glfb.c | MV shadow: 2D FBO drawn with multiview programs -> 2-slice arrays; FramebufferRenderbuffer / CopyTexImage2D / CopyTexSubImage2D hooks | per-game:doom3quest | no | ported (KL_GLFB_MV_SHADOW, default on only doom3quest); hooks are pass-through otherwise | no |
| kl_glfb.c | kl_glfb_set_foveation_default + g_foveation_default | UX (theirs: app setting) | KL_VRR default 1 | ported, default kept = 1 (our KL_VRR default) | no, as long as the app side doesn't call it with 0 (see note) |
| kl_glfb.c | klfb_mirror_vrr / kl_glfb_rate_map_layers / min-samples-1 size rule / rate-rule toggling / unmap during mirror copy | per-game:doom3quest | no | ported (KL_VRR_MIRROR default on only doom3quest); rate_map_layers returns 1 unless that | no (min_samples stays KL_RATE_MIN_SAMPLES; only a log string and bookkeeping vars differ) |
| kl_glfb.c | klfb_mirror_dest refactor of kl_glfb_mirror_eye_layer | refactor | — | ported (pure extraction) | no |
| kl_glfb.c | staged MSAA resolve across formats (KL_GLFB_RESOLVE_STAGE) + glGetError drain before color blits | generic-fix (Keep Talking) | no | ported-gated(KL_GLFB_RESOLVE_STAGE, default 1). Changed: the pre-blit error drain now also only runs when the knob is on, so =0 is the exact old blit | resolve only runs after the guest's blit FAILED with 0x502 on an MSAA renderbuffer (previously a dropped blit) -> clear fix. Side effect with default on: pending GL errors are drained before each colour blit (guest's glGetError won't see older errors) |
| kl_glfb.c | ours: bounded eye-texture logging, eye depth table (kl_glfb_note_eye_mtl_depth / _eye_mtl_depth) | ours | — | kept | — |
| kl_glfb.h | decls kl_glfb_rate_map_layers, kl_glfb_set_foveation_default | API | — | ported (ours' depth decls kept) | no |
| kl_egl.c | GL_VENDOR/RENDERER per-target identity (moss -> "Qualcomm"/"Adreno (TM) 650") | per-game:moss | ours: KL_GL_VENDOR/RENDERER knobs | conflict resolved: ours' getenv-with-empty-check + Metro comment kept, default now klgl_identity() | no (non-moss default unchanged "Klepton"/"Klepton GLES") |
| kl_egl.c | doom3quest added to klgl_want_multiview (advertise GL_OVR_multiview) | per-game:doom3quest | — | ported | no |
| kl_egl.c | kl_egl_sym returns NULL for glFramebufferTextureMultisampleMultiviewOVR | generic-fix (doom3quest) | — | ported-gated: only when klgl_want_multiview() (ieytd*/hl2/portal/doom3quest) | no for beatsaber/superhot/alyx/others (unchanged resolution) |
| angle-patches/klepton.patch | OVR_multiview for ANGLE Metal (translator, layered pass, instanced view emulation, topology class, maxViews, clear.metal) | generic (needed by doom3quest) | no | kept as text (file == theirs; ours never modified it) | no until ANGLE is rebuilt; see note |
| kl_gles3jni.c | Doom3Quest door: data staging (pak399, cfgs, demo paks, move demo aside when retail), void onCreate d3_create, start sequence, GAMELIBDIR/USER_FILES/GAMETYPE env, r_multithread 0 (KL_D3_MULTITHREAD) | per-game:doom3quest | no | ported | no (g_d3 only when entry lib is libdoom3) |
| kl_gles3jni.c | "doom3quest" in prefix probe list | per-game:doom3quest | — | ported | no (probed after lambda1vr/jkxr) |
| kl_gles3jni.c | static act[] (dangling pointer to kl_jni_set_activity_class) | generic-fix | no | ported | yes for lambda1vr/jkxr: fixes a use-after-return (clear bug fix) |
| kl_gles3jni.c | kl_jni_reclaim_frameless_strings(KL_JNI_RECLAIM_STRINGS) for all GLES3JNI guests | generic (their default 1) | no | ported-gated: default changed to on only for doom3quest | no (lambda1vr/jkxr keep old string lifetime; =1 enables) |
| kl_guestpoke.c | `target` field narrowing a cap row; rows 2019.4.36f1 (Eye of the Temple x5361030930653377) and 2022.3.62f3 (Keep Talking x2010043642376517) | per-game:x-rows | — | ported; existing rows given explicit NULL target | no: our beatsaber is Unity 2022.3.33f1 (row unchanged, use 0) |
| kl_guestpoke.c | KL_POKE_CAP forced on unlisted version used k_poke_caps[0] | fix to theirs | — | changed: fallback now finds the "2019.4" reference row explicitly (theirs' new first row would have silently changed the forced offsets) | no |

## Notes
- **ANGLE / multiview:** current built ANGLE (vendor/ = our old patch, verified `git apply --check -R` clean; DisplayMtl has no multiviewOVR) has NO OVR_multiview. Nothing in these runtime changes requires it for beatsaber/superhot: all multiview code is keyed on doom3quest (or on klgl_want_multiview targets, which already asked for multiview upstream). Doom3Quest itself will not render until ANGLE is rebuilt with the new patch. No runtime capability check added beyond those target gates.
- **Keeping the patch text is safe**: it only applies on a fresh `make angle-fetch` (vendor/ absent) or manual `git -C vendor apply`. On rebuild its effects are confined to layered passes (renderTargetArrayLength>1 / RenderTarget layer count >1, only set by multiview attachments) and multiview shaders; ANGLE exposing multiviewOVR natively doesn't reach guests because GL_EXTENSIONS stays Klepton's own gated list. HAZARD: `make angle-save` exports vendor/'s diff over this file and would silently drop the multiview hunks until vendor/ is actually re-patched.
- **Foveation default**: ours KL_VRR default 1; kept g_foveation_default=1. Theirs' visionOS KleptonTuning.apply() calls kl_glfb_set_foveation_default(setting) with a setting "off unless a person turns it on" — whoever ports the Swift side must make the default ON (or skip the call) for existing targets (beatsaber, superhot, alyx), else VRR silently turns off.
- Knobs added (new, mine): KL_GLFB_ESSL_COMPAT (default 1, all targets). Knobs ported: KL_GLFB_RESOLVE_STAGE (1, all), KL_GLFB_INVARIANT / KL_GLFB_MV_SHADOW / KL_VRR_MIRROR (on only doom3quest), KL_D3_MULTITHREAD (0), KL_JNI_RECLAIM_STRINGS (default changed: on only doom3quest; theirs 1 for all GLES3JNI), KL_GL_VENDOR/RENDERER (ours, now per-target default). None dropped.
- Exported API: added kl_glfb_rate_map_layers, kl_glfb_set_foveation_default (theirs' signatures). Ours' kl_glfb_note_eye_mtl_depth / kl_glfb_eye_mtl_depth kept. Nothing dropped. kl_gles3jni.c needs kl_jni_reclaim_frameless_strings, kl_jni_build_string, kl_jni_assets_dir (present in worktree from other groups).
- Compile-check (`clang -fsyntax-only -Wall -Wextra` with Makefile RUNTIME_INC/MVK_INC): all 4 C files clean; only a pre-existing warning (kl_glfb.c klfb_errprobe `said` unused, from ours/base). No conflict markers remain.

## D-libc-x18 inventory

| file | area | category | had equiv? | decision | changes existing targets? |
|---|---|---|---|---|---|
| runtime/kl_x18.c/.h | Linux ABI (g_abi, set_abi/abi, TP/SVC sysregs, KLX_TP/SVC_SLOT claim, init_linux, tp/svc survey+emit, stats fields, stat-section abi fields, magic bump to "8X1A") | their-alyx-linux | n/a | skipped (rule 2) | no |
| kl_x18.c/.h | CASP pair veneer (KLX_HZ_PAIR), enc_mov | generic-fix | yes: our Glovebox KLX_HZ_CASP | skipped, kept ours; `#define KLX_HZ_PAIR KLX_HZ_CASP` alias added. Their t_casp.c passes against OUR veneer | no |
| kl_x18.c | `blr x18` via `bl` + x16 | generic-fix | yes: ours (adrp/add x30 + br x18) | kept ours (device-tested on Alyx); theirs avoids the x18 window, noted as alternative | no |
| kl_x18.c | `adr x18` via adrp/add | generic-fix | yes | kept ours | no |
| kl_x18.c | KLX_VEN_MAX_INSN 10 | generic | ours is 12 | kept ours (12 ≥ 10) | no |
| kl_x18.c | single-reg CAS (o2=1,o1=1,Rt2=31) roles: Rs R/W, Rt R (was decoded as an exclusive load: Rt write-only, Rs missed) | generic-fix | no | ported (only the o2 branch; their o2=0 branch would mis-refuse STXP with Rt2=xzr and is covered by our CASP) | no. t_x18 decode output byte-identical, old vs new, over all 62 Alyx arm64 libs + 36 SUPERHOT/Metro/Beat Saber libs |
| kl_x18.c/.h | kl_x18_report_reset() | tooling | no | ported | no |
| tests/t_x18.c | TEST_PAIR for KLX_HZ_PAIR | tooling | ours covers it via check_x18 | skipped (back to ours = base) | no |
| tests/t_casp.c | executed CASP Rs/Rt + blr x18 + adr x18 | tooling | partly (t_x18_casp covers CASP only) | ported, switched to KLX_HZ_CASP. Kept as an independent cross-check and for the executed blr/adr cases. PASS against our emitter | no |
| tools/check_x18.py | casp want-string | tooling | yes (ours) | kept ours | no |
| tools/check_x18.py | `extr Xd,Xn,Xn` → `ror` normalisation | tooling fix | no | ported. Fixes a false BAD SUBST that made `check_x18` fail on Alyx libs (2 sites); now "all libraries clean" over 62 Alyx libs | tool only |
| tools/klepton_ld.c | pool_by_sites: try the pool above, then below, when .text > 128 MB (Deadpool libUE4), + far_refused accumulation + report_reset | generic-fix (relink) | no | ported | only on a path that used to die() |
| tools/klepton_ld.c | --abi, --print-name, kl_lx_name.h, tp/svc stats, lx report, abi in stat record | their-alyx-linux | n/a | skipped | no |
| tools/gen_libc_table.py | vswprintf moved to SPECIAL | generic | no | ported | no |
| runtime/libc/kl_libc_table.h | -free, -link, -vswprintf (now E() in kl_shim.c) | generated | n/a | kept theirs; consistent with the generator (`listed` = E() names) and kl_shim.c. glibc kind resolves these through kl_shim_lookup_base, so the same entries apply | see free/link/vswprintf rows |
| runtime/libc/kl_libc.c | KL_FS_REL_SDCARD (relative "sdcard/…" → "/sdcard/…") | per-game:x5812519008825194 | no | ported-gated (knob, default on only for AC Nexus) | no |
| kl_libc.c | klb_link with guest-path translation | generic-fix | no (was raw forward) | ported | only for guest paths that used to ENOENT |
| kl_libc.c | KL_CLOCK_RES_LINUX (clock_getres = 1 ns) | per-game:x5812519008825194 | no | ported-gated (default on only for AC Nexus) | no |
| kl_libc.c | klb_clock_nanosleep, klb___poll_chk | generic (Deadpool imports) | no | ported | no (these were unresolved imports) |
| runtime/libc/kl_pthread.c | rwlocks address-keyed (dropped SYNC_TABLE slot-in-guest-storage, which could recycle a LIVE lock's slot on init → self-deadlock, seen in Alien) | generic-fix | no | ported | yes, all guests incl. Alyx (glibc rwlocks go through klb_). Same design as our mutex/cond maps (262144 slots); fixes real aliasing |
| kl_pthread.c | sem_post reads KL_TRACE_SIG cached at sem_init (async-signal-safe) | generic-fix | no | ported | yes, fixes an IL2CPP GC deadlock; output unchanged |
| runtime/libc/kl_shim.c | klb_free + KL_FREE_QUARANTINE_MB | generic (Doom3Quest instrument) | no | ported-gated (knob, default 0 = plain free for every target) | no (one atomic load per free) |
| kl_shim.c | sched_setscheduler (QoS boost), sched_getscheduler/getparam/getcpu, pthread_attr_setinheritsched, pthread_getname_np, fesetround, mkdtemp, clock_nanosleep, __poll_chk, wcscasecmp, wctomb, quick_exit | generic / per-game Steam Link, Deadpool, Tea For God | no | ported | no (previously unresolved) |
| kl_shim.c | swprintf → klv_swprintf, vswprintf → kl_vswprintf_g, link → klb_link | generic-fix | no | ported | swprintf was a "" stub and vswprintf a raw forward with the wrong va_list ABI; both were broken |
| runtime/libc/kl_va.c | %S/%C classed as %ls/%lc | generic-fix | no | ported | only formats with %S/%C, which used to drop their args |
| kl_va_handlers.c / kl_va_thunks.S | kl_vswprintf_g, klh_swprintf, KL_VTHUNK klv_swprintf | generic-fix | no | ported (our glibc thunks kept alongside) | as above |
| runtime/kl_env.c | lock-free environ walk instead of getenv (IL2CPP stop-the-world deadlock) | generic-fix | no | ported, plus escape knob KL_ENV_LOCKED=1 (back to libc getenv) | yes, every knob read; justified below |

## kl_env.c lock-free read: is it safe for us?
These writers can still run once threads exist: kl_vulkan.c's MVK_CONFIG_* setenv(…,0) at Vulkan init; Fossilize prewarm's unsetenv/setenv of KL_VK_DEVICE_INFO (boot thread, before the guest starts, but host threads may already be reading knobs); and the guest's own setenv/unsetenv/putenv. Those are forwarded to the host for Android guests (KL_FWD) and for the glibc/Alyx guest (kl_glibc_shim putenv, plus the base table). All the other setenv calls (kl_driver/kl_native/kl_glibc defaults, hub Swift and kl_app setenv, m_boot) happen before the guest boots.
The race: a walk running at the same moment as an append that reallocates environ, or as an unsetenv that shifts entries. On Darwin's allocator the old array stays mapped, so the worst case is one missed or stale knob read, not a fault. libc getenv only protects the walk anyway: the pointer it returns is just as exposed afterwards.
The deadlock it removes is real and hits our IL2CPP targets (Beat Saber, SUPERHOT). Verdict: keep it. KL_ENV_LOCKED=1 is there as a rollback switch if Alyx ever shows env flakiness.

## Knobs
- Added: KL_ENV_LOCKED (default 0, every target).
- Ported from theirs: KL_FS_REL_SDCARD and KL_CLOCK_RES_LINUX (default on only for x5812519008825194). KL_FREE_QUARANTINE_MB (default 0 everywhere).
- None of these defaults is keyed on "alyx".

## Exported API dropped (Linux ABI)
kl_x18_set_abi, kl_x18_abi, kl_x18_init_linux, KLX_ABI_*, KLX_TP_SLOT, KLX_SVC_SLOT, KLX_SYS_TP_READ/WRITE/SVC, the stats tp_*/svc_*/lx_refused fields, and klx_stat_section abi/tp/svc (KLX_STAT_MAGIC stays at base "8X19"). Nothing outside runtime/linux references them.
Kept or added: kl_x18_report_reset, KLX_HZ_PAIR (alias), kl_libc_free_report, kl_vswprintf_g, klh_swprintf, klv_swprintf, klb_link, klb_clock_nanosleep, klb___poll_chk.
Makefile owner: keep the `casp` rule (tests/t_casp.c now exists and passes). Drop t_lx if it is still there.

## Verification
- `clang -fsyntax-only` with the Makefile CFLAGS is clean on kl_x18.c, kl_env.c, klepton_ld.c, t_casp.c, t_x18.c, kl_libc.c, kl_pthread.c, kl_shim.c, kl_va.c, kl_va_handlers.c and kl_va_thunks.S. The only warning is the old vfork deprecation in the table.
- Built standalone into $S/tmp: t_x18_casp PASS, t_casp PASS (CASP, blr x18, adr x18), t_ctr PASS.
- check_x18 over the 62 Alyx arm64 libs: old tool FAILS (extr false alarm), new tool "all libraries clean".
- Per-site decode output is identical before and after (Alyx, SUPERHOT, Metro, Beat Saber).
- No conflict markers left. No git add/commit.

## F-jni-media-guest — inventory

| file | area | category | had equiv? | decision | changes existing targets? |
|---|---|---|---|---|---|
| kl_jni.c | frameless-string reclaim ring (klj_loose_note, kl_jni_reclaim_frameless_strings) | per-game:doom3quest | no | ported (off unless a door calls it) | no here. NOTE: theirs turns it on in kl_gles3jni.c (`KL_JNI_RECLAIM_STRINGS`, default 1 for the GLES3JNI door), which would include our `hl1` — that agent's call |
| kl_jni.c | acnexus soft-default also for x5812519008825194 | per-game:x5812519008825194 | no | ported | no |
| kl_jni.c | KL_JNI_DROP_ANALYTICS (com/gameanalytics/* -> zero) | generic-fix (Max Mustard) | no | ported, knob default 1 | only on a path that used to abort ("no host implementation") |
| kl_jni.c | EOS enum static constants -> pinned objects | per-game:Cave Crave (EOS) | no | ported | no (narrowed to com/epicgames/mobile/eossdk/, previously aborted) |
| kl_jni.h | kl_jni_reclaim_frameless_strings decl | API | – | ported | no |
| kl_jni_android.c | Context.getApplicationContext, AcousticEchoCanceler.isAvailable | generic-fix (EOS) | no | ported | no (new rows) |
| kl_jni_fmod.c | FMOD.init dotted-signature row | generic-fix (Max Mustard) | no | ported | no |
| kl_jni_jkxr.c | Doom3Quest GLES3JNIActivity haptics rows | per-game:doom3quest | no | ported | no |
| kl_jni_lang.c | Context.getClassLoader, ClassLoader.loadClass | generic-fix (EOS) | no | ported | no |
| kl_jni_looper.c | HandlerThread quit/quitSafely, Thread isAlive/join/interrupt/isInterrupted, getThreadId, Message.getTarget, Handler.getLooper/removeCallbacksAndMessages, Looper.quitSafely | generic-fix (Unity VideoPlayer teardown, AC Nexus) | no | ported | no (new rows, previously aborts) |
| kl_jni_looper.c | Looper.myLooper() on a HandlerThread returns that thread's looper | generic-fix | no | ported | yes, Android-correct: before, a HandlerThread got NULL/the main looper. Only HandlerThreads change (Unity VideoPlayer: VRChat/Bonelab video). Worth a check on device |
| kl_jni_looper.c | SDLAudioManager.audioSetThreadPriority -> kl_pthread_boost_qos(self) | generic-fix (Steam Link dropouts) | no | ported | yes, SDL audio thread now high QoS (cs1/hl2/portal/steamlink): a scheduling fix, same QoS mapping Process.setThreadPriority(AUDIO) already uses |
| kl_jni_net.c | System.loadLibrary row; EOSSDK statics (verifyPlatformsOptions, GetOSVersion, URL/keychain/overlay stubs) | generic-fix (Max Mustard, Cave Crave) | no | ported | no |
| kl_jni_sdl.c | setBackButtonTrapEnabled, SteamLink USB/WiFi/lowlatency no-ops | per-game:steamlink-vr | no | ported (our getPreferredLocales kept) | no (previously aborted) |
| kl_jni_services.c | [conflict] includes | – | – | both (CoreFoundation + sys/mount) | no |
| kl_jni_services.c | Omni start, Locale.toString, StatFs, Photon AudioInAEC, FMOD.getAssetManager | generic-fix (Cave Crave, Walkabout, Max Mustard) | no | ported | no (new rows) |
| kl_jni_services.c | OculusUnity initComplete fallback when surfaceCreated is missing | generic-fix (Eye of the Temple) | no | ported | only where the old path skipped surface setup, which left the game with 0 layers |
| kl_jni_ue4.c | GetIntentExtras*, GetDeviceRotation, GetConfigurationOrientation, initializeBacktraceClient | generic-fix (Deadpool, Alien RI) | no | ported | no (new rows) |
| kl_aaudio.c/.h | kl_aaudio_output_rate + yield to/guard against OpenSL; kl_audio_src_release on close; no kl_audio_close while OpenSL holds the device | generic-fix (Moss: AAudio+OpenSL) | no | ported | only when AAudio and OpenSL hold the device together. Before, one API reopened the device under the other's feeder (wrong rate or close → silence). One API alone: unchanged |
| kl_aaudio.c | burst 1024 for x5812519008825194 | per-game:x5812519008825194 | no | ported | no |
| kl_aaudio.c | KL_AAUDIO_TRACE | tooling | no | ported, default 0 | no |
| kl_audio.c/.h | kl_audio_src_release; src table reset on reformat | generic-fix | no | ported | yes, clear fix: a closed producer's dead cursor used to stay forever, so a reopened stream fell into the mixing path against it. One live producer behaves as before |
| kl_audio.c/.h | kl_audio_peak accessor | API | no | ported | no |
| kl_opensl.c/.h | silent-player yield (silent_yield) | per-game:Max Mustard | no | ported-gated `KL_SL_SILENT_YIELD`, default 1 only for x5269080709783454 (theirs: 1 for all) | no |
| kl_opensl.c | take_device (silent-paced player with sound takes the device) | per-game:x3240283705987790 (Deadpool) | no | ported-gated: NEW knob `KL_SL_TAKE_DEVICE`, default 1 only for x3240283705987790 (theirs: ungated) | no. Ungated it could let a "near-silent" second player (vampire's UE4 output) take the device before FMOD makes a sound |
| kl_opensl.c | realize joins an AAudio-held device; destroy releases its src and doesn't close under AAudio; kl_opensl_yield_device / kl_opensl_audio_users | generic-fix (Moss) | no | ported | only when both APIs are open (see aaudio row) |
| kl_mediandk.c/.h | Vulkan guest: extractor default off + kl_mediandk_set_video_default | per-game (batman et al.) | no | ported-gated: refusal applies only to targets NOT in this fork's pre-port list (alyx…zix, 20 names in klm_preport_target). `KL_MEDIA_EXTRACTOR` and set_video_default still override | no (VRChat/Bonelab/etc. keep video ON) |
| kl_mediandk.c | AMediaDataSource_* + AMediaExtractor_setDataSourceCustom | generic-fix (batman) | no | ported | no (these were NULL weak imports, so calling them crashed) |
| kl_mediandk.c + kl_vtdec.c/.h | buffer mode (no surface): NV12 linearize, getOutputBuffer/getOutputFormat/info->size; kl_vtdec_want_nv12 | generic-fix (batman) | no | ported | only for codecs configured with no surface. Before, getOutputBuffer returned NULL and the guest crashed or failed with "format 0". Surface path unchanged |
| kl_driver.c | [3 conflicts] GLIBC vs LINUX cases | their-alyx-linux | ours | ours kept; every KL_GUEST_LINUX case, boot/begin_linux and the kl_linuxproc.h include dropped | no |
| kl_driver.c | per-target defaults for "alyx" (KL_OVRP_EYE_MAX 2800, KL_DISPLAY_HZ 60, KL_VK_PASS_BARRIERS 0, KL_VK_WIDEN_AREA 1, MVK_CONFIG_USE_MTLHEAP 0, KL_STALL_MS 250, KL_VK_ASYNC_PIPES 1) | their-alyx-linux | – | **skipped (all removed)** | no |
| kl_driver.c | Max Mustard KL_USLEEP_CAP/KL_GUEST_QOS | per-game:x5269080709783454 | no | ported | no |
| kl_driver.c | kl_mprobe_nexus_frame_budget call (self-gated on target) | per-game:x5812519008825194 | no | ported (kl_mprobe.h already declares it in the worktree) | no |
| kl_driver.c | kl_songs_tick call + include | per-game:beatsaber128/140 | no | ported (gated inside kl_songs) | no |
| kl_songs.c/.h | Beat Saber custom levels, stage 1 | per-game:beatsaber128/140 | no | ported-gated: `KL_SONGS` default 1 only for beatsaber128/beatsaber140, 0 elsewhere incl. our `beatsaber` (theirs: 1 for all) | no |
| kl_guestpatch.c | [1 conflict] their Linux-Alyx patches (player-by-userid, virtualalloc limit, lua arena) | their-alyx-linux | yes (our lua-arena patch, glibc shim drops the VirtualAlloc bound) | skipped, ours kept (file identical to e497979). FYI: alyx-player-by-userid (libclient 0x1460bc8) could be a candidate later if our Alyx hits the first-teleport fault | no |
| kl_guestpatch.c | wrath2 patches | – | already in base | unchanged | no |
| kl_native.c | libc++_shared preload for x6323807174332876 | per-game:Tea For God | no | ported | no |
| kl_ndk.c | empty AAssetDir for a missing dir (x5812519008825194 only); ANativeActivity_setWindowFlags; AAsset_seek | per-game + generic-fix | no | ported | no (new symbols. The empty-dir behaviour is target-gated) |
| kl_ue4.c | Build.VERSION.RELEASE lookup fix ("RELEASE") | generic-fix (Moss) | no | ported-gated: NEW knob `KL_UE4_OS_RELEASE`, default 0 for our pre-port UE4 targets (intotheradius, metro, re4, redmatter2, vampire), 1 otherwise | no. Ungated, it could change the device-profile/RHI choice for our UE4 games |

## Knobs added (new in this fork)
- `KL_SL_TAKE_DEVICE` (kl_opensl.c): default 1 only for x3240283705987790.
- `KL_UE4_OS_RELEASE` (kl_ue4.c): default 0 for intotheradius/metro/re4/redmatter2/vampire, 1 for every other UE4 guest.
Defaults changed from theirs: `KL_SL_SILENT_YIELD` (1 only for x5269080709783454), `KL_SONGS` (1 only for beatsaber128/140), `KL_MEDIA_EXTRACTOR`'s Vulkan default-off (not applied to the 20 pre-port targets).
Ported as theirs: `KL_JNI_DROP_ANALYTICS`=1, `KL_AAUDIO_TRACE`=0.

## Dropped knobs (their DEBUG_ENV_VARS)
`KL_LX_ROOT`, `KL_LX_DYLIBS`, `KL_LX_WAIT` (Linux door). The alyx per-target defaults are gone, but the knobs themselves (KL_VK_*, KL_STALL_MS…) live in other groups' files.
Docs: update DEBUG_ENV_VARS for the new defaults and the two new knobs.

## API dropped/changed
- No exported function dropped or renamed. KL_GUEST_LINUX is no longer referenced in kl_driver.c, so another group may drop the enum value.
- My files rely on these existing symbols: `kl_mprobe_nexus_frame_budget` (kl_mprobe, other group; declared in the worktree), `kl_vulkan_guest_active`, `kl_pthread_boost_qos`.
- **Makefile: add `runtime/guest/kl_songs.c` to RUNTIME_SHIP** (theirs has it there). kl_driver.c calls kl_songs_tick unconditionally, so without it the link fails. If gen_xcodeproj.py lists sources, add it there too.

## Compile check
`xcrun clang -fsyntax-only -arch arm64 -Wall -Wextra -Wno-unused-parameter` with the Makefile include dirs: all 21 .c files in the group pass with 0 errors and 0 warnings. No conflict markers left.

## E-visionos-tooling — inventory

| file | area | category | had equivalent? | decision | changes existing targets? |
|---|---|---|---|---|---|
| visionos/targets.py | rows beatsaber140, beatsaber128, walkabout, batman, wrath2, moss, doom3quest, x7527722310622065 (Cave Crave) | per-game | no | ported verbatim (+hand_matting False on Cave Crave) | no (new names) |
| targets.py | their beatsaber `hand_matting: False` | per-game:beatsaber | yes (KLGameSettings) | skipped (ours wins) | — |
| targets.py | their Linux `alyx` row, `lx_libs()` | their-alyx-linux | yes (our glibc alyx) | skipped; our alyx + hub rows, hub_games, glibc_libs_for kept; hub games unchanged | no |
| targets.py | `KLEPTON_GENERIC_TARGET` (_generic_row/_add_generic), STORE_DEFAULTS (AC Nexus video) | tooling | no | ported; generic row also sets hand_matting False | no (only when env set) |
| targets.py | per-row fields + setdefaults | tooling | no | ported with NEUTRAL defaults: hand_matting True, foveation True (= KL_VRR default 1), render_scale 1.0, video False, autoboot True, gamepad_map "", generic False, obb_file/meta ids "" (informational), data_panel computed; applied before the hub early-return | no |
| targets.py | explicit rows for Alien / Deadpool / AC Nexus / Eye of the Temple | per-game | — | NOT added: recipes give package + obb dir but not engine/entry (UE4 libUE4 vs UE5 libUnreal undeterminable for Alien/Deadpool); rely on generic mechanism (reads engine off the unpacked APK). Not in hub games. | no |
| runtime/kl_target_table.h | regenerated from targets.py | tooling | — | regenerated (+8 rows) | no |
| Makefile | LX_SRC, kl_linuxproc, t_lx/lx, m_linux, lx-rt, lx-boot | their-alyx-linux | — | skipped | no |
| Makefile | kl_mtl_foveate.m, kl_stall.c, kl_songs.c in RUNTIME_SHIP; `-framework Metal` (LDLIBS + both libklepton.dylib links) | — | — | REMOVED for now (orchestrator re-adds with the files; Metal is only needed for kl_mtl_foveate.m). CoreAudio already ours | no |
| Makefile | t_casp/casp target | tooling | yes (our t_x18_casp) | ported with note: keep only if tests/t_casp.c survives | no |
| Makefile | ANGLE_GN_EXTRA detection, use_custom_libcxx=false, treat_warnings_as_errors=false, use_thin_archive=false, angle-debug depot_tools update | tooling | yes (21a310a use_lld=false hard-coded) | skipped (ours) | no |
| visionos/run.sh | KLT_KIND=linux paths, KL_LX_* FORWARD_SKIP | their-alyx-linux | — | skipped | no |
| run.sh | c-table regen per build (generic targets), team device-registration retry, install retry, NSAccessoryTrackingUsageDescription check, KL_SKIP_LAUNCH, KLEPTON_SIM_UDID | tooling | partly (KL_BUILD_ONLY, sim generic dest kept) | ported; retries use our `$CONFIG` instead of their hard-coded Debug | no |
| stage_assets.sh / mkguest.sh | Linux branches (stage_sync.py, mklxguest.py) | their-alyx-linux | — | skipped (files now == ours). obb_raw/stage_files already in base | no |
| gen_xcodeproj.py | SWIFT list (KleptonGameData/Alyx/Text) | UX / their-alyx | yes (hub) | skipped | no |
| gen_xcodeproj.py | KL_HAND_MATTING/GAMEPAD_MAP/RENDER_SCALE/VIDEO/AUTOBOOT/FOVEATION_DEFAULT build settings | tooling | no | ported (hub bakes hub row's neutral values) | no |
| gen_xcodeproj.py | KL_START_SCREEN, KL_DATA_*, StartHero imageset, KLMeta datasets | UX (their start screen / data panel) | yes (hub) | skipped | no |
| gen_xcodeproj.py | usage strings as INFOPLIST_KEY_*, KLEPTON_APP_VERSION/BUILD | generic-fix / tooling | no | ported | no (same strings; version 1.0/1 unless env) |
| visionos/Info.plist | their rewrite (drops all comments) | — | — | kept ours (with comments) + added KLGamepadMap, KLHandMattingDefault, KLRenderScaleDefault, KLVideoDefault, KLAutoBootDefault, KLFoveationDefault; no KLStartScreen/KLMeta*/KLObb*/KLTree | no |
| KleptonApp.swift | start screen (productStart), PlayerSettingsView, KLRun, GameDataView/needsData, AlyxPanel/klAlyxApply/klIsAlyx, klT strings | UX / their-alyx-linux | yes (hub, Steam gate, fozLine) | skipped (ours kept in all 5 conflicts) | no |
| KleptonApp.swift | `targetAutoBoot` (KLAutoBootDefault) for KL_AUTOBOOT default + Boot/Start label; "Rendering" panel; KleptonRendering.apply() before kl_app_boot; openImmersiveSpace retry x3 on .error | tooling / generic-fix | no | ported (alyx exceptions removed) | no (autoboot default True; retry only after an .error) |
| KleptonApp.swift | `klAvpPlayTarget()` helper (new, ours) | tooling | — | added: gates avp-play behaviour changes to their targets | — |
| KleptonTuning.swift | KleptonRendering + RenderingView (foveation / render scale / video prefs) | generic | no | ported; targetFoveation treats missing key as ON (their `== "1"` would have turned VRR off) | no (all defaults = runtime defaults; prefs per app, shared by hub games) |
| KleptonChroma.swift | their app-wide handMatting + default-migration blob, alyx force-hidden | UX | yes (per-game KLGameSettings) | skipped; ours kept. Added `targetHandMatting` (KLHandMattingDefault) into single-game `defaultMatting` (`target != "alyx" && targetHandMatting`) | no (missing/True for existing rows) |
| KleptonCompositor.swift | KL_OVERLAY_SUBMIT_ORDER (overlayOrderState) | per-game:x24882487241367228,x5812519008825194 | no | ported, applied after our overSceneDepthState line | no |
| KleptonCompositor.swift | composite GPU queued/ran timing in cadence line | diag | partly (Glovebox Metal GPU time is guest-side) | ported | log only |
| KleptonCompositor.swift | rate-map valley fill `filled()` | generic | no | ported-gated KL_VRR_FILL (default on only for avp-play targets) | no |
| KleptonCompositor.swift | rate map with N layers (kl_glfb_rate_map_layers) | generic-fix (multiview mirrored guests) | no | ported | no (1 layer unless the guest is layered) |
| KleptonCompositor.swift | projection layers: per-layer grid (kl_proj_layer_grid, rect) + foveated-mirrored unwarp (kl_glfb_eye_rate_map, grid_eye=0) | generic-fix | no | ported (identity for full rect; foveated path only when the eye rate map matches the layer size) | no |
| KleptonCompositor.swift | loading card (kl_interstitial) + UIKit/CoreText imports, removal of `if n == 0` early return | their-alyx-linux | — | skipped; early return restored | no |
| KleptonCompositor.swift | equirect `ov.eq_hscale` | generic-fix | no | ported (needs kl_ovrp.h field from ovrp agent) | no (0 → old default) |
| KleptonControllers.swift | Steam Link: predict 0 ms, velocity noise gate | per-game:steamlink-vr | no | ported | Steam Link only (its own target) |
| KleptonControllers.swift | plain gamepad merged with hands (FaceMap, KL_GAMEPAD, KL_GAMEPAD_PINCH, KL_GAMEPAD_MAP) | input | no | ported (only acts with a non-spatial gamepad connected; previously ignored) | additive only |
| KleptonControllers.swift | thumbstick touch bit | generic-fix | no | ported-gated KL_SENSE_STICK_TOUCH (default 1, 0 for alyx) | yes for Sense users of non-alyx targets: missing capacitive bit was a bug |
| KleptonControllers.swift | right Options pill also Start | generic-fix | no | ported-gated KL_SENSE_RIGHT_START (default 1, 0 for alyx) | yes for non-alyx: the right pill did nothing in OVRPlugin guests (bug) |
| KleptonControllers.swift | pumpHaptics off the render thread (drop while busy) | generic-fix | no | ported | fix: CoreHaptics sync XPC could stall renderFrame → SIGKILL |
| KleptonControllers.swift | suppress hand tracking when other hand has a controller | input | no | ported-gated KL_HANDS_WITH_CONTROLLER (default 1 = old behaviour; 0 only for avp-play targets) | no |
| KleptonControllers.swift | hand standing in for a controller's dropped pose no longer pinches | generic-fix | no | ported | fix: spurious trigger clicks / lost real ones |
| visionos/Sources/kl_app.c | KL_GUEST_LINUX (target_is_linux, lx env.txt, folder_fed, KL_DYLIB_DIR, status strings, OpenXR pacer) | their-alyx-linux | yes (KL_GUEST_GLIBC) | skipped | no |
| kl_app.c | KL_GUEST_FRESH_POSE (published_ns, guest_now_ns) | per-game:x5812519008825194 | no | ported (beside our Glovebox pacer) | no |
| Klepton-Bridging-Header.h | `kl_mediandk_set_video_default` decl | tooling | — | ported (both kept) | no |
| .gitignore | AppIcon-*/StartHero-* ignores | tooling | — | ported (both kept) | no |
| DEBUG_ENV_VARS.md | 2 conflicts | docs | — | block0 both (KL_GUEST_FRESH_POSE, KL_NEXUS_FRAME_BUDGET*, KL_FS_REL_SDCARD docs); block1 ours + KL_OVERLAY_SUBMIT_ORDER (their KL_FULL text dropped); added a section for this group's knobs | — |
| BUILDING.md | visionOS 27 / Beat Saber 1.40 notes | docs | — | ported, reformatted | — |
| tools/walkabout_stub_bundles.py, batman-required-bundles.txt | tooling for walkabout/batman | tooling | — | kept, attribution header | — |
| KleptonGameData.swift, KleptonText.swift, KleptonAlyx.swift | in-app Meta download panel (web sign-in), DE/EN strings, Linux Alyx panel | UX / their-alyx-linux | yes (KleptonHub/HubPrep/SteamDepot) | SKIPPED; nothing kept depends on them (klT, KLGameFiles, GameDataView, AlyxPanel, klIsAlyx all removed) | — |

## Knobs added (ours, gating their behaviour)
- `KL_VRR_FILL` — default 1 for avp-play targets (klAvpPlayTarget), else 0.
- `KL_HANDS_WITH_CONTROLLER` — theirs, but default inverted: 1 (old) everywhere, 0 for avp-play targets.
- `KL_SENSE_STICK_TOUCH` — default 1, 0 for `alyx`.
- `KL_SENSE_RIGHT_START` — default 1, 0 for `alyx`.
- Kept theirs: KL_OVERLAY_SUBMIT_ORDER (Alien, AC Nexus), KL_GUEST_FRESH_POSE (AC Nexus), KL_GAMEPAD, KL_GAMEPAD_PINCH, KL_GAMEPAD_MAP, KL_SENSE_VEL_GATE(_ANG) (Steam Link), KL_SENSE_PREDICT_MS default 0 for Steam Link; KLEPTON_GENERIC_TARGET/DISPLAY, KLEPTON_APP_VERSION/BUILD, KL_SKIP_LAUNCH, KLEPTON_SIM_UDID.

## Knobs from their docs dropped (my group)
KL_LOADING_CARD, KL_START_SETTINGS, KLEPTON_START_SCREEN, KL_LX_PHASE/SYSROOT/GAME/XRIZER/MIRROR, their alyx `KL_HAND_MATTING` force-hide. DEBUG_ENV_VARS.md: orchestrator to prune other groups' dropped knobs.

## Exported API / cross-agent dependencies
- Dropped nothing exported. Swift now calls (must survive in other groups): `kl_glfb_set_foveation_default`, `kl_glfb_rate_map_layers`, `kl_glfb_eye_rate_map` (gfx), `kl_proj_layer_grid`, `KL_PROJ_LAYER_GRID_ENTRIES`, `grid_eye` set by `kl_proj_layer_build` (reproject), `kl_ovrp_set_render_scale_default`, `kl_ovrp_overlay.eq_hscale`, `kl_ovrp_set_hand_motion` (ovrp), `kl_mediandk_set_video_default` (media). Their compositor's `kl_interstitial_get`/`kl_interstitial` is NOT used (declared in merged kl_ovrp.h, defined only in runtime/linux — ovrp agent should drop the decl).
- Makefile: kl_mtl_foveate.m / kl_stall.c / kl_songs.c / `-framework Metal` removed pending decisions; t_casp target kept conditional on tests/t_casp.c.

## Checks
- No conflict markers in group files.
- `targets.py --list`, `targets.py hub`, `--c-table` OK; table regenerated; `KLEPTON_GENERIC_TARGET=x5812519008825194` resolves (kind from APK, video True).
- `xcrun swiftc -parse` on the 5 changed Swift files: OK. Full `swiftc -typecheck` (xros SDK, bridging header, 12 non-hub sources against the current worktree headers): 0 errors.
- kl_app.c `clang -fsyntax-only` (-DKL_TARGET_DEFAULT): clean. bash -n run.sh/stage_assets.sh/mkguest.sh OK; gen_xcodeproj.py py_compile OK; Info.plist plutil OK.
