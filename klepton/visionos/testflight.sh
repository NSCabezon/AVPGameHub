#!/bin/bash
# Archive + export (and, on request, upload) an App Store Connect build for
# INTERNAL TestFlight. Called by `run.sh archive` after the runtime, the guest
# translations, ANGLE/MoltenVK and the .xcodeproj are in place — i.e. through
#
#   KLEPTON_TEAM=<team> KLEPTON_BUNDLE_ID=<your.id> ./build_run_vpro.sh hub --archive [--upload]
#   KLEPTON_TEAM=<team> KLEPTON_BUNDLE_ID=<your.id> make testflight          # same thing
#
# and never on its own (it trusts run.sh's environment: KLT_*, PRODUCT, BUNDLE_ID).
#
# What it does, in order, stopping at the first failure:
#   1. xcodebuild archive, Release, generic visionOS device, automatic signing
#      (-allowProvisioningUpdates: Xcode registers the App ID's capabilities and
#      makes the profiles on the team the machine's Xcode account belongs to).
#   2. tf_check.py on the ARCHIVED app (structure, plists, slices, stray files).
#   3. xcodebuild -exportArchive, method app-store-connect, destination EXPORT:
#      an App Store signed .ipa on disk, nothing sent anywhere.
#   4. tf_check.py --distribution on the exported .ipa (adds the signature,
#      entitlement and profile checks that only an App Store signed app has).
#   5. KL_TF_VALIDATE=1: `altool --validate-app` — needs an App Store Connect API
#      key (ASC_KEY_ID / ASC_ISSUER_ID, the .p8 in ~/.appstoreconnect/private_keys)
#      AND the app record to exist. Uploads nothing.
#   6. KL_TF_UPLOAD=1 (--upload): -exportArchive again with destination UPLOAD,
#      which sends the build to App Store Connect with Xcode's signed-in account
#      (or the API key, see AUTH below).
#      Never the default.
#
# ExportOptions sets testFlightInternalTestingOnly: the build can go to the
# team's internal testers and can never be submitted for review or offered to
# external testers. KL_TF_INTERNAL_ONLY=0 lifts that.
set -euo pipefail
cd "$(dirname "$0")"

: "${KLT_NAME:?run through run.sh archive}"
: "${PRODUCT:?run through run.sh archive}"
: "${BUNDLE_ID:?run through run.sh archive}"
# The team is required, not detected: the development certificate's team is a
# guess, and a distribution build signed for the wrong team is a wasted upload.
TEAM="${KLEPTON_TEAM:?set KLEPTON_TEAM to the App Store Connect team id}"
BUILD="${KLEPTON_APP_BUILD:?}"
VERSION="${KLEPTON_APP_VERSION:?}"
OUT="${KL_TF_OUT:-build/testflight}/$KLT_NAME-$VERSION-$BUILD"
ARCHIVE="$OUT/$PRODUCT.xcarchive"
EXPORT="$OUT/export"
DD="build/dd-archive-$KLT_NAME"
# A re-run of the same version + build writes over the same paths; start them
# empty so nothing a previous layout embedded can ride along into this archive.
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$OUT"
LOG="$OUT/xcodebuild.log"

# Who xcodebuild signs and provisions as. Normally the Apple ID signed in under
# Xcode > Settings > Accounts. When xcodebuild cannot see it ("No Accounts" — a
# shell without access to the login keychain, a CI box), an App Store Connect API
# key does the same job: ASC_KEY_ID + ASC_ISSUER_ID, and the .p8 at ASC_KEY_PATH
# or where altool looks for it (~/.appstoreconnect/private_keys/AuthKey_<id>.p8).
# The key needs the Admin role (or App Manager with access to certificates) to
# create the App Store profile and enable capabilities on the App ID.
AUTH=()
if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
  KEYP="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
  [ -f "$KEYP" ] || { echo "!! ASC_KEY_ID is set but there is no key at $KEYP (set ASC_KEY_PATH)"; exit 1; }
  AUTH=(-authenticationKeyPath "$KEYP" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  echo "  signing: App Store Connect API key $ASC_KEY_ID"
fi
: > "$LOG"

echo "[3/5] archiving $PRODUCT $VERSION ($BUILD), $BUNDLE_ID, team ${TEAM}…"
set +e
xcodebuild -project "$PRODUCT.xcodeproj" -scheme "$PRODUCT" -configuration Release \
  -destination 'generic/platform=visionOS' -derivedDataPath "$DD" \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} archive >> "$LOG" 2>&1
RC=$?
set -e
grep -E 'error:|warning: .*(entitlement|provision|sign)|\*\* ARCHIVE' "$LOG" | sort -u | head -40 || true
[ "$RC" = 0 ] || { echo "!! archive FAILED (full log: visionos/$LOG)"; exit 1; }
APP="$ARCHIVE/Products/Applications/$PRODUCT.app"
[ -f "$APP/Info.plist" ] || { echo "!! no app in $ARCHIVE"; exit 1; }

echo "[4/5] checks on the archived app…"
CHECK_RC=0
python3 tf_check.py "$APP" --bundle-id "$BUNDLE_ID" --team "$TEAM" > "$OUT/check-archive.txt" 2>&1 || CHECK_RC=$?
grep -E '^  (FAIL|WARN)|^==' "$OUT/check-archive.txt" || true
[ "$CHECK_RC" = 0 ] || [ -n "${KL_TF_FORCE:-}" ] || {
  echo "!! the archived app fails a check above (full report: visionos/$OUT/check-archive.txt);"
  echo "   KL_TF_FORCE=1 exports anyway"; exit 1; }

# One ExportOptions for both destinations; only `destination` differs.
export_options() {   # <destination> <file>
  cat > "$2" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$1</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>automatic</string>
	<key>testFlightInternalTestingOnly</key><$([ "${KL_TF_INTERNAL_ONLY:-1}" = 0 ] && echo false || echo true)/>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>uploadSymbols</key><true/>
	<!-- The guest frameworks are hand-emitted Mach-O (klepton-ld) with no symbol
	     table to strip; leave every binary byte-for-byte as it was archived. -->
	<key>stripSwiftSymbols</key><false/>
</dict>
</plist>
EOF
}

echo "[5/5] exporting (App Store Connect signing, destination: export — nothing is uploaded)…"
export_options export "$OUT/ExportOptions.plist"
set +e
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} >> "$LOG" 2>&1
RC=$?
set -e
grep -E 'error:|\*\* EXPORT' "$LOG" | sort -u | head -20 || true
IPA="$(ls "$EXPORT"/*.ipa 2>/dev/null | head -1 || true)"
[ "$RC" = 0 ] && [ -n "$IPA" ] || { echo "!! export FAILED (full log: visionos/$LOG)"; exit 1; }

CHECK_RC=0
python3 tf_check.py "$IPA" --bundle-id "$BUNDLE_ID" --team "$TEAM" --distribution \
  --json "$OUT/check-ipa.json" > "$OUT/check-ipa.txt" 2>&1 || CHECK_RC=$?
grep -E '^  (FAIL|WARN)|^==|ipa:|uncompressed' "$OUT/check-ipa.txt" || true

if [ -n "${KL_TF_VALIDATE:-}" ]; then
  if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
    echo "  altool --validate-app (uploads nothing)…"
    xcrun altool --validate-app -f "$IPA" -t visionos \
      --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" 2>&1 | tee "$OUT/validate.txt" | tail -20 || true
  else
    echo "  KL_TF_VALIDATE: no ASC_KEY_ID / ASC_ISSUER_ID in the environment — skipped"
  fi
fi

echo
echo "    archive : visionos/$ARCHIVE"
echo "    ipa     : $(cd "$(dirname "$IPA")" && pwd)/$(basename "$IPA")"
echo "    reports : visionos/$OUT/check-ipa.txt"
[ "$CHECK_RC" = 0 ] || { echo "!! the exported ipa fails a check (see the report) — not uploading"; exit 1; }

if [ -n "${KL_TF_UPLOAD:-}" ]; then
  echo "  UPLOADING to App Store Connect (KL_TF_UPLOAD=1 / --upload)…"
  export_options upload "$OUT/ExportOptions-upload.plist"
  RC=0
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/upload" \
    -exportOptionsPlist "$OUT/ExportOptions-upload.plist" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
    > "$OUT/upload.log" 2>&1 || RC=$?
  grep -E 'error:|Upload|\*\* EXPORT' "$OUT/upload.log" || true
  [ "$RC" = 0 ] || { echo "!! upload FAILED (full log: visionos/$OUT/upload.log)"; exit 1; }
  echo "    uploaded $VERSION ($BUILD); it appears under TestFlight once App Store Connect has processed it"
else
  echo "    not uploaded (add --upload, or KL_TF_UPLOAD=1, to send it to App Store Connect)"
fi
