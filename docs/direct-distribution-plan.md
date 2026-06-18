# Direct Distribution Plan — Takes

Goal: ship Takes outside the Mac App Store as a **Developer ID–signed, notarized, stapled
DMG**, with **Sparkle auto-updates** served from **GitHub Releases**.

Context (as of 2026-06-18):
- Bundle ID: `com.nigelwarren.Takes` · Team: `KMA5YWAK8T`
- Cert installed: `Developer ID Application: NIGEL MENDELSOHN WARREN (KMA5YWAK8T)` ✅
- Toolchain: Xcode 26.3 + `notarytool` ✅
- Repo: `github.com/Nigelw/Takes`
- Sparkle integrated; `SUPublicEDKey` present, no `SUFeedURL` yet

Work through the steps in order. Each is self-contained.

---

## Phase 1 — Credentials (one-time)

### Step 1.1 — Create an app-specific password
1. Go to https://appleid.apple.com → **Sign-In & Security → App-Specific Passwords**.
2. Generate one named e.g. `notary-profile`. Copy the value (shown once).

### Step 1.2 — Store notarization credentials in the keychain
```sh
xcrun notarytool store-credentials "notary-profile" \
  --apple-id "nigel@nigelwarren.com" \
  --team-id "KMA5YWAK8T" \
  --password "<app-specific-password>"
```
Verify: `xcrun notarytool history --keychain-profile "notary-profile"` (empty history = auth works).

### Step 1.3 — Confirm you have the Sparkle EdDSA private key
The public key (`SUPublicEDKey`) is already in the Info.plist. The matching **private** key must
live in your login keychain (item: `https://sparkle-project.org`). Check:
```sh
security find-generic-password -s "https://sparkle-project.org" 2>/dev/null \
  && echo "Sparkle private key present" || echo "MISSING — see note"
```
If MISSING: you cannot sign updates that existing installs will accept. Locate the original key
(from when `SUPublicEDKey` was generated) and import it, or accept that you must reset the key
(only safe before any public release). Sparkle's `generate_keys` tool manages this.

---

## Phase 2 — Project configuration fixes

### Step 2.1 — Turn on Hardened Runtime (notarization blocker)
In `Takes.xcodeproj/project.pbxproj`, both the Debug and Release build configs for the Takes
target have `ENABLE_HARDENED_RUNTIME = NO`. Set the **Release** config to `YES`.
(Xcode UI: Takes target → Signing & Capabilities → add **Hardened Runtime**.)

### Step 2.2 — Add an entitlements file
Create `Config/Takes.entitlements` and set `CODE_SIGN_ENTITLEMENTS = Config/Takes.entitlements`
for the Takes target. Minimum contents for a non-sandboxed Developer ID app that uses Sparkle
and sends Apple Events:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
```
Notes:
- You are **not** sandboxed (no sandbox entitlement today). Direct distribution does not require
  the sandbox, so keep it off unless you want it — adding it later is a bigger change.
- Sparkle 2.x with Hardened Runtime needs **no extra entitlements** on the host app for the
  non-sandboxed case; its XPC services ship pre-signed inside the framework.

### Step 2.3 — Fix the version strings
`Config/Takes-Info.plist` hardcodes `CFBundleShortVersionString = 1.0` and `CFBundleVersion = 1`,
ignoring `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`. Change them to use the build settings:
```xml
<key>CFBundleShortVersionString</key>
<string>$(MARKETING_VERSION)</string>
<key>CFBundleVersion</key>
<string>$(CURRENT_PROJECT_VERSION)</string>
```
**Versioning decision (settled):**
- **`CFBundleVersion` / `CURRENT_PROJECT_VERSION`** is the update-ordering key. It must be a plain
  monotonic integer (Apple requires period-separated integers; Sparkle compares `sparkle:version`,
  which maps to this). **Increment it by 1 for every distributable build** — never reuse or
  decrease it. Currently `3`; the next distributed build is `4`, then `5`, …
- **`CFBundleShortVersionString` / `MARKETING_VERSION`** stays `2.0a2`. This is display-only under
  the default (build-number) comparison config, so the `a2` suffix is fine here and has no effect
  on update logic. Do **not** put `2.0a2` in `CFBundleVersion` — it's an invalid build number there.
- Keep Sparkle on the **default build-number comparison** (don't switch it to compare the short
  version string).
- **No prerelease channels for now.** Every release goes out on the single main/stable channel —
  all users receive each build. Do not tag appcast items with `<sparkle:channel>` and do not
  implement `allowedChannels(for:)`. (Revisit beta channels in a future release only if the
  overhead is worth it.)

### Step 2.4 — Add the Sparkle feed URL
Add to `Config/Takes-Info.plist`:
```xml
<key>SUFeedURL</key>
<string>https://nigelw.github.io/Takes/appcast.xml</string>
```
(This assumes GitHub Pages — see Step 5.1. If you instead commit the appcast to the repo, use the
`raw.githubusercontent.com/Nigelw/Takes/main/appcast.xml` URL.)

---

## Phase 3 — Build & export a Developer ID app

### Step 3.1 — Create `Config/ExportOptions.plist`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>KMA5YWAK8T</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
```

### Step 3.2 — Archive and export
```sh
rm -rf build/Takes.xcarchive build/export
xcodebuild -project Takes.xcodeproj -scheme Takes \
  -configuration Release -archivePath build/Takes.xcarchive archive

xcodebuild -exportArchive -archivePath build/Takes.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist Config/ExportOptions.plist
```
Result: `build/export/Takes.app`, signed with Developer ID + Hardened Runtime.

### Step 3.3 — Verify the signature
```sh
codesign --verify --deep --strict --verbose=2 build/export/Takes.app
codesign -dvvv build/export/Takes.app 2>&1 | grep -E "Authority|Runtime|TeamIdentifier"
```
Expect `Authority=Developer ID Application: ...` and the `runtime` flag set.

---

## Phase 4 — Notarize app, package styled DMG, staple

Notarization operates on **code** (the app + its nested Sparkle framework/XPC services), keyed by
CDHash; stapling attaches the ticket to a file for **offline** Gatekeeper checks. Stapling only the
DMG leaves the extracted app without its own ticket, so we **notarize and staple the app first**,
then build the DMG from the stapled app, then notarize and staple the DMG too. Result: both
artifacts work online or offline, whether launched from the DMG or after copying to /Applications.

### Step 4.1 — Notarize the app
`notarytool` can't take a bare `.app`, so zip it first (preserving the bundle with `--keepParent`):
```sh
ditto -c -k --keepParent build/export/Takes.app build/Takes.zip
xcrun notarytool submit build/Takes.zip \
  --keychain-profile "notary-profile" --wait
```
If rejected: `xcrun notarytool log <submission-id> --keychain-profile "notary-profile"`.

### Step 4.2 — Staple the app
The ticket now exists in Apple's DB (keyed by CDHash); `stapler` fetches and attaches it:
```sh
xcrun stapler staple build/export/Takes.app
xcrun stapler validate build/export/Takes.app
```

### Step 4.3 — Build the styled DMG (create-dmg)
(Delete the stale `build/TrackSwitch.dmg` — leftover from the old app name.) Build from the
**already-stapled** app so the DMG ships a ticketed app. Adjust positions/size to taste; add
`--background <png>` once you have artwork.
```sh
rm -f build/TrackSwitch.dmg build/Takes.dmg
create-dmg \
  --volname "Takes" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "Takes.app" 150 190 \
  --hide-extension "Takes.app" \
  --app-drop-link 450 190 \
  build/Takes.dmg \
  build/export/Takes.app
```
(Optional but recommended: sign the DMG with your Developer ID before notarizing —
`codesign --sign "Developer ID Application: NIGEL MENDELSOHN WARREN (KMA5YWAK8T)" build/Takes.dmg`.)

### Step 4.4 — Notarize and staple the DMG
```sh
xcrun notarytool submit build/Takes.dmg \
  --keychain-profile "notary-profile" --wait
xcrun stapler staple build/Takes.dmg
xcrun stapler validate build/Takes.dmg
```

### Step 4.5 — Gatekeeper smoke test
```sh
spctl -a -t open --context context:primary-signature -vvv build/Takes.dmg
```
Best real test: copy the DMG to a different Mac (or a fresh user account), open, drag to
/Applications, launch — confirm no Gatekeeper warning. Try once with networking **off** to confirm
the stapled tickets work offline.

---

## Phase 5 — Distribute & wire up auto-updates (GitHub Releases)

### Step 5.1 — Hosting: GitHub Pages serving the `website/` folder (DONE)
The appcast is served from **GitHub Pages**, published from the repo's **`website/`** folder via a
**GitHub Actions** workflow (modeled on Shpigford/clearly's `website/` layout). Live at
`https://nigelw.github.io/Takes/`, so `website/appcast.xml` → `https://nigelw.github.io/Takes/appcast.xml`
(matches the `SUFeedURL` from Step 2.4). The DMG is **not** on Pages — it's a GitHub **release asset**.

How it works:
- `.github/workflows/pages.yml` uploads **only `website/`** as the Pages artifact (`path: './website'`)
  on pushes to `main` that touch `website/**` (or the workflow), plus manual `workflow_dispatch`.
  Because only `website/` is published, internal `docs/` and source stay off the site.
- Pages **Source** is set to **GitHub Actions** (repo Settings → Pages). With the Actions source the
  files are served as-is — **no Jekyll**, so no `.nojekyll` file is needed. (`.nojekyll` only matters
  for the classic "Deploy from a branch" source or the Jekyll workflow.)
- To publish a new/updated appcast, commit it into `website/` on `main` and push — the workflow
  redeploys automatically (CDN cache may lag a minute or two).

Note: the repo is **public**, so files under `docs/` remain viewable directly on github.com even
though they're not on the published site. Pages scoping is about the website, not secrecy.

`website/` currently holds `icon.png` and `screenshot.jpg`; `appcast.xml` (and an optional
`index.html` landing page) are added below.

### Step 5.2 — Generate / update the signed appcast
Sparkle's `generate_appcast` signs each update with your EdDSA key and writes `appcast.xml`.
Point its enclosure URLs at the GitHub release download URL:
```
https://github.com/Nigelw/Takes/releases/download/<tag>/Takes.dmg
```
Run (path to the tool is inside the Sparkle SwiftPM checkout/artifacts):
```sh
./bin/generate_appcast --download-url-prefix \
  "https://github.com/Nigelw/Takes/releases/download/v2.0/" \
  build/   # a dir containing the notarized DMG
```
Review the generated `appcast.xml`, then publish it by writing it to `website/appcast.xml`,
committing on `main`, and pushing — the Pages workflow (Step 5.1) redeploys it automatically.

### Step 5.3 — Create the GitHub release
```sh
gh release create v2.0 build/Takes.dmg \
  --repo Nigelw/Takes \
  --title "Takes 2.0" --notes "..."
```
Confirm the asset download URL matches what's in `appcast.xml`.

### Step 5.4 — Verify the update flow
Install the *previous* version, then trigger "Check for Updates" in Takes — confirm it sees,
downloads, verifies (EdDSA), and installs the new build.

---

## Phase 6 — Make it repeatable (optional)
Once the manual flow works once, fold Steps 3–4 into `scripts/build-release.sh` (archive →
export → dmg → notarize → staple) so each release is one command. Consider a GitHub Actions
workflow later (needs cert + notary creds as encrypted secrets).

---

## Quick blocker checklist
- [ ] Notary credentials stored (1.2)
- [ ] Sparkle private key present (1.3)
- [ ] Hardened Runtime = YES (2.1)
- [ ] Entitlements file added (2.2)
- [ ] Version strings use build-setting vars (2.3)
- [ ] SUFeedURL set (2.4)
- [ ] ExportOptions.plist created (3.1)
- [ ] Signature verifies with Developer ID + runtime (3.3)
- [ ] App notarized + stapled (4.1–4.2)
- [ ] Styled DMG built from stapled app, notarized + stapled (4.3–4.4)
- [x] Pages serving website/ via Actions workflow (5.1)
- [x] Appcast signed & published, release created (5.2–5.3) — v2.0a2 / build 3
