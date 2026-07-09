# Takes Agent Notes

Takes is an Xcode-based native macOS SwiftUI app, not a SwiftPM package. Do not
use `swift test` as the verification path.

## Keeping this file current

After any merge or PR, review this file and update it to match the merged code
before considering the work done. Check the ownership list, Playback Model,
Behavior Invariants (especially the performance-architecture ones), and Test
Map against what changed, and verify any symbol or behavior it names still
exists before relying on it. Treat a stale AGENTS.md as a bug: its whole value
is that an agent can trust it without re-deriving the codebase.

## Verification

Use `xcodebuild test` with fresh DerivedData under `/private/tmp` for the
canonical repo check:

```bash
xcodebuild \
  -project Takes.xcodeproj \
  -scheme Takes \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/takes-derived-data \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Use a separate Debug build when a manual app/UI sanity check is needed:

```bash
xcodebuild \
  -project Takes.xcodeproj \
  -scheme Takes \
  -configuration Debug \
  -derivedDataPath /private/tmp/takes-debug-derived-data \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Project Shape

Main app code lives in `Sources/Takes/`. Tests live in `Tests/TakesTests/`.
The app project is `Takes.xcodeproj`.

Key ownership:

- `TakesApp.swift`: app windows, app/menu commands, files opened from Finder,
  remote media commands, main-window sizing policy, and Debug menu wiring.
- `ContentView.swift`: SwiftUI interface, file importers, drag-and-drop,
  local keyboard monitoring, waveform/timeline UI, loop gestures, and offset
  controls.
- `AppSettings.swift` and `SettingsView.swift`: persisted user preferences and
  the Settings window.
- `PlaybackController.swift`: loading files, session state, transport control,
  playback scheduling, and audibility.
- `Models.swift`: `LoadedTrack`, `SessionTrack`, `ComparisonSession`,
  `PlaybackError`, repeat modes, loop regions, and timeline marker helpers.
- `TransportMapping.swift`: pure transport math, signed timeline bounds,
  transport-to-file mapping, audibility checks, and gain conversion.
- `TrackAligner.swift`: audio-derived quick alignment and deeper tempo
  analysis.
- `WaveformStore.swift`: in-memory (process-lifetime) waveform generation —
  bounded to 2 concurrent decodes in session (top-first) order — plus the
  multi-resolution peak pyramid (`Waveform.reducedLevels`) the lanes draw
  from. No disk caches.
- `AudioFileLoader.swift`: local file loading through `AVAudioFile`.
- `LibraryTrackSelectionLoader.swift`: AppleScript-based Music.app selection
  loading.
- `StreamingTrackImport.swift`: streaming URL metadata, yt-dlp management, and
  downloaded audio import.
- `SoftwareUpdater.swift`: Sparkle and yt-dlp update state.

## Playback Model

Takes compares up to 32 tracks on a shared signed timeline. Playback uses one
`AVAudioEngine`, one `AVAudioPlayerNode` per loaded track, and one per-track
mixer node per loaded track. All loaded tracks are scheduled against the same
transport model, and only the active track is audible.

Transport behavior to preserve:

- Playback is allowed with one loaded track.
- The timeline is based on the union of loaded track ranges and the global 0:00
  point.
- Negative offsets extend the visible timeline before 0:00; positive offsets
  create leading empty space before a shifted track starts.
- If the active track is out of range, playback remains silent until transport
  re-enters that track's valid range.
- Repeat Off parks the playhead at the end of the playable range; the next Play
  starts from the beginning of the range.
- Repeat One restarts the current track at the beginning of the playable range.
- Switch & Repeat advances to the next track and restarts; with one track it
  behaves like Repeat One.
- A selected loop constrains the playable range until the loop is deselected.
- Timeline zoom changes the visible window, not the underlying session range.
- `AVAudioEngineConfigurationChange` should reschedule playback after output
  route/configuration changes when possible.

## Behavior Invariants

These are here to prevent parallel implementations and subtle regressions:

- Route new import/open entry points through the existing shared loading path
  instead of adding separate import behavior.
- Preserve canonical duplicate detection by standardized, symlink-resolved file
  URL.
- Keep removal behavior state-safe: removing one track preserves remaining
  offsets, while removing all tracks clears session-wide state.
- Preserve Blind Listening Mode as a runtime anonymization/shuffle layer that
  reapplies when importing while the mode is already enabled.
- Keep global shortcuts focus-safe; active numeric text fields should retain
  normal text editing behavior.

Performance-architecture invariants (established by the perf effort; breaking
these reintroduces the exact regressions it fixed):

- **Waveform lanes draw synchronously from the peak pyramid every frame**
  (`WaveformLaneView`'s `Canvas` → `LaneWaveformRenderer.waveformPath`, fed by
  `Waveform.reducedLevels`, picking the level nearest ~1 bucket/pixel). Do NOT
  reintroduce async or cached rasterized-image (`NSImage`) waveform rendering —
  that caused blank/stale lanes during zoom and scroll. Off-screen lanes are
  culled via `isRenderable`; waveform data is in-memory only.
- **Continuous on-screen motion must use Core Animation, never SwiftUI
  `TimelineView(.animation)` or `withAnimation`** — both burn main-thread CPU
  per frame on macOS. The playhead is CALayer-driven (one `CABasicAnimation`
  per transport anchor event); steady playback does zero per-frame main-thread
  work.
- **`PlaybackController` is `@Observable`** (not `ObservableObject`). Live
  transport position is derived from schedule anchors via
  `displayTransportPosition()`; `session.transportPosition` is written only at
  anchor events (play/pause/seek/stop/wrap), never per tick. The visible window
  (`visibleStart`/`visibleSpan`/`laneWindowStart`) lives on the controller and
  is written only on real change (equality-guarded).
- **Keep the track-row / lane-leaf isolation.** `TrackRowView` is `Equatable`
  and must not receive any per-scroll or per-zoom value; the zoom/scroll-varying
  lane window flows through `LaneViewportStore` → `LaneView` leaves, so
  scrolling and zooming never re-lay-out the track `VStack`.
- **Loop/repeat wraps are gapless via a pre-queued next iteration**
  (`establishLoopPreQueue` / `handleLoopWrap`, `isLoopPreQueued`): a wrap is
  bookkeeping-only (re-anchor + audibility flip + enqueue the following
  iteration), never a stop/reschedule/play. Any schedule-changing action routes
  through `rescheduleAndStart`, which re-arms the pre-queue. Loop resize while
  playing deliberately does a full reschedule (a one-time interactive cost, not
  per-wrap).

## Test Map

- `TransportMappingTests.swift`: transport math and range behavior, plus
  loop-wrap anchor math and gapless pre-queue segment mapping.
- `SessionTests.swift`: higher-level state, import behavior, Music/Finder
  selection handling, numeric control stepping, blind listening, window policy,
  and other non-UI logic.
- `StreamingTrackImportTests.swift`: streaming metadata, yt-dlp resolution,
  download/import behavior, checksum parsing, and error handling.
- `WaveformSourceTests.swift`: waveform generation and the peak pyramid
  (file-anchored pooling vs brute force, pyramid excluded from `Waveform` `==`).
- `AnalysisEngineTests.swift`, `AnalogSourceDSPTests.swift`, and
  `LossyArtifactDSPTests.swift`: the single-file analysis window's DSP.
- `LoopingTests.swift`, `TimelineHeaderMarkerTests.swift`,
  `TrackAlignerTests.swift`, and `TrackDropHighlightTests.swift`: their named
  subsystems.

## Ongoing Work

- [docs/performance-plan-status.md](docs/performance-plan-status.md): status
  of the playback/UI performance improvement effort (what's landed, what's
  measured, what's left). Check this before starting new perf work so it
  isn't duplicated or redone.
