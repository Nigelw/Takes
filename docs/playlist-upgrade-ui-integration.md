# Playlist UI integration

Status: proposed UI handoff; no UI implementation yet. Implements the approved
[specification](playlist-upgrade-spec.md) and
[contracts](playlist-upgrade-contracts.md). API names below are proposals for
agreement with the coordinator owner. Preserve the existing comparison layout
and components; the deployment target is macOS 14.

## View ownership and hierarchy

`TakesApp` owns one `@State PlaylistCoordinator`. A new `WorkspaceView` owns
window configuration, focused commands, import presentation, error presentation,
and the single main-window keyboard monitor. The coordinator owns the sole
`PlaybackController`; no playlist row owns a controller or audio resource.

```text
Window("Takes", id: "main")
  WorkspaceView
    mode-specific transport surface
    ZStack
      PlaylistView (retained across navigation)
        organization header / existing import split button
        native List(selection:) of stable item/version row IDs
          item: disclosure, title/artist, album, duration, versions, Compare
          expanded version: selected-version control, filename, duration, actions
      comparison detail (mounted only while comparing)
        Back to Playlist + item title
        existing comparison timeline/header/track rows
    shared importer, streaming sheet, repair picker, errors
```

Use the existing `WindowBackground`, `WindowDragArea`, `Theme` tokens,
`CircleTransportButtonStyle`, `DigitalTimeReadout`, and import split button.
Keep the raised transport surface and recessed content treatment. Use native
selection, disclosure controls, buttons and context menus for organization.
Rows use aligned metadata columns; title and artist share the flexible column,
album truncates before duration and version controls do. Missing metadata falls
back to filename/title and a secondary em dash. Do not add artwork or waveforms
to playlist rows. A playing symbol is distinct from the row selection highlight
and from the selected playback-version checkmark.

Playlist transport has Previous, Play/Pause, Next, file seek, Shuffle, and
Off/One/All repeat. Comparison retains its current controls and adds Back and
the item title in a compact navigation strip above the timeline. Include the
strip height in comparison sizing rather than compressing existing lanes.
Reuse the readout's existing whole-second updates. A moving playlist seek thumb
uses a small AppKit/Core Animation leaf driven by transport anchors; dragging
and accessibility adjustments dispatch seeks without publishing frame ticks.

## Selection, expansion, and scrolling

Keep `PlaylistPresentationState` at workspace-view lifetime: a set of selected
row IDs, expanded item IDs, and the focused row ID. Use a discriminated row ID
(`item(UUID)` / `version(UUID)`) rather than indices or file URLs. Single-click
changes organization selection only; double-click/Return invokes playback.
Changing the selected version uses an explicit control, not row selection.

Retain the playlist `List` at a stable identity beneath comparison, with opacity
zero, hit testing disabled, and accessibility hidden while comparing. This
retains native scroll position without observing scroll offset or rebuilding
the list on every navigation. Do not attach active-mode handlers to its
`onAppear`. On Back, restore keyboard focus to the surviving focused row without
scrolling to the playing item. Prune deleted row IDs after mutations; select a
group result or nearest surviving row once. Keep playlist frame dimensions
stable while hidden so comparison auto-sizing does not discard the scroll
position; verify this against the macOS 14 native List behavior.

Command/Shift multiselection and Up/Down remain native list navigation. Left/
Right expand or collapse when the list has focus. In that focus context, the
existing unmodified arrow skip shortcuts yield to the list; explicit transport
menu actions and Command-arrow jumps remain available. Comparison retains its
current numeric version hotkeys and arrow-switch behavior. Text editing takes
precedence in either mode, including rename and Locate File sheets.

The header/context menu offers Group as Versions, Group and Compare, Rename,
Separate, Move To, Remove, and Clear Playlist. Group actions accept selected
item rows in workspace order. Version operations accept selected version IDs;
mixed selections normalize away children whose parent is selected. Move To
names a destination item and disables destinations exceeding 32 versions.
Grouping beyond 32 fails atomically with a readable error. Reordering supports
selected items as one ordered block; expanded versions can reorder within an
item or move through Move To. Provide Move Up/Down menu actions so organizing
does not require a drag. Undo/Redo uses the main window's `UndoManager`, with
coordinator-owned transactions and action names.

Use a private playlist drag type distinct from the existing
`TrackReorderDrag.contentType`; do not classify Finder's plain text as an
internal reorder. External files dropped anywhere in playlist create items;
external files dropped in comparison add versions to its captured item.

## Entry points that must switch together

| Existing hook | Integration change |
| --- | --- |
| `TakesApp.controller`, `ContentView(controller:)`, app `.onAppear` | Install the coordinator/root shell, connect settings and remote commands once, and start restoration before exposing normal import actions. |
| `ContentView.init` closures constructing `OpenFileCommandState` | Route streaming, Music selection, Finder selection, removal and clearing through coordinator operations. Retain `NSWorkspace` reveal behavior using the mode's target version. |
| `OpenFileCommandState.presentOpenDialog`, `presentStreamingURLPrompt`, `openStreamingURL`, `openAppleMusicSelection`, `openFinderSelection` | Capture `PlaylistImportDestination` before presenting a picker/prompt or starting selection lookup. Each operation retains its own destination and task identity. |
| `ContentView.handleImport`, `performImportAction`, `.fileImporter`, streaming sheet | Move presentation to the persistent shell; pass the captured destination through completion. Cancellation clears that operation only. |
| `WindowFileImportDropDelegate`, `loadDroppedURLs`, `TrackRowDropKind` | Capture destination before asynchronous provider reads; preserve provider order and existing natural folder ordering. Keep internal reorder precedence over its accompanying file URL. |
| `ContentView.configureAppOpenRouter`, `AppDelegate.application(_:open:)`, `AppFileOpenRouter.setHandler` / `setStreamingURLHandler` | Register handlers at app/coordinator lifetime, never comparison appearance. Queued Finder and `takes:open-file`/`takes:open-url` batches append to the playlist after restoration. Handle every streaming URL rather than replacing one shared prompt/task in a loop. |
| `FileCommands`, focused `openFileCommandState` / `canClearTracks` / `canRemoveActiveTrack` / `canShowActiveTrackInFinder` | Publish mode-aware action targets and validation. Remove acts on playlist selection or comparison's active version. Clear Playlist is undoable; comparison Remove All removes that item's versions, never the entire workspace. |
| `PlaybackCommands`, `ContentView.playButton` / `switchTrackButton` / `repeatButton` | Share coordinator transport commands and enabled state. Next/Previous mean playlist traversal or comparison version switching. Repeat options and labels follow mode. |
| `ContentView.setupKeyMonitor`, `GlobalShortcutFocusPolicy`, focused `canUseGlobalMenuShortcuts` | Install one mode-aware monitor restricted to the main window. Coordinate Space, X/Shift-X, arrows, and number keys with menu equivalents; preserve field-editor routing and native list navigation. |
| `ViewCommands`, app Deselect, Blind Listening, Auto-Align, Nudge | Gate comparison-only commands by mode. Deselect targets playlist selection in playlist mode and the loop in comparison. Do not expose comparison shuffle as playlist Shuffle. |
| Timeline seek/loop gestures, gain/offset bindings, row select/remove/reorder callbacks | Keep rendering and gesture math in comparison; route application mutations through coordinator wrappers so edits synchronize by version ID. Never persist blind-shuffled runtime order. |
| `RemotePlaybackCommandController.connect`, `configureCommands`, `refreshRemoteState`, `updateRemoteState` | Observe a coordinator snapshot, using separate next/previous capability flags. Retain event-driven Now Playing publication; report playlist file time/metadata or comparison's established timeline/blind labels as appropriate. |
| `MainWindowConfigurationView`, `TakesWindowPolicy.configureMainWindow`, row-count `.onChange`, focused `mainWindowCommandState` | Configure once at shell lifetime; apply auto-grow/shrink only in comparison. Make Debug Reset Window Size mode-aware. |
| `ContentView.onAppear` / track `.onChange` calling `waveformStore.sync` | Keep waveform synchronization inside active comparison only, guarded by runtime context and stable IDs. Playlist rendering never starts decoding. |
| `.willTerminateNotification` calling `cleanupStreamingDownloads` | Replace with workspace persistence/resource lifecycle integration; quit must not delete retained downloads or Undo resources. |
| Debug `OpenComparisonWindowButton` | Continue feeding only the active comparison item's prepared versions; disable in playlist mode rather than accidentally passing its single prepared file. |

No view, menu, or remote handler may continue calling a legacy global import or
`clearTracks()` after the coordinator becomes the application entry point.

## Coordinator surface required by UI

Read-only observable state should expose `workspace`, `mode` (playlist or item
ID), `controller`, current playing item/version IDs, restoration status, import
progress and errors, plus command validation. Playlist rows consume their item
value and stable playing/selection flags only. Comparison leaves may observe
the controller's existing viewport and transport anchors directly.

Required operations, with final signatures agreed before UI implementation:

- Navigation/playback: `playItem(id:versionID:)`, `selectPlaybackVersion`,
  `enterComparison(itemID:)`, `backToPlaylist()`, `play`, `pause`, `togglePlayback`,
  `next`, `previous`, `seek`, `skip`, `jumpToBeginning`, `jumpToEnd`, playlist
  shuffle/repeat setters, and comparison repeat/blind/adjustment wrappers.
  The coordinator performs file-time conversion, loop deselection and runtime
  activation; views must not calculate transition positions.
- Imports: destination capture plus destination-taking local, Music, Finder
  and streaming entry points. Deleted destinations report failure. Inactive
  destination commits update content without replacing active runtime.
- Organization: ordered ID-taking group, group-and-compare, rename, reorder,
  separate, move, remove, and clear operations with UndoManager support and
  validation/capacity results. Return affected/result IDs for selection repair.
- Recovery: `locateFile(versionID:url:)`, explicit retry/recovery operations,
  error dismissal, and restored/failed status that distinguishes an absent
  snapshot. Locate replaces the reference while retaining version identity and
  rechecking workspace duplicates. Unavailable rows remain selectable and
  offer Locate File; failed restore does not masquerade as an empty playlist.
- Transport/remote snapshot: mode, title/artist/album where available, duration,
  elapsed/anchor, playing state, and independent `canPlay`, `canNext`,
  `canPrevious`. Snapshot changes at transport/content events, never per frame.

## Window policy

Playlist uses a scrollable, user-sized frame independent of item count and
expansion. Preserve its frame before entering comparison and restore it on
Back, clamped to the current display. Persist that frame separately if
comparison frame autosave would otherwise overwrite it. On launch in playlist
mode, do not execute the existing unconditional saved-frame height reset.
Choose a bounded playlist default/minimum suitable for the transport and a few
metadata rows; retain comparison's current width, info-column preference,
row-fit growth/shrink, monitor-bottom cap, and temporary-layout behavior.
Comparison row counts must never include inactive playlist items.

## Accessibility and verification

- Expose item title, artist, album, duration, version count, playing state,
  disclosure state, and selected version as meaningful labels/values. Keep
  Compare, Back to Playlist, version selection and Locate File keyboard and
  VoiceOver reachable. Color alone must not convey selection or availability.
- Announce repeat and shuffle values; expose seek as an adjustable control with
  elapsed/duration. Ensure hidden playlist rows are absent from the accessibility
  tree and comparison focus returns to the saved playlist row on Back.
- Verify four files → two groups → compare → change version → Back → next song,
  including paused and playing transitions, signed offsets and saved loops.
  Exercise grouping/moving/removing the playing version and Undo/Redo.
- Exercise all imports in the table, navigation during pending imports,
  destination deletion, unavailable files/Locate, restoration failure, and
  queued launch opens. Confirm general imports have no global 32-file limit.
- Verify Space/X/arrows/numbers, menus, media keys, Now Playing, rename fields,
  offset fields, blind mode, and comparison-only command validation together.
- Run canonical `xcodebuild test` with fresh `/private/tmp` DerivedData. For
  manual verification use the repository's `run-takes` skill and a separate
  Debug build; verify light/dark, minimum width, user sizing and Back retention.
- Check 100 playlist items and 32 comparison versions. Idle playlist items must
  own no audio nodes and trigger no waveform decodes. Preserve synchronous peak
  pyramid drawing, `TrackRowView`/lane-leaf isolation, equality-guarded viewport
  changes, Core Animation transport motion and pre-queued comparison wraps.

This document alone requires no build. UI implementation waits for reviewed
coordinator signatures and a runtime replacement boundary that does not delete
downloaded audio.
