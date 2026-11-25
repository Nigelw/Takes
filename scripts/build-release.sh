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
#   scripts/build-release.sh --beta-notes notes.md    # prepare a beta DMG and appcast
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
BETA_NOTES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --publish) PUBLISH=1; shift ;;
    --no-commit) NO_COMMIT=1; shift ;;
    --beta-notes)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "--beta-notes needs a Markdown file" >&2; exit 2; }
      BETA_NOTES="$2"
      shift 2
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
die()  { printf '\033[1;31merror: %s\033[0m\n' "$1" >&2; exit 1; }

# ---- Preflight ------------------------------------------------------------
step "Preflight"
if [[ -n "$BETA_NOTES" ]]; then
  [[ $PUBLISH -eq 0 && $NO_COMMIT -eq 0 ]] || die "--beta-notes prepares local artifacts; publish through the beta release workflow"
  [[ -s "$BETA_NOTES" ]] || die "beta notes file is missing or empty: $BETA_NOTES"
else
  [[ -f "$CHANGELOG" ]] || die "changelog not found: $CHANGELOG"
fi
command -v create-dmg >/dev/null || die "create-dmg not found (brew install create-dmg)"
grep -q "$TEAM_ID" <<<"$(security find-identity -v -p codesigning)" || die "Developer ID identity not in keychain"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
  || die "notarization preflight failed for '$NOTARY_PROFILE'"
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

APPCAST="$WEBSITE_DIR/appcast.xml"
if [[ -n "$BETA_NOTES" ]]; then
  [[ "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+b[1-9][0-9]*$ ]] \
    || die "beta marketing versions use X.Y.ZbN (for example 2.10.0b1)"
  BUILD_DIR="$BUILD_DIR/beta/$MARKETING_VERSION"
elif [[ "$MARKETING_VERSION" =~ b[0-9]+$ || "$MARKETING_VERSION" == *-beta* || "$MARKETING_VERSION" == *.beta* ]]; then
  die "use --beta-notes to prepare a beta for the Sparkle beta channel"
fi

if [[ -n "$BETA_NOTES" || $PUBLISH -eq 1 ]]; then
  python3 - "$APPCAST" "$BUILD_NUMBER" <<'PY'
import sys
import xml.etree.ElementTree as ET

appcast, version = sys.argv[1:]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
versions = ET.parse(appcast).findall("./channel/item/sparkle:version", ns)
latest = max(int(item.text) for item in versions)
if not version.isdecimal() or int(version) <= latest:
    sys.exit(f"Release build number must be an integer greater than {latest}.")
PY
fi

mkdir -p "$BUILD_DIR"
RELEASE_NOTES="$BUILD_DIR/release-notes.md"
if [[ -n "$BETA_NOTES" ]]; then
  # Preserve the exact feed this beta is based on for the publish-time check.
  cp "$APPCAST" "$BUILD_DIR/base-appcast.xml"
  APPCAST="$BUILD_DIR/appcast.xml"
  if [[ ! "$BETA_NOTES" -ef "$RELEASE_NOTES" ]]; then
    cp "$BETA_NOTES" "$RELEASE_NOTES"
  fi
else
  step "Reading release notes from changelog"
  python3 scripts/generate-changelog.py --release-notes "$MARKETING_VERSION" "$RELEASE_NOTES"
fi

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
step "Building DMG"
rm -f "$DMG"
DMG_SOURCE="$APP"
DMG_ARGS=(
  --volname "$APP_NAME"
  --window-pos 200 120
  --window-size 600 400
  --icon-size 100
  --icon "$APP_NAME.app" 150 190
  --hide-extension "$APP_NAME.app"
  --app-drop-link 450 190
)
if [[ -n "$BETA_NOTES" ]]; then
  DMG_SOURCE="$BUILD_DIR/dmg-src"
  rm -rf "$DMG_SOURCE"
  mkdir -p "$DMG_SOURCE"
  ditto "$APP" "$DMG_SOURCE/$APP_NAME.app"
  DMG_ARGS+=(--sandbox-safe)
fi
create-dmg "${DMG_ARGS[@]}" "$DMG" "$DMG_SOURCE"

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
APPCAST_ARGS=(--embed-release-notes --download-url-prefix "${GITHUB_DOWNLOAD_BASE}/${TAG}/")
if [[ -n "$BETA_NOTES" ]]; then
  cp "$BUILD_DIR/base-appcast.xml" "$APPCAST"
  APPCAST_ARGS+=(--channel beta --maximum-versions 0 --maximum-deltas 0)
fi
# Prior feed items are preserved because generate_appcast reads and updates the
# existing feed at its -o path. The canonical release history now lives in
# CHANGELOG.md; the appcast is the signed update feed served to Sparkle.
"$GENERATE_APPCAST" \
  "${APPCAST_ARGS[@]}" \
  -o "$APPCAST" \
  "$APPCAST_SRC/"
echo "  wrote $APPCAST"

if [[ -n "$BETA_NOTES" ]]; then
  python3 - "$APPCAST" "$BUILD_NUMBER" "$MARKETING_VERSION" "$GITHUB_DOWNLOAD_BASE/$TAG/$APP_NAME.dmg" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, build, version, url = sys.argv[1:]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
item = ET.parse(path).find(f"./channel/item[sparkle:version='{build}']", ns)
if (item is None
        or item.findtext("sparkle:shortVersionString", namespaces=ns) != version
        or item.findtext("sparkle:channel", namespaces=ns) != "beta"
        or not item.findtext("description", "").strip()):
    sys.exit("The appcast is missing the beta item or embedded notes.")
enclosure = item.find("enclosure")
if enclosure is None or enclosure.get("url") != url or not enclosure.get(f'{{{ns["sparkle"]}}}edSignature'):
    sys.exit("The appcast is missing the signed beta enclosure.")
PY

  step "Done (local beta build)"
  printf '  %s\n' "$APP" "$DMG" "$APPCAST" "$RELEASE_NOTES"
  exit 0
fi

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
  echo "Feed: https://takes.nigelwarren.com/appcast.xml (Pages redeploys on push)"
fi
