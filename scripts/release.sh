#!/usr/bin/env bash
#
# release.sh — build, sign, notarize, staple, and package TrackSwitch for
# direct (Developer ID) distribution.
#
# One-time setup before first run: store your notarization credentials in the
# keychain so this script can run unattended. Use an app-specific password
# generated at https://appleid.apple.com (NOT your Apple ID password):
#
#   xcrun notarytool store-credentials "trackswitch-notary" \
#     --apple-id "nigel@nigelwarren.com" \
#     --team-id "KMA5YWAK8T" \
#     --password "xxxx-xxxx-xxxx-xxxx"
#
# Then just run:  ./scripts/release.sh
#
set -euo pipefail

# ----- Configuration ---------------------------------------------------------
PROJECT="TrackSwitch.xcodeproj"
SCHEME="TrackSwitch"
APP_NAME="TrackSwitch"
NOTARY_PROFILE="trackswitch-notary"   # must match store-credentials name above
BUILD_DIR="build"
EXPORT_OPTIONS="Config/ExportOptions.plist"

# Resolve repo root so the script works from anywhere.
cd "$(dirname "$0")/.."

ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

echo "==> Cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ----- 1. Archive ------------------------------------------------------------
echo "==> Archiving (Release)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Release archive \
  -archivePath "$ARCHIVE_PATH" \
  | tail -3

# ----- 2. Export with Developer ID -------------------------------------------
echo "==> Exporting Developer ID app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  | tail -3

# ----- 3. Notarize -----------------------------------------------------------
# notarytool needs a zip/dmg/pkg, not a bare .app. Zip preserves the bundle.
echo "==> Zipping for notarization"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting to Apple notary service (this can take a few minutes)"
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

# ----- 4. Staple -------------------------------------------------------------
echo "==> Stapling notarization ticket to the app"
xcrun stapler staple "$APP_PATH"

# ----- 5. Verify -------------------------------------------------------------
echo "==> Verifying Gatekeeper acceptance"
spctl -a -vvv -t install "$APP_PATH"

# ----- 6. Package as DMG -----------------------------------------------------
echo "==> Building DMG"
if command -v create-dmg >/dev/null 2>&1; then
  rm -f "$DMG_PATH"
  create-dmg \
    --volname "$APP_NAME" \
    --app-drop-link 480 170 \
    --icon "$APP_NAME.app" 160 170 \
    --window-size 640 360 \
    "$DMG_PATH" "$APP_PATH"
else
  echo "    create-dmg not found; using hdiutil (no custom layout)."
  echo "    For a nicer installer window: brew install create-dmg"
  hdiutil create -volname "$APP_NAME" -srcfolder "$APP_PATH" \
    -ov -format UDZO "$DMG_PATH"
fi

# Staple the DMG too so it validates offline after download.
echo "==> Stapling the DMG"
xcrun stapler staple "$DMG_PATH"

echo ""
echo "==> Done. Distributable: $DMG_PATH"
