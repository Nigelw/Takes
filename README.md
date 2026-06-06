# TrackSwitch

TrackSwitch is a native macOS app for comparing multiple versions of the same audio track. It keeps loaded tracks aligned on a shared transport timeline and lets you switch playback between them instantly so you can evaluate mastering differences at the same point in the song.

This README is written for someone working on the repo. It covers project layout, how to build and run the app, the core playback model, and a brief operator guide for manual testing.

## Current Scope

The app currently supports:

- Loading up to 32 local audio files through a single Open control
- Dragging files onto a specific track row to replace that row
- Dragging files elsewhere in the window to append to the track list
- Placeholder waveform lanes for each loaded track
- Signed global timeline playback with a playhead over the waveform lanes
- Independent offset adjustment for each loaded track
- Independent gain trim per track through the track settings popup
- Importing the current selection from Music.app
- Loading one or more selected Music tracks, ordered by Music's current view order
- Shared transport playback with only one track audible at a time
- Switching playback through loaded tracks in list order during playback
- Seeking across the full session range
- Silence on a track when the current transport position falls outside that track's valid range

Out of scope at the moment:

- Real waveform extraction and caching
- Loudness analysis
- Automatic alignment
- Session persistence
- Export / rendering

## Requirements

- macOS
- Xcode with command line tools selected
- Music.app installed if you want to use the Music selection import button

The project is an Xcode app project, not a Swift package.

## Open And Run

Open the project:

```bash
open /Users/Nigel/Developer/TrackSwitch/TrackSwitch.xcodeproj
```

In Xcode:

1. Select the `TrackSwitch` scheme.
2. Select `My Mac` as the run destination.
3. Press `Cmd-R`.

The app bundle produced by local builds typically ends up under:

```text
/Users/Nigel/Developer/TrackSwitch/.derived-data/Build/Products/Debug/TrackSwitch.app
```

## Build And Test

Build:

```bash
xcodebuild -project TrackSwitch.xcodeproj -scheme TrackSwitch -configuration Debug -derivedDataPath .derived-data build
```

Compile the app and test targets:

```bash
xcodebuild -project TrackSwitch.xcodeproj -scheme TrackSwitch -configuration Debug -derivedDataPath .derived-data build-for-testing
```

Notes:

- `build-for-testing` is the most reliable repo-local verification command in this environment.
- Full `xcodebuild test` may be blocked in sandboxed environments because it depends on Apple test infrastructure processes outside the workspace.

## Repo Layout

```text
TrackSwitch/
├── Config/
│   └── TrackSwitch-Info.plist
├── Sources/TrackSwitch/
│   ├── AudioFileLoader.swift
│   ├── ContentView.swift
│   ├── KeyMonitor.swift
│   ├── LibraryTrackSelectionLoader.swift
│   ├── Models.swift
│   ├── PlaybackController.swift
│   ├── TrackSwitchApp.swift
│   └── TransportMapping.swift
├── Tests/TrackSwitchTests/
│   ├── SessionTests.swift
│   └── TransportMappingTests.swift
└── TrackSwitch.xcodeproj/
```

## Architecture Overview

### UI

- `TrackSwitchApp.swift` creates the app window.
- `ContentView.swift` contains the SwiftUI interface, file importers, drag-and-drop handling, keyboard shortcut monitoring, and the gain/offset control UI.

### Playback

- `PlaybackController.swift` is the main coordinator for loading files, tracking session state, running the transport, scheduling playback, and updating audibility.
- Playback uses a single `AVAudioEngine` with:
  - one `AVAudioPlayerNode` per loaded track
  - one per-track mixer node per loaded track
- All loaded tracks are scheduled against the same transport model.
- Only the active track is audible at a time by muting the inactive tracks' mixer output.

### Transport Model

- `Models.swift` defines `LoadedTrack`, `SessionTrack`, `ComparisonSession`, and `PlaybackError`.
- `TransportMapping.swift` contains the pure transport math:
  - signed timeline bounds and range
  - transport-to-file position mapping
  - audibility checks
  - dB-to-linear gain conversion

Current transport behavior:

- The progress timeline is based on the union of loaded track ranges and the global 0:00 point.
- Negative offsets extend the visible timeline before 0:00.
- Positive offsets create leading empty space before the shifted track starts.
- If you switch to a track that is currently out of range, playback remains silent until transport re-enters that track's valid window.

### File Loading

- `AudioFileLoader.swift` reads local audio files through `AVAudioFile`.
- `LibraryTrackSelectionLoader.swift` uses AppleScript against `com.apple.Music` to read the current Music.app selection and validate that it points to local files.

### Tests

- `TransportMappingTests.swift` covers transport math and range behavior.
- `SessionTests.swift` covers higher-level state, Music selection handling, numeric control stepping behavior, and other non-UI logic.

## Important Behavior Notes

- Playback is allowed with only one loaded track.
- Switching playback requires at least two loaded tracks.
- Replacing a track row resets that row's gain and offset values.
- Removing a track preserves the remaining tracks' gain and offset values.
- Music import requires Automation permission to control Music.
- The app includes `NSAppleEventsUsageDescription` for that permission prompt.
- If more tracks are imported than the session cap allows, TrackSwitch loads available slots and reports skipped files.

## Brief Operator Guide

### Loading Audio

- Use the `+` button above the track info area to append one or more local files.
- Drag a compatible audio file onto a specific track row to replace that row.
- Drag files elsewhere in the window to append them to the track list.
- Use the `+` menu above the track info area and choose `Open Apple Music Selection` to import the current Music.app selection.

Music import rules:

- Selected tracks append to the current track list.
- Multiple selected tracks load based on Music's playlist/library view order.
- TrackSwitch supports up to 32 loaded tracks and reports any skipped files.
- The selected Music items must be local files on disk.

### Playback

- `Space`: play/pause
- `X`: switch playback to the next loaded track in list order
- `Shift+X`: switch playback to the previous loaded track in list order
- `Left` / `Right`: seek by 1 second
- `Shift+Left` / `Shift+Right`: seek by 10 seconds

### Gain And Offset Controls

- Each loaded track has an offset control.
- Each track's settings popup contains gain trim.
- Sliders and numeric fields stay in sync.
- Numeric fields support arrow-key stepping:
  - gain: `Up/Down = 1 dB`, `Shift+Up/Down = 10 dB`
  - offset: `Up/Down = 10 ms`, `Shift+Up/Down = 100 ms`
- `Reset` returns the value to `0`.
- Double-clicking a slider thumb also resets it to `0`.
- Press `Enter` or click outside a numeric field to end editing and return keyboard control to transport shortcuts.

## Manual Verification Checklist

Useful spot checks after changing playback or UI behavior:

1. Confirm the top transport shows play/pause, rewind, switch, and signed time readout.
2. Confirm the `+` dropdown above the track info area contains `Open Finder Selection` and `Open Apple Music Selection`.
3. Use the `+` button with one file and confirm it creates Track 1 and makes it active.
4. Use the `+` button with additional files and confirm they append in order.
5. Use the `+` button with more than 32 files and confirm the app loads available slots and reports skipped files.
6. Use a mixed valid/invalid import and confirm successful files append while failures are reported together.
7. Confirm `Switch Playback` is disabled with one loaded track and cycles through three or more tracks in row order.
8. Confirm placeholder waveform lanes render for loaded tracks.
9. Confirm positive offset creates leading blank space.
10. Confirm negative offset extends the visible timeline left of zero.
11. Confirm the playhead line spans the visible track lanes.
12. Click and drag in a waveform lane and confirm it seeks.
13. Click the track info area and confirm it changes the active track.
14. Confirm the gear popup contains gain only.
15. Confirm offset controls are visible for each loaded track.
16. Drop a file on a specific track row and confirm it replaces that row.
17. Drop multiple files on a row and confirm they append instead of replacing.
18. Drop files elsewhere in the window and confirm they append.
19. Remove a non-active track during playback and confirm playback continues.
20. Remove the active track and confirm playback pauses and selects the next track, or previous if the removed track was last.

## Known Constraints

- The UI is entirely SwiftUI/AppKit-bridged for control behavior; there are no UI automation tests yet.
- Music integration depends on AppleScript and macOS Automation permissions.
- Test execution may be environment-dependent even when `build-for-testing` succeeds.
- The repo currently targets local development in Xcode rather than distribution packaging or notarized release workflows.
