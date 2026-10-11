# Foveated rendering — design (2026-10-06)

## How Alyx does it (Steam Frame ARM64 port)
- **VK_EXT_fragment_density_map (FDM)**, plus VK_EXT_fragment_density_map_offset (QCOM offset) for eye tracking.
  The game builds the density map on the CPU; the driver only has to honour it.
- `librendersystemvulkan.so`: `-vulkan_disable_ext_fragment_density_map`, "BindRenderTargets (bFDM)",
  `TSPEC_FRAGMENT_DENSITY_MAP`/`TSPEC_SUBSAMPLED`, `r_subsampled_sampler_desc`, `unsubsample.vfx_ps`,
  convars `vr_fdm_offset`, `vr_fdm_offset_debug`, `vr_fdm_offset_flip_y`.
- `librenderingpipelines.so`: `vr_fdm`, `fove_level`, `fove_square*`, `fove_radial_inner/_outer/_min/_outer_only`,
  `fove_dump`, `vr_render_subsampled`, `vr_render_subsampled_depth`, textures `foveated_fdm_texture_%d_%d_%d`.
- `libvr.so`: older stencil path (`vr_foveated_*`, modes 0=Off 1=VerticalSplit 2=Checker 3=FixedFoveated2x).
- Turn-on: advertise FDM + `fragmentDensityMap` (+ `fragmentDensityMapNonSubsampledImages`), then `vr_fdm 1`, `fove_level`.
- MoltenVK 1.4.2 advertises neither FDM nor fragment shading rate. visionOS exposes no gaze → fixed foveation.

## Plan
1. **Discovery spoof** in `kl_vulkan.c` (`KL_FDM_SPOOF`): advertise FDM, strip it before MoltenVK
   (ext name, `VkRenderPassFragmentDensityMapCreateInfoEXT`, usage 0x200, SUBSAMPLED flags, extra attachment).
   Legal (map may be ignored) → trace which passes/images use FDM. ~½ day.
2. **MoltenVK fork** (v1.4.2 source): density-map passes → `MTLRasterizationRateMap` from a `KL_FOVEATE_LEVEL`
   profile (centre ~40% full rate, then ½, ¼; separable per axis). Render to physical-size shadow targets, then
   an unwarp pass into the real attachments (fuse with MSAA resolve). ~3–5 days.
3. Optional: subsampled mode (`vr_render_subsampled 1`) via SPIRV-Cross `rasterization_rate_map_decoder` rewrite. ~1 week.

Expected: 33–52% of fragments shaded (Beat Saber rate-map data); unwarp ~2–3 ms/frame on M2 at 4608x2880/eye;
device is GPU-bound at ~50 ms/frame → net gain likely. Estimate, not measured.

Risks: Mac is CPU-bound (force high res or GPU timers to measure); game may gate FDM by GPU vendor/perf level;
unwarp bandwidth. Worktree: `vendor/Klepton-fov` (branch `alyx-foveation`, no code yet).
