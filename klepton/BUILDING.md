# Building Klepton

macOS on Apple Silicon only. Everything here assumes an arm64 host — the project
runs guest ARM64 code natively, so there is no x86_64 path and never will be.

The build is a plain `Makefile` plus a few shell scripts. There is no CMake, no
package manager for the project itself, and no git submodules.

---

## TL;DR

```bash
# host deps
brew install pkg-config sdl3 apktool

# put the APKs you supply in the repo root, then unpack them
apktool d -f -o <target> <target>.apk

make check                               # regression sweep, builds everything in the process
make angle-all                           # pull, patch and build ANGLE (slow)
make mvk                                 # MoltenVK, for the Vulkan targets

./build_run_viewer.sh <target>           # build and run the macOS viewer for a target
./build_run_vpro.sh <target>             # build and run the visionOS app bundle for a target
```

`make check` needs no ANGLE, no NDK and no headset. Everything past it does.

---

## Host requirements

Known-good versions are what this tree is developed against, not minimums —
where a version is load-bearing it says so.

| dependency | known-good | needed for | how to get it |
|---|---|---|---|
| macOS on Apple Silicon | 26.5.1 (Darwin 25.5) | everything | — |
| Xcode + Command Line Tools | 26.0.1 (17A400), Apple clang 17.0.0 | everything | App Store; `xcode-select --install` |
| macOS SDK | 26.0 | host builds | ships with Xcode |
| xrOS + xrSimulator SDKs | 26.0 | `make xros`, visionOS app | Xcode → Settings → Components → visionOS |
| Python 3 | 3.14.6 (3.8+ is plenty) | `tools/*.py`, `visionos/gen_xcodeproj.py` | ships with Xcode CLT, or `brew install python` |
| `pkg-config` | any | locating SDL3 | `brew install pkg-config` |
| SDL3 | 3.4.12 | macOS interactive viewer (**optional**) | `brew install sdl3` |
| apktool | 2.11.1 | unpacking the guest APKs | `brew install apktool` |
| ANGLE (vendored, patched) | ANGLE `25e7211`, depot_tools `6afa997` | any real-GL path | `make angle-all` |
| MoltenVK (vendored, prebuilt) | `v1.4.2` | any Vulkan path (BONELAB, Open Brush, RE4) | `make mvk` |
| Fossilize (vendored source) | `556da9f` | Alyx pipeline record/replay (**optional**, host `m_boot`) | `make fossilize` |
| Android NDK | r25c (`25.2.9519653`) | `make guest` only (**optional**) | Android Studio SDK Manager |
| Vision Pro + Apple Developer account | — | device runs only | — |

visionOS signing is auto-detected from your keychain's `Apple Development`
certificate; override with `KLEPTON_TEAM=<teamid>`. The Simulator needs neither.

The bundle id is set to `$USER.dev.klepton.target.<target>` in order to avoid collisions.
Set `KLEPTON_BUNDLE_SCOPE` to use something else instead of `$USER`, or `KLEPTON_BUNDLE_ID` 
to override the the whole id.

---

## Guest applications

**Do not ask me where to get these.** You supply them.

| target | APK | unpacked to | graphics | also needs |
|---|---|---|---|---|
| Beat Saber 1.40.8 | `beatsaber.apk` | `beatsaber/` | GLES (ANGLE) | one OBB, 1.3 GB |
| SUPERHOT VR 1.72 (Steam Frame, depot 617833 `shvr.apk`) | `superhot.apk` | `superhot/` | Vulkan (MoltenVK) | — (hub: downloaded in-app) |
| BONELAB 1.2974 | `bonelab.apk` | `bonelab/` | Vulkan (MoltenVK) | two OBBs, 6.3 GB |
| VRChat 2026.2.3 | `vrchat.apk` | `vrchat/` | GLES (ANGLE) | — |
| Open Brush 2.30.0 | `openbrush.apk` | `openbrush/` | Vulkan (MoltenVK) | — |
| RE4 VR 2.3 | `re4.apk` | `re4/` | Vulkan (MoltenVK) | two OBBs, 7.9 GB |
| JKXR 1.1.28 | `jkxr.apk` | `jkxr/` | GLES (ANGLE, via gl4es) | retail game pk3s |
| Steam Link 2.0.20 (VR) | `steamlink-vr.apk` | `steamlink-vr/` | GLES (ANGLE) | — |
| Steam Link (flat) | `steamlink-android.apk` | `steamlink-android/` | — | `make x18-slink` only |

Unpack with **apktool**:

```bash
apktool d -f -o beatsaber    beatsaber.apk
apktool d -f -o superhot     superhot.apk
apktool d -f -o steamlink-vr steamlink-vr.apk
# ... etc
```

**Keep the `.apk` files themselves.** `getPackageCodePath()` hands Unity the APK path
and Unity opens it as a zip.

Additional targets can be defined in `visionos/targets.py`; run `make targets`
afterwards to regenerate the runtime's copy of the table
(`runtime/kl_target_table.h`, which is committed).

To build a target:

```bash
make check TARGET=<target>          # the host gates
./build/m_boot <target>             # host run
./build_run_vpro.sh <target>        # on the headset
```

Steam Link is the only target with separate mains of its own, still working on unifying that.

### OBBs (split application binaries)

Some targets ship their data beside the APK rather than inside it. The runtime
reads the OBB out of the guest's userdata directory:

```
~/Library/Application Support/Klepton/userdata/<target>/<obb path>/
```

| target | OBB path under userdata | files |
|---|---|---|
| `beatsaber` | `obb/` | `main.1716.com.beatgames.beatsaber.obb` |
| `bonelab` | `obb/` | `main.2974` + `patch.2974`, `.com.StressLevelZero.BONELAB.obb` |
| `re4` | `Android/obb/com.Armature.VR4/` | `main.203` + `patch.203`, `.com.Armature.VR4.obb` |
| `metro` | `Android/obb/com.vertigogames.ImpactDevelopment/` | `main.944116` + `chunk.1`..`chunk.12`, `chunk.20`, `.com.vertigogames.ImpactDevelopment.obb` (17 GB; symlinks to the depot download work) |

Metro Awakening (Steam Frame build, Steam app 2669410, depot 2669412) keeps its
tree OUTSIDE the repo: unpack with `apktool d -o game/metro/apk
Impact-Android-Shipping-arm64.apk` next to the depot download and point the
gitignored `metro` and `metro.apk` symlinks at the repo root to it.

---

## ANGLE

```bash
make angle-all       # pull + patch + all three slices, from nothing
```

ANGLE requires a lot of disk space to build, budget ~20 GiB total for both the
source checkout and build intermediates:

| | |
|---|---|
| sources (`third_party`, `buildtools`, `depot_tools`, `.git`) | ~12 GiB |
| `out/Debug` — host slice | 4.4 GiB |
| `out/ios` + `out/ios-sim` | ~1.4 GiB |
| `out/xros` + `out/xrsim` — the retargeted frameworks | 24 MiB |
| **`vendor/` total** | **~18 GiB** |


`vtool` is used to retarget the iOS builds to visionOS.

---

## MoltenVK

```bash
make mvk             # pull the pinned prebuilt + stage all three slices
```

## Fossilize (Half-Life: Alyx pipeline warmup)

```bash
make fossilize       # clone ValveSoftware/Fossilize (MIT) at the pinned rev into vendor-fossilize/
make build/m_boot    # links runtime/gfx/kl_fossilize.cpp + Fossilize when vendor-fossilize/ exists
```

Optional: without the checkout `m_boot` links as before and `KL_FOZ_RECORD` /
`KL_FOZ_REPLAY` do nothing (DEBUG_ENV_VARS.md, Vulkan section). The pipeline
list itself is game-derived and never goes in git. Rebuild it from your own
copy of the game with a recipe (offsets + SHA-256 of the game's own SPIR-V,
no shader code):

```bash
# Glovebox's recipe (MIT): packages/alyx/pipelines/alyx.recipe in
# github.com/glovebox-vr/glovebox — for Steam build 25487405
# (manifests 546561=1436897171613240821, 546564=9198205754520568813)
python3 tools/alyx_pipelines.py check alyx.recipe
python3 tools/alyx_pipelines.py build alyx.recipe ../local/game/content/game alyx.foz
# your own recordings (KL_FOZ_RECORD) -> a recipe you may share
python3 tools/alyx_pipelines.py make mine.recipe ../local/game/content/game recorded.foz
```

`make xros` compiles the same files into each visionOS slice of the runtime
archive when `vendor-fossilize/` exists (kl_vulkan.c then built with
`-DKL_HAVE_FOSSILIZE`; the app links `-lc++`). On the headset the hub's
per-game setting "Precompilar gráficos" (Alyx; default off) replays the list
before the game boots (`KL_FOZ_PREWARM`, DEBUG_ENV_VARS.md) with a
"Preparando gráficos… n/N" line in the game's window. The list is made on the
Mac and copied into the hub's container (the hub creates nothing; devicectl
makes the folders):

```bash
xcrun devicectl device copy to --device <udid> \
  --domain-type appDataContainer --domain-identifier "$KLEPTON_BUNDLE_ID" \
  --source alyx.foz --destination Documents/games/alyx/klfz/alyx.foz
# optional, only for the very first launch: the Mac's record of the game's device.
# The headset writes its own there on every launch with the setting on, and the
# prewarm needs one; without it that launch replays on the game's own device.
xcrun devicectl device copy to --device <udid> \
  --domain-type appDataContainer --domain-identifier "$KLEPTON_BUNDLE_ID" \
  --source device-info.json --destination Documents/games/alyx/klfz/device-info.json
```

(`KL_VK_DEVICE_INFO=$PWD/device-info.json ./build/m_boot alyx` writes the Mac's.)
A single-game build (no hub) keeps its data at `Documents/`, so there the path
is `Documents/klfz/alyx.foz`.

Worktrees can share the main checkout's dependencies by symlink:
`vendor/out -> ../../Klepton/vendor/out`, `vendor-moltenvk -> ../Klepton/vendor-moltenvk`.

---

## Build Targets

Everything below builds what it needs first. `<target>` is any name from
`python3 visionos/targets.py --list` and defaults to Beat Saber.

| want | command |
|---|---|
| a guest on macOS, in a window | `./build_run_viewer.sh <target>` |
| a guest on macOS, headless | `./build/m_boot <target>` |
| a guest on the visionOS Simulator | `KLEPTON_TARGET=<target> visionos/run.sh` |
| a guest on Vision Pro | `./build_run_vpro.sh <target>` |
| a guest on macOS, with a summary | `./build_run_host.sh <target>` |
| Steam Link config UI, macOS | `./build_run_host.sh steamlink-vr --shell --view` |
| any target's shim work list, in seconds | `./build_run_host.sh <target> --gap` |
| visionOS build gate, no device needed | `make xros` |

---

## Working on ANGLE itself

Skip unless you are editing `vendor/`.

```bash
make angle-save      # export vendor/'s delta -> angle-patches/klepton.patch
make angle-status    # pin, HEAD, local delta, whether the patch is current
make angle-sync      # force the DEPS re-resolve that angle-fetch skips
```

## Notes for visionOS 27+ / Beat Saber 1.40 (from avp-play)

Adapted from avp-play (MIT, github.com/myMartek/avp-play) BUILDING.md.

1. If `make angle-all` fails, run `./update_depot_tools` in `vendor/depot_tools`
   before retrying.
2. To avoid being stuck on Beat Saber's interactive first-run screens (language
   selection / explicit content) on a device, stage the local save profile
   explicitly:
   `KLEPTON_TARGET=beatsaber KLT_STAGE_FILES="files" visionos/stage_assets.sh <device-udid>`
