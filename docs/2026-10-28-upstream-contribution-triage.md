# Klepton: what to contribute upstream (triage, 2026-10-28)

Read-only triage of `git log origin/main..main` in `klepton/` (238 commits) against
`shinyquagsire23/Klepton` `main` (`1fe7e6c` after `git fetch origin`). Nothing was committed,
pushed or posted. Cherry-picks were tried in a throwaway worktree on `origin/main` (removed).

## Upstream state since our fork point (`ce74582`)

Upstream moved 32 commits: PRs 5 (battery), 6 (visionOS 27 build), 7 (Ancient Dungeon), 8 (UE 4.25
probe), 9 (Vulkan foveation through Metal rate maps, `kl_fove.m`) and 10 (x18 veneers: `blr x18`
via x16, `adr`/literal rebuilds, jump tables, split pools) are **merged**. PRs 11-22 are still open,
and we took several of them into our fork (see `2026-10-15-klepton-upstream-pr-triage.md`).
What that means here:

- `21a310a` (ANGLE `use_lld=false`): PR 6 already did the device and debug builds. Only the
  `angle-ios-sim` line is still missing it.
- `6451ca1`'s `-framework CoreAudio` link fix is in PR 6.
- Our `blr x18` / `adr x18` veneers (`3bc8d17`) are superseded by PR 10 for bionic guests. The
  `stp/ldp x18` pair and TLS-site shapes remain glibc-only.
- `acf1dc4` (MoltenVK-FDM foveation) is a different design from upstream's merged `kl_fove`. It
  stays ours.

## Counts

| Category | Commits | What |
|---|---|---|
| UPSTREAM | 12 | generic, stands alone, applies cleanly or with trivial context fixes |
| UPSTREAM-AFTER-WORK | 60 | valuable but entangled with the glibc/Alyx series, the avp-play port, hub keys or other commits; needs extraction, a flag, or a rewrite onto upstream's files |
| OURS-ONLY | 82 | hub (catalog, Steam/Meta stores, downloads, cloud saves, Siri, UI), Play from Mac streaming, SenseKit, TestFlight/flat Frameworks, product naming, hub defaults in `kl_app.c`, MoltenVK-FDM, `stage_alyx.sh` |
| NOT-OURS | 47 | cherry-picks/merges of open upstream PRs (rebelancap 11/13/21, fayep 14/15/16/17/18/19, johnrtipton 7/8) and `a37704e` (port of avp-play, MIT, another author's fork) |
| OBSOLETE | 2 | `9d5d3ef` (tgkill probe, superseded by PR 11's real liveness check), `f2c58e5` (untracks our own stray symlinks) |
| merge commits | 37 | branch merges with no content of their own (except `0ee8685`, counted as NOT-OURS) |

Totals: 12 + 60 + 82 + 47 + 2 + 37 = 238. Two commits are split across categories:
- `4553be3`: the x18 CASP part is UPSTREAM, the SysV/signal part goes with the glibc series.
- `c14f9a5`: the locale and `/sys` CPU-topology parts are UPSTREAM-AFTER-WORK, the rest is
  hub/Alyx.

## Classification by group

| Group | Commits | Category | Notes |
|---|---|---|---|
| OBB read-through on plain `open()` | `35ff6a7` | UPSTREAM | code half clean; BUILDING.md half conflicts (names our metro row) |
| OpenXR swapchain FIFO | `c7785f8` | UPSTREAM | clean; `t_xrinput` "swapchain order: ok" on origin/main |
| GL_OVR_multiview only when ANGLE has it | `98a2a82` | UPSTREAM | clean; builds; `t_glcaps` passes |
| OVRPlugin EyeLevel origin + real recenter | `dd68c16`, `aa948fe` | UPSTREAM | first clean, second has 2 small hunks (avp-play pose-time lines to drop) |
| x18 CASP pair veneer | `4553be3` (x18 files only) | UPSTREAM | adapted from Glovebox (MIT); 2 keep-both hunks against PR 10 |
| mprobe field chains | `fe76f91` | UPSTREAM | clean, diagnostic only |
| Build scripts | `4ed75c8`, `fe9d41f`, `21a310a` (sim hunk) | UPSTREAM | `ed9ae69` as well if its default is inverted (AFTER-WORK) |
| mprobe tree census / strings | `f7095bd`, `e168136` | AFTER-WORK | build on avp-play's `KL_PROBE_STATIC` code (not upstream) |
| Unity targets ieytd, ktane | `c500f7c`, `b854b29`, `8097ff7`, `e483b00`, `eaacd4e`, `5a122a3`, `80195e4`, `4e9a286` | AFTER-WORK | strip hub keys; ktane's poke row is avp-play's (or depend on PR 14) |
| Touch/near-touch words, arming pulse | `ed062a3`, `72a7263` (C side) | AFTER-WORK | upstream bug is real (`neartouches = touches`); overlaps open PR 15 |
| Locale / CPU topology | `c14f9a5` (runtime hunks) | AFTER-WORK | extract from a hub commit; overlaps PR 20's Locale rows |
| Mac viewer side by side | `71b1164`, part of `9e64e73` | AFTER-WORK | 4 hunks in `kl_view_mtl.m`, built on the Alyx viewer change |
| Incremental `mkguest.sh` | `d7fee53` | AFTER-WORK | built on flat Frameworks (`e8bddde`, ours) and TestFlight; redo on upstream's script |
| Vulkan robustness | `1e86354` (kl_vulkan hunk), `b2115ec` (display-timing hunk) | AFTER-WORK | extract from Alyx/Metro commits |
| Fossilize record/replay/prewarm | `410daa8`, `a76ab7a` (runtime half) | AFTER-WORK | adapted from Glovebox (MIT); hub UI and FDM pipelines (`e9d3a3f`) stay ours |
| glibc guest kind, OpenVR, Steamworks stand-in (Alyx) | `6451ca1` `3bc8d17` `b8bdddd` `c71144b` `076bb6d` `4228a83` `1bd6284` `be3ea21` `47d564a` `1e86354` `793382b` `75bd7ae` `0638288` `6e87c99` `9e64e73` `07b05eb` `c09f3f2` `fa4e3a5` `46d05eb` `208f23e` `3ec8d79` `75575c3` `acf5c56` `af78e04` `87f96f1` `e27ffef` `eca1a26` `b3cccf6` `071cc0f` `80ed607` `b35928d`, glibc half of `4553be3` | AFTER-WORK | ~12k lines; policy questions (below) |
| Metro Awakening (Steam Frame) | `64fc9c7`, `e21313a`, `b2115ec`, `060e6da` | AFTER-WORK | needs the Steam stand-in; guest patches are target-gated |
| Perf/diagnostic knobs | `4f5c992`, `3b0e186`, `9df72e6`, `1c3825e` | AFTER-WORK | all opt-in; low priority; `9df72e6` is Glovebox-derived; `KL_PTHREAD_WIDE_HASH` superseded by PR 11 |
| Compositor reprojection, stage/fence pairing, FXAA | `da083b7`, `ccd43c5` | AFTER-WORK | overlap open PR 13 (`KL_WARP=system`, `last_complete_record`); FXAA is hub-wired |
| Language packs from disk | `b357c78` | AFTER-WORK | needs the batman row (avp-play's); `b7066fe` (hub note file) is ours |
| Hub, store, downloads, cloud/iCloud saves, Siri, UI | `bdef967` `e8fdb77` `5eb64ed` `88cc3f5` `482c567` `b7289b2` `3f0c883` `e4d38bd` `ac5da33` `60b9c90` `a9ef98d` `fdbd889` `fe359fb` `0aae9ed` `ff8f7cd` `d937922` `16a7c11` `cc10b47` `5fe1741` `5592d85` `3452bbb` `7a92304` `b7066fe` `319f180` `3cc1e7d` `6a1c48b` `6143a27` `7212b68` `9384fd0` `8ba568e` `8ccca8b` `15571a5` `e664add` `8f5a802` `3de381b` `61c1022` `4fcc650` `4431df0` `7e96c8f` `430250e` `1cc36f8` `216d589` `fe1712d` `3bc1f4e` `f313cdb` `d144ea9` `be63b2a` | OURS-ONLY | |
| Hub defaults for Alyx | `30966b6` `9867327` `8efb6a2` `d9958ce` `2583be8` | OURS-ONLY | |
| Play from Mac streaming | `b2d151e` `9dc410b` `1bd4fed` `ab4637b` `f094ac1` `2823142` `c649820` `63cdd67` `018d0b6` `48b2f64` `de21453` `81d9d80` `3ff255e` | OURS-ONLY | |
| SenseKit / Sense UI | `365a7f4` `eafd716` `da5e69b` `62ec517` `3b1021a` `42046f7` `ffd0855` | OURS-ONLY | |
| TestFlight, flat Frameworks, MoltenVK-FDM, staging | `1c9e18b` `e8bddde` `6bd23f8` `acf1dc4` `e9d3a3f` `f08e3b8` `f1b4f1f` `80eb3de` `a153503` `7736da8` | OURS-ONLY | `6bd23f8`'s sim path came from avp-play and is not upstream |
| Other people's PRs | rebelancap `f798253`..`0a38a70` (PR 11), `9ca3e38`..`1814c3a`, `5d16234` (PR 21/13); fayep `c420c63`..`c051e55`, `4a0eae5`..`15553d7`, `7ac1eeb`, `701930a` (PR 14-19); johnrtipton `0c1de07` (PR 8, merged); `94804a3`, `faa61e4` (hand-taken hunks of PR 7/13); `0ee8685` (PR 11 merge); `a37704e` (avp-play) | NOT-OURS | |

## Decided grouping (2026-10-28): 9 PRs, in this order

Upstream already takes themed PRs (open PR 20 "Unreal/JNI: …", PR 21 "gl: …"), so the 17
candidates below ship as 9. Each one keeps one theme so a reviewer can read it in one sitting, and
a problem in one does not block the others. Don't merge any further than this.

| Order | PR | Contains | Theme / notes |
|---|---|---|---|
| 1 | **A. RE4 end to end** | P1 + P2 + `ovrp_Shutdown2` fix | `make check TARGET=re4` passes fully, Bink movies show. Fix `klovrp_Shutdown2` to take the pointer RE4's `libOVRPlugin.so` passes (the `ovrpabi` gate fails today on origin/main too). BUILDING.md note rewritten without the metro row. |
| 2 | **C. Graphics** | P5 + P14 | Re-check hl2/portal (were in the by-name multiview list). |
| 3 | **B. Tooling** | P3 + P12 + P8 | Confirm the simulator ANGLE/lld flag is still needed on Xcode 27. |
| 4 | **E. Mac viewer + locale** | P11 + P9 | |
| 5 | **D. OpenXR/OVRPlugin** | P4 + P6 + P10 | Overlaps open PRs 13 (P6) and 15 (P10): comment on those PRs first, don't compete. |
| 6 | **F. x18 CASP veneer** | P7 | Alone (translator). Adapted from Glovebox (MIT): credit in commit + PR. |
| 7 | **G. Fossilize** | P15 | Alone (~1.3k). Glovebox-derived: credit. |
| 8 | **H. New targets** | P13 + P17 | ieytd, ktane, Metro. Metro needs D, C and part of I. Scrub private-path comments and hub keys. |
| — | **I. Half-Life: Alyx (glibc guest)** | P16 | Open an issue asking upstream whether they want a glibc/PC guest kind and the Steamworks stand-in before splitting ~12k lines. |

Mechanics for each: branch from `origin/main`, cherry-pick `-x` (or re-apply by hand), strip
`Claude-Session:` trailers and any hub/personal text, `make -s check` (+ the target's own check),
show the diff to the owner, push to the `fork` remote, open the PR to shinyquagsire23/Klepton.
Nothing is pushed or opened without the owner seeing the diff first.

## Proposed upstream PRs

Ordered from smallest and safest to largest. "Clean" means `git cherry-pick` onto `origin/main`
with no conflict. Builds were checked with `make build/t_xrinput build/t_load build/m_boot
build/t_glcaps` and their selftests, using the stock MoltenVK and our ANGLE `vendor/`.

### P1. `make check`: skip the il2cpp gate on guests that have no libil2cpp.so

- **Commits:** none yet; this is a new ~5-line change to `Makefile` (the `=== il2cpp runtime ===`
  line, `origin/main` line 627). It uses the same skip-loudly pattern the opus gate already has.
- **Why:** `make check TARGET=<UE4/SDL/native target>` dies at `t_il2cpp $(LIBS)/libil2cpp.so`
  for every non-Unity target upstream ships (re4, redmatter2, vampire, intotheradius, hl2, …).
  Every gate after it never runs.
- **Files:** `Makefile`. **Applies:** written against `origin/main`. **Deps:** none. **Risk:**
  none for Unity targets: the branch is taken only when the file exists.
- **Test:** `make check TARGET=re4` should get past the il2cpp line. `make check` (beatsaber)
  should be unchanged.
- **Verified on origin/main + this change:** with `TARGET=re4`:
  - il2cpp is now "SKIPPED";
  - opus is skipped;
  - the guest-entry gate passes ("Unreal chain is bound and initialised", "NativeActivity
    lifecycle ran with no unimplemented JNI calls").
- **Second finding, same PR or a sibling:** `make check TARGET=re4` fails *earlier*, at
  `ovrpabi`. `tools/ovrp_abi.py` reports RE4's `libOVRPlugin.so` refusing a NULL x8 in
  `ovrp_Shutdown2` (-1001), while `klovrp_Shutdown2(void)` takes no pointer. Our fork has the same
  code, so this is a real ABI question for that OVRPlugin version, not a check bug. Investigate
  before sending: give `Shutdown2` the out-parameter, or teach the checker the version. The run
  above made `ovrpabi` non-fatal only to see the later gates.

### P2. libc: plain `open()` asks the OBB read-through too

- **Commits:** `35ff6a7`. Take the code half (`runtime/libc/kl_va_handlers.c`, +10/-1) as is. The
  BUILDING.md half conflicts because it sits under our metro row: rewrite that paragraph against
  upstream's table, without metro.
- **Why:** `stat`/`access` saw OBB-stored files, but `klh_open` went straight to the host. A
  library built without FORTIFY (RE4's Bink player, `.bk2` movies) got ENOENT, and the movie
  panels stayed black. `openat` and `__open_2` already ask `kl_obbmap_open`.
- **Applies:** code half clean, compiles, `t_fault` passes. **Deps:** none. **Risk:** low. It only
  answers for paths the OBB index knows.
- **Test:** `re4`, Comfort Mode preview panel (movie plays instead of black). With
  `KL_TRACE_FS=1`, no more `stat ok` then `open FAILED` for `.bk2`.

### P3. Build scripts: Release config, empty bundle id, ANGLE simulator linker

- **Commits:**
  - `4ed75c8` (`KL_CONFIG=Release`, clean).
  - `fe9d41f` (empty `KLEPTON_BUNDLE_ID` falls back to the row's id, and the value is quoted). The
    `or` hunk is clean; the quoting hunk must be re-applied at upstream's
    `PRODUCT_BUNDLE_IDENTIFIER` line (context differs).
  - From `21a310a`, only `use_lld=false` on `angle-ios-sim`.
  - Optional: `ed9ae69` (keep an existing `.xcodeproj`), but with the default inverted to an
    opt-in `KL_KEEP_XCODEPROJ=1`. As committed it would silently ignore `targets.py` edits.
- **Why:** three small papercuts in the public build path.
- **Files:** `visionos/run.sh`, `visionos/gen_xcodeproj.py`, `Makefile`. **Risk:** low.
- **Test:** `./run.sh device` with `KL_CONFIG=Release`. `KLEPTON_BUNDLE_ID= python3
  gen_xcodeproj.py` gives a valid pbxproj. `make angle-ios-sim` on Xcode 27 (unverified that lld
  still fails there; check before sending).

### P4. OpenXR: swapchain acquire/wait/release in spec order

- **Commits:** `c7785f8` (+147/-10). **Clean**; `t_xrinput` passes on origin/main, including the
  new "swapchain order: ok" selftest.
- **Why:** UE5's OpenXR plugin acquires the next image a frame ahead. With one tracked image, the
  second acquire failed and every wait failed (48,992 `CALL_ORDER_INVALID` on device). Release
  then published the image UE was about to draw into: whole-view flicker. Images are now a FIFO.
  A/W/R guests are unchanged.
- **Files:** `runtime/xr/kl_openxr.c/.h`, `tests/t_xrinput.c`. **Deps:** none. **Risk:** low to
  medium (every OpenXR guest goes through it).
- **Test:** `make check` (`t_xrinput`); any OpenXR guest (steamlink-vr, a UE OpenXR title) with
  `KL_XR_SC_TRACE=200`.

### P5. GL: offer GL_OVR_multiview only when ANGLE can compile it

- **Commits:** `98a2a82` (+40/-3). **Clean**; builds; `t_glcaps` passes.
- **Why:** `kl_egl` advertised `OVR_multiview(2)` by target name, but the vendored Metal ANGLE does
  not expose it. Unity 2019.4 then baked `num_views` shaders that ANGLE rejected, and drew nothing.
  The extension is now withheld unless ANGLE has it; `KL_GL_MULTIVIEW=0/1` forces either answer.
- **Files:** `runtime/gfx/kl_egl.c`, `kl_glfb.c/.h`. **Risk:** medium for hl2/portal, which were
  in the by-name list. A reviewer must check that they still render (or set `KL_GL_MULTIVIEW=1`).
- **Test:** hl2, portal, one Unity GLES title.

### P6. OVRPlugin: honour the EyeLevel tracking origin; real recenter

- **Commits:** `dd68c16` (clean) + `aa948fe`. The second has 2 conflict hunks: drop the avp-play
  `klovrp_pose_time` lines and fix the `DEBUG_ENV_VARS.md` context.
- **Why:** frontends publish the head in a floor frame. A guest that never selects FloorLevel
  (OVRPlugin's default is EyeLevel) put its UI 1.7 m below the view. Node poses for an EyeLevel
  guest are now relative to an anchor, and `ovrp_RecenterTrackingOrigin` is real (position + yaw).
  `KL_OVRP_EYELEVEL=0` / `KL_OVRP_RECENTER_YAW=0` roll it back.
- **Files:** `runtime/xr/kl_ovrp.c`, `DEBUG_ENV_VARS.md`. **Deps:** none. **Risk:** medium.
  **Overlap:** open PR 13 (`ORIGIN_REBASE`) solves the same problem differently; say so in the PR
  body.
- **Test:** an EyeLevel Unity title (ieytd once P13 lands); beatsaber must be unchanged
  (FloorLevel).

### P7. x18: CASP pair veneer

- **Commits:** `4553be3`, x18 files only (`runtime/kl_x18.c/.h`, `tests/t_x18_casp.{c,S}`,
  `tools/check_x18.py`, the `x18casp` Makefile target). Not the glibc SysV/signal half.
- **Why:** `casp{,a,l,al}` names register *pairs*. Upstream decodes it in the exclusive class,
  which sees only the base registers. A pair naming x18:x19 gets a single-register substitution
  (odd scratch = unallocated encoding; even scratch pairs with the wrong odd register). This is a
  latent wrong-code bug in upstream's decoder. Upstream has no `KLX_HZ_CASP`.
- **Applies:** 2 keep-both conflict hunks in `kl_x18.c` (encoders next to PR 10's `enc_cbz`; the
  casp block next to PR 10's `adr` block). `KLX_VEN_MAX_INSN` 8 → 12 must be re-checked against
  PR 10's `KLX_JT_MAX_INSN` and klepton-ld pool sizing. **Risk:** medium: it changes every
  translated library (klepton-ld rebuild retranslates all).
- **Provenance:** adapted from Glovebox (MIT, glovebox-vr/glovebox). Keep the attribution comments
  and add the MIT notice. Upstream has no `THIRD_PARTY_NOTICES.md`.
- **Test:** `make x18casp`, `make x18` (decoder vs objdump), `make check`. Related: avp-play's
  single-register `cas` decode fix (inside `a37704e`) is the sibling bug in the same function.
  That one is not ours; point upstream at avp-play.

### P8. mprobe: `KL_PROBE_FIELDS` field/getter chains from a static

- **Commits:** `fe76f91` (+162). **Clean.** Diagnostic only; nothing runs unless the knob is set.
- **Test:** any IL2CPP title,
  `KL_PROBE_FIELDS=GameManager:_instance._fsm._currentState`.
- `f7095bd` / `e168136` (tree census, string values) can follow, but only after avp-play's
  `KL_PROBE_STATIC` base, which upstream lacks.

### P9. Locale follows `KL_LOCALE`, then `LANG`, then the system language (AFTER-WORK)

- **Source:** runtime hunks of `c14f9a5`: `kl_jni_services.c` (`klj_locale_parse`,
  CFLocale fallback), `kl_jni_sdl.c` (`getPreferredLocales`), `kl_libc.c` (locale sysprops), plus
  the `kl_jni_locale_parts` export. The `/sys/devices/system/cpu/*/topology` files from the same
  commit could be a separate tiny PR.
- **Why:** an app launched from the visionOS Home View has no `LANG`, so every guest saw en/US
  whatever the headset language.
- **Work:** hand-extract from a hub commit; reconcile with open PR 20's Locale rows. **Risk:** low.
- **Test:** a non-English headset; Unity `Application.systemLanguage`, SDL titles.

### P10. OVRPlugin Touches/NearTouches in the guest's layout + near-touch arming (AFTER-WORK)

- **Source:** C side of `ed062a3` (`kl_ovrp_touch_word` / `kl_ovrp_neartouch_word`, `t_xrinput`
  selftest) and `72a7263` (arming pulse). Drop the Swift halves: they target our Sense controller
  code, which upstream's `KleptonControllers.swift` does not have.
- **Why:** upstream still does `neartouches = touches` (`kl_ovrp.c` ~3116), so ovrpButton bits
  land on ovrpNearTouch bits (in IEYTD, right B drove the left thumb).
- **Conflicts:** 6 hunks per commit. **Overlap:** open PR 15 (fayep) fixes the same bug more
  narrowly; offer ours as a superset or comment there.
- **Test:** `t_xrinput`; an OVRPlugin title that poses hands from touch (ieytd).

### P11. Mac viewer: both eyes side by side on every composite path (AFTER-WORK)

- **Source:** `71b1164` plus the non-Alyx viewer part of `9e64e73`. 4 conflict hunks in
  `runtime/gfx/kl_view_mtl.m`.
- **Why:** the projection-layer and plain-src paths showed one letterboxed eye for OpenXR guests.
- **Test:** `m_boot --view` on an OpenXR guest; `KL_VIEW_EYE=0/1` gives the old view back.

### P12. `mkguest.sh`: incremental translations (AFTER-WORK)

- **Source:** `d7fee53`, re-done on upstream's `mkguest.sh`. Ours sits on flat Frameworks and
  TestFlight changes that stay ours.
- **Why:** reuse a slice when it is newer than its `.so` and than klepton-ld. An unchanged rebuild
  goes from minutes to under a second. `KL_FORCE_GUEST=1` restores the wipe.
- **Risk:** low to medium (a stale slice if the mtime rule misses a dependency, such as the guest
  patch table: forced by `KL_GUEST_PATCH_OFF`).

### P13. Targets: I Expect You To Die and Keep Talking and Nobody Explodes (AFTER-WORK)

- **Commits:** `c500f7c`, `8097ff7`, `b854b29` (ieytd poke row), `e483b00` (ES 3.0 for ieytd,
  `DEBUG_ENV_VARS.md` context conflict), `5a122a3`, `4e9a286`, `80195e4` (ktane poke row; the
  offsets were avp-play's).
- **Work:**
  - Drop `eaacd4e` and the `hand_matting` / `render_scale` / `post_aa` keys (hub-only).
  - Scrub comments naming our private script paths.
  - If upstream merges PR 14 (texunit mask), drop both poke rows instead.
- **Deps:** P5, P6 (ieytd is black or misplaced without them), P10 (ieytd hands), P8 (docs
  mention its knobs).
- **Test:** `make check TARGET=ieytd`, `TARGET=ktane`; headless `m_boot` to the first room.

### P14. Vulkan robustness bits (AFTER-WORK)

- **Source:**
  - `1e86354` `kl_vulkan.c` hunk: formats the device cannot back are substituted instead of
    aborting inside Metal (visionOS simulator), plus the >8192 px clamp on the simulator only.
  - `b2115ec` `kl_vulkan.c` hunk: `vkGetRefreshCycleDurationGOOGLE` /
    `vkGetPastPresentationTimingGOOGLE` / `vkGetSwapchainStatusKHR` answered for Klepton's own
    swapchains instead of being handed to MoltenVK, which aborted on the cast.
- **Test:** any Vulkan guest in the simulator; a UE title that paces with
  `VK_GOOGLE_display_timing`.

### P15. Fossilize pipeline record/replay and in-process prewarm (AFTER-WORK)

- **Source:** `410daa8` (only `DEBUG_ENV_VARS.md` and `Makefile` conflict; `kl_vulkan.c` merges)
  and the runtime half of `a76ab7a`: `kl_fossilize.cpp`, `kl_vk_pipe_hooks.h`, `KL_FOZ_PREWARM`
  device from `device-info.json`, the `m_boot` hook, and building Fossilize for xros.
- **Leave out:**
  - the hub toggle and Spanish UI strings;
  - `e9d3a3f` (FDM pipelines);
  - optionally `tools/alyx_pipelines.py`.
- **Why:** Metal's shader cache warmed before the guest boots. On the host, a1_intro_world went
  from 101 stalls / 36.6 s to 0. It helps any Vulkan guest (re4, bonelab).
- **Provenance:** adapted from Glovebox (MIT). Fossilize itself (MIT) is fetched by
  `make fossilize`.
- **Risk:** medium (new C++ dependency); off unless `KL_FOZ_*` is set.

### P16. glibc guest kind: Half-Life: Alyx (AFTER-WORK, large, split in five)

About 12k lines of runtime. Split as below; each part needs `make check` plus an Alyx host boot.

1. **Loader, TLS and glibc ABI:**
   - `6451ca1`, `3bc8d17`, `4228a83`, `47d564a`, `75575c3`;
   - the glibc half of `4553be3` (in-process SysV semaphores; fatal signals stay unblocked);
   - the x18 `stp/ldp x18` pair and the TLS-site-as-code test.
2. **SDL video/audio seam and host window:** `b8bdddd`, SDL parts of `9e64e73` and `c14f9a5`.
3. **OpenVR runtime over kl_ovrp:**
   - `076bb6d`, `1bd6284`, `793382b`, `75bd7ae`, `07b05eb`, `c09f3f2`, `fa4e3a5`, `46d05eb`;
   - `208f23e`, `3ec8d79`, `af78e04`, `87f96f1`, `eca1a26`, `b3cccf6`, `071cc0f`, `80ed607`,
     `b35928d`;
   - `be3ea21` and `e27ffef` net: the no-pause patch was added, then dropped.
4. **Steamworks stand-in:** `c71144b`, `0638288`, `6e87c99`, the Android flat API of `64fc9c7`.
   Make the account bridge (`kl_steam_bridge`, our SteamDepot service) an optional seam. Its Swift
   side (`d144ea9`) stays ours.
5. **Alyx content helpers:** `1e86354` (overlay, soname stems, fd limit), `acf5c56`.

**Policy questions for the maintainer:** without the bridge, the stand-in reports a fixed SteamID
that owns the target's app. That has the same shape as the existing `kl_ovrplat` entitlement
answer, but it is Steam. Does upstream want a glibc/PC guest kind at all?

### P17. Metro Awakening (Steam Frame build) (AFTER-WORK)

- **Source:**
  - the target row from `64fc9c7`, without hub keys;
  - `e21313a`: Valve maker, Adreno 750 and the Android version for metro;
    `metro-fireant-null-trackingspace`; `kl_obbmap_resolve` for MediaPlayer; thread-name tracing;
  - `b2115ec`'s `metro-swappy-off` guest patch;
  - `060e6da` (UObject slots after a survived fatal);
  - the UE knobs of `3b0e186` (`KL_UE_INI_CVARS`, `KL_UE_THREAD_QOS`), opt-in.
- **Deps:** P4, P14, P16 part 4.
- **Risk:** medium; every guest patch is target-gated.

### Not proposed now

| Commits | What | Why not now |
|---|---|---|
| `da083b7`, `ccd43c5` | render-anchor reprojection, stage+fence pairing, FXAA | duplicate open PR 13's `KL_WARP=system` and `last_complete_record`. Offer as review input there; FXAA is wired to hub keys |
| `4f5c992`, `3b0e186` (rest), `9df72e6`, `1c3825e` | perf audit knobs, Glovebox pacer/GPU time, scripted inputs | opt-in diagnostics with low reviewer value; `9df72e6` is Glovebox-derived and its tkill part is superseded by PR 11 |
| `b357c78` | language packs answered from disk | gated to the batman row, which is avp-play's and not upstream |
| `f7095bd`, `e168136` | mprobe tree census and strings | sit on avp-play's mprobe code |

## Personal data and placeholders to scrub before sending

- Target-row comments in `visionos/targets.py` (ieytd, ktane) name a private repo path
  (`AlyxAVP/local/...`). Remove them.
- Comments naming the hub product appear in `runtime/libc/kl_pthread.c` ("AVPGameHub: opt-in…")
  and in hub-flavoured `DEBUG_ENV_VARS.md` entries. Reword them in any extracted hunk.
- `visionos/targets.py`'s `_load_local_config` (reads `local/config.env`), the hub row
  (`com.example.avpgamehub` placeholder), `.gitmodules` (our SenseKit URL) and the stream code
  (example LAN address in a Swift comment) are ours only. Never include them.
- Commit trailers carry `Claude-Session:` URLs. Strip them when re-committing for upstream.
- No team id, real bundle id, LAN IP or e-mail appears in the hunks proposed above (P1-P8 checked
  by grep).

## Open questions

- Glovebox-derived work (P7, P15, `9df72e6`): send it upstream with attribution, or ask the
  Glovebox authors to send it themselves?
- P6 and P10 overlap open PRs 13 and 15. Offer ours as alternatives, or comment on those PRs?
- P16: whether upstream wants a glibc/PC guest kind and a Steamworks stand-in at all; ask before
  spending the split work.
