# Half-Life: Alyx on Vision Pro: performance audit (2026-10-07)

Scope: what Klepton (our runtime, our MoltenVK use, our compositor) does wastefully, beyond "the M2 GPU is slow".
Sources: the device logs from today (`boot3`, `swim0-boot`, `rt06`, `boot`) and Mac runs of `m_boot alyx` on an
**M1 Max** (32-core GPU, 400 GB/s), with `sample`, `vmmap` and `xctrace` (Metal System Trace).

**Every number below is labelled.** *Measured* means read from a log, a trace or the source. *Estimate* means
arithmetic on measured inputs. *Hypothesis* means not measured. Nothing was run on the headset. The Mac is a
different machine: it is **CPU-bound** for Alyx (GPU 18–28 % busy), so Mac GPU deltas do not transfer to the M2.
The device has to answer the GPU questions (see the plan at the end).

Caveats about the Mac runs:
- Several Mac runs died 2–4 min in with the same fault: `signal 11 at 0x18, pc libvr.so+0xb53bc`, right after
  `IVRRenderModels_006::GetComponentCount / LoadRenderModel_Async: not implemented`. It looks like a render-model
  path in the current working tree, which includes other agents' uncommitted `kl_openvr.c`. It limits how long a
  Mac measurement can run. This is not perf work, but someone should look at it.
- A visionOS Simulator (SimMetalHost) was using ~7 % of the GPU during the first trace. Another agent's
  `m_boot_sk*` sessions overlapped my first sampling. My later runs were alone.
- Mac GPU-per-frame figures from Metal System Trace varied by ±30 % between runs at the same settings, depending
  on scene and load phase. I do not use them for small deltas.

---

## Ranked findings

| # | Issue | Ours or inherent | Evidence | Expected gain | Effort |
|---|---|---|---|---|---|
| 1 | MoltenVK turns Alyx's 4-segment dynamic-rendering scene pass into 4 Metal render encoders, **storing and reloading every 4x MSAA attachment (colour + D32S8) at each of 3 boundaries**. Vulkan asked for CLEAR / DONT_CARE + resolve, so on a tiler none of it ever needs memory. | Ours (MoltenVK translation) | Measured (Mac) + source | Hypothesis: large on M2 (bandwidth-bound). Estimate below: up to ~4 GB/frame uncompressed at L5. | Medium-high (MoltenVK fork patch) |
| 2 | 4x MSAA on fidelity levels 1–8 (the `deckard` CSV), backed by real DEVICE_LOCAL memory, not memoryless | Ours to override | Measured (CSV, Mac RT census) | Hypothesis: proportional to #1; 2x halves the bytes. Cheap to A/B on device. | Trivial (convar / override CSV) |
| 3 | Shaded pixels nobody sees: Alyx symmetrises the frustum (21 % of columns past the declared edge), plus the 0.12 overscan. At rest only ~63 % of rendered pixels fall on the display. The hidden-area mesh we return masks nothing. | Ours | Measured (log tangents) | Estimate: per-eye hidden-area mesh over the symmetric excess saves ~21 % of pixel shading. | Small |
| 4 | Submit blocks the render thread until the GPU finishes the frame (per-eye `WaitForFences` + `vkQueueWaitIdle`), so CPU frame N+1 and GPU frame N never overlap | Ours | Measured (source, Mac sample + seam counters) | Mac: GPU-idle bubble of 1.5–1.8 ms per 8.6–9.8 ms frame (~17 %). Device: unmeasured; matters most near the 11 ms target. | Medium |
| 5 | We render more pixels than we keep: the stage image is a fixed 3072x2465 and the eye copy **downscales** Alyx's 3840x2400 (L5) or 4128x2592 (L6) into it | Ours | Measured (logs + code) | Estimate: 20–26 % of horizontal rendered resolution discarded. Either stop paying for it or stop throwing it away. | Small-medium |
| 6 | Compositor drawable at render quality 1.0 (device default 0.435): 2× 2496x2432 physical + depth stored, at 90 Hz | Ours | Measured (log) | Unmeasured (likely a few % of GPU) | Trivial A/B (`KL_CP_QUALITY`) |
| 7 | Synchronous MoltenVK encode on the render thread (`MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS` default, no prefill) | Ours (config) | Measured (Mac) | Mac: 1.0–1.4 ms/frame of render-thread time | Trivial to A/B; safety unknown |
| 8 | Klepton Vulkan layer per-call overhead: `klvk_img_reg_ok`, a linear scan of up to 16384 images under one global mutex, on every image barrier, blit and copy | Ours | Measured (Mac sample) | Small (~1 % of render-thread samples on the Mac) | Small |
| 9 | Slow footprint growth after the resolution switch, ~17 MB/min | Unknown | Measured (device `[hb]`) | Not a perf cause today; jetsam risk in long sessions | Investigate |
| 10 | Debug-xros app build: Swift compositor at `-Onone`, app C at `-O0`; libklepton `-O1` | Ours | Measured (gen_xcodeproj.py, Makefile) | CPU only (compositor thread); unmeasured | Trivial |

Not problems:
- **The 39→14 fps "decay" is not thermal and not a leak.** See A.
- Translation overhead looks small. See F.

---

## A. The fps "decay" in `boot3` is a resolution switch (measured)

In every device log, the drop starts at the same game event, `[ForceNativeRes Hack] Client menu hands state: Visible`:

| log | before | event line | after |
|---|---|---|---|
| boot3 | 38.7 / 39.3 fps | 8104 | 25.9 → 19.3 → ~15 fps |
| swim0-boot | 48.5 / 47.7 | 8228 | 35.5 → 23.6 → 19–22 |
| rt06 (RT_SCALE 0.6) | 53.4 / 54.2 | 8138 | 51.5 → 39.3 → 36.7 |
| boot | 35.5 | 8358 | 15.9 |

- While the menu hands are invisible, Alyx renders at "native" resolution (`vr_force_native_resolution_for_invisible_hands`).
- When they appear, it switches to the fidelity-level target. In `boot3` the footprint jumps by the same step: `foot=4470M` (13:06:34) → `4926M` (13:06:36), +456 MB, which is the size of new MSAA targets.
- **No thermal data exists in these logs**, so thermal throttling is not excluded. I added a thermal field to `[hb]` (see Instrumentation).
- The later wander in `boot3` (19 → 14 → 17 fps) is not monotonic. Scene content or auto-fidelity level changes are the likely causes; both are unmeasured (see the plan).

Footprint after the switch, `boot3`: 4935 MB (13:06:58) → 5098 MB (13:16:08). That is a steady ~17 MB/min.
Source unknown: game streaming, MoltenVK, or ours (per-frame Swift strings, logs). *Unmeasured.*

## B. Render targets and the MoltenVK mapping (measured on the Mac, by source reading)

The RT census (new `[perf] RT` and `[perf] vkAllocateMemory` lines), Mac, L5:

```
RT 2688x2880 fmt 130 (D32_SFLOAT_S8) samples 4 layers 2 usage 0xa7 -> vkAllocateMemory 303.3 MB type 0 flags 0x1
RT 2688x2880 fmt 122 (B10G11R11)     samples 4 layers 2 usage 0x97 -> vkAllocateMemory 240.2 MB type 0 flags 0x1
```

- Memory type 0 has flags `0x1`, DEVICE_LOCAL only, **not LAZILY_ALLOCATED**. MoltenVK therefore backs these with real memory, not memoryless tile storage: 543 MB at the Mac's maximum size.
- At the device's maximum (4608x2880 per layer, swim0) the same pair would be ~955 MB. *Estimate.* That is consistent with the +456/+684 MB footprint steps.

The scene-pass census (new `KL_PERF_PASS_LOG`), Mac, one frame, in recording order:

```
pass flags 0x2 area 2208x2400 viewMask 0x3 | C0 CLEAR/DONTCARE +resolve | D CLEAR/DONTCARE +resolve | S CLEAR/DONTCARE +resolve
pass flags 0x6 ...same...
pass flags 0x6 ...same...
pass flags 0x4 ...same...
```

Flag values: 0x2 = SUSPENDING, 0x4 = RESUMING. Other small passes are interleaved between the segments in recording order. So the segments come from different VkCommandBuffers recorded on different threads.

How MoltenVK 1.4.2 handles this (source, `MVKRenderPass.mm` `getMTLStoreAction` / `populateMTLRenderPassAttachmentDescriptor`, `MVKCommandBuffer.mm` `endRenderpass`):
- A SUSPENDING segment ends with `MTLStoreActionStore` on every attachment. It does not resolve.
- A RESUMING segment begins with `MTLLoadActionLoad`.
- Each segment calls `encodeStoreActions(); endMetalRenderEncoding();`, so it is its own Metal render encoder.
- **Result: 3 boundaries × (store + load) of the 4x colour and the D32S8.** The Vulkan intent was to keep all of it on-tile and only resolve at the end.
- There is also a "Metal renderpass restart" encoder every frame: MoltenVK split a pass mid-way, which means another store/load. On the Mac it cost 0.22–0.28 ms/frame of GPU. *Measured.*

Bandwidth estimate for the device at L5 (3840x2400, 2 views, 4x). *Estimate; Apple lossless render-target compression is unknown and will lower it.*
- 73.7 M samples × (4 B colour + 4 B depth + 1 B stencil) = **~0.66 GB per full store**.
- Store + load per boundary × 3 boundaries = **~4 GB/frame** uncompressed.
- The M2 has ~100 GB/s. Uncompressed, that alone would exceed the measured ~45–50 ms frame, so compression clearly applies.
- Even 25–50 % of it would be one of the largest single costs in the frame. This is the best candidate for "same pixels, slower than the Steam Frame".

Mac A/B attempts. *Inconclusive; I do not draw conclusions from them.*
- Fixed level 1 (4x, 0.78) against level 0 (2x, 0.78) gave 5.01 against 4.45 GPU ms/frame. A level-5 repeat gave 4.39 (another earlier run gave 6.08). That noise is as large as the effect.
- A strip-the-suspend-flags A/B (`KL_PERF_NO_SUSPEND_AB`, below) showed no clear square wave on the M1 Max, and that run degraded and crashed (the libvr fault).
- Reading: on a 400 GB/s GPU the round trips are not dominant. Whether they dominate on the 100 GB/s M2 is the first device measurement.

## C. Pixels rendered against pixels shown (measured inputs, arithmetic estimate)

Device, overscan 0.12 (current default):
- We offer l = 1.94, r = 1.12. Alyx renders l = r = 1.94, u = 1.12, d = 1.335 (`rendered with tangents` lines).
- Display tangents: 1.732 / 1.0 / 1.0 / 1.19.
- Visible fraction at rest = (2.73 × 2.19) / (3.88 × 2.455) = **63 %**. 21 % of the columns are the symmetric nasal excess; the rest is overscan margin.

The deckard CSV levels are 0.78–1.2 of the recommended size. With the recommended size 3072x2465 (the RT_SCALE 1 default):
- L5 is 3840x2400 and L6 4128x2592 per eye.
- `vk_copy_eye` **blits (linear downscale)** that into a fixed 3072x2465 stage, so 20–26 % of horizontal detail rendered is discarded.

`swim0-boot`'s first frames sat at L6: `bounds u 0..0.896` of 4608 = 4128. What auto-fidelity picks after that is unmeasured.

## D. CPU/GPU serialisation at Submit (measured on the Mac)

Code facts:
- `vk_copy_eye`: `QueueSubmit` then `WaitForFences` immediately, per eye. The eye-0 wait covers the game's whole frame of GPU work.
- `kl_vulkan_frame_done`: `vkQueueWaitIdle` (`KL_VK_FRAME_SYNC`, default on).
- `WaitGetPoses` never waits, so pacing comes only from these waits.

Mac `sample`, 8 s, another agent's session at ~73 fps: the render thread spent 21 % of samples in `vkWaitForFences` under `co_submit_impl` and 8 % in `vkQueueSubmit` (MoltenVK encode).

Mac seam counters (new `[perf] frame seam` line, run s1, level 5, steady state), per frame:
- period 9.83 ms, GPU-idle bubble (frame end → next frame's first big submit committed) **1.78 ms**, encode 1.16 ms in 9 submits.
- period 8.60 ms, bubble **1.47 ms**, encode 1.04 ms.
- So ~17 % of the frame period the game's queue is empty while the CPU builds the next frame. That idle is structural: we waited for the GPU before returning from Submit.
- On the Mac it is masked by the CPU limit. On device at RT_SCALE 0.6 (19 ms frames) or at a 90 Hz target it is directly lost GPU time. *Device value unmeasured; the same counter will print it there.*
- The "render thread blocked … last big submit → frame end" field (7–8 ms on the Mac) includes the render thread's own CPU work after its last large submit. Read it as an upper bound on the Submit wait, not as the wait itself.

Mac Metal System Trace, external session, one frame:
- Command buffers are committed at 0.57, 1.91 and 2.29 ms; the GPU runs from 2.37 ms to ~11.7 ms.
- The eye copies are committed at 12.25 and 14.2 ms; `vkQueueWaitIdle` at 14.05.
- The next frame's main command buffer (43 encoders, 1.1 ms of encode) is committed at 18.56 ms.
- GPU busy over the whole trace: 23 %.

## E. Is the device GPU-bound? Scale arithmetic (estimate)

- Mac L5 (2208x2400 ×2, 4x) GPU ≈ 4.4–6.1 ms/frame on an M1 Max. The M2 is ~3.2× less shader throughput and 4× less bandwidth.
- Device L5 has 1.74× the pixels: ×3.2–4 ×1.74 ≈ 25–40 ms. That is consistent with the measured ~45–50 ms device frame being GPU-dominated at RT_SCALE 1.
- At 0.6 (19 ms) the device may be near the CPU floor. The Mac's CPU frame is 8.6–13 ms on faster, cooler cores. **Unmeasured on device**; the seam line and `KL_MVK_GPU_TIME` answer it.

## F. CPU and translation (measured on the Mac, partial)

- Guest frames are unsymbolised (no load-base lines in these logs). Library attribution was done with `vmmap`.
- Main thread (`hlvr-main`) ~53 % busy.
- Klepton shims (`klb_*`) are almost all blocking waits (cond, epoll, kevent).
- Small hot spots:
  - `klb_dlsym` / `klb_dlopen` called at runtime from the main thread: ~23 samples per 1644.
  - `klb_clock_gettime`: 73 samples.
  - `klvk_img_reg_ok`: 154 inclusive samples, global mutex.
- No x18 or veneer cost showed up in samples.
- Conclusion: translation overhead is small next to the game's own CPU work and MoltenVK's encode. The Mac's ~70 fps limit, and its drop when the City 17 vista comes into view (user report), point to scene CPU work (draw calls, culling) plus the serialisation in D. That is a *hypothesis* until guest frames are symbolised.
- MoltenVK encode is synchronous on the render thread: 1.0–1.4 ms/frame on the Mac; one 43-encoder command buffer per frame.
- Prefill A/B (`MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1`, run s2): in 9 min (15:48–15:57) it never reached the first eye submission, while a normal boot takes ~2–3 min. It is unknown whether prefill hangs Alyx's boot or that run was just slow. **Unmeasured. Do not use it on device until a Mac run boots with it.**

## G. Configuration review (measured, static)

- **MoltenVK:**
  - Stock prebuilt v1.4.2 (Release).
  - Klepton sets `MVK_CONFIG_LOG_LEVEL=1` and `SHOULD_MAXIMIZE_CONCURRENT_COMPILATION=1`.
  - The argument-buffer and compile-timeout knobs are gated to wanderer and wrath2, so off for Alyx.
  - No validation or debug layer is enabled. Synchronous submits and no prefill are the MoltenVK defaults.
- **Builds:**
  - `run.sh` always builds `-configuration Debug`: `GCC_OPTIMIZATION_LEVEL=0`, `SWIFT_OPTIMIZATION_LEVEL=-Onone` for the app target (KleptonCompositor.swift, kl_app.c).
  - libklepton is built by the Makefile at `-O1` (Mac and xros). Guest code is the original ARM64 machine code.
  - No Metal API or shader validation is set in code. `devicectl` launches do not apply scheme diagnostics.
- **Compositor** (KleptonCompositor.swift, read-only):
  - One amplified render pass per display frame and one grid draw.
  - Colour and depth stored (depth is needed by visionOS reprojection).
  - bgra8 sRGB drawable, foveation on, `maxRenderQuality = 1.0` (device default 0.435).
  - Eye images are sampled once per display frame. The stage images are RGBA8 sRGB (fmt 43), not 16F.
  - Per-frame Swift allocations: `uniforms` and `sources` arrays, and a `String(format:)` of the eye placement every frame (CPU only, at `-Onone`).
- **Frame timing:**
  - `GetFrameTiming` reports WaitGetPoses→Submit as both `PreSubmitGpuMs` and `TotalRenderGpuMs`. That over-reports GPU time when the frame is CPU-bound, which pushes auto-fidelity down.
  - `SetExplicitTimingMode` / `SubmitExplicitTimingData` are generic stubs. Alyx logs that it sets explicit timing mode.
  - Which levels auto-fidelity actually holds on device is **unmeasured**.
- **Eye copy GPU cost:** Mac median 0.080 ms per eye (351 single-blit command buffers). Device unmeasured; estimate ~0.5 ms per eye.
- **Game blits:** ~27 `vkCmdBlitImage` per frame (mip chains), each its own render encoder in MoltenVK: 0.4–1.0 ms/frame GPU on the Mac.

---

## Fix list, in order

1. **Merge suspended→resumed dynamic-rendering segments into one Metal render encoder** (MoltenVK fork; `vendor/Klepton-fdm` already builds MoltenVK from source).
   - When a command buffer in one submission ends SUSPENDING and the next begins RESUMING, keep the MTLRenderCommandEncoder open instead of `encodeStoreActions` + `endMetalRenderEncoding` / `Load`. Mark all state dirty for the new MVKCommandEncoder.
   - Afterwards the MSAA attachments could be memoryless: ~0.5–1 GB of footprint back.
   - Gain unmeasured; it is the prime suspect for the Steam Frame gap. Effort 2–4 days.
2. **Measure, then likely ship, 2x MSAA** via `vr_fidelity_levels_override.csv` (the string is in libvr.so; where it is read from is unverified) or `+vr_msaa 2`. Trivial.
3. **Per-eye hidden-area mesh** covering the symmetric excess beyond the real display edge (mirrored per eye), plus a small reprojection margin. Today we return one degenerate triangle. Alyx stencils the mesh out. ~21 % fewer shaded pixels (estimate). Small; in `kl_openvr.c` (after the other agents land).
4. **Asynchronous Submit:**
   - Submit the copies with fences and return immediately.
   - A filer thread waits on the fence and calls `kl_ovrp_frame_end_external`. Keep the per-stage ordering.
   - `WaitGetPoses(N+1)` waits only for frame N−1's fence.
   - Drop the `vkQueueWaitIdle` in `kl_vulkan_frame_done` for this path.
   - SteamVR does not block Submit on GPU completion either. Gain: the measured bubble (~17 % on the Mac) wherever the GPU is the limit. Medium effort.
5. **Stop rendering pixels we discard:** size the stage to the rendered sub-rect (copy, not scale), or set the recommended size so the chosen level ≈ the stage. Then retune `KL_OPENVR_RT_SCALE` for sharpness against fps. Reconsider the 0.12 overscan once fps is higher. Small.
6. A/B `KL_CP_QUALITY=0.6–0.75` (compositor). Trivial.
7. A/B `MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1` (encode on Source 2's recording threads, off the render thread) and `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0`. Mac first, for correctness.
8. Replace the `klvk_img_reg_*` linear scan under a global mutex with a hash set (or skip it for Alyx). Remove the runtime `dlsym`/`dlopen` from the frame path if it is ours. Small.
9. Build the app Release, or at least `-O` for the compositor Swift and kl_app.c. Trivial.
10. Find the ~17 MB/min footprint growth. Measure first.

---

## Device measurement plan (for the orchestrator; nothing run yet)

Build:
- Current tree plus this audit's instrumentation (`kl_vulkan.c`, `kl_app.c`): `make build/xros/libklepton.dylib`, then the hub as usual.
- For run D6 only: the `vendor/Klepton-fdm` MoltenVK fork, which has `KL_MVK_GPU_TIME`.

Launch with env (the hub accepts `KL_HUB_GAME=alyx` to skip the library):

```
xcrun devicectl device process launch --device "$KLEPTON_DEVICE" --console --terminate-existing \
  --environment-variables '{"KL_HUB_GAME":"alyx","KL_GLIBC_ARGS":"-vr -vulkan -console +vr_fidelity_level_spew 2", ...}' \
  "$KLEPTON_BUNDLE_ID" > /tmp/dN.log 2>&1
```

Convars ride in `KL_GLIBC_ARGS`. kl_app.c only sets its default `-vr -vulkan -console` if the variable is unset.

Each run: load the same save or intro spot, wait until the menu hands are visible (the `ForceNativeRes … Visible` line), then hold still 60 s and look around 60 s.

| run | env / convars | what to read |
|---|---|---|
| D1 baseline | `+vr_fidelity_level_spew 2` | `[Auto-Fidelity…]` spew (level over time; MAX/CRITICAL/PREDICTIVE DROP lines with the frame times it saw); `[openvr] guest N fps`; `[vk] [perf] frame seam` (bubble, encode, wait); `[vk] [perf] RT` / `vkAllocateMemory` (MSAA memory on device); `[hb] … thermal=` over 10 min |
| D2 | `+vr_fidelity_level_auto 0 +vr_fidelity_level 1` (4x, 0.78) | fps, frame work, seam |
| D3 | `+vr_fidelity_level_auto 0 +vr_fidelity_level 0` (2x, 0.78) | same; D2 − D3 = cost of 4x over 2x at equal pixels |
| D4 | D2 + `KL_PERF_NO_SUSPEND_AB=10` | fps lines alternate every 2 lines between phases (`[perf] NO_SUSPEND_AB phase` lines). **The picture is wrong in the STRIPPED phase.** The fps delta is the segment store/load cost. |
| D5 | `KL_OPENVR_RT_SCALE=0.6` + level 5 fixed | seam bubble and encode at a ~19 ms frame: is the device CPU-bound there? |
| D6 | fdm build, `KL_MVK_GPU_TIME=1` (`KL_FOVEATE` off), level 5 fixed | `[mvk-fov] GPU busy X ms per second`: below ~90 % while fps < 90 means CPU or serialisation, not GPU |
| D7 | `KL_CP_QUALITY=0.6` | fps against D1 at the same fixed level |
| D8 | `KL_VK_FRAME_SYNC=0` | check whether the frame-end `vkQueueWaitIdle` matters (the copy fences already cover ordering); watch for torn frames |
| D9 | `MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1`, only after a Mac correctness pass | seam encode, fps |

Thermal: `thermal=` is the raw `com.apple.system.thermalpressurelevel` notify state. Compare it with the value at launch. The scale's semantics on visionOS are unverified.

---

## Instrumentation added (uncommitted, marked `[perf-audit 2026-10-07]`)

- `runtime/gfx/kl_vulkan.c`:
  - `KL_PERF_FRAME` (default on): a `[vk] [perf] frame seam` line every 5 s.
  - `KL_PERF_RT_LOG` (default on): first 128 large render targets with sample count and TRANSIENT, plus allocations ≥ 16 MB with memory-type flags.
  - `KL_PERF_PASS_LOG=<n>` and `KL_PERF_PASS_SKIP` (default off): the dynamic-rendering census.
  - `KL_PERF_NO_SUSPEND_AB=<s>` (default off; measurement only, corrupts the picture).
  - A small image→samples table (`perf_rt_note` / `perf_rt_find`). The census's attachment sizes printed 0 on the Mac because `g_view_map` is full (8192 views); the flags and ops are correct.
  - `KL_PERF_BIG_MS` (default 0.25): the threshold that separates the game's frame submits from small ones.
- `visionos/Sources/kl_app.c`: `thermal=` on the `[hb]` line, via `notify_get_state`.
- Not documented in DEBUG_ENV_VARS.md yet; other agents are editing that file.

Raw Mac data is in the session scratchpad, `perf/`:
- traces: `mst_sk5.trace`, `mst_p1_L5.trace`, `mst_L0/L1/L5b.trace`, `mst_p2_ab.trace`
- samples: `sample_sk5.txt`
- logs: `run/p1.log` (pass census), `run/s1.log` (seam), `ab_msaa.out`
- tools: `tools/mst.py`, `gpustat.py`, `threadbusy.py`, `elfmap.py`, `vpk.py`
