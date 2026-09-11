# Playlist tracks with multiple versions

Status: approved feature plan; implementation integrated and automated validation
passed. Manual/external/performance acceptance remains incomplete; see the
implementation plan and validation report for evidence and remaining checks.

Implementation sequence: [playlist-upgrade-implementation.md](playlist-upgrade-implementation.md).

## Summary

Add a playlist above Takes’ existing comparison workflow. Each playlist item contains one or more versions of a song.

V1 uses manual grouping. Imported files initially become separate playlist items. Selecting items and choosing **Group and Compare** combines them and opens the waveform comparison. Later, automatic grouping can open comparison directly when an import contains only one detected song.

Keep one main window and automatically restore the last workspace. No document-based conversion, named project files, or multiple workspace windows in v1.

## Playlist interface

- Show an ordered list with title, artist, album, duration, version count, and playing indicator. Read embedded metadata where available; fall back to filenames.
- Show **Compare** for items containing two or more versions.
- Expand items to inspect versions, choose the playback version, move versions between items, or separate them into individual items.
- Single-click selects rows for organization; double-click starts playback. Support multiselection, drag reordering, and keyboard navigation.
- Provide **Group as Versions**, **Group and Compare**, rename, separate, move, and remove actions, with Undo/Redo.
- Grouping places the result at the earliest selected row and preserves version order. Use that row’s title and version as defaults, unless one selected version is currently playing.
- General playlist imports create separate items. Imports inside comparison add versions to the current item. Capture the destination when import begins so navigation cannot redirect an unfinished import.
- Preserve canonical file duplicate detection across the workspace.

## Playback and comparison

| Behavior | Playlist | Comparison |
|---|---|---|
| Audio | Full selected file, original gain | Existing gain, offsets, and shared timeline |
| End behavior | Next item; stop at playlist end | Existing comparison end behavior |
| Repeat | Off, One, All | Off, One, Switch & Repeat |
| Shuffle | Playlist items | Existing blind-listening behavior |
| Display | Metadata rows and seek control | Existing waveform lanes and timeline |
| Controls | Previous, Play/Pause, Next, seek, shuffle, repeat | Existing comparison controls plus Back |

- Playlist shuffle visits each item once per cycle; Previous follows listening history. Repeat One repeats the selected version.
- Entering comparison for the playing item preserves version, audible position, and playing/paused state. Entering another item starts its comparison at the beginning, preserving playing/paused state.
- Entering comparison retains saved adjustments and repeat mode, but deselects a saved loop if it would exclude the incoming position.
- Back continues the version currently being auditioned, remembers it for playlist playback, and resumes playlist advancement.
- Translate file time to comparison time using the version’s offset. Returning from comparison ignores offsets, gain, and loops; clamp positions outside the file to its bounds.
- Keep comparison settings per item. Blind listening stays confined to comparison and never shuffles playlist order.
- Grouping or moving a playing version preserves its identity and audible position. Removing the playing version pauses and selects the next available version or item.
- Menus, keyboard shortcuts, media keys, and Now Playing information follow the active mode. Numeric fields retain normal editing behavior.

## Window behavior

Use a playlist root and comparison detail view with **Back to Playlist** and the item title. Preserve playlist selection and scroll position across navigation.

Keep a scrollable playlist at the user’s chosen window size. Preserve comparison’s existing sizing behavior without letting playlist length or expanded groups grow the window indefinitely.

## Infrastructure

- Introduce an ordered `PlaylistWorkspace`, `PlaylistItem`, and stable version identities. Each item owns its selected version and comparison configuration.
- Separate persisted content from transient audio-engine state. Retain `ComparisonSession` as the active comparison model rather than making every playlist item a live playback controller.
- Add a coordinator responsible for playlist navigation, mode transitions, imports, and transferring comparison edits back to the workspace.
- Reuse one audio engine. Playlist playback prepares the selected file; comparison prepares only the current item’s versions. Retain the 32-version comparison limit and remove the global 32-file playlist limit.
- Split metadata loading from audio-runtime preparation. Generate waveforms on entry to comparison, using the existing bounded decoding queue and in-memory peak pyramid.
- Keep observation granular: playlist edits must not introduce per-frame list updates. Preserve Core Animation transport motion, lane isolation, and pre-queued comparison loops.
- Protect asynchronous import, alignment, waveform, and scheduling results with stable identities and context checks so stale work cannot affect a newly selected item.

No public API is added. Existing import and transport interfaces become destination-aware and mode-aware. Automatic grouping will later feed the same grouping operations rather than introducing a second import path.

## Workspace restoration

Use a versioned, atomically written snapshot in Application Support.

- Persist ordering, groups, titles, file references, selected versions, comparison adjustments, playlist modes, active view, and listening position.
- Restore the same view, always paused. Save on edits and transport events, with a lightweight periodic position checkpoint while playing.
- Restore before processing queued Finder/open events; append incoming files to the restored workspace.
- Reference local audio in place. Use file bookmarks with a stored-path fallback; show unavailable files with a **Locate File** action.
- Retain downloaded streaming audio in workspace-owned storage instead of deleting it on quit. Delay removal until it cannot break Undo.
- Skip unavailable items during sequential playback, report the issue, and stop if none are playable. Explicitly opening an unavailable item offers repair.
- Keep a last-known-good snapshot. Failed restoration must not silently overwrite recoverable data.
- Provide **Clear Playlist** as an undoable action. Never delete users’ original audio files.

## Defaults and deferred work

- Imported batches preserve their supplied order; folder imports retain the existing natural path ordering. Users can reorder explicitly.
- First available version is the default until the user selects another.
- Group merges preserve per-version gain; retain the destination group’s timeline settings and translate incoming offsets relative to its reference version. Splitting a version into its own item resets its offset and loop.
- No automatic grouping, named projects, multiple windows, crossfade, guaranteed gapless album transitions, metadata editing, or automatic quality-based version selection in v1.

## Acceptance

- Four imported files can become two items with two versions each, then be separated or regrouped without losing file identity.
- Play through an album, compare one song, select another version, return at the same audible location, and continue to the next song.
- Quit and reopen with the same organization, adjustments, view, and position, paused; missing files remain repairable.
- Existing comparison playback, signed timeline, blind listening, import safety, and performance invariants remain intact.
