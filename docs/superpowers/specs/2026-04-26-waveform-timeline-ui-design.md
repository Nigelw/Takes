# TrackSwitch Waveform Timeline UI Design

## Context

TrackSwitch currently compares two loaded audio files with shared transport playback, instant active-track switching, per-track gain, and Track B offset. The UI is still arranged around per-track load cards, a separate transport slider, and control cards below the transport.

The new UI should make the shared timeline visible. Playback controls move to the top, tracks are listed below, each track shows a waveform lane, and the transport slider is replaced by a vertical playhead that extends through the waveform area.

Real waveform extraction is not part of this first implementation. Placeholder waveform rendering is acceptable while the timeline, loading, offset, and interaction behavior are implemented correctly.

## Goals

- Move playback controls to the top of the window.
- Replace the transport slider with a draggable playhead over the waveform area.
- Show two track lanes below the controls, each with a placeholder waveform.
- Position each waveform on a signed global timeline using that track's offset.
- Allow both Track A and Track B offsets.
- Move gain into a per-track gear popup.
- Keep offset visible and editable on each track row.
- Replace separate load buttons with one `Open` button plus a dropdown action for Music import.
- Use consistent file assignment rules for `Open`, Music import, and general drag-and-drop.

## Non-Goals

- Real waveform extraction, caching, or audio analysis.
- Automatic alignment.
- Loudness analysis.
- Session persistence.
- Export or rendering.

## Timeline Model

The app should use a signed global timeline for playback and display.

Each loaded track occupies this global range:

```text
trackStart = track.offsetSeconds
trackEnd = track.offsetSeconds + track.duration
```

The visible and playable session range is the union of the loaded track ranges plus the global zero point:

```text
timelineStart = min(0, loaded track starts)
timelineEnd = max(0, loaded track ends)
```

Positive offsets create leading empty space before a track's waveform because the visible range still includes `0:00`. Negative offsets expand the visible timeline left of `0:00`, while `0:00` remains a meaningful global timeline marker. Both full waveforms should remain visible when offsets differ.

The playhead position is signed global time. Seeking clamps to `timelineStart...timelineEnd`, not to `0...duration`. Playback scheduling maps global time to a track file position with:

```text
filePosition = globalTime - track.offsetSeconds
```

A track is audible only when `filePosition` falls within `0...track.duration`. If the active track is out of range at the current global time, playback is silent until the playhead enters that track's range.

## Time Display

The transport readout should show signed global time. Negative positions should format with a leading minus sign, such as:

```text
-00:12
```

The primary readout should show signed current global time and signed timeline end, for example `-00:12 / 03:42`. If the timeline starts below zero, the UI may also show the signed start elsewhere, but it must not convert the current position to elapsed session time.

## Layout

The main window should use this structure:

1. Top transport bar.
2. Inline warning/error area.
3. Track waveform list.

The top transport bar contains:

- `Open` button.
- Adjacent dropdown/menu with `Load Selected from Music`.
- Play/pause control.
- Rewind control.
- Switch playback control.
- Signed time readout.

The old transport slider is removed.

Each track row contains:

- Left track info/control area.
- Right waveform timeline area.

The track info area contains:

- Track label, such as `Track A`.
- Active/audible state.
- Track title and metadata when loaded.
- Empty state when no file is loaded.
- Gear button for gain.
- Offset control visible directly in the row.

The waveform area contains:

- Placeholder waveform segment for the loaded track.
- Empty leading/trailing gaps based on offset and shared timeline bounds.
- A shared vertical playhead line overlaid across both waveform lanes.
- A visual indication of each row's drop target when dragging over it.

## Interaction

Clicking the track info area selects that track as the active/audible track. Clicking the waveform area does not select the track; it seeks.

Clicking or dragging anywhere in the waveform timeline moves the playhead. The playhead can move into negative global time when the visible timeline extends left of zero.

Keyboard controls should continue to work:

- `Space`: play/pause.
- `X`: switch active track.
- Left/right arrows: seek by the existing small step.
- Shift-left/shift-right: seek by the existing large step.
- Command-left/command-right: seek to the start/end of the signed session range.

Rewind should seek to the start of the signed session range. If the range starts before zero, rewind goes to that negative start.

## Loading And Assignment

The `Open` button allows selecting one or two audio files.

Assignment rules:

- One selected file fills Track A if empty.
- Otherwise one selected file fills Track B if empty.
- Otherwise one selected file replaces the currently active track.
- Two selected files load into Track A and Track B in selected order.
- More than two selected files shows a user-facing error.

`Load Selected from Music` uses the same assignment rules as `Open`.

Drag-and-drop uses the same model with one exception:

- Dropping directly on a specific track row targets that row.
- Dropping elsewhere in the window uses the general assignment rules.

When replacing a track, that track's existing gain and offset values should be preserved, matching the current Track B replacement behavior but applying to both tracks.

## Track Controls

Gain moves into a popup opened from the gear button on each track row. The popup contains gain only.

Offset is visible and editable directly on each track row for both Track A and Track B. Offset range expands to:

```text
-300000...300000 ms
```

Existing numeric control behavior should be preserved where practical:

- Arrow stepping.
- Shift-arrow large stepping.
- Reset to zero.
- Commit on Enter or focus loss.
- Escape cancels editing.

The current step sizes can remain:

- Offset small step: `10 ms`.
- Offset large step: `100 ms`.

## Errors

The app should continue to show user-facing inline errors for:

- Unsupported audio files.
- Failed file open.
- Music selection failures.
- More than two files selected or dropped.
- Invalid or empty playable range.

Warnings/errors should appear below the top transport area so they do not interrupt the track rows.

## Implementation Boundaries

The implementation should keep the first pass focused:

- Use placeholder waveform drawing.
- Refactor transport math before polishing visuals.
- Keep SwiftUI/AppKit bridging patterns that already exist for numeric controls.
- Avoid introducing a real waveform extraction pipeline until the signed timeline UI is stable.

Likely code areas:

- `Sources/TrackSwitch/ContentView.swift` for layout, popups, drag/drop, file import, and timeline seeking gestures.
- `Sources/TrackSwitch/Models.swift` for signed timeline session state.
- `Sources/TrackSwitch/PlaybackController.swift` for signed seek/playback scheduling and assignment helpers.
- `Sources/TrackSwitch/TransportMapping.swift` for pure signed global timeline math.
- `Tests/TrackSwitchTests/TransportMappingTests.swift` for timeline math coverage.
- `Tests/TrackSwitchTests/SessionTests.swift` for assignment, formatting, and controller behavior coverage.

## Testing

Automated tests should cover:

- Signed timeline union bounds for one and two loaded tracks.
- Positive offset leading gaps in the model.
- Negative offset expanding timeline start below zero.
- Global-time to file-position mapping.
- Audibility checks for global time before, within, and after a track.
- Seeking clamps to signed timeline bounds.
- One-file assignment into empty A, empty B, and replacement of active track.
- Two-file assignment to A then B.
- More-than-two assignment error.
- Signed timestamp formatting.
- Offset support for both tracks.

Manual verification should cover:

- Top transport layout.
- Placeholder waveform lanes.
- Playhead extends across both waveform lanes.
- Clicking and dragging waveform seeks.
- Clicking track info selects active track.
- Gear popup contains gain only.
- Offset controls remain visible on both rows.
- Row-specific drop targets replace the row.
- General window drop follows the shared assignment rule.
