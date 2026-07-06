#!/usr/bin/env bash
#
# build-release.sh — one-command direct-distribution release for Takes.
#
# Pipeline (see docs/direct-distribution-plan.md):
#   archive → export (Developer ID) → verify → notarize app → staple app
#   → styled DMG → sign DMG → notarize DMG → staple DMG → generate signed appcast
#   → [--publish] create GitHub release + commit/push appcast
#
# By default this builds and notarizes everything LOCALLY and stops before
# anything outward-facing. Pass --publish to also create the GitHub release and
# push the updated appcast (this is the irreversible part).
#
# Prereqs (one-time): see Phase 1 of the plan.
#   - Developer ID Application cert in the keychain
#   - notarytool keychain profile (default: "notary-profile")
#   - Sparkle EdDSA private key in the login keychain
#   - create-dmg installed (brew install create-dmg)
#   - gh authenticated (only needed for --publish)
#
# Usage:
#   scripts/build-release.sh                          # build + notarize, no publish
#   scripts/build-release.sh --publish                # also create release + push appcast
#
# Release notes are extracted from CHANGELOG.md for the current MARKETING_VERSION
# and used for both the Sparkle appcast and GitHub release body.
# --no-commit          With --publish, create the release and stage
#                      appcast.xml + changelog.html but do NOT commit/push them.
#                      Lets the caller fold them into a single combined commit
#                      (e.g. alongside updated screenshots + README).

set -euo pipefail

# ---- Config ---------------------------------------------------------------
PROJECT="Takes.xcodeproj"
SCHEME="Takes"
APP_NAME="Takes"
TEAM_ID="KMA5YWAK8T"
SIGN_IDENTITY="Developer ID Application: NIGEL MENDELSOHN WARREN (${TEAM_ID})"
NOTARY_PROFILE="notary-profile"
REPO="Nigelw/Takes"
GITHUB_DOWNLOAD_BASE="https://github.com/${REPO}/releases/download"
WEBSITE_DIR="website"
BUILD_DIR="build"
DEFAULT_BRANCH="main"
CHANGELOG="CHANGELOG.md"

# ---- Locate project root --------------------------------------------------
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PUBLISH=0
NO_COMMIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --publish) PUBLISH=1; shift ;;
    --no-commit) NO_COMMIT=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
die()  { printf '\033[1;31merror: %s\033[0m\n' "$1" >&2; exit 1; }

# ---- Preflight ------------------------------------------------------------
step "Preflight"
[[ -f "$CHANGELOG" ]] || die "changelog not found: $CHANGELOG"
command -v create-dmg >/dev/null || die "create-dmg not found (brew install create-dmg)"
grep -q "$TEAM_ID" <<<"$(security find-identity -v -p codesigning)" || die "Developer ID identity not in keychain"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notary profile '$NOTARY_PROFILE' not usable (see Phase 1.2)"
security find-generic-password -s "https://sparkle-project.org" >/dev/null 2>&1 \
  || die "Sparkle EdDSA private key missing from keychain (see Phase 1.3)"
if [[ $PUBLISH -eq 1 ]]; then
  command -v gh >/dev/null || die "gh not found (needed for --publish)"
  gh auth status >/dev/null 2>&1 || die "gh not authenticated (needed for --publish)"
fi

GENERATE_APPCAST="$(find "$HOME/Library/Developer/Xcode/DerivedData" "$ROOT/.derived-data" \
  -path "*sparkle*bin/generate_appcast" -type f 2>/dev/null | head -1 || true)"
[[ -n "$GENERATE_APPCAST" ]] || die "generate_appcast not found; build once in Xcode to resolve Sparkle"

# ---- Read version from the project ---------------------------------------
step "Reading version"
SETTINGS="$(xcodebuild -project "$PROJECT" -target "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null)"
MARKETING_VERSION="$(awk -F' = ' '/ MARKETING_VERSION =/{print $2; exit}' <<<"$SETTINGS")"
BUILD_NUMBER="$(awk -F' = ' '/ CURRENT_PROJECT_VERSION =/{print $2; exit}' <<<"$SETTINGS")"
[[ -n "$MARKETING_VERSION" && -n "$BUILD_NUMBER" ]] || die "could not read version from project"
TAG="v${MARKETING_VERSION}"
echo "  marketing version : $MARKETING_VERSION"
echo "  build number      : $BUILD_NUMBER  (Sparkle comparison key)"
echo "  release tag       : $TAG"

mkdir -p "$BUILD_DIR"
RELEASE_NOTES="$BUILD_DIR/release-notes.md"
step "Reading release notes from changelog"
python3 scripts/generate-changelog.py --release-notes "$MARKETING_VERSION" "$RELEASE_NOTES"

if [[ $PUBLISH -eq 1 ]] && gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  die "release $TAG already exists — bump CURRENT_PROJECT_VERSION / MARKETING_VERSION first"
fi

ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$APP_NAME.app"
DMG="$BUILD_DIR/$APP_NAME.dmg"
ZIP="$BUILD_DIR/$APP_NAME.zip"

# ---- Archive + export -----------------------------------------------------
step "Archiving (Release)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" archive

step "Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" -exportOptionsPlist Config/ExportOptions.plist

step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# Capture once, then grep the variable: piping codesign into `grep -q` races
# under `set -o pipefail` — grep exits on first match and closes the pipe, so
# codesign gets SIGPIPE and the pipeline "fails" even though the match succeeded.
sig_info=$(codesign -dvv "$APP" 2>&1)
grep -q "Developer ID Application" <<<"$sig_info" || die "app not Developer ID signed"
grep -q "flags=.*runtime" <<<"$sig_info" || die "hardened runtime not enabled"

# ---- Notarize + staple the app -------------------------------------------
step "Notarizing app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

step "Stapling app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# ---- Build + sign + notarize + staple the DMG ----------------------------
step "Building styled DMG"
rm -f "$DMG"
create-dmg \
  --volname "$APP_NAME" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "$APP_NAME.app" 150 190 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 450 190 \
  "$DMG" "$APP"

step "Signing DMG"
codesign --force --sign "$SIGN_IDENTITY" "$DMG"

step "Notarizing DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

step "Stapling DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

step "Gatekeeper check"
spctl -a -t open --context context:primary-signature -vvv "$DMG"

# ---- Generate signed appcast ---------------------------------------------
step "Generating signed appcast"
APPCAST_SRC="$BUILD_DIR/appcast-src"
rm -rf "$APPCAST_SRC"; mkdir -p "$APPCAST_SRC"
cp "$DMG" "$APPCAST_SRC/$APP_NAME.dmg"
# Release notes: generate_appcast reads notes from a file with the same
# basename as the archive ($APP_NAME.md) and renders the Markdown to HTML.
# --embed-release-notes is REQUIRED: without it, a .md notes file is emitted as
# an external <sparkle:releaseNotesLink> to a URL we never host (404 in the
# updater + blank changelog). Embedding inlines the notes as <description>, so
# Sparkle can show the notes without depending on a separately hosted notes URL.
cp "$RELEASE_NOTES" "$APPCAST_SRC/$APP_NAME.md"
echo "  using release notes from $CHANGELOG"
# Prior feed items are preserved because generate_appcast reads and updates the
# existing feed at its -o path. The canonical release history now lives in
# CHANGELOG.md; the appcast is the signed update feed served to Sparkle.
"$GENERATE_APPCAST" \
  --embed-release-notes \
  --download-url-prefix "${GITHUB_DOWNLOAD_BASE}/${TAG}/" \
  -o "$WEBSITE_DIR/appcast.xml" \
  "$APPCAST_SRC/"
echo "  wrote $WEBSITE_DIR/appcast.xml"

step "Generating changelog page"
python3 scripts/generate-changelog.py "$CHANGELOG" "$WEBSITE_DIR/changelog.html"

# ---- Publish (outward-facing) --------------------------------------------
if [[ $PUBLISH -eq 0 ]]; then
  step "Done (local build only)"
  cat <<EOF
Built and notarized:
  $DMG
  $WEBSITE_DIR/appcast.xml  (enclosure → ${GITHUB_DOWNLOAD_BASE}/${TAG}/$APP_NAME.dmg)
  $WEBSITE_DIR/changelog.html

Nothing was published. To create the GitHub release and publish the appcast, re-run with:
  scripts/build-release.sh --publish
EOF
  exit 0
fi

step "Creating GitHub release $TAG"
RELEASE_ARGS=(--repo "$REPO" --title "$APP_NAME $MARKETING_VERSION")
[[ "$MARKETING_VERSION" =~ [a-zA-Z] ]] && RELEASE_ARGS+=(--prerelease)  # alpha/beta strings
RELEASE_ARGS+=(--notes-file "$RELEASE_NOTES")
gh release create "$TAG" "$DMG" "${RELEASE_ARGS[@]}"

step "Verifying release asset"
URL="${GITHUB_DOWNLOAD_BASE}/${TAG}/$APP_NAME.dmg"
DMG_SIZE="$(stat -f%z "$DMG")"
ASSET_SIZE="$(curl -sL -o /dev/null -w '%{size_download}' "$URL")"
[[ "$DMG_SIZE" == "$ASSET_SIZE" ]] || die "uploaded asset size ($ASSET_SIZE) != local DMG ($DMG_SIZE)"

git add "$WEBSITE_DIR/appcast.xml" "$WEBSITE_DIR/changelog.html"
if [[ $NO_COMMIT -eq 1 ]]; then
  step "Staged appcast + changelog (--no-commit: not committing/pushing)"
  echo "  $WEBSITE_DIR/appcast.xml and $WEBSITE_DIR/changelog.html are staged."
  echo "  Caller must commit + push (combine with screenshots/README into one commit)."
  step "Released $TAG (appcast not yet live)"
  echo "Feed goes live once the staged appcast is pushed."
else
  step "Publishing appcast + changelog (commit + push)"
  git commit -m "Publish $MARKETING_VERSION (build $BUILD_NUMBER): appcast + changelog"
  git push origin "$DEFAULT_BRANCH"
  step "Released $TAG"
  echo "Feed: https://nigelw.github.io/Takes/appcast.xml (Pages redeploys on push)"
fi
