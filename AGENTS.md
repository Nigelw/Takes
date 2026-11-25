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
  A2 default/minimum sizes, visibility toggle resizing, fitting the window
  to added and removed tracks (`frameFittingContent`), frame clamping), and
  Debug menu wiring.
- `WorkspaceView.swift`: playlist/comparison navigation, shared import routing,
  the shared Open and Locate file picker,
  startup restoration ordering, the playlist control bar
  (`PlaylistTransportView`) with the playlist bottom bar placed below the
  list, window-wide file drops (`WorkspaceFileDropDelegate`), the shared
  `FileImportEmptyState` badge and `FileImportHighlight` glow, keyboard focus
  handling (including Esc clearing compare's loop), when the
  window fits its tracks (`scheduleContentFit`), and the
  window chrome both modes share: the cover above the control bar and the
  titlebar Artwork, Player, and Playlist toggles.
- `TransportControls.swift`: the A2 control bar both modes share
  (`ControlBarLayout`: transport row and readout slot (playlist only);
  `ControlBarMetrics`; `ControlBarSideButtonStyle` for Shuffle/Blind/Repeat
  (`SideButtonAppearance`) and `ControlBarRepeatSymbol`;
  `ControlBarDivider`), v2.9.0's `CircleTransportButtonStyle`,
  `SevenSegmentDisplay`,
  window drag/background helpers, and the Debug Appearance Tuner.
- `BottomBar.swift`: the A2 bottom bar both modes share (A2 §7):
  `BottomBarLayout` and `BottomBarMetrics`, the +/− segmented control
  (`BottomBarAddRemoveControl`), the Reject button
  (`BottomBarRejectButton`), the playlist bar (`PlaylistBottomBar`, its
  `…` pull-down and summary text, `PlaylistSummaryText`), the compare bar
  (`CompareBottomBar`: `CompareAlignButton` with the "Couldn't Align Tracks"
  popover and `AlignmentOfferText`, and the zoom leaf `CompareZoomControl`),
  and each bar's enablement (`PlaylistBottomBarState`,
  `CompareBottomBarState`).
- `DotMatrixReadout.swift`: the playlist readout
  (`PlaylistControlBarReadout`, its title rule in `ControlBarReadoutTitle`),
  the elapsed-time leaf both modes use (`ControlBarElapsedDigits`), the
  compare info bar's framed time (`CompareInfoBarTime`), the dot-matrix
  text and marquee, the seekable LED meter (`DotMatrixProgressBar`), and the
  Glass frame (`readoutGlass`).
- `CoverArtwork.swift`: `PlaylistArtworkStore` (in-memory, downsampled,
  bounded embedded-artwork caches: the cover, and the playlist rows'
  thumbnails), the width-scaled cover view, the record placeholder
  (`RecordPlaceholder`: the bundled bitmaps' names, geometry and
  cover-square sizing, and the cover's live ground,
  `RecordPlaceholderCoverView`), and the titlebar toggle style and custom
  artwork sleeve glyph.
- `PlaylistView.swift`: the playlist list's SwiftUI host (empty state, no
  header bar), selection/expansion presentation state, the Playlist menu, and
  the selection-aware organization commands (`PlaylistCommandContext`,
  including Reject / Clear Rejection's targets, `rejectionTargets`); the
  shared organization menu builder (`playlistOrganizationMenuItems`) and
  focused validation (`PlaylistOrganizationAvailability`) for the Playlist
  menu and the bottom bar's `…` pull-down (Move Up/Down, Group/Ungroup
  Versions, Reject, in that order; the pull-down passes no
  `toggleRejection` and leaves Reject out, since the bar has a Reject
  button); and `PlaylistRejectionCommand`
  (the command's title rule and its R key).
- `PlaylistOutlineView.swift`: the playlist table — an `NSOutlineView` wrapped
  in `NSViewRepresentable` (items with versions as children), the A2 rows
  (`PlaylistRowMetrics`, `PlaylistRowView`, `PlaylistItemCellView`,
  `PlaylistVersionCellView` and its mark column, the thumbnail with its
  rejection badge, chevron and Compare pill views), the row text colours
  (`PlaylistRowTextStyle`),
  visible-row thumbnail requests, context menu, keyboard
  handling, and row drag and drop. Row colors are `PlaylistRowPalette` in
  `Theme.swift`.
- `ContentView.swift`: the compare control bar's buttons, the compare title
  bar (`CompareInfoBar`: `CompareInfoBarMetrics`, the version count and
  `CompareInfoBarText`, the centring `CompareInfoBarRow`, and
  `CompareDoneButtonStyle`; [docs/a2-compare-info-bar-spec.md](docs/a2-compare-info-bar-spec.md)),
  and the compact compare area (A2 §8): ruler and lane sizing
  (`CompareLaneLayout`), the 21 pt ruler (`TimelineHeaderRulerView`,
  `TimelineRulerMetrics`), the
  playhead (`PlayheadGeometry`, `TimelinePlayheadVisual`), the full-width
  lanes (`TrackRowView` → `LaneView` → `WaveformLaneView`), their info
  strips (`LaneStripView`, `LaneOffsetField`, `LaneStripText`, the strip's
  drag source and context menu, `RejectionBadgeView`), the rejected and
  missing lanes' hatching (`LaneHatching`), loop gestures, and reorder
  drag-and-drop.
  The compare bottom bar sits below the lanes; it lives in `BottomBar.swift`.
- `AppSettings.swift` and `SettingsView.swift`: persisted user preferences
  (including `WorkspaceVisibility`, the titlebar toggles' state) and the Settings
  window.
- `PlaybackController.swift`: loading files, session state, transport control,
  playback scheduling, audibility, compare switching, and applying
  rejection to loaded lanes in place (`setRejectedTracks`).
- `Models.swift`: `LoadedTrack` (including `isMissing` and `isRejected`),
  `SessionTrack`, `ComparisonSession` (switching: `canSwitchPlayback`,
  `switchTarget(forward:)`; Align's `hasMultipleTracks`), `PlaybackError`,
  repeat modes, loop regions, and timeline marker helpers.
- `PlaylistWorkspace.swift`: playlist value model (the culling flags
  `PlaylistItem.isRejected` and `PlaylistVersion.isRejected`, the derived
  `PlaylistItem.keyVersion`, schema-1 decoding of the retired stored key),
  stable version ownership, organization operations (`setRejected`
  included), and snapshot validation.
- `PlaylistCoordinator.swift`: mode transitions, captured-destination imports,
  playlist traversal (skipping rejected and unavailable tracks),
  organization/Undo (Reject / Clear Rejection: `toggleRejection`), and active
  runtime coordination.
- `PlaylistWorkspaceStore.swift`: versioned atomic snapshots (schema 2;
  schema 1 still decodes, `migratableSchemaVersions`), recovery protection,
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
- `RejectedMark.swift`: the rejection mark, a broken heart drawn in code
  (culling §9.1): its geometry on the 24-unit grid (the zigzag per size,
  the halves moved apart), its image, and the badge's ring outline.
- `WaveformStore.swift`: in-memory (process-lifetime) waveform generation —
  bounded to 2 concurrent decodes in session (top-first) order — plus the
  multi-resolution peak pyramid (`Waveform.reducedLevels`) the lanes draw
  from. No disk caches. A new runtime context restarts in-flight generations;
  finished waveforms survive a re-activation of the same item (Remove
  Version, reorder and regroup rebuild the runtime), so lanes don't redraw
  from scratch. Finished waveforms also go into `WaveformCache.shared`
  (process lifetime, keyed by `WaveformSource.Identity`: path, size and
  modification date; least recently used evicted past 64 MB), which
  outlives compare's view and its `WaveformStore`, so re-entering an item
  already compared, or any item sharing a file, draws its lanes without
  decoding. Only a full read is cached (`WaveformProgress.decoded`); a
  cancelled decode, or one that stopped early (`.stoppedEarly`: the file
  wouldn't open or a read failed or came up short), is not, so the next
  activation retries it. The identity reads size and date from the
  symlink-resolved file, so rewriting a link's target misses the cache.
- `AudioFileLoader.swift`: local file metadata through `AVAudioFile`, embedded
  title/artist/album tags and cover art (`embeddedArtworkData(for:)`) through
  `AVURLAsset`, and audio-runtime file preparation.
- `LibraryTrackSelectionLoader.swift`: AppleScript-based Music.app selection
  loading.
- `StreamingTrackImport.swift`: streaming URL metadata, yt-dlp management, and
  downloaded audio import.
- `SoftwareUpdater.swift`: Sparkle and yt-dlp update state, including the
  opt-in `beta` channel. `scripts/build-release.sh --beta-notes` prepares
  local beta artifacts and a separate signed appcast candidate for that
  channel. The [beta release workflow](.agents/skills/release/beta.md)
  publishes the GitHub prerelease and appcast.
- `Analysis/`: the experimental single-file Analysis window (Debug → Analysis,
  ⌘⌥Z) and the experimental multi-track Compare Quality window
  (Debug → Compare Quality, ⇧⌘L). Both are debug-only and deliberately not
  integrated into the main UI. See
  [docs/experimental-audio-analysis.md](docs/experimental-audio-analysis.md)
  and
  [docs/comparative-quality-analysis.md](docs/comparative-quality-analysis.md).

## Playback Model

Takes keeps an ordered playlist with up to 32 versions per item and no global
32-file cap. Playlist playback loads only one version (the item's key
version, or the version named explicitly), at original gain and file time. Comparison loads only the current item's versions on a
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
- Switch & Repeat advances to the next track that isn't rejected or
  missing and restarts; with one track, or no other such track, it behaves
  like Repeat One.
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
  Back, and a Compare restoration that fails for a reason other than a
  missing file, return to the playlist. Missing files never block compare
  (next item).
- Compare opens with missing files. `materializedComparisonItem` returns
  the missing version IDs; `activateComparison` marks their tracks
  `LoadedTrack.isMissing` and starts on the first available version when the
  incoming one is missing. A missing track keeps its lane (from stored
  metadata) but gets no audio nodes (`replaceRuntimeSession` skips it), no
  waveform decode (`WaveformStore.sync`), and no alignment; it is silent
  like a track out of range, and `ComparisonSession.isPlayable` needs at
  least one available track. When no lane is playable, Play does nothing in
  Compare. Switch Track passes over the missing lane
  (`SessionTrack.isSwitchable`); clicking its lane or its number hotkey
  still selects it. Its lane draws
  no waveform and shows the rejected lanes' neutral hatching across the
  whole lane (`LaneHatching`, drawn by `TrackRowView`, blind or not; there
  is no dashed warning band), its strip dims like a rejected lane's and
  shows `File Not Found` in place of the format, and the strip menu adds
  Locate File… (the playlist's Locate
  dialog, through `ContentView.locateVersion`) and disables Reveal in
  Finder. Locating any version of the compared item rebuilds compare
  (`locateFile`), keeping the audible version.
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
  Imports preserve the playlist selection, including an empty selection.
- Playlist row drags are in-app only for organization (reorder, drop on an
  item to group, drag versions between items or out to separate) and carry a
  file URL for dragging out to Finder. An item row dragged out copies every
  version whose file is there: `PlaylistNSOutlineView.beginDraggingSession`
  adds the other versions as image-less, file-URL-only dragging items
  (`extraDraggingItems`); in-app drops read `draggedNodes`, never those. Finder file drops are position
  independent: they go through the shared import path, which merges into a
  metadata match or appends.
- An external file drag over the window lights the visible list or waveform
  area with the v2.9.0 wash and edge glow, and shades the cover and the
  control bar, buttons included (`FileDropShade`, `Theme.fileDropShade`:
  black 10%; the control bar's `Theme.controlBarFileDropShade` is 20% in
  dark), driven by
  the `isFileDropTargeted` environment value. Compare's lane list has its own
  drop target, which combines its hover state with the window target's.
  The window-wide `onDrop` takes no `contentShape`: a full-window content
  shape made AppKit treat clicks in the titlebar band as window drags, so
  the titlebar toggles stopped responding.
  The empty playlist and timeline share a clickable badge that darkens and
  swaps its drag prompt for a click prompt on mouse hover. A file drag tints
  the badge and restores the drag prompt.
- Context-menu commands act on the selection when opened on a selected row and
  on the clicked row alone otherwise (`PlaylistCommandContext.rows`).
- Move Up/Down shifts selected tracks and selected versions one place among
  their siblings, keeping their relative order and disabling directions that
  would leave the order unchanged. A selected track covers its child rows.
  The commands animate playlist rows through `NSOutlineView.moveItem`, with
  selected rows and their expanded children above the rows they pass, and
  animate the active lane in Compare. Compare keeps the audio runtime in place, and
  a Blind Listening move changes only the displayed order. Both animations
  respect Reduce Motion.
  Group Versions uses the first selected track as the destination.
  Ungroup Versions splits all versions of each selected track and any
  individually selected versions into standalone tracks, then selects the
  resulting track rows.
- The playlist table (A2 §6) is one full-width column with no header.
  AppKit's disclosure triangle and indentation are suppressed
  (`frameOfOutlineCell`, `frameOfCell`); item rows (46 pt) draw their own
  chevron in an always-reserved 12 pt slot, only on multi-version items.
  `PlaylistRowView` draws every background (selection, hover, the
  drop-on-item ring) inside the 10 pt edge inset with a 6 pt radius; the
  geometry lives in `PlaylistRowMetrics`. Now playing draws no row
  background. Item and version
  titles truncate in the middle; item metadata truncates at the tail.
  Item rows use their key version's title tag or filename stem, duration,
  thumbnail, and metadata. The Metadata tab in Settings controls which fields
  appear on the second line (`TrackMetadataField`, Artist by default).
  `PlaylistRowText.metadataLine` joins enabled, available values with ` • `.
- The key version is derived, never stored ([docs/culling-spec.md](docs/culling-spec.md)
  §2–3): `PlaylistItem.keyVersion` is the first version that isn't
  rejected, else the first version. Availability doesn't enter into it (a
  missing key stays key, so unplugging a drive never changes a row). To
  change it, reorder versions or reject the ones above it; there is no Set
  as Key Version command or control. A key change never touches playback:
  the current version keeps playing until the track is next reached by
  sequential navigation or played from its item row. Snapshot schema 2
  dropped `selectedVersionID`; decoding a schema-1 item moves its stored
  key to the front of `versions`.
- Version rows (30 pt) are named by their title tag, else the filename
  without its extension (`PlaylistRowText.versionName`). The row shows the
  duration. The title tooltip includes the filename and format details.
  A single click selects the row. The hover Compare pill turns white with
  accent text on a selected row (`PlaylistComparePill.isEmphasized`). Double-clicking (or Return on) an item row plays its key
  version, resuming a track that is already current on its current
  version; on a version row it plays that version from the beginning,
  rejected or not, and leaves the key alone. Unavailable files show a
  warning triangle with the load
  error in its tooltip. The warning shows the plain tile instead of the record placeholder.
  A failed play attempt leaves playback alone. Locate
  File… is available explicitly in the menus. The hover Compare pill
  (multi-version items only) and the context menu's Compare are the ways
  into compare from a row; neither asks to locate missing files first.
- Entering compare never starts an item: another item's playback stops, and
  only the item already playing keeps playing
  (`PlaylistCoordinator.enterComparison`). It starts on the playing version
  if that item is playing, otherwise on the key version.
- Culling ([docs/culling-spec.md](docs/culling-spec.md)): tracks and
  versions carry independent `isRejected` flags, saved by stable ID and
  carried by every organization operation (Ungroup Versions starts the new
  track unrejected). Reject / Clear Rejection is one toggle
  (`PlaylistCoordinator.toggleRejection`, one undoable organization edit
  rebased by ID): it reads Clear Rejection only when every target is
  rejected. Targets: the selection or clicked row
  (`PlaylistCommandContext.rejectionTargets`), where a selected item row
  targets the track only and version rows their versions; in compare the
  active lane, or the right-clicked lane from the strip menu. It appears in
  the Playlist menu (`playlistOrganizationMenuItems`), the row context
  menu, both bottom bars' Reject button and the lane strip's menu, not the
  bottom bar's `…`. ⌘R runs it in both modes through the key monitor
  (`PlaylistRejectionCommand.keyCode`). Rejecting never moves rows, never
  changes the selection and never refreshes the audio runtime
  (`runtimeRequiresRefresh` ignores the flags): the current track or version
  keeps playing, and compare's lanes take the flag in place
  (`syncRuntimeRejection` → `PlaybackController.setRejectedTracks`).
- Rejected and missing rows dim to the same grey
  (`PlaylistRowTextStyle`, `PlaylistRowPalette.dimmedTitle`/`dimmedDetail`);
  the broken heart (`RejectedMark`) marks a rejection and the triangle a
  missing file. A missing file's empty tile (no artwork) stays at full
  strength so it reads as empty artwork; otherwise a dimmed item's
  thumbnail goes greyscale at 45% (a Core Image filter on the tile layer),
  and a rejected track carries the 16 pt broken-heart badge at its
  artwork's bottom-right, its 2 pt heart-shaped ring
  (`RejectedMark.ringOutline`, `PlaylistThumbnailView.badgeCutout`) cut out
  of the tile and stack (`PlaylistCardsView`'s mask) so the row shows
  around it and through its crack. A version row's 34 pt mark column holds
  the speaker, the warning and the 12 pt heart, side by side.
  Selected dimmed rows keep the selection colours at 65%. Rejected rows add
  "Rejected" to their accessibility value. The item row shows its own flag
  only; a track whose every version is rejected shows nothing extra.
- Now playing has no row background: the white speaker over the artwork
  carries a glow (`PlaylistRowPalette.nowPlayingSpeakerGlow`); the speaker over the artwork, the
  title, the metadata and the duration take the tint
  (`PlaylistRowPalette.nowPlayingTitle`/`nowPlayingDetail`), which replaces
  rejected dimming (a playing rejected track keeps its badge). An expanded
  track splits the state: the item row keeps its tinted text and the speaker
  moves to the playing version's mark column, whose text takes the tint
  (`PlaylistItemCellView.Content.showsSpeakerOnArtwork`); collapsing moves it
  back. The outline gets the current version (`currentVersionID`) for this.
- The playlist has no header bar. Its bottom bar (A2 §7) has Add Files…
  (⌘O's dialog) and Remove Selected (Delete's selection-aware removal),
  Reject (`BottomBarRejectButton`, the menu's targets), the
  `…` pull-down with the Playlist menu's organization commands except
  Reject, and the
  `N tracks · m:ss` summary (one track per item, at its key version's
  duration; rejected tracks are left out of the count and the total). The File
  menu has the import commands (⌘O, ⇧⌘O, ⇧⌘F, ⇧⌘M). The Playlist menu has
  Remove Selected Items and Remove All Tracks in the playlist, and Remove
  Current Version and Remove All Versions in compare (Delete and ⌘Delete
  in both modes).
- Help ▸ Debug ▸ Reset Window Size (`WorkspaceView.resetWindowSize`) turns
  the artwork on and sets the default 360 pt width and the mode's height: the
  playlist's default (760 pt, then stored as its height) or compare's fit
  to its lanes; top-left kept (`frameResettingSize(currentFrame:height:)`).
- The playlist outline stays mounted behind Compare to preserve its scroll
  position. On deactivation it releases AppKit first responder, declines
  keyboard, mouse and drag input, and stops writing selection or expansion
  back to the presentation state. Playlist row commands require playlist mode.
  Edit ▸ Select All uses the text responder when editing in the workspace.
- Keep global shortcuts focus-safe; active numeric text fields should retain
  normal text editing behavior. The key monitor (`WorkspaceView.setupKeyboard`)
  reads text editing from the first responder at each key press
  (`GlobalShortcutFocusPolicy`), never from `textInputIsFocused`: that
  notification-driven flag goes stale when a field is torn down mid-edit, and
  once blocked Space and every other global shortcut until relaunch. The flag
  only disables menu shortcuts (`canUseShortcuts`). Editing notifications
  come from workspace controls, excluding sheets and other windows. The
  workspace rechecks its responder after a sheet ends, on return to the key
  window, and on mode switches.
- Transport shortcuts differ by mode. Playlist: Space play/pause; ⌘← / ⌘→
  Previous / Next Track, which behave like a media player
  (`PlaylistCoordinator.previous`/`next`): Previous restarts the track past
  `previousTrackRestartThreshold` (3 s), else walks back through listening
  history, then list order (wrapping with Repeat All), else restarts; Next
  wraps with Repeat All, and past the last track returns to the first
  track that is neither rejected nor unavailable, paused (or does nothing
  if there is none). Sequential navigation (Previous through history and
  list order, Next, natural advancement, Repeat All, Shuffle, the media
  keys, the cover's Previous/Next) skips rejected tracks and unavailable
  files without adding the skipped items to listening history; natural
  advancement with only rejected tracks left ends playback. Explicit play
  (double-click, Return) ignores the flag, and Repeat One repeats a
  rejected current track. Space resumes the current track, rejected or
  not; with none, Play starts the first track that is neither rejected nor
  unavailable. The control bar's buttons and the media keys use the same
  commands. ⌥← / ⌥→ skip (⇧ for 10 s), since plain arrows move through the
  list. Edit ▸ Select All (⌘A) selects all visible rows in playlist mode when
  the list is shown and has tracks. Edit ▸ Deselect All (⌘D) and Esc clear the selection. Playlist ▸ Go
  to Current Song (⌘L) selects the current item. Compare: X / ⇧X Switch Track (passing
  over rejected and missing lanes in displayed order, Blind Listening's included,
  wrapping; disabled when `ComparisonSession.canSwitchPlayback` finds no
  switchable lane other than the active one), ⌘← / ⌘→
  Jump to Beginning / End, plain arrows skip, and Edit ▸ Deselect (⌘D) and
  Esc clear the loop (Esc does nothing without one). Clicking a lane and the number hotkeys select
  rejected lanes too. Both modes use ⌘R for Reject / Clear Rejection,
  ⌥⌘R for Change Repeat Mode (Playback ▸ Repeat), and ⌥⌘A / ⌥⌘P / ⌥⌘L
  for Show/Hide Artwork, Player and Playlist
  (`WorkspaceVisibility.Region.visibilityShortcut`, through
  `MainWindowCommandState.toggleVisibility`, the titlebar toggles' path).
  Compare's Auto-Align Tracks is ⇧⌘A. Playlist only: ⌘] Compare Versions (`PlaylistCommandContext.compare`,
  one multi-version item), ⌥⌘S Shuffle, ⌘G / ⇧⌘G Group / Ungroup Versions,
  File ▸ Locate File… (`locateVersionID`). Both modes: ⌥⌘↑ / ⌥⌘↓
  Move Up / Down. The Playback menu ends with Nudge Track (⌘J / ⌘K, ⇧ for
  larger steps), Reset Offset for the active compare lane, and Reset All
  Offsets for every lane in the current comparison. The bulk reset applies
  the offsets together via `PlaybackController.setOffsets` and captures
  the comparison edits once.
- One main window serves both modes (A2). With the player and lower region
  visible, it opens 360 pt wide (760 tall with artwork, 412 without) and is
  user-resizable down to `TakesWindowPolicy.minimumSize(for:isComparison:)`:
  260 × 519 with the
  artwork, 260 × 271 without (the compare control bar, its info bar, the
  ruler, one whole lane and the bottom bar; `minimumHeightWithoutArtwork`).
  Only the playlist remembers its height (the width is shared):
  `WorkspaceView.switchModeHeight` stores it on entering compare and
  restores it on leaving (`TakesWindowPolicy.storePlaylistHeight`,
  `WorkspaceView.applyModeHeight`; defaults key `main.a2.height.playlist`).
  The stored height excludes the cover and is normalized to include the
  player. A live resize, a track fit and a clamped artwork toggle in
  expanded playlist mode store it too. Compare sizes the window to the item's
  lanes (`compareFittingHeight` through `frameSettingHeight`, growing or
  shrinking). Launch gives the restored mode its height (`restoreModeHeight`).
  The retired `main.a2.height.compare` key is removed on launch. The
  artwork toggle changes the height by the cover height less 12 pt, clamped
  on screen. Hiding the lower region fits the window to the visible
  artwork or player and preserves the expanded playlist height. The
  player toggle removes or restores the control bar height above the divider.
  The lower region owns the divider, so hiding it hides the divider too.
  The Player and Playlist toggles animate the window with the cover held at
  its height in the final frame (`WorkspaceView.regionResize`), since the
  room reserved below the cover changes before the window reaches its new
  height; the window and content minimums allow both layouts meanwhile.
  Track fit, in both modes
  (`TakesWindowPolicy.frameFittingContent`): adding tracks grows a window
  too short to show every row (`playlistFittingHeight`: item rows and
  expanded version rows; `compareFittingHeight`: one lane per version),
  removing tracks shrinks a window taller than the rest need, and a window
  already tall enough keeps its height; top edge fixed, growth stops at the
  screen's bottom. `WorkspaceView.scheduleContentFit` follows the
  workspace's track count (the playlist's versions, or the compared item's),
  never the runtime's rows, so runtime rebuilds don't resize; it skips mode
  switches, restoration, a hidden lower region, a running artwork resize and full screen, and waits
  30 ms so an import's selection and expansion land first. Its
  frame autosaves as `main.a2`; do not reintroduce per-mode frames (only
  the playlist's height is remembered).
  Playlist and compare crossfade below the shared cover. Toggling artwork
  slides the cover down from the top or back up along the same
  path while the window resizes. The cover and control-bar inset follow
  the window's current height, keeping the transport at a fixed distance
  from the bottom. A screen-clamped resize animates the remaining cover
  travel. Both transitions respect Reduce Motion.
- The cover and visibility toggles live in `WorkspaceView`, above both modes'
  control bars, so entering compare never moves them. While the cover is
  shown, its AppKit hover sensor reveals the toggles and window buttons, with
  a shade behind them over the image. With the cover hidden, the controls stay
  visible. Artwork or Player must stay visible. The toggles share one
  rounded material background and stay visible in the artwork-only layout.
  With Player hidden, hovering over the cover reveals playback controls at
  its bottom in the same material. The overlay uses 32 pt Play/Pause and
  26 pt secondary buttons. Playlist shows Previous, Play/Pause and Next.
  Compare shows Play/Pause and Switch Track. The Playlist toggle controls
  the divider and everything below it in either mode. Hiding it disables
  navigation between modes, including a grouped import opening Compare.
  The View menu offers the same three
  visibility commands. The control bars take their top padding from
  `TakesWindowPolicy.controlBarTopPadding(showsArtwork:)`
  (12 under the cover, 24 under the titlebar). The cover's version comes from
  `CoverVersionRule`: in compare it follows the audible version, except in
  Blind Listening Mode, where it stays on the item's key version so it
  can't reveal which version is audible. The previous cover stays up until
  the next one has loaded (`shownCoverVersionID`), so switching never
  flashes the placeholder.
- Without artwork, the cover and the item rows' thumbnails show a record
  ([docs/a2-record-placeholder-spec.md](docs/a2-record-placeholder-spec.md)):
  bundled bitmaps, a light and a dark variant each, in
  `Assets/Assets.xcassets` (`RecordPlaceholderCover`, 1440 px for the
  360 pt square; `RecordPlaceholderThumbnail`, 68 px with its ground),
  generated by `scripts/make-record-placeholder.swift` (seeded, so
  re-running gives the same PNGs; run it from the repository root after
  changing the design). Nothing is rendered at runtime: the cover scales
  its one bitmap to the `min(width, height)` square
  (`RecordPlaceholder.coverSquare`) during and after resizes, over a SwiftUI
  `RadialGradient` ground sized to that square whose edge colour fills the
  rest. Every eligible row shares `RecordPlaceholder.thumbnail` through the
  tile's `contentsImage` (`PlaylistThumbnailView.tileImage`: artwork, else
  the record, except the warning state's plain tile); `PlaylistFillView`
  resolves the appearance variant in `updateLayer`, so visible rows swap
  it when the appearance changes.
- Artwork is in-memory only (no disk caches); the readouts carry none. The
  cover loads only the version on display, capped at
  `PlaylistArtworkStore.capacity` decoded images. Playlist item rows show a
  34 pt thumbnail of their key version from a separate bounded cache
  (`thumbnailPixelSize` 68 px, `thumbnailCapacity`, at most
  `maximumConcurrentThumbnailLoads` decodes at once). Decoding sizes come
  from `ArtworkDecodeTarget` (`.cover` 720 px, `.thumbnail` 68 px): Image I/O
  caps the long edge, so a cropped image's long edge grows with its aspect
  ratio until the short edge reaches the target. The cover crops only nearly
  square art (`CoverArtworkLayout.maximumCropAspect`, 1.1) and otherwise
  fits the whole image over a blurred fill of itself; thumbnails always crop
  (extra resolution capped at 4:1). The outline controller
  requests thumbnails only for item rows inside the visible rect
  (`requestVisibleThumbnails`, coalesced per run-loop turn on scroll/resize/
  reload), and each request replaces the queue, so rows scrolled away before
  their turn — and rows AppKit prepares off screen — are never decoded. A
  version whose cover is decoded (or decoding) is scaled from that image
  instead of reading its file again. Finished thumbnails are pushed into the
  visible cell (`onThumbnailLoaded`), never by reloading the table. A key
  version change (a rejection, a reorder) updates the item row's title,
  thumbnail, duration and metadata through the same content path, never a
  table reload.
- Both modes build their control bar from one `ControlBarLayout` (A2 §5):
  the centre group centred with 12 pt gaps; the 30 × 40 pt side buttons each
  centred midway between its window edge and the playlist's Previous · Play
  · Next group (`ControlBarTransportRow`,
  `ControlBarMetrics.sideButtonCenterX`), at the same place in compare even
  though its centre group is narrower; in playlist mode the readout inside
  the 10 pt insets; then the one `ControlBarDivider`. Compare has no readout
  (`ControlBarLayout`'s readout-less init): its bar ends 10 pt under the
  transport row (`ControlBarMetrics.transportRowBottomPadding`), 51 pt
  shorter than the playlist's (79 vs 130 pt with the artwork), and the
  transport row doesn't move between modes. It stretches to any width of
  260 pt or more, with at least 10 pt between each side slot and the window
  edge. Side buttons are plain icons
  (`ControlBarSideButtonStyle`) with no lamp or other indicator: the lit
  glyph is the on state. Their values are
  `TransportAppearance.lightSideButton`/`darkSideButton`
  (`SideButtonAppearance`, tunable in the Appearance Tuner), not the circle
  buttons' secondary fields. The lit glyph is `Theme.sideButtonLitGlyph`
  (#F4F2FF in dark, with three glow layers; the dark off glyph is
  #86868C); the titlebar toggles share that glyph and glow. Repeat's
  glyph names its mode in both modes (`repeat.1` for Repeat One; compare's
  symbols are `ControlBarRepeatSymbol.compare`). Centre buttons are v2.9.0's
  `CircleTransportButtonStyle` (Play 56/22, secondary 40/15). Previous/Next
  are playlist-only. There is one readout frame, v2.9.0's Glass
  (`readoutGlass`); the Teenage Engineering theme and the Retro frame were
  removed, and their stored preferences are simply not read.
- The readout title comes from `ControlBarReadoutTitle.playlist`: the
  playing (or current) version's title tag, else its filename without the
  extension, preserving its capitalization. With no current version, the
  title field shows `READY` in subdued dot-matrix text. Compare shows no
  version title in its control bar or info bar; the active lane and the cover
  carry the audible version.
  Long titles scroll (`DotMatrixMarqueeText`). The title field takes
  its width from the line, never from its text (the cells draw in an
  overlay); sized by its cells it could only grow, and a launch-time layout at
  a restored wider frame left the readout wider than the window.
- Compare's info bar (32 pt, between the control bar's divider and the
  ruler, on the well with no line to the ruler) shows `N versions` (`1 version`,
  `CompareInfoBarText`, unchanged when blind) on the left, the elapsed
  time in a 24 pt Glass frame centred in the window
  (`CompareInfoBarRow` gives both sides equal widths), and Done on the
  right. Compare leaves through Done or ⌘[ — both
  `PlaylistCoordinator.backToPlaylist`, which keeps the audible version as
  the current version of the playlist's current track, at the translated
  file time. It is listening state, not a stored choice:
  `PlaylistPlaybackBoundary.capture` writes no key version, so the item row
  may show its key version while the readout and cover show the one
  playing. Zoom's
  on-screen control is in the bottom bar (magnifier − · slider · magnifier
  +, no Fit); ⌘+/⌘−, Zoom to Selection, Zoom to Fit and pinch also zoom.
- Both modes dim their content (control bar, list or lanes, bottom bar)
  while the main window is in the background, with one modifier
  (`windowActivityAppearance`, in `ContentView.swift`); the cover and the
  file-drop highlight stay at full colour. Help ▸ Debug ▸ Show Component Names
  tags components in both modes (`componentDebugLabel`); the playlist
  table's rows, being AppKit, use `ComponentDebugBadgeView` via
  `PlaylistRowView.debugLabel`.
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
  clicks; the strip's empty middle passes clicks through. The context menu
  starts with Reject / Clear Rejection for that lane. Don't fold the
  strip into `TrackRowView` or put it under the gesture surface: its controls
  would stop receiving clicks and the playhead line would cross them. The
  strip's frame runs from the lane's top to the waveform band
  (`CompareLaneLayout.stripFrameHeight`), its contents centred. The offset
  field (`LaneOffsetField`) sizes itself to its number, including while it is
  typed; hovering it shows an "Offset" label to its left that takes room in
  the row, so a long title truncates rather than running under it. Its hover
  comes from an AppKit tracking area (`HoverSensor`), because SwiftUI hover is
  unreliable over the AppKit text field. Strip titles use
  the version-row rule (`PlaylistRowText.versionName`) and always appear.
  The Metadata tab has separate Format, Sample Rate, and Bitrate settings for
  Compare, all enabled by default. `LaneStripText.format` joins available,
  enabled values with ` • ` for the strip, tooltip, and drag preview. Blind Listening Mode
  shows `Track n`, no format or tooltip, and disables Reveal in Finder.
- A rejected lane (culling §5.4, §9.1) shows the 15 pt grey broken heart
  (`RejectionBadgeView`) in place of its index, a dimmed title and format,
  `LaneHatching` across the whole lane behind its visuals, and the inactive
  waveform colour, active or not; the active tint stays. Blind Listening
  shows it too: it reveals only that the lane was rejected, never which file
  it is. Rejecting the active lane doesn't switch away from it.
- Compare has no header. Its bottom bar (A2 §7) has Add Version… (⌘O's
  dialog, importing into the captured item), Remove Active Version (File ▸
  Remove Version, Delete), Align (⇧⌘A), Reject (the active lane) and
  zoom. Remove All Versions is ⌘⌫ only. Align shows the quick pass's spinner, tempo analysis's progress
  ring and the two-second outcome flash, and anchors the "Couldn't Align
  Tracks → Analyze Further" popover; in Blind Listening Mode the popover
  lists `Track n`, never file names.
- Both modes build their bottom bar from one `BottomBarLayout` (A2 §7): 30 pt
  including its 1 pt top hairline, 10 pt insets, standard small controls
  (`.controlSize(.small)`). The compare zoom slider contracts from 96 pt
  to fit narrow widths. It sits below the playlist table or the compare lanes and
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
  info bar) that re-renders once per displayed second from
  `playingReadoutText`; nothing else in the control bar or the info bar
  reads it or the transport position.
  The LED meter's fill and brighter head, and dark appearance's glow under
  them (pre-blurred images, never live layer shadows), step on discrete
  `CAKeyframeAnimation`s armed per transport anchor event; titles scroll on
  Core Animation only when they overflow. The marquee pauses its layer
  clock when its window resigns key and resumes when it becomes key again.
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
  per-zoom value (their `isRejected` and `isMissing` inputs change only on
  a rejection edit or a runtime rebuild) (the bottom bar's zoom slider included: it is its own leaf,
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
  starting another item, compare opening (and restoring) with missing
  versions as error lanes, media-player Previous/Next Track, leaving compare
  keeping the audible version current without changing the key, culling
  (Next/Previous/natural advance/Shuffle/Repeat All skipping rejected
  tracks and keeping them out of history, explicit play, Play with no
  current track, rejecting the current track or version without
  interrupting it, Reject targets and title, Undo/Redo of Reject, compare
  switching past rejected lanes and rejecting the active lane in place),
  and workspace/runtime integration.
- `PlaylistRuntimeTests.swift`: runtime replacement, stable IDs, stale imports,
  teardown, preparation failure, and natural-end callbacks.
- `PlaylistWorkspaceStoreTests.swift`: snapshot round trips (rejection flags
  included), recovery protection, schema handling (the schema-1 migration
  moving the stored key version to the front), file references, and
  retained downloads.
- `PlaylistPersistenceControllerTests.swift`: restoration/save gating, failures,
  and automatic event-save observation rearming.
- `PlaylistWaveformContextTests.swift`: stale waveform rejection across
  activations, finished waveforms kept when the same item re-activates, and
  `WaveformCache` (reuse across stores and items, unfinished and
  stopped-early results left out, the identity following a symlink's
  target, LRU eviction by byte budget).
- `PlaylistWorkspaceTests.swift`: playlist value encoding/validation, stable
  ownership, canonical duplicates, atomic organization operations, the
  key-version rule (first non-rejected, all-rejected fallback, missing key
  stays key), and the rejection flags through reject, move, group, separate
  and coding.
- `PlaylistPlaybackBoundaryTests.swift`: signed position conversion, session
  identity, loop entry, playlist gain isolation, blind-order-safe capture
  (which never stores a key version), and descriptive tags reaching
  comparison tracks.
- `TransportMappingTests.swift`: transport math and range behavior, plus
  loop-wrap anchor math and gapless pre-queue segment mapping.
- `SessionTests.swift`: higher-level state, import behavior, Music/Finder
  selection handling, numeric control stepping, blind listening, the A2 window
  policy (sizes, minimums, artwork-toggle frames, clamping, fitting
  heights and the grow/shrink rules for added and removed tracks, the stored
  playlist height, compare sizing to its lanes on entry, and the debug
  reset frame), missing versions as silent lanes that stay in the switch
  order, compare switching past rejected and missing lanes (`switchTarget`,
  `canSwitchPlayback`, Switch & Repeat degrading to Repeat One, Align's
  `hasMultipleTracks`), the rejected/missing lane hatching, the playlist
  culling visuals (row text styles, the version mark column, the
  thumbnail's dimming and badge, the expanded now-playing split, the
  broken heart's geometry: turns per size, the gap at notch and tip, and
  halves that never overlap),
  the beta update preference and Sparkle channel selection,
  persisted window visibility, compact heights, the artwork/player
  invariant, retired control-bar preferences loading as defaults, the
  A2 readout title rule (tag, filename), the compare control bar's height
  and the info bar (its geometry, centring and take-count text), the
  ruler labels' tops level with the major notches, the LED meter's cell count
  (no endcaps), head geometry, unlit opacity and glow, the control bar's side-button placement, the side buttons' appearance defaults, compare's repeat glyph per mode, the cover
  rule (`CoverVersionRule`), the A2 playlist row metrics, version names,
  metadata formatting and playlist and compare preferences, the record placeholder (cover-square
  sizing and ground, the thumbnail rule,
  one bitmap per appearance, and the disc, label and lead-in geometry
  measured in the exported cover), the
  thumbnail cache (visible-only queue, concurrency bound, capacity, cover
  reuse, the cover's crop-or-fit rule and decode sizes), the A2 compact compare geometry (ruler and seat, the fixed lane
  height, the waveform band, ruler notches and labels, the playhead's line
  and grabber), the lane strip's text and blind rules, the offset field's
  width, the bottom bars (the playlist summary's count and total, rejected
  tracks left out, both
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
- `LoopingTests.swift`, `TimelineHeaderMarkerTests.swift`, and
  `TrackAlignerTests.swift`: their named subsystems.
- `TrackDropHighlightTests.swift`: drop targeting, the playlist outline's
  32-version limit for item and version row drops, and import command routing.
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

- [docs/culling-spec.md](docs/culling-spec.md): rejecting tracks and
  versions, and the derived key version. Implemented, with the R shortcut
  (§8 question 1) and the summary leaving rejected tracks out (question 2).
  Questions 3–5 (Move to Top, Hide Rejected, Accept flags) and the
  now-playing emphasis in §9.2 are not implemented.
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
  [docs/a2-compare-info-bar-spec.md](docs/a2-compare-info-bar-spec.md)
  (done) replaced compare's readout row with the info bar; it overrides
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
