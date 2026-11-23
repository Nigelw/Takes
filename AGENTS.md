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
  remote media commands, the main-window size policy (`TakesWindowPolicy`:
  A2 default/minimum sizes, the artwork toggle's resize, frame clamping), and
  Debug menu wiring.
- `WorkspaceView.swift`: playlist/comparison navigation, shared import routing,
  startup restoration ordering, the playlist control bar
  (`PlaylistTransportView`) with the playlist bottom bar placed below the
  list, keyboard focus handling (including Esc leaving compare), and the
  window chrome both modes share: the cover above the control bar and the
  titlebar artwork toggle.
- `TransportControls.swift`: the A2 control bar both modes share
  (`ControlBarLayout`: transport row, readout slot (playlist only), divider;
  `ControlBarMetrics`; `ControlBarSideButtonStyle` for Shuffle/Blind/Repeat;
  `ControlBarDivider`), v2.9.0's `CircleTransportButtonStyle`,
  `SevenSegmentDisplay`,
  window drag/background helpers, and the Debug Appearance Tuner.
- `BottomBar.swift`: the A2 bottom bar both modes share (A2 §7):
  `BottomBarLayout` and `BottomBarMetrics`, the +/− segmented control
  (`BottomBarAddRemoveControl`), the playlist bar (`PlaylistBottomBar`, its
  `…` pull-down and summary text, `PlaylistSummaryText`), the compare bar
  (`CompareBottomBar`: `CompareAlignButton` with the "Couldn't Align Tracks"
  popover and `AlignmentOfferText`, and the zoom leaf `CompareZoomControl`),
  and each bar's enablement (`PlaylistBottomBarState`,
  `CompareBottomBarState`).
- `DotMatrixReadout.swift`: the playlist readout
  (`PlaylistControlBarReadout`, its title rule in `ControlBarReadoutTitle`),
  the elapsed-time leaf both modes use (`ControlBarElapsedDigits`), the
  compare title bar's framed time (`CompareTitleBarTime`), the dot-matrix
  text and marquee, the seekable LED meter (`DotMatrixProgressBar`), and the
  Glass frame (`readoutGlass`).
- `CoverArtwork.swift`: `PlaylistArtworkStore` (in-memory, downsampled,
  bounded embedded-artwork caches: the cover, and the playlist rows'
  thumbnails), the 360 pt cover view, and the artwork toggle with its custom
  sleeve glyph.
- `PlaylistView.swift`: the playlist list's SwiftUI host (empty state, no
  header bar), selection/expansion presentation state, the Playlist menu, and
  the selection-aware organization commands (`PlaylistCommandContext`); the
  one list of organization menu items (`PlaylistOrganizationMenuItems`) that
  the Playlist menu and the bottom bar's `…` pull-down both show.
- `PlaylistOutlineView.swift`: the playlist table — an `NSOutlineView` wrapped
  in `NSViewRepresentable` (items with versions as children), the A2 rows
  (`PlaylistRowMetrics`, `PlaylistRowView`, `PlaylistItemCellView`,
  `PlaylistVersionCellView`, the thumbnail, chevron and Compare pill views),
  visible-row thumbnail requests, context menu, inline rename, keyboard
  handling, and row drag and drop. Row colors are `PlaylistRowPalette` in
  `Theme.swift`.
- `ContentView.swift`: the compare control bar's buttons, the compare title
  bar (`CompareTitleBar`: `CompareTitleBarMetrics`, the take count and
  `CompareTitleBarText`, the centring `CompareTitleBarRow`, and
  `CompareDoneButtonStyle`; [docs/a2-compare-title-bar-spec.md](docs/a2-compare-title-bar-spec.md)),
  and the compact compare area (A2 §8): ruler and lane sizing
  (`CompareLaneLayout`), the 21 pt ruler (`TimelineHeaderRulerView`,
  `TimelineRulerMetrics`), the
  playhead (`PlayheadGeometry`, `TimelinePlayheadVisual`), the full-width
  lanes (`TrackRowView` → `LaneView` → `WaveformLaneView`), their info
  strips (`LaneStripView`, `LaneOffsetField`, `LaneStripText`, the strip's
  drag source and context menu), loop gestures, and reorder drag-and-drop.
  The compare bottom bar sits below the lanes; it lives in `BottomBar.swift`.
- `AppSettings.swift` and `SettingsView.swift`: persisted user preferences
  (including `showsArtwork`, the titlebar toggle's state) and the Settings
  window.
- `PlaybackController.swift`: loading files, session state, transport control,
  playback scheduling, and audibility.
- `Models.swift`: `LoadedTrack`, `SessionTrack`, `ComparisonSession`,
  `PlaybackError`, repeat modes, loop regions, and timeline marker helpers.
- `PlaylistWorkspace.swift`: playlist value model, stable version ownership,
  organization operations, and snapshot validation.
- `PlaylistCoordinator.swift`: mode transitions, captured-destination imports,
  playlist traversal, organization/Undo, and active runtime coordination.
- `PlaylistWorkspaceStore.swift`: versioned atomic snapshots, recovery protection,
  bookmarks, and retained download storage.
- `PlaylistPersistenceController.swift`: startup restoration, event saves,
  playback checkpoints, and quit-time flushing.
- `PlaylistStreamingImporter.swift`: streaming downloads into workspace storage.
- `PlaylistPlaybackBoundary.swift`: value conversion between playlist versions
  and comparison sessions, file-time mapping, and adjustment capture by ID.
- `PlaylistContracts.swift`: captured import destinations, runtime activation
  identities, and the workspace persistence protocol.
- `TransportMapping.swift`: pure transport math, signed timeline bounds,
  transport-to-file mapping, audibility checks, and gain conversion.
- `TrackAligner.swift`: audio-derived quick alignment and deeper tempo
  analysis.
- `TrackMetadataMatcher.swift`: normalized title/artist/filename matching and
  duration safeguards for automatic playlist grouping.
- `TrackSimilarityClustering.swift`: deterministic conservative grouping and
  existing-item admission from pairwise metadata evidence.
- `WaveformStore.swift`: in-memory (process-lifetime) waveform generation —
  bounded to 2 concurrent decodes in session (top-first) order — plus the
  multi-resolution peak pyramid (`Waveform.reducedLevels`) the lanes draw
  from. No disk caches. A new runtime context restarts in-flight generations;
  finished waveforms survive a re-activation of the same item (Remove
  Version, reorder and regroup rebuild the runtime), so lanes don't redraw
  from scratch.
- `AudioFileLoader.swift`: local file metadata through `AVAudioFile`, embedded
  title/artist/album tags and cover art (`embeddedArtworkData(for:)`) through
  `AVURLAsset`, and audio-runtime file preparation.
- `LibraryTrackSelectionLoader.swift`: AppleScript-based Music.app selection
  loading.
- `StreamingTrackImport.swift`: streaming URL metadata, yt-dlp management, and
  downloaded audio import.
- `SoftwareUpdater.swift`: Sparkle and yt-dlp update state.
- `Analysis/`: the experimental single-file Analysis window (Debug → Analysis,
  ⌘⌥Z) and the experimental multi-track Compare Quality window
  (Debug → Compare Quality, ⇧⌘L). Both are debug-only and deliberately not
  integrated into the main UI. See
  [docs/experimental-audio-analysis.md](docs/experimental-audio-analysis.md)
  and
  [docs/comparative-quality-analysis.md](docs/comparative-quality-analysis.md).

## Playback Model

Takes keeps an ordered playlist with up to 32 versions per item and no global
32-file cap. Playlist playback loads only the selected version, at original
gain and file time. Comparison loads only the current item's versions on a
shared signed timeline. Playback uses one
`AVAudioEngine`, one `AVAudioPlayerNode` per loaded track, and one per-track
mixer node per loaded track. All loaded tracks are scheduled against the same
transport model, and only the active track is audible.

Comparison transport behavior to preserve:

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

- Keep one `PlaybackController` and audio engine. Inactive playlist items are
  persisted values, with no audio nodes or waveform generation. Navigation uses
  `replaceRuntimeSession(_:context:)`, never the legacy `clearTracks()` path.
- Capture `PlaylistImportDestination` before asynchronous import work. General
  imports create items; comparison imports target the captured item ID even if
  the user navigates. Canonical duplicate detection covers the whole workspace.
- Save comparison edits by stable version ID; playlist playback ignores their
  gain, offset, loop, and blind ordering. Mode transitions translate file time.
  Read the transport and active offset from the same runtime when handing off.
  Back and failed Compare restoration return to the playlist so missing files
  remain repairable.
- Restore before draining external-open events and always restore paused.
  Failed recovery blocks automatic saves; successful streaming downloads stay
  in workspace storage so navigation, quit, and Undo cannot delete them.
- Keep persistence snapshots side-effect free. Position checkpoints may read
  transport anchors but must not create periodic observed workspace mutations.
  Save observation follows the settled viewport revision so scrolling and
  animated playback page turns do not rearm it per frame.
- Route new import/open entry points through the existing shared loading path
  instead of adding separate import behavior.
- Validate multi-row organization on one candidate workspace; use the source
  and destination references from before the edit for offset translation.
  Undo and Redo rebase the recorded edit against current versions and retain
  live playback by stable ID when that version survives.
- Keep automatic grouping conservative: missing metadata or incompatible
  duration must not create a match; incoming and existing tracks use the same
  rules, existing items require an unambiguous all-member witness, and imports
  never merge existing items. Normalize each version once per matching pass,
  check performance qualifiers before fuzzy matching, and recheck the matching
  inputs before committing evidence computed off the main actor.
- Preserve canonical duplicate detection by standardized, symlink-resolved file
  URL.
- Keep removal behavior state-safe: removing one track preserves remaining
  offsets, while removing all tracks clears session-wide state.
- Preserve Blind Listening Mode as a runtime anonymization/shuffle layer that
  reapplies when importing while the mode is already enabled.
- The playlist table is an `NSOutlineView`, not a SwiftUI `List`. Do not move
  it back: SwiftUI row `onDrag` swallowed selection clicks and offered no
  insertion indicator, drop-on-row, or multi-row drag image.
  `PlaylistPresentationState` stays the source of truth for selection and
  expansion; the outline controller mirrors it in both directions.
- Playlist row drags are in-app only for organization (reorder, drop on an
  item to group, drag versions between items or out to separate) and carry a
  file URL for dragging out to Finder. Finder file drops are position
  independent: they go through the shared import path, which merges into a
  metadata match or appends.
- Context-menu commands act on the selection when opened on a selected row and
  on the clicked row alone otherwise (`PlaylistCommandContext.rows`).
- The playlist table (A2 §6) is one full-width column with no header.
  AppKit's disclosure triangle and indentation are suppressed
  (`frameOfOutlineCell`, `frameOfCell`); item rows (46 pt) draw their own
  chevron in an always-reserved 12 pt slot, only on multi-version items.
  `PlaylistRowView` draws every background (selection, now-playing tint,
  hover, the drop-on-item ring) inside the 10 pt edge inset with a 6 pt
  radius; the geometry lives in `PlaylistRowMetrics`. Item and version
  titles truncate in the middle; artist lines at the tail.
- Version rows (30 pt) are named by their title tag, else the filename
  without its extension (`PlaylistRowText.versionName`). A plain click on a
  version row makes it the playback version; a missing file shows a warning
  triangle in place of the check and its click opens Locate. Double-click
  plays on every row. The hover Compare pill (multi-version items only) and
  the context menu's Compare are the ways into compare from a row.
- Entering compare never starts an item: another item's playback stops, and
  only the item already playing keeps playing
  (`PlaylistCoordinator.enterComparison`).
- The playlist has no header bar. Its bottom bar (A2 §7) has Add Files…
  (⌘O's dialog) and Remove Selected (Delete's selection-aware removal), the
  `…` pull-down with the Playlist menu's organization commands, and the
  `N tracks · m:ss` summary (one track per item). The File menu (⌘O, ⇧⌘O, ⇧⌘F, ⇧⌘M), Delete, the
  context menu and the Playlist menu keep every one of those commands; the
  bar is another way in, not a replacement.
- Keep global shortcuts focus-safe; active numeric text fields should retain
  normal text editing behavior.
- One main window serves both modes (A2). It opens 360 pt wide (760 tall with
  artwork, 414 without) and is user-resizable down to
  `TakesWindowPolicy.minimumSize(showsArtwork:)`: 360 × 617 with the
  artwork, 360 × 271 without (the compare control bar, its title bar, the
  ruler, one whole lane and the bottom bar; `minimumHeightWithoutArtwork`). Mode switches and
  track counts never resize it; the artwork toggle is the only automatic resize
  (±`artworkCollapseHeight`, 346 pt, top edge fixed, clamped on screen). Its
  frame autosaves as `main.a2`; do not reintroduce per-mode frames.
- The cover and artwork toggle live in `WorkspaceView`, above both modes'
  control bars, so entering compare never moves them. The control bars take
  their top padding from `TakesWindowPolicy.controlBarTopPadding(showsArtwork:)`
  (10 under the cover, 24 under the titlebar). The cover's version comes from
  `CoverVersionRule`: in compare it follows the audible version, except in
  Blind Listening Mode, where it stays on the item's playback version so it
  can't reveal which version is audible. The previous cover stays up until
  the next one has loaded (`shownCoverVersionID`), so switching never
  flashes the placeholder.
- Artwork is in-memory only (no disk caches); the readouts carry none. The
  cover loads only the version on display, downsampled to 720 px, capped at
  `PlaylistArtworkStore.capacity` decoded images. Playlist item rows show a
  34 pt thumbnail of their playback version from a separate bounded cache
  (`thumbnailPixelSize` 68 px, `thumbnailCapacity`, at most
  `maximumConcurrentThumbnailLoads` decodes at once). The outline controller
  requests thumbnails only for item rows inside the visible rect
  (`requestVisibleThumbnails`, coalesced per run-loop turn on scroll/resize/
  reload), and each request replaces the queue, so rows scrolled away before
  their turn — and rows AppKit prepares off screen — are never decoded. A
  version whose cover is decoded (or decoding) is scaled from that image
  instead of reading its file again. Finished thumbnails are pushed into the
  visible cell (`onThumbnailLoaded`), never by reloading the table.
- Both modes build their control bar from one `ControlBarLayout` (A2 §5):
  the centre group centred with 12 pt gaps; the 30 × 40 pt side buttons each
  centred midway between its window edge and the playlist's Previous · Play
  · Next group (`ControlBarTransportRow`,
  `ControlBarMetrics.sideButtonCenterX`), at the same place in compare even
  though its centre group is narrower; in playlist mode the readout inside
  the 10 pt insets; then the one `ControlBarDivider`. Compare has no readout
  (`ControlBarLayout`'s readout-less init): its bar ends 10 pt under the
  transport row (`ControlBarMetrics.transportRowBottomPadding`), 53 pt
  shorter than the playlist's (77 vs 130 pt with the artwork), and the
  transport row doesn't move between modes. It stretches to any width of
  360 pt or more; do not
  reintroduce width-dependent layouts. Side buttons are plain icons
  (`ControlBarSideButtonStyle`); centre buttons are v2.9.0's
  `CircleTransportButtonStyle` (Play 56/22, secondary 40/15). Previous/Next
  are playlist-only. There is one readout frame, v2.9.0's Glass
  (`readoutGlass`); the Teenage Engineering theme and the Retro frame were
  removed, and their stored preferences are simply not read.
- The readout title comes from `ControlBarReadoutTitle.playlist`: the
  playing (or current) version's title tag, else its filename without the
  extension, uppercased. Compare shows no version title in its control bar
  or title bar; the active lane and the cover carry the audible version.
  Long titles scroll (`DotMatrixMarqueeText`). The title field takes
  its width from the line, never from its text (the cells draw in an
  overlay); sized by its cells it could only grow, and a launch-time layout at
  a restored wider frame left the readout wider than the window.
- Compare's title bar (32 pt, between the control bar's divider and the
  ruler, on the well with no line to the ruler) shows `N takes` (`1 take`,
  `CompareTitleBarText`, unchanged when blind) on the left, the elapsed
  time in a 24 pt Glass frame centred in the window
  (`CompareTitleBarRow` gives both sides equal widths), and Done on the
  right. Compare leaves through Done, Esc, or ⌘[ — all
  `PlaylistCoordinator.backToPlaylist`, so the audible version becomes the
  playback version. Zoom's
  on-screen control is in the bottom bar (magnifier − · slider · magnifier
  +, no Fit); ⌘+/⌘−, Zoom to Selection, Zoom to Fit and pinch also zoom.
- Compare has no track-info column (A2 §8). Below the control bar's divider:
  a 21 pt ruler with a 1 pt bottom border and no top border (v2.9.0's 19 pt
  major and 8 pt minor notches hanging from its bottom, each label's digits
  level with its major notch's top; the grabber may overlap the labels), then lanes edge
  to edge. Every lane has one fixed height (`CompareLaneLayout.laneStep`,
  96 pt: a 95 pt lane and its 1 pt divider); lanes that don't fit scroll, and
  neither the window size nor the version count ever resizes a lane, so
  adding or removing a version never redraws the others. The 14 × 16
  grabber's tip sits on the ruler's bottom edge
  (`CompareLaneLayout.seatBottom`, 22) in an overlay above the section; the
  2 pt line runs through the lanes inside their scroll content. The lanes
  and ruler mask their first point (`TimelineLeadingEdgeMask`), so the 0:00
  marker, guide and notch don't draw a stray line on the window's edge when
  the timeline starts at 0:00.
- Each lane's 21 pt info strip (`LaneStripView`) is its own layer ABOVE the
  lanes' seek/loop gesture surface and the playhead line, with the lane
  visuals below them; it has no background. Only the badge, title and format
  (the drag source: reorder, drag-out to Finder, and the context menu —
  Remove Version, Reveal in Finder, Reset Offset) and the offset field take
  clicks; the strip's empty middle passes clicks through. Don't fold the
  strip into `TrackRowView` or put it under the gesture surface: its controls
  would stop receiving clicks and the playhead line would cross them. The
  strip's frame runs from the lane's top to the waveform band
  (`CompareLaneLayout.stripFrameHeight`), its contents centred. The offset
  field (`LaneOffsetField`) sizes itself to its number, including while it is
  typed; hovering it shows an "Offset" label to its left that takes room in
  the row, so a long title truncates rather than running under it. Its hover
  comes from an AppKit tracking area (`HoverSensor`), because SwiftUI hover is
  unreliable over the AppKit text field. Strip titles use
  the version-row rule (`PlaylistRowText.versionName`); Blind Listening Mode
  shows `Track n`, no format or tooltip, and disables Reveal in Finder.
- Compare has no header. Its bottom bar (A2 §7) has Add Version… (⌘O's
  dialog, importing into the captured item), Remove Active Version (File ▸
  Remove Version, Delete), Align (⌥⌘A) and zoom. Remove All Versions is
  ⌘⌫ only. Align shows the quick pass's spinner, tempo analysis's progress
  ring and the two-second outcome flash, and anchors the "Couldn't Align
  Tracks → Analyze Further" popover; in Blind Listening Mode the popover
  lists `Track n`, never file names.
- Both modes build their bottom bar from one `BottomBarLayout` (A2 §7): 30 pt
  including its 1 pt top hairline, 10 pt insets, standard small controls
  (`.controlSize(.small)`), stretching to any width with no width-dependent
  layouts. It sits below the playlist table or the compare lanes and
  shortens their scroll area, never a lane. Every control runs an existing
  command (`OpenFileCommandState`, `PlaylistCommandContext`, the
  controller's align and zoom methods) and follows that command's
  validation (`PlaylistBottomBarState`, `CompareBottomBarState`); do not add
  parallel add, remove, organize, align or zoom paths. Remove Active Version
  follows the lane strip's Remove Version: enabled for any active version,
  and removing an item's last version removes the item and returns to the
  playlist.

Performance-architecture invariants (established by the perf effort; breaking
these reintroduces the exact regressions it fixed):

- **Waveform lanes draw synchronously from the peak pyramid every frame**
  (`WaveformLaneView`'s `Canvas` → `LaneWaveformRenderer.waveformPath`, fed by
  `Waveform.reducedLevels`, picking the level nearest ~1 bucket/pixel). Do NOT
  reintroduce async or cached rasterized-image (`NSImage`) waveform rendering —
  that caused blank/stale lanes during zoom and scroll. Off-screen lanes are
  culled via `isRenderable`; waveform data is in-memory only.
- **The readouts do no per-frame work.** Elapsed digits are an isolated
  leaf (`ControlBarElapsedDigits`, in the playlist readout and the compare
  title bar) that re-renders once per displayed second from
  `playingReadoutText`; nothing else in the control bar or the title bar
  reads it or the transport position.
  The LED meter's fill and brighter head, and dark appearance's glow under
  them (pre-blurred images, never live layer shadows), step on discrete
  `CAKeyframeAnimation`s armed per transport anchor event; titles scroll on
  Core Animation only when they overflow.
- **Continuous on-screen motion must use Core Animation, never SwiftUI
  `TimelineView(.animation)` or `withAnimation`** — both burn main-thread CPU
  per frame on macOS. The playhead is CALayer-driven: its grabber and its
  line are two layer views (`PlayheadPart`), each moved by one
  `CABasicAnimation` per transport anchor event; steady playback does zero
  per-frame main-thread work.
- **`PlaybackController` is `@Observable`** (not `ObservableObject`). Live
  transport position is derived from schedule anchors via
  `displayTransportPosition()`; `session.transportPosition` is written only at
  anchor events (play/pause/seek/stop/wrap), never per tick. The visible window
  (`visibleStart`/`visibleSpan`/`laneWindowStart`) lives on the controller and
  is written only on real change (equality-guarded).
- **Keep the track-row / lane-leaf isolation.** `TrackRowView` and
  `LaneStripView` are `Equatable` and must not receive any per-scroll or
  per-zoom value (the bottom bar's zoom slider included: it is its own leaf,
  `CompareZoomControl`, the only bar view that reads `visibleSpan`, and it
  zooms through `setZoomSliderValue`, never `withAnimation`); the
  zoom/scroll-varying lane window flows through `LaneViewportStore` →
  `LaneView` leaves, so scrolling and zooming never
  re-lay-out the lane `VStack`s. Reorder offsets and lifted opacity are applied
  around both (`ReorderPlacement`), never inside them.
- **Loop/repeat wraps are gapless via a pre-queued next iteration**
  (`establishLoopPreQueue` / `handleLoopWrap`, `isLoopPreQueued`): a wrap is
  bookkeeping-only (re-anchor + audibility flip + enqueue the following
  iteration), never a stop/reschedule/play. Any schedule-changing action routes
  through `rescheduleAndStart`, which re-arms the pre-queue. Loop resize while
  playing deliberately does a full reschedule (a one-time interactive cost, not
  per-wrap).

## Test Map

- `PlaylistCoordinatorTests.swift`: traversal, import destinations, organization,
  Undo, missing-file repair/advancement, 100-item/32-version runtime isolation,
  automatic-grouping transactions/cancellation, entering compare without
  starting another item, and workspace/runtime integration.
- `PlaylistRuntimeTests.swift`: runtime replacement, stable IDs, stale imports,
  teardown, preparation failure, and natural-end callbacks.
- `PlaylistWorkspaceStoreTests.swift`: snapshot round trips, recovery protection,
  schema handling, file references, and retained downloads.
- `PlaylistPersistenceControllerTests.swift`: restoration/save gating, failures,
  and automatic event-save observation rearming.
- `PlaylistWaveformContextTests.swift`: stale waveform rejection across
  activations, and finished waveforms kept when the same item re-activates.
- `PlaylistWorkspaceTests.swift`: playlist value encoding/validation, stable
  ownership, canonical duplicates, and atomic organization operations.
- `PlaylistPlaybackBoundaryTests.swift`: signed position conversion, session
  identity, loop entry, playlist gain isolation, blind-order-safe capture, and
  descriptive tags reaching comparison tracks.
- `TransportMappingTests.swift`: transport math and range behavior, plus
  loop-wrap anchor math and gapless pre-queue segment mapping.
- `SessionTests.swift`: higher-level state, import behavior, Music/Finder
  selection handling, numeric control stepping, blind listening, the A2 window
  policy (sizes, minimums, artwork-toggle frames, clamping), the persisted
  artwork setting, retired control-bar preferences loading as defaults, the
  A2 readout title rule (tag, filename), the compare control bar's height
  and the title bar (its geometry, centring and take-count text), the
  ruler labels' tops level with the major notches, the LED meter's cell count
  (no endcaps), head geometry, unlit opacity and glow, the control bar's side-button placement, the cover
  rule (`CoverVersionRule`), the A2 playlist row metrics and version names, the
  thumbnail cache (visible-only queue, concurrency bound, capacity, cover
  reuse), the A2 compact compare geometry (ruler and seat, the fixed lane
  height, the waveform band, ruler notches and labels, the playhead's line
  and grabber), the lane strip's text and blind rules, the offset field's
  width, the bottom bars (the playlist summary's count and total, both
  bars' enablement, the zoom slider sharing the timeline zoom model, the
  alignment offer's blind names), the settled minimum height, and other
  non-UI logic.
- `StreamingTrackImportTests.swift`: streaming metadata, yt-dlp resolution,
  download/import behavior, checksum parsing, and error handling.
- `WaveformSourceTests.swift`: waveform generation and the peak pyramid
  (file-anchored pooling vs brute force, pyramid excluded from `Waveform` `==`).
- `AnalysisEngineTests.swift`, `AnalogSourceDSPTests.swift`, and
  `LossyArtifactDSPTests.swift`: the single-file analysis window's DSP.
- `PairAlignmentTests.swift`: sample-accurate pair alignment, residual
  measurement, and relationship classification for the comparative analysis.
  Synthetic signals only — it must not depend on the corpus.
- `ComparativeInferenceTests.swift`: the high-frequency comparison and the
  provenance tiers. Guards the cutoff-scalar defect: two files whose measured
  cutoffs agree but whose spectra diverge must still produce a bandwidth
  finding.
- `LoopingTests.swift`, `TimelineHeaderMarkerTests.swift`,
  `TrackAlignerTests.swift`, and `TrackDropHighlightTests.swift`: their named
  subsystems.
- `TrackMetadataMatcherTests.swift` and
  `TrackSimilarityClusteringTests.swift`: metadata normalization, duration
  safeguards, and deterministic conservative grouping. Coordinator integration
  coverage lives in `PlaylistCoordinatorTests.swift`.

## Ongoing Work

- [docs/playlist-upgrade-implementation.md](docs/playlist-upgrade-implementation.md):
  staged playlist feature work, agent ownership, and milestone status. The
  playlist and comparison now share one coordinator/runtime. Automated validation
  passes; blocked manual/external/performance checks are recorded in
  [docs/playlist-upgrade-validation.md](docs/playlist-upgrade-validation.md).
  Read the linked contracts before extending it.

- [docs/performance-plan-status.md](docs/performance-plan-status.md): status
  of the playback/UI performance improvement effort (what's landed, what's
  measured, what's left). Check this before starting new perf work so it
  isn't duplicated or redone.
- [docs/a2-redesign-spec.md](docs/a2-redesign-spec.md): the A2 compact
  cover-column redesign (360 pt window, artwork toggle, glass readout,
  two-line playlist rows, compact compare, bottom bars). All five
  milestones are done: 1 (window shell and artwork), 2 (control bar),
  3 (playlist rows), 4 (compact compare) and 5 (bottom bars). Read it, and
  its §13 decisions, before changing any of them.
  [docs/a2-compare-title-bar-spec.md](docs/a2-compare-title-bar-spec.md)
  (done) replaced compare's readout row with the title bar; it overrides
  §5.2 and §9's back button.
- [docs/comparative-quality-analysis.md](docs/comparative-quality-analysis.md):
  the multi-track "which of these is the better copy?" feature — design,
  milestones, tuning findings, and limitations. Read it before touching
  anything under `Sources/Takes/Analysis/Comparative*` or `PairAlignment.swift`;
  several thresholds there look arbitrary and are not.

## Analysis Invariants

The comparative feature rests on one rule, and breaking it is how it stops
being trustworthy:

- **Fidelity and taste never mix.** `QualityFinding.Dimension.isFidelityBearing`
  decides which differences may influence a ranking (bandwidth, codec
  artifacts, added noise, clipping, provenance) and which are description only
  (loudness, dynamics, tonal balance). Never fold a taste dimension into a
  score, and never rank a pair whose `PairRelationship` says
  `supportsFidelityRanking == false`.
- **Abstention is a real outcome.** `PairRanking` has `equivalent`,
  `undetermined` and `notComparable` for a reason. Do not add a tiebreaker that
  makes the feature always name a winner.
- **Never rank on a derived scalar where the underlying curve is available.**
  Comparative bandwidth differences the two average spectra sub-band by
  sub-band; it does not subtract two `detectedCutoffHz` values, which on dark
  masters report the same number for a gentle rolloff and a hard cliff.
- **A weak measurement must not support a strong conclusion.** Anything keyed
  to `detectedCutoffHz` checks `BandwidthMetrics.confidence` first.
- **Keep the dimensions independent.** `provenanceTier` is about the kind of
  file (lossless / lossy / lossy-in-lossless-clothing), never about encode
  quality — that is what the bandwidth and codec-artifact dimensions measure,
  and ranking on it twice inflates confidence.
- **A metric tuned for single-file judgement is not automatically valid as a
  comparison.** Bitrate and HF-flicker are restricted to same-codec pairs, and
  clipped-run counts need a 4× disparity, because decoding artifacts otherwise
  masquerade as fidelity differences. See the plan's M4–M8 findings.
- **Alignment must stay sample-accurate.** The residual is measured after a
  frequency-domain fractional shift; substituting an interpolation kernel puts
  a floor in the air band, which is where the codec evidence lives.

Verify comparative changes with `scripts/analysis-benchmark.sh
compare-benchmark` (14 pairs, ground truth by construction) alongside the
single-file `scripts/analysis-benchmark.sh` (29 cases). Both need the corpus
generated by `scripts/make-analysis-corpus.sh`.
