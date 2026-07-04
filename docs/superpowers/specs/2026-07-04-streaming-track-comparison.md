# Streaming Track Comparison Design

## Goal

Allow a user to paste an Apple Music, Spotify, YouTube, or YouTube Music URL,
resolve it to a playable YouTube URL when needed, download that audio through
yt-dlp, and compare it as a normal Takes track.

This should feel like adding a track, not like opening a separate downloader.
The lookup and download state belongs in the `Open Streaming URL` prompt. The
main track list should only change after the downloaded audio has imported as a
real Takes track.

## Current Repo Fit

- File imports converge on `PlaybackController.loadImportedFiles(_:)`.
- Loaded rows are `ComparisonSession.tracks` rendered by `ContentView.trackTimelineSection`.
- Track removal goes through `PlaybackController.removeTrack(_:)`; removing all tracks goes
  through `clearTracks()`.
- Takes is currently a non-sandboxed Developer ID app. `Config/Takes.entitlements`
  contains Apple Events only, with no app sandbox entitlement.
- Audio loading is `AVAudioFile` based. Files downloaded from YouTube must be readable by
  AVFoundation, or they need a decode/transcode step before import.

## Proposed User Flow

1. User chooses `File > Open Streaming URL...` or the `+` menu equivalent.
2. The prompt remains open and advances through explicit states:
   - `Reading Apple Music track info...`
   - `Reading Spotify track info...`
   - `Searching YouTube for <artist> <title>...`
   - `Found YouTube match: <title>`
   - `Preparing downloader...`
   - `Downloading audio... 42%`
   - `Opening audio...`
3. On success, the prompt closes and the imported audio appears as a normal
   track row.
4. On failure, the prompt stays open and shows the error. No row is added to the
   main Takes window.

## Platform Metadata And YouTube Matching

Do not depend on Odesli/Songlink. The public API is deprecated, and live probes
showed that it no longer reliably returns YouTube links for Spotify or Apple
Music inputs.

For the first slice:

- YouTube and YouTube Music URLs are already a downloadable match. Skip metadata
  lookup and pass the URL directly to yt-dlp.
- Apple Music track URLs use the public iTunes lookup endpoint with the `i=`
  track ID from the URL. This returns title, artist, and duration for many
  catalog links without app-managed OAuth.
- Spotify track URLs use Spotify's public embed page for the track ID. The
  embedded `__NEXT_DATA__` payload contains title, artist, and duration.
- YouTube search uses yt-dlp's `ytsearch5:<artist> <title> audio` extractor with
  `--dump-single-json --flat-playlist --skip-download`.
- Takes scores candidates locally by title similarity, artist/channel similarity,
  duration distance, and penalties for obvious variant terms such as live, remix,
  cover, karaoke, slowed, sped up, lyric, and lyrics.

Do not make candidate selection mandatory for MVP. Auto-pick when a candidate
clears the confidence threshold. If no candidate clears it, leave the prompt open
with a recoverable error and add no track row.

## yt-dlp Embedding And Updates

### Technical Recommendation

Do not place yt-dlp inside `Takes.app` for the first shipping version.

Instead, build a `YTDLPManager` that installs an app-managed copy into:

```text
~/Library/Application Support/com.nigelwarren.Takes/Tools/yt-dlp/<version>/yt-dlp_macos
```

The manager should:

- Download the official macOS standalone `yt-dlp_macos` release asset.
- Verify the release checksum/signature before marking it usable.
- Store a small manifest with version, channel, install date, checksum, and path.
- Check for updates at most once per day, and before each streaming download if
  the installed copy is missing or older than a chosen age.
- Replace binaries atomically by installing into a new version directory and then
  switching the manifest.
- Keep the previous known-good binary until the replacement has passed
  `yt-dlp --version`.

Do not rely solely on `yt-dlp -U` as the app's update mechanism. yt-dlp supports
self-update for release binaries, but Takes should own verification, atomic
replacement, and rollback. `-U` can still be exposed as a manual repair action if
we decide to trust yt-dlp's updater behavior for official channels.

Use the `nightly` channel only if we are comfortable with occasional regressions.
The yt-dlp README currently says nightly is recommended for regular users because
stable can lag behind site changes. For Takes, the default should probably be
stable plus a user-visible `Use yt-dlp nightly` troubleshooting option.

### Legal Recommendation

This is not legal advice, but the risk profile is clear enough to shape the
engineering plan.

- yt-dlp source is Unlicense.
- The official PyInstaller standalone executables include GPLv3+ licensed code,
  so those combined release binaries are GPLv3+.
- Bundling the PyInstaller binary inside a closed-source app bundle is the
  highest-risk path and should not be done without accepting GPL obligations or
  getting legal review.
- Downloading the official binary after install, storing it outside the app
  bundle, invoking it as a separate process, and displaying its license notices is
  a cleaner separation. It still deserves legal review, but it avoids shipping the
  GPL binary as part of the signed Takes bundle.
- The app should show a first-run disclosure: Takes uses yt-dlp to download audio
  from YouTube for user-provided links; users are responsible for using it only
  where they have rights or permission.

## Audio Format Strategy

Takes currently needs files readable by `AVAudioFile`.

There are two viable modes:

### MVP: Prefer YouTube M4A

Run yt-dlp with a format selector like:

```text
--no-playlist
--format bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]
```

Pros:

- No ffmpeg dependency.
- Smaller implementation and legal surface.
- Usually works for YouTube music/audio.

Cons:

- Not always the absolute highest-quality audio stream.
- Fails if no compatible M4A/AAC audio is available.

### High-Fidelity: Add ffmpeg

Run yt-dlp against `bestaudio` and use ffmpeg to decode into a temporary
CoreAudio-readable file, likely CAF or WAV.

Pros:

- Actually starts from the highest-quality available stream.
- Decoded output is easy for AVFoundation to read.

Cons:

- Adds another fast-moving binary dependency.
- ffmpeg licensing depends on the build configuration.
- Download cache can become large quickly.

Recommended staging: ship the M4A-only path first, with the row error clearly
explaining when a compatible YouTube audio stream is unavailable. Add ffmpeg only
after the rest of the workflow proves useful.

## Download Cache

Use an app-owned cache root, not Application Support:

```text
~/Library/Caches/com.nigelwarren.Takes/StreamingDownloads/
```

Within that root, create one directory per app launch:

```text
StreamingDownloads/<launch-id>/<load-id>/
```

The downloaded file path becomes the `LoadedTrack.url` imported through the normal
`loadImportedFiles(_:)` path.

Track source metadata should be extended so Takes knows whether a file is owned
by the streaming cache. Do not infer ownership from arbitrary paths at removal
time. Suggested model:

```swift
enum TrackSource: Equatable {
    case localFile
    case streamingDownload(originalURL: URL, resolvedURL: URL, cacheFileURL: URL)
}
```

Add `source: TrackSource = .localFile` to `LoadedTrack`, or hold equivalent
ownership metadata keyed by `SessionTrack.ID` in `PlaybackController`. Adding it
to `LoadedTrack` keeps drag/export and Finder behavior honest.

## Cleanup Policy

Desired behavior:

- When a streaming track is removed: stop/detach its runtime audio, then delete
  its owned cache file and empty parent directory.
- When all tracks are cleared: delete all cache files owned by the current
  session.
- When the app quits normally: clear the current launch cache directory.
- When the app crashes or is killed: clear stale launch directories on next
  launch, before accepting new streaming downloads.

Implementation:

- `StreamingDownloadCache.prepareForLaunch()` removes every existing directory
  under `StreamingDownloads/`, then creates the new launch directory.
- Keep a manifest in memory mapping `SessionTrack.ID` to owned cache files.
- On `removeTrack(_:)`, capture and delete the owned file after `detachRuntimeTrack`.
- On `clearTracks()`, delete all currently owned streaming cache files.
- On `applicationWillTerminate`, call the same cache cleanup. This is best effort
  only; next-launch cleanup is the real guarantee.

This means cached audio does not intentionally persist across app launches. If
the app exits before cleanup, files persist only until the next Takes launch or
until the OS purges Caches.

## Process And Progress Model

`StreamingTrackResolver` and `YTDLPDownloader` should be async services owned by
`PlaybackController`.

Suggested components:

- `PlatformMetadataResolver`: Apple Music and Spotify metadata lookup.
- `YTDLPYouTubeSearcher`: yt-dlp-backed YouTube search.
- `YouTubeMatchScorer`: local candidate scoring.
- `YTDLPManager`: installation, update checks, version manifest, binary path.
- `YTDLPDownloader`: runs `Process`, parses progress, returns final file URL.
- `StreamingDownloadCache`: launch directory, per-load directories, cleanup.
- `StreamingURLPromptStatus`: UI model for prompt progress and errors.

Use `Process` rather than embedding yt-dlp as a Python module. It keeps Swift
isolated from Python packaging details and preserves the ability to replace the
binary without relinking Takes.

Progress parsing should use yt-dlp progress templates instead of scraping the
default console output. Capture stdout/stderr asynchronously and translate lines
into structured prompt states. Add cancellation before enabling prompt dismissal
during an active lookup or download.

## First Implementation Slice

1. Add `Open Streaming URL...` command and modal/prompt.
2. Implement `PlatformMetadataResolver`, `YTDLPYouTubeSearcher`, and
   `YouTubeMatchScorer`.
3. Show lookup/search/download/open progress in the prompt, with no main-window
   row until import succeeds.
4. Add `StreamingDownloadCache` with startup, removal, clear-all, and termination
   cleanup tests.
5. Add `YTDLPManager` behind a protocol with a fake implementation in tests.
6. Add real yt-dlp download path with M4A-only format selection.
7. Import the downloaded file through the existing `loadImportedFiles(_:)` path.
8. Add cancellation and retry.

The first code slice should not attempt ffmpeg, playlists, albums, private links,
cookies, OAuth-gated service APIs, or a candidate picker.

## Open Decisions

- Whether to default yt-dlp to stable or nightly.
- Whether first-run installation should be automatic or require a one-time
  confirmation.
- Whether a streaming-loaded row should display original service artwork/title
  instead of the downloaded file name.
- Whether drag-to-Finder should expose the downloaded cache file, a `.webloc` for
  the original stream, or be disabled for streaming rows.
- Whether Sparkle release notes should include the yt-dlp disclosure once this
  ships.
