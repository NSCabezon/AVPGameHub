#!/bin/bash
# Build MoltenVK FROM SOURCE with Klepton's foveation patches, and stage it
# exactly where `make mvk` stages the prebuilt — vendor-moltenvk/out/{macos,
# xros,xrsim,include} — so nothing downstream (kl_vulkan.c's dlopen, the
# visionOS packaging, `make mvk-check`) knows the difference.
#
# WHY A SOURCE BUILD AT ALL. Everything else here vendors MoltenVK as a
# prebuilt because nothing patched it (tools/mvk_fetch.sh). Phase H patches it:
# Half-Life: Alyx foveates through VK_EXT_fragment_density_map, which MoltenVK
# 1.4.2 does not have. Klepton's libvulkan layer (runtime/gfx/kl_vulkan.c,
# KL_FDM_SPOOF) advertises the extension; this fork honours a render pass's
# density map with a Metal rasterization rate map (MVKFoveation.{h,mm}, behind
# KL_FOVEATE=1, default OFF — with it off the fork renders exactly as stock).
#
# Two patches, mirroring angle-patches/:
#   mvk-patches/moltenvk-fdm.patch     MoltenVK v1.4.2 (render pass, encoder,
#                                      pipeline, implicit buffer, GPU timing)
#   mvk-patches/spirv-cross-fdm.patch  SPIRV-Cross at MoltenVK's pinned revision:
#                                      the gl_FragCoord physical->screen remap
#                                      (MSL option rasterization_rate_map_fragcoord)
#
# Sources and build trees live in vendor-moltenvk-fdm/ (gitignored, ~3 GB with
# the external dependencies). First run ~20 min; reruns rebuild only MoltenVK
# unless the SPIRV-Cross patch changed.
#
#   ./tools/mvk_fdm_build.sh            # all three slices, then stage
#   MVK_FDM_SLICES=macos ./tools/...    # host only (fast iteration)
#   MVK_FDM_NO_STAGE=1 ./tools/...      # build, leave vendor-moltenvk/ alone
#
# The prebuilt is not lost: vendor-moltenvk/MoltenVK-all-<ver>.tar stays, and
# `rm vendor-moltenvk/.klepton-fdm && make mvk` puts stock back.
set -euo pipefail
cd "$(dirname "$0")/.."

MVK_VERSION="v1.4.2"
ROOT="vendor-moltenvk-fdm"
SRC="$ROOT/MoltenVK"
SPC="$ROOT/SPIRV-Cross"
PATCH_MVK="mvk-patches/moltenvk-fdm.patch"
PATCH_SPC="mvk-patches/spirv-cross-fdm.patch"
SLICES="${MVK_FDM_SLICES:-macos visionos visionossim}"
mkdir -p "$ROOT"

# ---- sources -----------------------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
  echo "  [mvk-fdm] cloning MoltenVK $MVK_VERSION"
  git clone -q --depth 1 --branch "$MVK_VERSION" https://github.com/KhronosGroup/MoltenVK.git "$SRC"
fi
SPC_REV="$(cat "$SRC/ExternalRevisions/SPIRV-Cross_repo_revision")"
if [ ! -d "$SPC/.git" ]; then
  echo "  [mvk-fdm] cloning SPIRV-Cross $SPC_REV (MoltenVK's pin)"
  git clone -q https://github.com/KhronosGroup/SPIRV-Cross.git "$SPC"
  git -C "$SPC" checkout -q "$SPC_REV"
fi

# Idempotent: a patch that already reverse-applies is in place.
apply_patch() {
  local repo="$1" patch="$PWD/$2"
  if git -C "$repo" apply --reverse --check "$patch" 2>/dev/null; then
    echo "  [mvk-fdm] $2 already applied"
  else
    git -C "$repo" apply "$patch"
    echo "  [mvk-fdm] applied $2"
  fi
}
apply_patch "$SPC" "$PATCH_SPC"
apply_patch "$SRC" "$PATCH_MVK"

# ---- external dependencies (SPIRV-Cross, SPIRV-Tools, ...) ------------------
# Rebuilt only when missing or when the SPIRV-Cross patch changed. NOT
# --parallel-build: that mode's `trap "kill 0" EXIT` kills its whole process
# group on the way out — this script included.
SPC_STAMP="$ROOT/.spirv-cross-patch.sha"
SPC_SHA="$(shasum -a 256 "$PATCH_SPC" | awk '{print $1}')"
XCF="$SRC/External/build/Release/SPIRVCross.xcframework"
if [ ! -d "$XCF" ] || [ "$(cat "$SPC_STAMP" 2>/dev/null)" != "$SPC_SHA" ]; then
  echo "  [mvk-fdm] building external dependencies (macOS + visionOS + simulator; ~10 min)"
  ( cd "$SRC" && ./fetchDependencies --macos --visionos --visionossim \
      --spirv-cross-root "$(cd "../SPIRV-Cross" && pwd)" ) > "$ROOT/fetchdeps.log" 2>&1 \
    || { echo "  !! fetchDependencies failed — $ROOT/fetchdeps.log"; exit 1; }
  echo "$SPC_SHA" > "$SPC_STAMP"
fi

# ---- MoltenVK ------------------------------------------------------------------
for s in $SLICES; do
  echo "  [mvk-fdm] make $s"
  ( cd "$SRC" && make "$s" ) > "$ROOT/build-$s.log" 2>&1 \
    || { echo "  !! make $s failed — $ROOT/build-$s.log, $SRC/xcodebuild.log"; exit 1; }
done
PKG="$SRC/Package/Release/MoltenVK"
# (Into a variable first: `nm | grep -q` under pipefail fails on nm's SIGPIPE.)
SYMS="$(nm -gU "$PKG/dynamic/dylib/macOS/libMoltenVK.dylib" 2>/dev/null || true)"
case "$SYMS" in *klMVKFoveationABI*) ;; *)
  echo "  !! built MoltenVK has no klMVKFoveationABI — patch not in the build?"; exit 1 ;; esac

[ -n "${MVK_FDM_NO_STAGE:-}" ] && { echo "  [mvk-fdm] built; not staged (MVK_FDM_NO_STAGE)"; exit 0; }

# ---- stage -------------------------------------------------------------------
# Into the layout tools/mvk_retarget.sh reads from the prebuilt tarball, then
# the same retarget (visionOS floor 1.0, @rpath install name). The fetch stamp
# makes `make mvk` a no-op instead of overwriting the fork with the prebuilt.
if [ "$SLICES" != "macos visionos visionossim" ]; then
  # A partial build: only the host dylib is replaced; the frameworks stay as they were.
  mkdir -p vendor-moltenvk/out/macos
  cp "$PKG/dynamic/dylib/macOS/libMoltenVK.dylib" vendor-moltenvk/out/macos/
  echo "  [mvk-fdm] staged the host dylib only ($SLICES)"
  exit 0
fi
DIST="vendor-moltenvk/dist/MoltenVK/MoltenVK"
rm -rf "$DIST"
mkdir -p "$DIST"
cp -R "$PKG/dynamic" "$PKG/include" "$DIST/"
# MoltenVK's packaging builds its dynamic xcframework from a STAGING copy in Xcode's
# DerivedData that an incremental build does not refresh for visionOS and the
# simulator (measured: after a source change Release-xros held the new framework while
# Package/.../xros-arm64 still held the old one — a hub would have shipped stale code).
# Take those two frameworks straight from this build's products instead.
for dd in "$HOME"/Library/Developer/Xcode/DerivedData/MoltenVKPackaging-*; do
  [ "$(plutil -extract WorkspacePath raw "$dd/info.plist" 2>/dev/null)" = "$PWD/$SRC/MoltenVKPackaging.xcodeproj" ] || continue
  for pair in "Release-xros:xros-arm64" "Release-xrsimulator:xros-arm64_x86_64-simulator"; do
    from="$dd/Build/Products/${pair%%:*}/MoltenVK.framework"
    to="$DIST/dynamic/MoltenVK.xcframework/${pair##*:}/MoltenVK.framework"
    if [ -f "$from/MoltenVK" ] && [ -d "$to" ]; then rm -rf "$to"; cp -R "$from" "$to"; fi
  done
done
touch "vendor-moltenvk/.klepton-fetched-$MVK_VERSION"
git -C "$SRC" rev-parse HEAD > vendor-moltenvk/.klepton-fdm
./tools/mvk_retarget.sh
# Every staged slice must be THIS build (see the staging note above).
for f in vendor-moltenvk/out/macos/libMoltenVK.dylib vendor-moltenvk/out/xros/MoltenVK.framework/MoltenVK \
         vendor-moltenvk/out/xrsim/MoltenVK.framework/MoltenVK; do
  SYMS="$(nm -gU "$f" 2>/dev/null || true)"
  case "$SYMS" in *klMVKFoveationABI*) ;; *) echo "  !! $f has no klMVKFoveationABI — stale slice"; exit 1 ;; esac
done
echo "  [mvk-fdm] foveating MoltenVK staged in vendor-moltenvk/out (KL_FOVEATE=1 to use it)"
