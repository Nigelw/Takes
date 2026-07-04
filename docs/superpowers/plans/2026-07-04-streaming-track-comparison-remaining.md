# Streaming Track Comparison Remaining Plan

## Current State

Branch: `codex/add-streaming-track-comparison`

The first streaming-track comparison implementation is mostly in place:

- `Open Streaming URL...` is available from the import menu, File menu, and `Cmd+Shift+O`.
- `takes://open-url?url=...` routes through the same modal path as the GUI.
- `takes://open-file?url=file:///...` routes through the file import path.
- Apple Music, Spotify, YouTube, and YouTube Music URLs are accepted.
- Apple Music and Spotify URLs resolve local metadata first, then search YouTube.
- YouTube URLs skip service metadata lookup and download directly.
- The prompt owns lookup/download/opening state. The main track list is not mutated until import succeeds.
- Downloads use yt-dlp with an M4A/AAC-only format selector and import through `PlaybackController.loadImportedFiles(_:)`.
- Downloaded filenames use `Artist – Title.m4a` when metadata is available.
- Streaming downloads are cached under `~/Library/Caches/<bundle-id>/StreamingDownloads/`.
- Cache cleanup exists for track removal, clear all, app quit, and stale launch directories on next prepare.
- Direct YouTube metadata extraction exists via `yt-dlp --dump-single-json --skip-download --no-playlist`.

The latest completed slice adds first-run `yt-dlp_macos` installation:

- `YTDLPManager` checks a manifest-backed app-managed binary first.
- If missing, it downloads `yt-dlp_macos` and `SHA2-256SUMS` from the official yt-dlp GitHub release assets.
- It verifies SHA-256, installs under Application Support, writes `manifest.json`, and falls back to system `yt-dlp` if install fails.
- Focused and full tests passed after these changes.

## Immediate Next Step

Run manual end-to-end QA against the completed implementation, then handle
release/docs prep.

## Execution Status

- [x] Validate yt-dlp install robustness — completed by subagent `Rawls`; focused `StreamingTrackImportTests` run passed.
- [x] Add yt-dlp update UI and weekly auto check — implemented; focused streaming/settings tests passed.
- [x] Add cancellation — implemented; focused cancellation tests passed.
- [x] Improve error model — implemented; focused streaming error tests passed.
- [x] Add About window credits — completed by subagent `Schrodinger`; focused `SessionTests` run passed.
- [ ] Manual end-to-end QA — ready for user testing; full `xcodebuild test` passed after follow-up Settings spinner and yt-dlp staging cleanup fixes.
- [ ] Release/docs prep — pending after implementation.

## Remaining Work

### 1. Validate yt-dlp Install Robustness

Status: complete.

The installer verifies checksum and writes a manifest, and has been hardened for
shipping.

Add:

- Atomic install directory staging, then rename into the version directory.
- Keep the previous manifest/binary if a replacement fails.
- Run `yt-dlp --version` on the installed binary before writing the manifest.
- Store enough manifest data to support future update checks: `version`, `channel`, `installedAt`, `lastCheckedAt`, `checksum`, `executablePath`.
- Surface install failures as the generic friendly streaming error, not raw networking or checksum text.

Tests:

- Failed version check does not write manifest.
- Existing known-good manifest remains active when update/install fails.
- Manifest path outside manager root is rejected.
- Bad checksum does not leave an executable selected.

### 2. Add yt-dlp Update UI And Weekly Auto Check

Status: complete.

The manager installs if missing, checks weekly before streaming imports, and
Settings exposes manual update controls.

Add:

- Add a `yt-dlp` section to `Settings > Updates`.
- Display the automatic update cadence as weekly.
- Display the last yt-dlp update/check timestamp.
- Add an `Update Now` button for user-initiated yt-dlp updates.
- Check automatically at most once per week.
- Check before each streaming import only if `lastCheckedAt` is stale.
- Stable channel by default.
- No nightly channel support.
- Preserve fallback to existing managed binary if update check fails.

Tests:

- Fresh `lastCheckedAt` skips network.
- Stale `lastCheckedAt` attempts update.
- Failed update keeps old executable.
- New verified release switches manifest to the new executable.
- `Settings > Updates` renders the yt-dlp cadence, last update/check value, and `Update Now`.
- `Update Now` triggers the manager and reports success/failure without blocking Sparkle app updates.

### 3. Add Cancellation

Status: complete.

The prompt can now cancel active streaming work.

Implement:

- Let Cancel abort metadata/search/download work.
- Terminate the yt-dlp process if download is active.
- Delete the partially created load directory.
- Return prompt to idle or dismissed state without adding a row.

Tests:

- Cancelling during metadata lookup adds no track.
- Cancelling during download terminates process and removes partial cache.
- Cancelling after download but before import does not leak cache ownership metadata.

### 4. Improve Error Model

Status: complete.

The UI already hides raw yt-dlp errors behind a friendly connection/retry
message. Keep that default, but map expected failures to more useful
user-facing categories.

Add:

- Internal logging for install/search/download failures.
- User-facing categories:
  - unsupported URL
  - no matching YouTube result
  - network/download error
  - no compatible M4A audio stream
  - open/import failed
- Do not add a separate Try Again control. Pressing `Open` again with the same
  URL is the retry path.

Tests:

- Raw yt-dlp stderr never appears in prompt text.
- Missing M4A output maps to a friendly compatible-audio message.
- Pressing `Open` again after failure resubmits the existing URL and status path.

### 5. Add About Window Credits

Status: complete.

Add credits for the app and bundled/managed third-party resources.

Credits text:

```text
Lead designer & developer
Nigel M. Warren <https://nigelwarren.com>

Third-Party Resources
Sparkle <https://sparkle-project.org/>
yt-dlp <https://github.com/yt-dlp/yt-dlp>
```

Suggested owner:

- Existing app/about command wiring in `TakesApp.swift`, or a small custom About
  panel if the default AppKit About panel cannot present this cleanly.

Tests:

- About command exposes the expected credits text.
- Links are correct.

### 6. Manual End-To-End QA

Use a fresh app data state for at least one pass, so yt-dlp install is exercised.

Test matrix:

- GUI `Cmd+Shift+O` with YouTube URL.
- `open 'takes://open-url?url=https://www.youtube.com/watch?v=XPL_qGqSJxA'`.
- Apple Music track URL.
- Spotify track URL.
- YouTube Music URL.
- Invalid URL.
- Supported-service URL with no match.
- Remove one streaming track and confirm its load directory is deleted.
- Clear all and confirm all current-session streaming cache files are deleted.
- Quit and relaunch; stale launch directories should be removed on next prepare.
- Offline or blocked network first-run install should show a friendly error and add no row.

Check actual install/cache paths:

```text
~/Library/Application Support/com.nigelwarren.Takes/Tools/yt-dlp/
~/Library/Caches/com.nigelwarren.Takes/StreamingDownloads/
```

### 7. Release/Docs Prep

Before shipping:

- Mention in release notes that Takes can download and run yt-dlp.
- Include yt-dlp license notice or link in app/help/release notes.
- Revisit whether the app should expose a settings panel entry for:
  - yt-dlp version
  - update now
  - reset downloader
  - use system yt-dlp
- Legal review remains recommended before shipping this to users.

## Known Non-Goals For This Feature Slice

- No Odesli/Songlink dependency.
- No OAuth/API integration with Spotify or Apple Music.
- No playlists, albums, or batch streaming imports.
- No candidate picker UI unless auto-matching proves unreliable.
- No ffmpeg dependency yet.
- No "highest possible YouTube audio" path beyond M4A/AAC-compatible audio.

## Verification Commands

Use focused tests during each slice:

```sh
xcodebuild test -project Takes.xcodeproj -scheme Takes -destination 'platform=macOS' -derivedDataPath /private/tmp/takes-streaming-focused-dd CODE_SIGNING_ALLOWED=NO -only-testing:TakesTests/StreamingTrackImportTests
```

Run the full suite before handoff or commit:

```sh
xcodebuild test -project Takes.xcodeproj -scheme Takes -destination 'platform=macOS' -derivedDataPath /private/tmp/takes-streaming-full-dd CODE_SIGNING_ALLOWED=NO
```
