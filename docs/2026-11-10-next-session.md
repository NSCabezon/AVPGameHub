# Next session: resume here (written 2026-11-10)

The 2026-10-28 notes (`2026-10-28-next-session.md`) still apply for anything not covered here.

## What changed today

### Disk (55 GB → 30 GB)
- Deleted `klepton/visionos/build`, `klepton/build`, Xcode DerivedData, a duplicate MoltenVK tar
  and **all of `klepton/vendor/`** (ANGLE checkout, ~20 GB). `make angle-all` brings ANGLE back.
- `visionos/mkangle.sh` now keeps the staged `visionos/Frameworks/ANGLE_*.xcframework` when
  `vendor/out` is absent (the hub build used to fail without `vendor/`).
- Kept on purpose: `local/game/metro` (18 GB, Metro perf work), APKs and extracted game dirs.

### ANGLE
- `vendor/` had drifted *behind* `angle-patches/klepton.patch` (12 of 27 files missing, among them
  the shader-side OVR_multiview). Reset `vendor/` to the pin, applied the tracked patch, rebuilt
  `xros` + `xrsim`. Every TestFlight build before 20261110.1118 shipped an ANGLE without the
  shader multiview. **Never run `make angle-save` from a stale `vendor/`**: it overwrites the
  good patch.

### SenseKit
- Submodule bumped to `bd2c577` (macOS support, aim ray, shake detector, ghost no-blink).

### TestFlight
- **0.1.0 (20261110.1118)** uploaded: full ANGLE patch + new SenseKit. Not yet run on the headset.

### Metro Awakening
- **Shader cache.** The headset had no Fossilize cache: 720 compile stalls (188 s) in one session.
  Copied `local/metro/foz/metro-mac.foz` to the headset as `games/metro/klfz/metro.foz`; with it
  the next launch prewarmed 1660 pipelines in 0.9 s, 0 stalls, load 53 s → 4 s, average fps
  62.7 → 89.0. **Product follow-up:** ship or download a base `.foz` per game so a fresh install
  does not pay this.
- **Black meshes fixed** (`KL_VK_SUBPASS_EARLY_Z`, default on). Hands, NPCs, chess pieces, a book,
  a large mesh rendered pure black. Cause: in UE's base pass the depth attachment is also an input
  attachment, so MoltenVK has SPIRV-Cross append `gl_FragDepth = gl_FragCoord.z` to every
  subpass-reading fragment shader. That depth is not bit-identical to the prepass, so the
  depth-EQUAL test rejects those draws. Klepton now gives those shaders `EarlyFragmentTests`
  (discarding ones get a twin, swapped in only for pipelines with no depth/stencil writes), which
  makes SPIRV-Cross skip the write. Verified on the Mac viewer (no magenta with
  `KL_VK_SCENE_TINT=1`, hair included). **Not yet seen on the headset.** Worth reporting upstream
  to MoltenVK (it injects the write even when the pipeline has depth writes off).
- **Diagnostic knobs** added while hunting it, all off by default and documented in
  `DEBUG_ENV_VARS.md`: `KL_VK_SCENE_TINT`, `KL_VK_DEPTH_EQ_RELAX`, `KL_VK_DRAW_TRACE(_AT)`,
  `KL_VK_FS_STATS`, `KL_MVK_NO_ARGBUF`.
- **Async frame publisher** (`KL_VK_ASYNC_PUBLISH=1`, default off, OpenXR Vulkan path only).
  Replaces the frame-end `vkQueueWaitIdle` with a fence + publisher thread. Mac main menu: period
  6.9 → 4.5 ms, GPU-idle bubble 0.95 → 0.02 ms. Headset baseline (D0b, with the cache): 74.6 fps
  avg, bubble 3.5–4 ms with GPU 8–12.5 ms, i.e. the bubble is what pushes frames past 11.1 ms.
  **Not yet run on the headset.** Risk to watch: torn or stale eye images (one less frame of
  margin before a swapchain image is reused).

## Next, in order

1. Install a dev build on the headset (`./build_run_vpro.sh hub --build-only`, then
   `xcrun devicectl device install app …`) and check Metro's tutorial room: no black meshes, hair
   OK, no flicker.
2. Headset A/B from the audit (`private/docs/2026-10-12-metro-perf-audit.md` §7), launched from the
   Mac with `KL_LOG_FILE=0` so the log streams. Done: D0 (no cache), D0b (cache). Pending:
   **D10 = `KL_VK_ASYNC_PUBLISH=1`**, then D1–D8. Keep the headset on between runs: a sleeping
   headset drops the devicectl connection.
3. If D10 holds 90 fps without tearing, make it the default.
4. Small fix: `build_run_viewer.sh` forces `KL_GLFB=1`, which shows a black window for Vulkan
   games (Metro, RE4). Launch `m_boot` directly without it until fixed.
5. Upstream (`upstream-contribution`): the early-Z fix and the async publisher are candidate PRs.
