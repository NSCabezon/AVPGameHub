#!/bin/bash
# Release build of AVP Game Hub, wrapped as an .app bundle (ad-hoc signed) in build/ beside Package.swift.
#   scripts/make-app.sh && open "build/AVP Game Hub.app"
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product AVPGameHub
BIN="$(swift build -c release --show-bin-path)"
APP="build/AVP Game Hub.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AVPGameHub" "$APP/Contents/MacOS/AVPGameHub"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
VERSION="$(git describe --always --dirty 2>/dev/null || echo dev)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AVP Game Hub</string>
  <key>CFBundleDisplayName</key><string>AVP Game Hub</string>
  <key>CFBundleExecutable</key><string>AVPGameHub</string>
  <key>CFBundleIdentifier</key><string>local.avpgamehub.mac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>es</string></array>
</dict></plist>
PLIST
# Meta's ovr-platform-util is proprietary: never committed, only bundled from a local copy if one
# exists, and only when it carries Meta's signature (team HXH6UQBHD4). Looked for in order:
# $AVPGH_LOCAL/tools, <repo>/local/tools (gitignored), the configured path, ~/Downloads.
REPO="$(git rev-parse --show-toplevel 2>/dev/null || (cd .. && pwd))"
CONFIGURED="$(defaults read local.avpgamehub.mac metaToolPath 2>/dev/null || true)"
TOOL=""
for c in ${AVPGH_LOCAL:+"$AVPGH_LOCAL/tools/ovr-platform-util"} "$REPO/local/tools/ovr-platform-util" \
         ${CONFIGURED:+"$CONFIGURED"} "$HOME/Downloads/ovr-platform-util"; do
  [ -f "$c" ] || continue
  if codesign --verify --strict "$c" 2>/dev/null \
     && [ "$(codesign -dv --verbose=2 "$c" 2>&1 | sed -n 's/^TeamIdentifier=//p')" = "HXH6UQBHD4" ]; then
    TOOL="$c"; break
  fi
  echo "skipped $c: not signed by Meta (HXH6UQBHD4)" >&2
done
if [ -n "$TOOL" ]; then
  mkdir -p "$APP/Contents/Resources/Tools"
  cp -X "$TOOL" "$APP/Contents/Resources/Tools/ovr-platform-util"   # -X: no quarantine/xattrs
  chmod 755 "$APP/Contents/Resources/Tools/ovr-platform-util"
  echo "bundled Meta's tool from $TOOL"
else
  echo "no Meta-signed ovr-platform-util found locally; not bundled (the app helps you get it: Status › Get Meta's tool opens Meta's page and picks the download up from ~/Downloads)"
fi
codesign --force --sign - "$APP" >/dev/null
echo "built: $PWD/$APP"
