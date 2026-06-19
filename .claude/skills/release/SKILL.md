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

## Step 5 — Build and publish

```bash
scripts/build-release.sh --publish --notes-file build/release-notes.md
```

This archives, exports (Developer ID), notarizes + staples the app, builds the styled signed DMG, notarizes + staples it, generates the signed appcast (with the notes embedded), creates the `v<MARKETING_VERSION>` GitHub release (auto-flagged prerelease for alpha/beta strings) with the DMG attached, then commits and pushes `website/appcast.xml`. Takes several minutes (two notarization round-trips). All failure-prone work happens **before** anything is published, so a notarization failure aborts cleanly with no release/tag created.

Optional safety: run once **without** `--publish` first to confirm the build + notarize half, then re-run with `--publish`. Costs an extra build cycle.

## Step 6 — Verify the live feed

Pages redeploys on the appcast push (~1 min, CDN cache may lag). Confirm the new build is actually being served:

```bash
curl -sL https://nigelw.github.io/Takes/appcast.xml | grep -E 'sparkle:version|enclosure url'
```

- The top `<sparkle:version>` should equal the new build number.
- The enclosure URL should be `https://github.com/Nigelw/Takes/releases/download/v<MARKETING_VERSION>/Takes.dmg`; confirm it returns HTTP 200:

```bash
curl -sL -o /dev/null -w '%{http_code} %{size_download}\n' \
  "https://github.com/Nigelw/Takes/releases/download/v<MARKETING_VERSION>/Takes.dmg"
```

Report the released version, the release URL, and the live-feed confirmation back to the user.

## Notes

- This is an outward-facing, hard-to-reverse operation. Pause for the user's confirmation at Step 2 (version) and Step 3 (notes) before the irreversible Step 5.
- The definitive end-to-end check (install an older build → "Check for Updates" → verify it updates) is manual and can't be automated here — remind the user it's worth doing after the first release of a new pipeline.
