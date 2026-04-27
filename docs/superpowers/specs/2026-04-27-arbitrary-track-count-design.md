# TrackSwitch Arbitrary Track Count Design

## Context

TrackSwitch currently has a fixed two-track comparison model. The UI has already moved toward a vertical track list with a shared timeline, but the underlying session, import, playback, and tests still assume Track A and Track B.

This feature removes the two-file limit and allows users to load, remove, and switch between an ordered list of tracks. The first release should keep the model intentionally simple: tracks are ordered by load order, reordering is out of scope, and the app enforces a conservative cap of 32 loaded tracks.

## Goals

- Support loading up to 32 tracks in one session.
- Append newly opened, dropped, or Music-selected tracks to the existing list.
- Allow individual tracks to be removed.
- Let `Switch Playback` cycle through loaded tracks in UI order.
- Keep instant switching by scheduling every loaded track in sync and making only the active track audible.
- Generalize the shared signed timeline to the union of all loaded track ranges.
- Remove the overlap warning behavior.
- Keep the initial implementation focused and testable without adding track reordering.

## Non-Goals

- Track reordering.
- Session persistence.
- Waveform extraction or waveform caching.
- Multi-track simultaneous audible playback.
- Mixing, solo/mute groups, or export.
- A product promise of unlimited tracks.

## Core Model

Replace the fixed `ComparisonSession.trackA`, `ComparisonSession.trackB`, and `TrackSide` model with an ordered collection:

```swift
struct ComparisonSession {
    var tracks: [SessionTrack]
    var activeTrackID: SessionTrack.ID?
    var isPlaying: Bool
    var transportPosition: TimeInterval
    var timelineStart: TimeInterval
    var timelineEnd: TimeInterval
}
```

Each loaded row should have a stable identity:

```swift
struct SessionTrack: Identifiable, Equatable {
    let id: UUID
    var loadedTrack: LoadedTrack
}
```

`LoadedTrack` can continue to own URL, display metadata, duration, sample rate, channel count, gain, and offset. The key change is that gain and offset belong to the track instance in the ordered list, not to a fixed A/B side.

Rules:

- The first successfully loaded track automatically becomes active.
- If at least one track remains loaded, there should normally be an active track.
- If no tracks are loaded, `activeTrackID` is `nil`.
- `isPlayable` is true when at least one track is loaded and `timelineEnd > timelineStart`.
- `canToggleComparison` should become a more general `canSwitchPlayback`, true only when at least two tracks are loaded.
- Row labels should be display-only ordinals such as `Track 1`, `Track 2`, and may change after removals.
- Stable IDs, not labels or indexes, should drive active selection, row identity, and runtime audio resources.

## Import Behavior

All general imports append to the existing list:

- `Open` appends selected audio files.
- `Load Selected from Music` appends the selected Music tracks.
- Dropping files on the list or timeline background appends them.

Batch imports are best-effort, not atomic:

- Each file attempts to load independently.
- Successful files append in selection order.
- Failed files do not prevent successful files from appending.
- All failures from one batch are presented together in one user-facing error.
- If a batch would exceed the 32-track cap, the app appends only until the cap is reached and reports skipped files in the same summarized error.

The 32-track cap is an app-level guard for the initial release. It avoids unbounded growth in `AVAudioEngine` nodes, scheduled players, file handles, memory use, and UI rows while still removing the current two-track limitation.

Suggested cap error text:

```text
TrackSwitch currently supports up to 32 loaded tracks.
```

The summarized import error should include enough detail to act on, such as the display names of failed or skipped files. The UI can continue using the existing inline error area for this release; a modal alert is not required by the spec.

## Music Selection

Music selection should allow more than two local-file tracks, up to the remaining TrackSwitch capacity.

The AppleScript should keep returning each selected track's Music view index and POSIX path so TrackSwitch can preserve Music's selection order. Parsing should continue sorting by Music index before appending.

Music-specific failure cases remain:

- Music.app is unavailable.
- Music.app is not running.
- No track is selected.
- A selected track is not a local file.
- A selected path does not exist.

Failures from Music selection should use the same best-effort import summary when some selected tracks load and others fail.

## Row Replacement And Removal

Dropping one file directly onto an existing track row replaces that row's track:

- Replacement resets gain and offset to defaults.
- Replacement keeps the row's stable ID.
- If the replaced row is active, it remains active.
- If replacement succeeds while playback is running, playback should keep running and the row should be rescheduled from the current transport position.
- If replacement fails, the existing row remains unchanged and the error is shown.

Dropping multiple files onto a row should not try to map multiple files to one row. Treat it as a general append operation using the batch import rules.

Each loaded row should include a remove control. Removing a track:

- Preserves all remaining tracks and their gain/offset settings.
- Removes that row's runtime audio resources.
- Recalculates the shared timeline.
- Clamps or preserves the current transport position using the existing timeline recalculation policy where practical.

Removing a non-active track:

- Leaves active selection unchanged.
- Keeps playback running if it was running.

Removing the active track:

- Pauses playback.
- Selects the next track by the removed row's index.
- If the removed row was last, selects the previous remaining track.
- If no tracks remain, clears active selection.

## Playback

Playback should maintain one scheduled player/mixer path per loaded track. Only the active track's mixer is audible.

Rules:

- Play schedules all loaded tracks from the shared transport position.
- Switching playback updates active selection and mixer volumes only.
- `Switch Playback` cycles by current UI order and wraps from the last track to the first.
- `Switch Playback` is disabled when fewer than two tracks are loaded.
- Gain changes update the track's stored gain immediately. If that track is active, the audible mixer volume updates immediately.
- Offset changes recalculate the timeline. If playback is running, all loaded tracks should reschedule from the current transport position so sync remains correct.
- Appending tracks while playback is running keeps playback running. Newly appended tracks are attached, scheduled from the current transport position, and silent unless selected.
- Replacing a row while playback is running keeps playback running if replacement succeeds and rescheduling succeeds.
- Natural end-of-playback stops playback, keeps the active track selected, and parks transport at `timelineEnd`.
- Manual rewind should continue seeking to `timelineStart`.
- Manual stop can keep its current behavior unless implementation exposes a clearer separate rule that needs review.

The controller should avoid using fixed `playerA`, `playerB`, `mixerA`, and `mixerB` properties. Runtime audio state should be keyed by `SessionTrack.ID`, for example:

```swift
struct RuntimeTrack {
    let file: AVAudioFile
    let player: AVAudioPlayerNode
    let mixer: AVAudioMixerNode
}
```

The implementation should detach and clean up runtime nodes when tracks are removed. It should also handle the case where a track is appended while the engine is already running.

## Timeline

The shared timeline spans the union of all loaded track ranges, including global zero where appropriate.

For each track:

```text
trackStart = track.offsetSeconds
trackEnd = track.offsetSeconds + track.duration
```

For the session:

```text
timelineStart = min(0, all track starts)
timelineEnd = max(0, all track ends)
```

If no tracks are loaded, both timeline bounds are `0` and the transport position is `0`.

Seeking clamps to `timelineStart...timelineEnd`. File scheduling continues to map shared global time to each file's local position:

```text
filePosition = globalTime - track.offsetSeconds
```

The existing overlap warning should be removed. With more than two tracks, pairwise or all-track overlap warnings become noisy and ambiguous, and they are not required for this release.

## UI

The track list should scale vertically up to 32 tracks:

- Use a scrollable list/timeline region when the loaded tracks exceed available vertical space.
- Show one row per loaded track.
- Remove fixed empty `Track A` and `Track B` placeholder rows.
- When no tracks are loaded, show a single empty drop target/list placeholder.
- Keep the shared playhead visible across the track lane area.
- Each row shows ordinal label, active state, display name, metadata, gain control, offset control, and remove control.
- The row's active indicator should be driven by `activeTrackID`.
- The row's remove control should be available only for loaded rows.
- `Switch Playback` is disabled for zero or one loaded track.

Drag and drop:

- Dropping one file on a row replaces that row.
- Dropping multiple files on a row appends.
- Dropping on the background appends.
- Drop target styling should still make the row target clear.

The UI should not add reordering handles or drag-to-reorder behavior in this release.

## Errors

The app should show user-facing errors for:

- Unsupported audio files.
- Failed file open.
- Music selection failures.
- Files skipped because the 32-track cap was reached.
- Replacement failure.
- Scheduling or engine failures.

Batch import errors should be grouped. A successful best-effort import may still leave an error visible if some files failed or were skipped.

## Implementation Boundaries

Likely code areas:

- `Sources/TrackSwitch/Models.swift` for ordered session state and track identity.
- `Sources/TrackSwitch/PlaybackController.swift` for import, removal, active selection, runtime audio resources, scheduling, and audibility.
- `Sources/TrackSwitch/TransportMapping.swift` for N-track timeline range helpers.
- `Sources/TrackSwitch/ContentView.swift` for rendering a dynamic list, row replacement, removal, and import/drop behavior.
- `Sources/TrackSwitch/LibraryTrackSelectionLoader.swift` for removing the two-track Music selection limit.
- `Tests/TrackSwitchTests/SessionTests.swift` for session/import/removal behavior.
- `Tests/TrackSwitchTests/TransportMappingTests.swift` for N-track timeline math.

The implementation should preserve the existing SwiftUI/AppKit bridging patterns for numeric controls and keep unrelated visual polish out of scope.

## Testing

Automated tests should cover:

- Empty sessions are not playable and have no active track.
- The first appended track becomes active.
- Additional imports append without replacing existing tracks.
- Existing gain and offset settings remain unchanged after appending or removing other tracks.
- The 32-track cap appends only available slots and reports skipped files.
- Best-effort batch import appends successes and reports all failures.
- Music selection parsing allows more than two tracks and preserves Music view order.
- Single-file row drop replaces that row and resets gain/offset.
- Replacement failure leaves the existing row unchanged.
- `Switch Playback` cycles through list order and wraps.
- `Switch Playback` is disabled with zero or one loaded track.
- Removing a non-active track keeps active selection and playback state.
- Removing the active track pauses playback and selects next or previous as specified.
- Removing the final track clears active selection and resets timeline state.
- Timeline range is computed from N tracks and includes zero.
- Offset changes while playing reschedule from the current transport position.
- Appending while playing keeps playback running and schedules the new track silently.
- Natural playback end stops at `timelineEnd` and preserves active selection.

Manual verification should cover:

- Loading more than two files from `Open`.
- Loading more than two selected local tracks from Music.app.
- Removing tracks from the list.
- Switching playback through three or more tracks.
- Appending tracks while playback is running.
- Replacing a row by dropping one file.
- Dropping multiple files on a row appends instead of replacing.
- Scrolling a long track list.
- Error summary content for mixed successful and failed imports.
