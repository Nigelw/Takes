# Takes beta releases

Publish the notarized DMG as a GitHub prerelease with embedded notes in the existing Sparkle feed. The beta workflow's only Pages change is `website/appcast.xml`. Takes already uses the `beta` Sparkle channel when Settings → Updates → Beta Builds is on. Builds older than the toggle's introduction need a one-time install from GitHub.

## Prepare the source

- Use the release source on up-to-date `main`. In a detached worktree, find the checked-out main with `git worktree list`. Compare local and remote heads before any push. Use that checkout or an explicitly chosen release commit, and keep the release tag pinned to the exact source commit that was built.
- Propose an unused marketing version in the form `X.Y.ZbN` such as `2.10.0b1`. Show the proposed version to the user and wait for explicit confirmation or a replacement before setting it in the project or using it to build a candidate. Check that a replacement is available too.
- After approval, set both Takes-target `MARKETING_VERSION` entries to the approved version. Set both Takes-target `CURRENT_PROJECT_VERSION` entries to the next integer after the highest build number in the project and the live appcast across both channels. Keep the test target's build number. The next stable build also advances this sequence.

## Draft and review the release notes

- Draft standalone Markdown notes from the latest beta in the same series (from the latest stable tag for the first beta). Use the regular release's New, Improved, and Fixed guidance. Keep beta notes out of `CHANGELOG.md`, which supplies the public changelog.
- Show the draft and link to the editable Markdown file. Pause for the user to edit the file or give edits in chat. Read the file again after edits and wait for explicit approval of the resulting text. Version approval and build or signing instructions don't count as notes approval.
- Once the notes are approved, use that exact Markdown for both GitHub and Sparkle. Commit the version bump with the release source, then build from a clean tracked tree and record the commit SHA for the tag. Push that exact source commit to the approved branch before creating the GitHub release. Inspect the pushed commit and tag state first.

## Build and archive locally

Run from the repository root:

```bash
scripts/build-release.sh --beta-notes /absolute/path/to/approved-beta-notes.md
```

The script produces `build/beta/<version>/` with `export/Takes.app`, `Takes.dmg`, `appcast.xml`, `base-appcast.xml`, and `release-notes.md`. Build and notarization are shared with the regular release. Check that the candidate appcast adds exactly one item with the intended build number, display version, `sparkle:channel` of `beta`, embedded notes, and the signed GitHub DMG enclosure. Verify the existing stable and beta entries are retained.

Capture screenshots for the private archive only. Leave the website's screenshot files untouched.

- Launch the exported beta app from the versioned build directory. Set `SCREENSHOT_HOME=$(mktemp -d /private/tmp/takes-release-screenshot.XXXXXX)` per appearance. This isolates the Release app’s playlist and preferences. Launch with `open -n -a "$APP" --env "CFFIXED_USER_HOME=$SCREENSHOT_HOME" "${TRACKS[@]}" --args --appearance-theme "$THEME" --default-window-layout`. Use the audio files from `Private/Audio Samples/Screenshot Tracks/` in the primary checkout when working from a linked worktree.
- For each appearance, get the window ID with `swift .agents/skills/release/window-info.swift Takes` and capture it with `screencapture -l"$WID" "$BETA_OUTPUT/screenshot_${THEME}.png"`. Review both captures. Save to the private archive as `Private/Screenshots/Takes v<version> Light.png` and `Private/Screenshots/Takes v<version> Dark.png`. Copy the notarized DMG to `Private/Builds/Takes v<version>.dmg` and the approved notes to `Private/Builds/Takes v<version> Release Notes.md`. Resolve those paths in the primary checkout so the archive survives worktree removal.

## Publish and verify

1. Check the candidate feed's `base-appcast.xml` against the current `website/appcast.xml` on remote main and confirm the live feed has caught up with that revision. If another release has advanced the feed, reconcile before publishing so its entries cannot be lost. Confirm the beta still has the highest build number.
2. Create the prerelease from the recorded source SHA. Use the already notarized and signed DMG that generated the candidate feed.

   ```bash
   gh release create "$TAG" "$BETA_OUTPUT/Takes.dmg" --repo Nigelw/Takes \
     --target "$BUILT_COMMIT" --title "Takes ${TAG#v}" --prerelease --latest=false \
     --notes-file "$BETA_OUTPUT/release-notes.md"
   ```

3. Download the published DMG and compare its bytes with the local DMG. Then copy the candidate `appcast.xml` to `website/appcast.xml`. Use `git commit --only -m "Publish $TAG beta appcast" -- website/appcast.xml`. Before pushing to main, check that the feed commit contains only `website/appcast.xml`. If GitHub already created the release during a previous attempt, verify its target, prerelease status, and asset against the prepared files, then continue with the feed push. An asset or target mismatch needs to be resolved before advertising it to Sparkle.
4. Wait for Pages to serve the new feed at `https://takes.nigelwarren.com/appcast.xml`. Check the live channel, notes, version, and enclosure, and verify GitHub still lists the stable release as Latest. In an older beta-aware Takes build, check for updates with Beta Builds off and then on. Expect the beta only in the second check. Use a beta-aware build with a lower `CFBundleVersion` for this check.
5. Report the GitHub release, live feed verification, and private archive paths. Report any updater check that remains unverified.
