---
name: release
description: Cut and publish a new direct-distribution release of Takes — bump the version, draft user-facing release notes, build/notarize/staple, and publish the Sparkle appcast + GitHub release. Use when asked to release, ship a new build, cut a release, or publish an update of Takes.
---

Releases Takes as a notarized, Developer ID–signed DMG with a signed Sparkle appcast served from GitHub Pages, and a matching GitHub release. The heavy lifting (archive → export → notarize → staple → DMG → appcast → release) is done by `scripts/build-release.sh`; this skill drives the human-judgment parts around it (versioning, release notes) and the git ordering.

Background: see [docs/direct-distribution-plan.md](../../../docs/direct-distribution-plan.md). All paths are relative to the repo root (`Takes/`).

## Versioning model (do not deviate)

- **`CURRENT_PROJECT_VERSION`** (build number) — a plain integer, the Sparkle comparison key. **Always +1 every release.** Never reuse or decrease.
- **`MARKETING_VERSION`** (display string, e.g. `2.0a2`) — human-facing. **Must be unique every release**, because the git tag is `v$MARKETING_VERSION` and the script aborts if that tag already exists.
- Both live in `Takes.xcodeproj/project.pbxproj` (two occurrences each, in the Takes target's Debug + Release configs). The `TakesTests` target's `CURRENT_PROJECT_VERSION = 1` must **not** change.

## Step 0 — Preflight

Confirm a safe starting state; stop and tell the user if any fails:

```bash
git rev-parse --abbrev-ref HEAD     # must be: main
git status --porcelain              # must be empty (clean tree)
git pull --ff-only origin main      # sync with origin
```

The script runs its own checks for the Developer ID cert, notary profile, Sparkle key, `create-dmg`, and `gh` auth — don't duplicate those.

## Step 1 — Find the last release

```bash
git describe --tags --abbrev=0 2>/dev/null   # last tag, e.g. v2.0a2
```

Use it as the commit range for notes and to read the current versions:

```bash
grep -m1 'MARKETING_VERSION'        Takes.xcodeproj/project.pbxproj
grep -m1 'CURRENT_PROJECT_VERSION'  Takes.xcodeproj/project.pbxproj
```

## Step 2 — Set the versions

1. **Build number:** read current `CURRENT_PROJECT_VERSION`, add 1. Edit `project.pbxproj`, replacing **both** Takes-target occurrences (use the exact `CURRENT_PROJECT_VERSION = <old>` string with replace-all; the tests target is `= 1`, so it's untouched).
2. **Marketing version:** look at the commits since the last tag and **suggest** a new `MARKETING_VERSION`, then **ask the user to confirm or override**:
   - If the current version is a pre-release (contains a letter, e.g. `2.0a2`), suggest the next in that series (`2.0a3`) or graduating to the stable string (`2.0`).
   - If stable, suggest a semver bump matching the change scope (patch/minor/major).
   - Reject any choice whose tag `v<version>` already exists (`git tag | grep`).
   Edit `project.pbxproj`, replacing both Takes-target `MARKETING_VERSION` occurrences.

Do not commit yet — notes come first so the bump + notes land together.

## Step 3 — Draft user-facing release notes

Gather the changes:

```bash
git log --no-merges <last-tag>..HEAD --pretty='%s%n%b'
```

Write `build/release-notes.md` (build/ is gitignored — the notes are captured in the appcast and the GitHub release, so this file is transient and not committed). Author it as a short Markdown bullet list, applying these rules:

- **Rewrite every entry from the user's perspective.** Never echo commit messages. Describe what changed for someone *using* the app.
- **Drop anything with no user-visible impact** — internal refactors, test/CI changes, dependency bumps, doc edits.
- **One succinct line per entry, no jargon.** No file names, symbols, or implementation detail.

Example shape:

```markdown
- Tracks now keep their order after you reload a session
- Fixed a crash when dropping a folder of audio files
- The transport scrubber is smoother on long takes
```

Then let the user review/edit: show the draft, offer to open it (`${EDITOR:-${VISUAL:-open}} build/release-notes.md`) or take edits in conversation. **Get explicit confirmation** before continuing. The same Markdown is used verbatim for both the Sparkle appcast (rendered to HTML) and the GitHub release body.

## Step 4 — Commit the version bump and push

The tag is created by the script via `gh release create`, which tags the **remote** `main` HEAD — so the bump must be pushed *before* the script runs, or the tag won't include it.

```bash
git add Takes.xcodeproj/project.pbxproj
git commit -m "Bump version to <MARKETING_VERSION> (build <BUILD_NUMBER>)"
git push origin main
```

## Step 5 — Build and publish (defer the push)

```bash
scripts/build-release.sh --publish --no-commit --notes-file build/release-notes.md
```

This archives, exports (Developer ID), notarizes + staples the app, builds the styled signed DMG, notarizes + staples it, generates the signed appcast (with the notes embedded), regenerates `website/changelog.html` from the appcast, and creates the `v<MARKETING_VERSION>` GitHub release (auto-flagged prerelease for alpha/beta strings) with the DMG attached. Takes several minutes (two notarization round-trips). All failure-prone work happens **before** anything is published, so a notarization failure aborts cleanly with no release/tag created.

`--no-commit` is the key to a **single push**: the script stages `website/appcast.xml` + `website/changelog.html` but leaves them uncommitted, so they get folded into one commit with the fresh screenshots and README in Step 8 (instead of a separate appcast push here and another for the website). The GitHub release is live at this point, but the Sparkle feed isn't served until that combined push lands.

Optional safety: run once with **neither** `--publish` nor `--no-commit` first to confirm the build + notarize half, then re-run with both. Costs an extra build cycle.

## Step 6 — Capture screenshots (local, transient)

These screenshots feed the archive (Step 7) and the website/README update (Step 8). Capture two versions of the main window — **with** and **without** the background shadow — into `build/` (gitignored, transient). They're deleted at the end of Step 8.

Launch the build just produced (`build/export/Takes.app` — the notarized release app) with the dedicated screenshot tracks already loaded, then screenshot the window. Use the **computer-use** tools only for the screenshot — loading the files doesn't need them.

1. Quit any running instance (`pkill -x Takes`).
2. Open the app directly with the screenshot tracks as arguments — this loads them into the track slots without any UI navigation, so skip the file picker/drag-and-drop dance entirely. **Always use the tracks in `Private/Audio Samples/Screenshot Tracks/`** for visual consistency across releases:
   ```bash
   APP="$PWD/build/export/Takes.app"
   open -a "$APP" "$PWD/Private/Audio Samples/Screenshot Tracks/"*
   ```
   Wait for the app to appear (`pgrep -x Takes`).
3. `request_access` for `["Takes"]`, then `screenshot` to confirm both tracks show as loaded.
4. Capture **just the Takes window**, twice, into `build/`. Get the window id (and exact bounds) with the helper — no need to eyeball anything:
   ```bash
   read WID X Y W H < <(swift .claude/skills/release/window-info.swift Takes)
   ```
   - **With shadow** (default — includes the window drop shadow):
     ```bash
     screencapture -l"$WID" build/screenshot_shadow.png
     ```
   - **Without shadow** (`-o` omits the shadow — tight crop to the window bounds):
     ```bash
     screencapture -o -l"$WID" build/screenshot_noshadow.png
     ```
   `screencapture` needs **Screen Recording** permission for the process that runs it (System Settings → Privacy & Security → Screen Recording). Granting it to the terminal you release from is a one-time step that makes this the whole capture.
   - **Fallback if `screencapture` is blocked** (e.g. the agent's shell lacks that permission — it fails with `could not create image from window`): take a computer-use `screenshot` with `save_to_disk` (that path has screen access). Crop to the helper's `$X $Y $W $H` rectangle for the no-shadow version; expand each edge by ~60 px (staying within the display) for the shadow version.
5. Quit the app (`pkill -x Takes`).

Confirm both `build/screenshot_shadow.png` and `build/screenshot_noshadow.png` exist.

## Step 7 — Archive the build (local)

Local archival only — `Private/` is gitignored, so nothing is pushed. Both items use the `<MARKETING_VERSION>` filename convention (note the space, matching existing files like `Private/Builds/TrackSwitch v1.0.dmg`).

**7a — Archive the disk image.** Copy the notarized release DMG into `Private/Builds/`:

```bash
cp build/Takes.dmg "Private/Builds/Takes v<MARKETING_VERSION>.dmg"
```

**7b — Archive the screenshot.** Copy the **with-shadow** screenshot into `Private/Screenshots/`:

```bash
cp build/screenshot_shadow.png "Private/Screenshots/Takes v<MARKETING_VERSION>.png"
```

Confirm both artifacts exist and report their paths.

## Step 8 — Update the website and README, then push (single commit)

Refresh the public screenshots, keep the developer-facing README aligned with the current build, and push **everything in one commit** — the appcast + changelog the build script staged in Step 5, plus the screenshots and README. This is the only outward-facing push of the web feed, and it's what makes the new build go live.

1. Copy both screenshots into `website/`, overwriting the previous release's:
   ```bash
   cp build/screenshot_shadow.png   website/screenshot_shadow.png
   cp build/screenshot_noshadow.png website/screenshot_noshadow.png
   ```
   `website/index.html` embeds `screenshot_noshadow.png` (it applies its own frame); the `README.md` marketing header embeds `screenshot_shadow.png`. Both update automatically once the files are replaced.
2. Review the README section **below the marketing header** — everything after the `---` divider (the developer-facing "Current Scope", requirements, behavior notes, operator guide, etc.). Compare it against what actually shipped in this build (use the release notes from Step 3 and the commits since the last tag) and make any edits needed to keep it accurate: features moved in/out of scope, removed constraints, changed keyboard shortcuts, etc. Leave the marketing header (icon, title, tagline, download links) untouched.
3. Commit and push in one shot. `appcast.xml` + `changelog.html` are already staged from Step 5; add the screenshots and README to the same commit:
   ```bash
   git add website/appcast.xml website/changelog.html \
           website/screenshot_shadow.png website/screenshot_noshadow.png README.md
   git commit -m "Release <MARKETING_VERSION> (build <BUILD_NUMBER>): appcast, changelog, screenshots, README"
   git push origin main
   ```
4. Clean up the transient screenshots:
   ```bash
   rm -f build/screenshot_shadow.png build/screenshot_noshadow.png
   ```

## Step 9 — Verify the live feed

The Step 8 push is what publishes the appcast; Pages redeploys on it (~1 min, CDN cache may lag). Confirm the new build is actually being served:

> **If the Pages deploy fails, never `gh run rerun --failed`.** The `pages.yml` workflow uses `upload-pages-artifact@v5` / `deploy-pages@v5`, whose v4+ artifact backend makes artifacts **immutable** — a re-run uploads a *second* `github-pages` artifact instead of overwriting, and `deploy-pages` then aborts with `Multiple artifacts named "github-pages"... count is 2`. GitHub Pages also fails transiently on its own (`Deployment failed, try again later.`), so a failed deploy is common and expected. The correct recovery in both cases is a **fresh** run — `gh workflow run pages.yml --ref main` — which builds one clean artifact. Watch it with `gh run list --workflow pages.yml --limit 1` / `gh run view <id>`. (Seen live during the v2.6 release, 2026-07-02.)

```bash
curl -sL https://nigelw.github.io/Takes/appcast.xml | grep -E 'sparkle:version|enclosure url'
```

- The top `<sparkle:version>` should equal the new build number.
- The enclosure URL should be `https://github.com/Nigelw/Takes/releases/download/v<MARKETING_VERSION>/Takes.dmg`; confirm it returns HTTP 200:

```bash
curl -sL -o /dev/null -w '%{http_code} %{size_download}\n' \
  "https://github.com/Nigelw/Takes/releases/download/v<MARKETING_VERSION>/Takes.dmg"
```

- The changelog page should show the new version at the top:

```bash
curl -sL https://nigelw.github.io/Takes/changelog.html | grep -m1 '<h2>'
```

Report the released version, the release URL, and the live-feed confirmation back to the user.

## Notes

- This is an outward-facing, hard-to-reverse operation. Pause for the user's confirmation at Step 2 (version) and Step 3 (notes) before Step 5 — that's where the GitHub release is created (irreversible), even though the feed doesn't go live until the Step 8 push.
- **Recovery — if you stop between Step 5 and the Step 8 push:** the GitHub release `v<MARKETING_VERSION>` exists and the DMG is uploaded, but the appcast is only *staged*, so Sparkle users aren't offered the update yet — nothing is broken, the release is just dormant. Two ways forward:
  - **Finish it:** complete Steps 6–8 (or, to skip the screenshots, just `git add website/appcast.xml website/changelog.html && git commit && git push origin main`) so the feed goes live, then verify with Step 9.
  - **Abandon it:** delete the release + tag (`gh release delete v<MARKETING_VERSION> --cleanup-tag`), reset the staged web files (`git restore --staged website/appcast.xml website/changelog.html && git checkout -- website/appcast.xml website/changelog.html`), and re-run from Step 5 when ready. The build number was already consumed, so on the next attempt bump `CURRENT_PROJECT_VERSION` again (Step 2) — never reuse it.
- The definitive end-to-end check (install an older build → "Check for Updates" → verify it updates) is manual and can't be automated here — remind the user it's worth doing after the first release of a new pipeline.
