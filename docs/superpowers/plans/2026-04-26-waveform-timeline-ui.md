# Waveform Timeline UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the approved Takes top-transport, signed global timeline, placeholder waveform lanes, unified loading rules, and per-track offset/gain controls.

**Architecture:** Refactor transport state from relative session time to signed global time, keeping pure timeline math in `TransportMapping.swift` and playback coordination in `PlaybackController.swift`. Then replace the current card/slider UI in `ContentView.swift` with a top transport bar and two waveform rows that share one playhead.

**Tech Stack:** Swift, SwiftUI, AppKit bridging, AVFoundation, Swift Testing, Xcode project build/test commands.

---

## File Structure

- Modify `Sources/Takes/TransportMapping.swift`: signed timeline bounds, global-time file position, clamping, audibility, and display span helpers.
- Modify `Sources/Takes/Models.swift`: session stores `timelineStart`, `timelineEnd`, and signed `transportPosition`; add signed timestamp formatting and assignment error text.
- Modify `Sources/Takes/PlaybackController.swift`: preserve gain/offset on replacement for both tracks, add shared URL assignment, use signed transport for scheduling/timer/seek, expose active-track selection.
- Modify `Sources/Takes/ContentView.swift`: replace current header/transport/control cards with top transport, import menu, two track rows, placeholder waveform timeline, gear gain popover, offset controls, click/drag seek, and drop routing.
- Modify `Sources/Takes/LibraryTrackSelectionLoader.swift`: align the Music more-than-two error text with the shared import error.
- Modify `Tests/TakesTests/TransportMappingTests.swift`: rewrite transport math tests for signed global time.
- Modify `Tests/TakesTests/SessionTests.swift`: update session readiness, assignment, signed timestamp, and expanded offset range tests.

Keep all changes in existing files. Do not add a waveform extraction service in this pass.

---

### Task 1: Signed Timeline Math

**Files:**
- Modify: `Sources/Takes/TransportMapping.swift`
- Test: `Tests/TakesTests/TransportMappingTests.swift`

- [ ] **Step 1: Replace transport tests with signed global-time expectations**

In `Tests/TakesTests/TransportMappingTests.swift`, update the tested API to signed timeline methods:

```swift
import AVFoundation
import Testing
@testable import Takes

struct TransportMappingTests {
    @Test
    func timelineRangeIncludesZeroAndLoadedTrackRangeForSingleTrack() throws {
        let track = makeTrack(duration: 10, offset: 6)

        let range = try #require(TransportMapping.timelineRange(trackA: track, trackB: nil))

        #expect(range.lowerBound == 0)
        #expect(range.upperBound == 16)
    }

    @Test
    func timelineRangeExpandsBelowZeroForNegativeOffsets() throws {
        let trackA = makeTrack(duration: 10, offset: 0)
        let trackB = makeTrack(duration: 8, offset: -12)

        let range = try #require(TransportMapping.timelineRange(trackA: trackA, trackB: trackB))

        #expect(range.lowerBound == -12)
        #expect(range.upperBound == 10)
    }

    @Test
    func timelineRangeCoversPositiveGapsBetweenTracks() throws {
        let trackA = makeTrack(duration: 5, offset: 0)
        let trackB = makeTrack(duration: 5, offset: 6)

        let range = try #require(TransportMapping.timelineRange(trackA: trackA, trackB: trackB))

        #expect(range.lowerBound == 0)
        #expect(range.upperBound == 11)
    }

    @Test
    func filePositionUsesSignedGlobalTimeAndTrackOffset() {
        #expect(TransportMapping.filePosition(forGlobalTime: -8, offset: -10) == 2)
        #expect(TransportMapping.filePosition(forGlobalTime: 3, offset: 5) == -2)
        #expect(TransportMapping.filePosition(forGlobalTime: 9, offset: 5) == 4)
    }

    @Test
    func trackAudibilityUsesSignedGlobalTime() {
        let track = makeTrack(duration: 5, offset: -2)

        #expect(!TransportMapping.isTrackAudible(track, atGlobalTime: -2.01))
        #expect(TransportMapping.isTrackAudible(track, atGlobalTime: -2))
        #expect(TransportMapping.isTrackAudible(track, atGlobalTime: 3))
        #expect(!TransportMapping.isTrackAudible(track, atGlobalTime: 3.01))
    }

    @Test
    func clampTransportAllowsNegativeTimelineBounds() {
        #expect(TransportMapping.clampedTransport(-20, timelineStart: -10, timelineEnd: 12) == -10)
        #expect(TransportMapping.clampedTransport(-5, timelineStart: -10, timelineEnd: 12) == -5)
        #expect(TransportMapping.clampedTransport(20, timelineStart: -10, timelineEnd: 12) == 12)
    }

    @Test
    func normalizedPositionMapsSignedTimeIntoDisplaySpan() {
        #expect(TransportMapping.normalizedPosition(globalTime: -10, timelineStart: -10, timelineEnd: 10) == 0)
        #expect(TransportMapping.normalizedPosition(globalTime: 0, timelineStart: -10, timelineEnd: 10) == 0.5)
        #expect(TransportMapping.normalizedPosition(globalTime: 10, timelineStart: -10, timelineEnd: 10) == 1)
    }

    @Test
    func dbConversionMatchesExpectedLinearGain() {
        #expect(abs(TransportMapping.linearGain(fromDB: 6) - 1.9952623) < 0.0001)
    }

    private func makeTrack(duration: TimeInterval, offset: TimeInterval) -> LoadedTrack {
        LoadedTrack(
            url: URL(fileURLWithPath: "/tmp/test.wav"),
            displayName: "test.wav",
            fileFormatDescription: "WAV",
            duration: duration,
            sampleRate: 44_100,
            channelCount: 2,
            gainDB: 0,
            offsetSeconds: offset
        )
    }
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath .derived-data -only-testing:TakesTests/TransportMappingTests test
```

Expected: FAIL or compile failure because `timelineRange`, `filePosition(forGlobalTime:)`, signed `isTrackAudible`, and signed `clampedTransport` do not exist yet.

- [ ] **Step 3: Implement signed helpers in `TransportMapping.swift`**

Replace the relative helpers with signed global helpers while keeping `overlapRange` and `linearGain`:

```swift
import Foundation

struct TransportMapping {
    static func transportBounds(duration: TimeInterval, offset: TimeInterval) -> ClosedRange<TimeInterval> {
        offset...(offset + duration)
    }

    static func timelineRange(trackA: LoadedTrack?, trackB: LoadedTrack?) -> ClosedRange<TimeInterval>? {
        let ranges = [trackA, trackB].compactMap { track -> ClosedRange<TimeInterval>? in
            guard let track else { return nil }
            return transportBounds(duration: track.duration, offset: track.offsetSeconds)
        }

        guard !ranges.isEmpty else { return nil }

        let lower = min(0, ranges.map(\.lowerBound).min() ?? 0)
        let upper = max(0, ranges.map(\.upperBound).max() ?? 0)
        guard upper > lower else { return nil }
        return lower...upper
    }

    static func overlapRange(trackA: LoadedTrack, trackB: LoadedTrack) -> ClosedRange<TimeInterval>? {
        let a = transportBounds(duration: trackA.duration, offset: trackA.offsetSeconds)
        let b = transportBounds(duration: trackB.duration, offset: trackB.offsetSeconds)
        let lower = max(a.lowerBound, b.lowerBound)
        let upper = min(a.upperBound, b.upperBound)
        guard upper > lower else { return nil }
        return lower...upper
    }

    static func validOverlapDuration(trackA: LoadedTrack, trackB: LoadedTrack) -> TimeInterval {
        guard let range = overlapRange(trackA: trackA, trackB: trackB) else { return 0 }
        return range.upperBound - range.lowerBound
    }

    static func filePosition(forGlobalTime globalTime: TimeInterval, offset: TimeInterval) -> TimeInterval {
        globalTime - offset
    }

    static func isTrackAudible(_ track: LoadedTrack, atGlobalTime globalTime: TimeInterval) -> Bool {
        let position = filePosition(forGlobalTime: globalTime, offset: track.offsetSeconds)
        return position >= 0 && position <= track.duration
    }

    static func clampedTransport(
        _ transport: TimeInterval,
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval
    ) -> TimeInterval {
        min(max(transport, timelineStart), timelineEnd)
    }

    static func normalizedPosition(
        globalTime: TimeInterval,
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval
    ) -> Double {
        let span = timelineEnd - timelineStart
        guard span > 0 else { return 0 }
        return (globalTime - timelineStart) / span
    }

    static func linearGain(fromDB db: Float) -> Float {
        powf(10, db / 20)
    }
}
```

- [ ] **Step 4: Run focused tests and verify they pass**

Run:

```bash
xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath .derived-data -only-testing:TakesTests/TransportMappingTests test
```

Expected: PASS for `TransportMappingTests`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Takes/TransportMapping.swift Tests/TakesTests/TransportMappingTests.swift
git commit -m "Refactor transport mapping for signed timeline"
```

---

### Task 2: Session State, Signed Formatting, And Assignment Rules

**Files:**
- Modify: `Sources/Takes/Models.swift`
- Modify: `Sources/Takes/PlaybackController.swift`
- Modify: `Sources/Takes/ContentView.swift`
- Test: `Tests/TakesTests/SessionTests.swift`

- [ ] **Step 1: Add failing session tests**

In `Tests/TakesTests/SessionTests.swift`, update or add these tests:

```swift
@Test
func sessionUsesSignedTimelineBoundsForPlaybackReadiness() {
    var session = ComparisonSession()
    #expect(!session.isPlayable)

    session.trackA = makeTrack(name: "a.wav")
    session.timelineStart = -4
    session.timelineEnd = 120
    session.transportPosition = -4

    #expect(session.isPlayable)
    #expect(session.duration == 124)
}

@Test
func signedTimestampFormatsNegativeTimes() {
    #expect(TimeInterval(-12).formattedSignedTimestamp == "-00:12")
    #expect(TimeInterval(12).formattedSignedTimestamp == "00:12")
    #expect(TimeInterval(-3723).formattedSignedTimestamp == "-1:02:03")
}

@Test
func offsetRangeExpandsToFiveMinutes() {
    let offsetConfig = NumericControlConfiguration.offset

    #expect(offsetConfig.clamped(300_001) == 300_000)
    #expect(offsetConfig.clamped(-300_001) == -300_000)
    #expect(offsetConfig.steppedValue(from: 299_950, direction: 1, largeStep: true) == 300_000)
    #expect(offsetConfig.steppedValue(from: -299_950, direction: -1, largeStep: true) == -300_000)
}

@Test
func importAssignmentsUseSharedOpenRules() throws {
    var session = ComparisonSession()
    let first = URL(fileURLWithPath: "/tmp/first.wav")
    let second = URL(fileURLWithPath: "/tmp/second.wav")
    let third = URL(fileURLWithPath: "/tmp/third.wav")

    #expect(try PlaybackController.importAssignments(for: [first], in: session) == [(.a, first)])

    session.trackA = makeTrack(name: "a.wav")
    #expect(try PlaybackController.importAssignments(for: [second], in: session) == [(.b, second)])

    session.trackB = makeTrack(name: "b.wav")
    session.activeTrack = .b
    #expect(try PlaybackController.importAssignments(for: [third], in: session) == [(.b, third)])
    #expect(try PlaybackController.importAssignments(for: [first, second], in: session) == [(.a, first), (.b, second)])
}

@Test
func importAssignmentsRejectMoreThanTwoFiles() {
    let urls = [
        URL(fileURLWithPath: "/tmp/a.wav"),
        URL(fileURLWithPath: "/tmp/b.wav"),
        URL(fileURLWithPath: "/tmp/c.wav")
    ]

    #expect(throws: PlaybackError.tooManyImportFiles) {
        try PlaybackController.importAssignments(for: urls, in: ComparisonSession())
    }
}
```

Update the existing Music assignment tests to call `importAssignments(for:in:)` or remove the clicked-side expectation, because one-item Music import no longer targets a clicked side.

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath .derived-data -only-testing:TakesTests/SessionTests test
```

Expected: FAIL or compile failure for missing `timelineStart`, `timelineEnd`, `formattedSignedTimestamp`, `tooManyImportFiles`, and `importAssignments`.

- [ ] **Step 3: Update models**

In `Sources/Takes/Models.swift`, make these changes:

```swift
struct ComparisonSession: Equatable {
    var trackA: LoadedTrack?
    var trackB: LoadedTrack?
    var activeTrack: TrackSide = .a
    var isPlaying = false
    var transportPosition: TimeInterval = 0
    var timelineStart: TimeInterval = 0
    var timelineEnd: TimeInterval = 0

    var duration: TimeInterval {
        max(0, timelineEnd - timelineStart)
    }

    var isPlayable: Bool {
        (trackA != nil || trackB != nil) && timelineEnd > timelineStart
    }

    var canToggleComparison: Bool {
        trackA != nil && trackB != nil
    }
}
```

Add the error case:

```swift
case tooManyImportFiles
```

and in `errorDescription`:

```swift
case .tooManyImportFiles:
    "Select one or two audio files."
```

Replace offset range in `NumericControlConfiguration` in `ContentView.swift` during this task if the tests compile through that type:

```swift
static let offset = NumericControlConfiguration(range: -300_000...300_000, step: 10, largeStep: 100, suffix: "ms")
```

Add signed formatting while preserving existing non-signed formatting:

```swift
extension TimeInterval {
    var formattedTimestamp: String {
        abs(self).formattedUnsignedTimestamp
    }

    var formattedSignedTimestamp: String {
        let prefix = self < 0 ? "-" : ""
        return prefix + abs(self).formattedUnsignedTimestamp
    }

    private var formattedUnsignedTimestamp: String {
        guard self.isFinite else { return "--:--" }
        let rounded = Int(max(0, self.rounded()))
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let seconds = rounded % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
```

- [ ] **Step 4: Add shared assignment helper**

In `Sources/Takes/PlaybackController.swift`, replace `libraryAssignments(for:clickedSide:)` with:

```swift
nonisolated static func importAssignments(
    for urls: [URL],
    in session: ComparisonSession
) throws -> [(TrackSide, URL)] {
    switch urls.count {
    case 1:
        if session.trackA == nil {
            return [(.a, urls[0])]
        }
        if session.trackB == nil {
            return [(.b, urls[0])]
        }
        return [(session.activeTrack, urls[0])]
    case 2:
        return [(.a, urls[0]), (.b, urls[1])]
    default:
        throw PlaybackError.tooManyImportFiles
    }
}
```

Delete `libraryAssignments(for:clickedSide:)` and update all call sites to use `importAssignments(for:in:)` or `loadImportedFiles(_:)`.

- [ ] **Step 5: Run focused session tests**

Run:

```bash
xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath .derived-data -only-testing:TakesTests/SessionTests test
```

Expected: PASS for `SessionTests`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Takes/Models.swift Sources/Takes/PlaybackController.swift Sources/Takes/ContentView.swift Tests/TakesTests/SessionTests.swift
git commit -m "Add signed session state and import assignment rules"
```

---

### Task 3: Playback Controller Signed Scheduling

**Files:**
- Modify: `Sources/Takes/PlaybackController.swift`
- Test: `Tests/TakesTests/TransportMappingTests.swift`
- Test: `Tests/TakesTests/SessionTests.swift`

- [ ] **Step 1: Add controller-adjacent tests where pure behavior is exposed**

Add a session test for replacing both tracks preserving per-side settings once implementation exposes deterministic behavior through helpers:

```swift
@Test
func replacementPreservesExistingSideSettings() {
    var oldTrack = makeTrack(name: "old.wav")
    oldTrack.gainDB = -3
    oldTrack.offsetSeconds = -12

    let newTrack = PlaybackController.replacingTrackMetadata(
        makeTrack(name: "new.wav"),
        preservingSettingsFrom: oldTrack
    )

    #expect(newTrack.displayName == "new.wav")
    #expect(newTrack.gainDB == -3)
    #expect(newTrack.offsetSeconds == -12)
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath .derived-data -only-testing:TakesTests/SessionTests test
```

Expected: FAIL because `replacingTrackMetadata` does not exist.

- [ ] **Step 3: Add replacement helper and use it in `loadTrack`**

In `PlaybackController` add:

```swift
nonisolated static func replacingTrackMetadata(
    _ metadata: LoadedTrack,
    preservingSettingsFrom existingTrack: LoadedTrack?
) -> LoadedTrack {
    guard let existingTrack else { return metadata }
    var adjusted = metadata
    adjusted.offsetSeconds = existingTrack.offsetSeconds
    adjusted.gainDB = existingTrack.gainDB
    return adjusted
}
```

Use it in both switch cases:

```swift
case .a:
    session.trackA = Self.replacingTrackMetadata(metadata, preservingSettingsFrom: session.trackA)
    audioFileA = file
    if session.trackB == nil {
        session.activeTrack = .a
    }
case .b:
    session.trackB = Self.replacingTrackMetadata(metadata, preservingSettingsFrom: session.trackB)
    audioFileB = file
    if session.trackA == nil {
        session.activeTrack = .b
    }
```

- [ ] **Step 4: Refactor signed transport methods**

Replace relative scheduling state with signed global time:

```swift
private var playbackStartedFromTransport: TimeInterval = 0
```

continues to hold global time. Remove `sessionStart` entirely.

Update `seek(to:)`:

```swift
func seek(to seconds: TimeInterval) {
    guard session.isPlayable else { return }
    let clamped = TransportMapping.clampedTransport(
        seconds,
        timelineStart: session.timelineStart,
        timelineEnd: session.timelineEnd
    )
    session.transportPosition = clamped

    guard session.isPlaying else { return }
    do {
        try reschedulePlayers(startingAt: clamped)
        if audioFileA != nil { playerA.play() }
        if audioFileB != nil { playerB.play() }
        playbackStartedFromTransport = clamped
        playbackStartedAt = CACurrentMediaTime()
        applyAudibility()
    } catch let error as PlaybackError {
        playbackError = error
    } catch {
        playbackError = .schedulingFailed
    }
}
```

Update `reschedulePlayers(startingAt:)`:

```swift
private func reschedulePlayers(startingAt globalTime: TimeInterval) throws {
    guard session.isPlayable else {
        throw PlaybackError.schedulingFailed
    }

    let transport = TransportMapping.clampedTransport(
        globalTime,
        timelineStart: session.timelineStart,
        timelineEnd: session.timelineEnd
    )
    playerA.stop()
    playerB.stop()

    if let trackA = session.trackA, let fileA = audioFileA {
        scheduleTrack(trackA, file: fileA, on: playerA, atGlobalTime: transport)
    }

    if let trackB = session.trackB, let fileB = audioFileB {
        scheduleTrack(trackB, file: fileB, on: playerB, atGlobalTime: transport)
    }

    session.transportPosition = transport
}
```

Update `scheduleTrack` signature/body:

```swift
private func scheduleTrack(
    _ track: LoadedTrack,
    file: AVAudioFile,
    on player: AVAudioPlayerNode,
    atGlobalTime globalTime: TimeInterval
) {
    let filePosition = TransportMapping.filePosition(
        forGlobalTime: globalTime,
        offset: track.offsetSeconds
    )

    if filePosition >= track.duration {
        return
    }

    if filePosition < 0 {
        scheduleSilence(on: player, format: file.processingFormat, duration: -filePosition)
        player.scheduleSegment(file, startingFrame: 0, frameCount: AVAudioFrameCount(file.length), at: nil)
        return
    }

    let frame = AVAudioFramePosition(filePosition * track.sampleRate)
    let framesRemaining = max(0, file.length - frame)
    guard framesRemaining > 0 else { return }
    player.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(framesRemaining), at: nil)
}
```

- [ ] **Step 5: Recalculate signed timeline bounds**

Replace `recalculateSessionDuration()` internals:

```swift
private func recalculateSessionDuration() {
    guard let range = TransportMapping.timelineRange(trackA: session.trackA, trackB: session.trackB) else {
        session.timelineStart = 0
        session.timelineEnd = 0
        session.transportPosition = 0
        overlapWarning = nil
        return
    }

    session.timelineStart = range.lowerBound
    session.timelineEnd = range.upperBound
    session.transportPosition = TransportMapping.clampedTransport(
        session.transportPosition,
        timelineStart: session.timelineStart,
        timelineEnd: session.timelineEnd
    )

    if session.transportPosition == 0 {
        session.transportPosition = TransportMapping.clampedTransport(
            0,
            timelineStart: session.timelineStart,
            timelineEnd: session.timelineEnd
        )
    }

    if let trackA = session.trackA, let trackB = session.trackB {
        let overlapDuration = TransportMapping.validOverlapDuration(trackA: trackA, trackB: trackB)
        if overlapDuration == 0 {
            overlapWarning = "Track A and Track B do not overlap at the current offsets."
        } else if overlapDuration < min(trackA.duration, trackB.duration) {
            overlapWarning = "Offsets reduce the shared compare range to \(overlapDuration.formattedTimestamp)."
        } else {
            overlapWarning = nil
        }
    } else {
        overlapWarning = nil
    }

    playbackError = nil
}
```

This keeps newly loaded sessions at global `0:00` when `0:00` is inside the signed timeline, while still clamping correctly if a future session range does not include zero.

- [ ] **Step 6: Update timer/current transport**

```swift
private func refreshTransportTick() {
    guard session.isPlaying else { return }
    let transport = currentTransportPosition()
    session.transportPosition = transport
    if transport >= session.timelineEnd {
        stop()
    }
}

private func currentTransportPosition() -> TimeInterval {
    guard session.isPlaying, let playbackStartedAt else {
        return TransportMapping.clampedTransport(
            session.transportPosition,
            timelineStart: session.timelineStart,
            timelineEnd: session.timelineEnd
        )
    }

    let elapsed = CACurrentMediaTime() - playbackStartedAt
    return TransportMapping.clampedTransport(
        playbackStartedFromTransport + elapsed,
        timelineStart: session.timelineStart,
        timelineEnd: session.timelineEnd
    )
}
```

Update `stop()` to reset to `session.timelineStart` rather than `0`:

```swift
func stop() {
    playerA.stop()
    playerB.stop()
    session.isPlaying = false
    session.transportPosition = session.timelineStart
    playbackStartedAt = nil
    playbackStartedFromTransport = session.transportPosition
    timer?.invalidate()
    applyAudibility()
}
```

- [ ] **Step 7: Run all focused tests**

Run:

```bash
xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath .derived-data -only-testing:TakesTests/TransportMappingTests -only-testing:TakesTests/SessionTests test
```

Expected: PASS for both test files.

- [ ] **Step 8: Commit**

```bash
git add Sources/Takes/PlaybackController.swift Tests/TakesTests/SessionTests.swift
git commit -m "Use signed timeline for playback scheduling"
```

---

### Task 4: Top Transport And Unified Import UI

**Files:**
- Modify: `Sources/Takes/ContentView.swift`
- Modify: `Sources/Takes/PlaybackController.swift`
- Test: `Tests/TakesTests/SessionTests.swift`

- [ ] **Step 1: Update importer state for multi-select**

In `ContentView`, replace per-side import state:

```swift
@State private var importingTrack = false
@State private var pendingImportSide: TrackSide?
```

with:

```swift
@State private var importingTracks = false
@State private var gainPopoverSide: TrackSide?
```

Use a multi-file importer:

```swift
.fileImporter(
    isPresented: $importingTracks,
    allowedContentTypes: [.audio],
    allowsMultipleSelection: true
) { result in
    handleImport(result)
}
```

- [ ] **Step 2: Add shared loading entry points**

In `PlaybackController`, add:

```swift
func loadImportedFiles(_ urls: [URL]) async {
    do {
        let assignments = try Self.importAssignments(for: urls, in: session)
        for (side, url) in assignments {
            await loadTrack(side, from: url)
        }
    } catch let error as PlaybackError {
        playbackError = error
    } catch {
        playbackError = .failedToOpenFile(urls.first ?? URL(fileURLWithPath: ""))
    }
}

func loadSelectedLibraryTracks() async {
    do {
        let urls = try libraryTrackSelector.selectedTrackURLs()
        await loadImportedFiles(urls)
    } catch let error as PlaybackError {
        playbackError = error
    } catch {
        playbackError = .librarySelectionFailed("Could not load the selected track from Music.")
    }
}
```

Keep `loadSelectedLibraryTrack(_:)` temporarily if existing code still references it; remove references from the new UI.

- [ ] **Step 3: Replace top-level body sections**

In `ContentView.body`, use:

```swift
VStack(alignment: .leading, spacing: 14) {
    transportBar
    if let warning = controller.overlapWarning {
        Text(warning)
            .font(.callout)
            .foregroundStyle(.orange)
    }
    if let error = controller.playbackError {
        Text(error.localizedDescription)
            .font(.callout)
            .foregroundStyle(.red)
    }
    trackTimelineSection
    Spacer(minLength: 0)
}
.padding(20)
.frame(minWidth: 860, minHeight: 540)
```

Remove calls to old `headerSection`, `transportSection`, and `controlsSection`.

- [ ] **Step 4: Add top transport bar**

Add:

```swift
private var transportBar: some View {
    HStack(spacing: 10) {
        Button("Open") {
            importingTracks = true
        }

        Menu {
            Button("Load Selected from Music") {
                Task { await controller.loadSelectedLibraryTracks() }
            }
        } label: {
            Image(systemName: "chevron.down")
                .accessibilityLabel("Import Options")
        }
        .menuStyle(.borderlessButton)

        Divider()
            .frame(height: 22)

        Button(controller.session.isPlaying ? "Pause" : "Play") {
            controller.session.isPlaying ? controller.pause() : controller.play()
        }
        .keyboardShortcut(.space, modifiers: [])
        .disabled(!controller.session.isPlayable)

        Button("Rewind") {
            controller.seek(to: controller.session.timelineStart)
        }
        .disabled(!controller.session.isPlayable)

        Button("Switch Playback") {
            controller.toggleActiveTrack()
        }
        .keyboardShortcut("x", modifiers: [])
        .disabled(!controller.session.canToggleComparison)

        Spacer()

        Text("\(controller.session.transportPosition.formattedSignedTimestamp) / \(controller.session.timelineEnd.formattedSignedTimestamp)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
    .padding()
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
}
```

- [ ] **Step 5: Update import handler**

```swift
private func handleImport(_ result: Result<[URL], Error>) {
    importingTracks = false

    switch result {
    case let .success(urls):
        Task {
            await controller.loadImportedFiles(urls)
        }
    case .failure:
        break
    }
}
```

- [ ] **Step 6: Run build-for-testing**

Run:

```bash
xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath .derived-data build-for-testing
```

Expected: BUILD SUCCEEDED. Fix compile errors before continuing.

- [ ] **Step 7: Commit**

```bash
git add Sources/Takes/ContentView.swift Sources/Takes/PlaybackController.swift
git commit -m "Add top transport and unified import controls"
```

---

### Task 5: Waveform Rows, Playhead, And Seek Gestures

**Files:**
- Modify: `Sources/Takes/ContentView.swift`
- Test: `Tests/TakesTests/TransportMappingTests.swift`

- [ ] **Step 1: Add geometry helpers for display math**

In `ContentView.swift`, add small helpers near the view:

```swift
private var timelineSpan: TimeInterval {
    max(controller.session.timelineEnd - controller.session.timelineStart, 0.001)
}

private func globalTime(atX x: CGFloat, width: CGFloat) -> TimeInterval {
    guard width > 0 else { return controller.session.timelineStart }
    let normalized = min(max(Double(x / width), 0), 1)
    return controller.session.timelineStart + normalized * timelineSpan
}

private func xPosition(for globalTime: TimeInterval, width: CGFloat) -> CGFloat {
    CGFloat(
        TransportMapping.normalizedPosition(
            globalTime: globalTime,
            timelineStart: controller.session.timelineStart,
            timelineEnd: controller.session.timelineEnd
        )
    ) * width
}
```

- [ ] **Step 2: Add track timeline section**

```swift
private var trackTimelineSection: some View {
    GeometryReader { proxy in
        let infoWidth: CGFloat = 240
        let waveformWidth = max(proxy.size.width - infoWidth, 1)
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                trackRow(side: .a, track: controller.session.trackA, infoWidth: infoWidth, waveformWidth: waveformWidth)
                Divider()
                trackRow(side: .b, track: controller.session.trackB, infoWidth: infoWidth, waveformWidth: waveformWidth)
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if controller.session.isPlayable {
                Rectangle()
                    .fill(.blue)
                    .frame(width: 2)
                    .offset(x: infoWidth + xPosition(for: controller.session.transportPosition, width: waveformWidth))
                    .padding(.vertical, 8)
            }
        }
    }
    .frame(minHeight: 260)
}
```

- [ ] **Step 3: Add track row and info area**

```swift
private func trackRow(
    side: TrackSide,
    track: LoadedTrack?,
    infoWidth: CGFloat,
    waveformWidth: CGFloat
) -> some View {
    HStack(spacing: 0) {
        trackInfoArea(side: side, track: track)
            .frame(width: infoWidth, minHeight: 124, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                controller.selectActiveTrack(side)
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: dropBinding(for: side)) { providers in
                handleDrop(providers: providers, side: side)
            }

        waveformLane(side: side, track: track, width: waveformWidth)
            .frame(maxWidth: .infinity, minHeight: 124)
    }
}
```

Add in `PlaybackController`:

```swift
func selectActiveTrack(_ side: TrackSide) {
    switch side {
    case .a:
        guard session.trackA != nil else { return }
    case .b:
        guard session.trackB != nil else { return }
    }
    session.activeTrack = side
    applyAudibility()
}
```

- [ ] **Step 4: Add info area with offset and gear**

```swift
private func trackInfoArea(side: TrackSide, track: LoadedTrack?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        HStack {
            Text(side.title)
                .font(.headline)
            if controller.session.activeTrack == side {
                Text("Active")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15), in: Capsule())
            }
            Spacer()
            gainButton(side: side, track: track)
        }

        if let track {
            Text(track.displayName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(track.metadataSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("No file loaded")
                .foregroundStyle(.secondary)
        }

        offsetControl(side: side, track: track)
    }
    .padding(12)
    .background(backgroundStyle(for: side))
}
```

- [ ] **Step 5: Add gain menu and offset control**

```swift
private func gainButton(side: TrackSide, track: LoadedTrack?) -> some View {
    Button {
        gainPopoverSide = side
    } label: {
        Image(systemName: "gearshape")
            .accessibilityLabel("\(side.title) Settings")
    }
    .buttonStyle(.borderless)
    .disabled(track == nil)
    .popover(
        isPresented: Binding(
            get: { gainPopoverSide == side },
            set: { isPresented in
                gainPopoverSide = isPresented ? side : nil
            }
        ),
        arrowEdge: .trailing
    ) {
        gainPopoverContent(side: side, track: track)
            .padding()
            .frame(width: 300)
    }
}

private func gainPopoverContent(side: TrackSide, track: LoadedTrack?) -> some View {
    let gainValue = Int((track?.gainDB ?? 0).rounded())
    return VStack(alignment: .leading, spacing: 10) {
        Text("\(side.title) Gain")
            .font(.headline)
        Text("\(gainValue) dB")
            .foregroundStyle(.secondary)
        HStack(spacing: 10) {
            ResettableSlider(
                value: Binding(
                    get: { Double(gainValue) },
                    set: { controller.setGain(side, db: Float(Int($0.rounded()))) }
                ),
                range: -24...24,
                resetValue: 0
            )
            NumericControlRow(
                value: Binding(
                    get: { gainValue },
                    set: { controller.setGain(side, db: Float($0)) }
                ),
                configuration: .gain
            )
        }
        .disabled(track == nil)
    }
}

private func offsetControl(side: TrackSide, track: LoadedTrack?) -> some View {
    let offsetMs = Int(((track?.offsetSeconds ?? 0) * 1000).rounded())
    return VStack(alignment: .leading, spacing: 4) {
        Text("Offset \(offsetMs) ms")
            .font(.caption)
            .foregroundStyle(.secondary)
        NumericControlRow(
            value: Binding(
                get: { offsetMs },
                set: { controller.setOffset(side, seconds: Double($0) / 1000) }
            ),
            configuration: .offset
        )
        .disabled(track == nil)
    }
}
```

The info-area call site now uses `gainButton(side:track:)`.

- [ ] **Step 6: Add placeholder waveform lane and seek gestures**

```swift
private func waveformLane(side: TrackSide, track: LoadedTrack?, width: CGFloat) -> some View {
    GeometryReader { proxy in
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(.background.opacity(0.01))

            if let track {
                placeholderWaveform(for: side)
                    .frame(
                        width: max(CGFloat(track.duration / timelineSpan) * proxy.size.width, 1),
                        height: 58
                    )
                    .offset(
                        x: xPosition(for: track.offsetSeconds, width: proxy.size.width)
                    )
                    .foregroundStyle(side == .a ? .blue.opacity(0.55) : .green.opacity(0.55))
            } else {
                Text("Drop audio file here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
            }

            Rectangle()
                .fill(.secondary.opacity(0.25))
                .frame(width: 1)
                .offset(x: xPosition(for: 0, width: proxy.size.width))
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    controller.seek(to: globalTime(atX: value.location.x, width: proxy.size.width))
                }
        )
    }
}

private func placeholderWaveform(for side: TrackSide) -> some View {
    Canvas { context, size in
        let barCount = 96
        let barWidth = max(size.width / CGFloat(barCount * 2), 1)
        for index in 0..<barCount {
            let phase = Double(index) * 0.37 + (side == .a ? 0 : 0.8)
            let amplitude = 0.25 + 0.7 * abs(sin(phase) * cos(phase * 0.43))
            let height = size.height * amplitude
            let x = CGFloat(index) * size.width / CGFloat(barCount)
            let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .foreground)
        }
    }
}
```

- [ ] **Step 7: Run build-for-testing**

Run:

```bash
xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath .derived-data build-for-testing
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add Sources/Takes/ContentView.swift Sources/Takes/PlaybackController.swift
git commit -m "Add waveform lanes and draggable playhead"
```

---

### Task 6: Drag-And-Drop Routing And Cleanup

**Files:**
- Modify: `Sources/Takes/ContentView.swift`
- Modify: `Sources/Takes/PlaybackController.swift`
- Modify: `Sources/Takes/LibraryTrackSelectionLoader.swift`
- Test: `Tests/TakesTests/SessionTests.swift`

- [ ] **Step 1: Add URL extraction helper for multi-drop**

In `ContentView.swift`, add:

```swift
private func loadDroppedURLs(from providers: [NSItemProvider], side: TrackSide?) -> Bool {
    let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    guard !fileProviders.isEmpty else { return false }

    var urls: [URL] = []
    let group = DispatchGroup()

    for provider in fileProviders {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let url = extractDroppedFileURL(from: item) {
                urls.append(url)
            }
            group.leave()
        }
    }

    group.notify(queue: .main) {
        Task { @MainActor in
            if let side, urls.count == 1 {
                await controller.loadTrack(side, from: urls[0])
            } else if let side, urls.count > 1 {
                controller.setPlaybackError(.tooManyImportFiles)
            } else {
                await controller.loadImportedFiles(urls)
            }
        }
    }

    return true
}
```

Add controller setter:

```swift
func setPlaybackError(_ error: PlaybackError) {
    playbackError = error
}
```

- [ ] **Step 2: Wire row-specific and general drops**

For row drop:

```swift
.onDrop(of: [UTType.fileURL.identifier], isTargeted: dropBinding(for: side)) { providers in
    loadDroppedURLs(from: providers, side: side)
}
```

For window-level drop on the top `VStack`, keep row highlighting only:

```swift
.onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
    loadDroppedURLs(from: providers, side: nil)
}
```

- [ ] **Step 3: Remove obsolete UI functions**

Delete these old sections after the new UI compiles:

```swift
private var headerSection: some View
private func trackHeader(...)
private var transportSection: some View
private var controlsSection: some View
private func gainCard(...)
private func handleDrop(providers:side:)
```

Keep reusable pieces:

```swift
NumericControlRow
IntegerInputField
ResettableSlider
extractDroppedFileURL
```

Keep `ResettableSlider` and `DoubleClickResetSlider` because the gain popover still uses the gain slider.

- [ ] **Step 4: Clean up Music parser error text**

Update `LibraryTrackSelectionLoader.musicSelectionScript` so Music reports the same more-than-two selection wording as file import:

```applescript
if (count of selectedTracks) > 2 then error "Select one or two audio files."
```

Update the `parseSelectionOutput` guard to use the same text:

```swift
guard entries.count <= 2 else {
    throw PlaybackError.librarySelectionFailed("Select one or two audio files.")
}
```

- [ ] **Step 5: Run build-for-testing**

Run:

```bash
xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath .derived-data build-for-testing
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Sources/Takes/ContentView.swift Sources/Takes/PlaybackController.swift Sources/Takes/LibraryTrackSelectionLoader.swift
git commit -m "Route drops through unified import behavior"
```

---

### Task 7: Final Verification And Documentation Update

**Files:**
- Modify: `README.md`
- Verify: whole project

- [ ] **Step 1: Update README current scope and operator guide**

In `README.md`, update the scope bullets:

```markdown
- Loading one or two local audio files through a single Open control
- Dragging files onto a specific track row to replace that row
- Dragging files elsewhere in the window to use the shared Open assignment rules
- Placeholder waveform lanes for each loaded track
- Signed global timeline playback with a playhead over the waveform lanes
- Independent offset adjustment for Track A and Track B
- Independent gain trim per track through the track settings popup
```

Update out-of-scope:

```markdown
- Real waveform extraction and caching
```

Update playback notes:

```markdown
- The progress timeline is based on the union of loaded track ranges and the global 0:00 point.
- Negative offsets extend the visible timeline before 0:00.
- Positive offsets create leading empty space before the shifted track starts.
```

- [ ] **Step 2: Run focused tests**

Run:

```bash
xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath .derived-data -only-testing:TakesTests/TransportMappingTests -only-testing:TakesTests/SessionTests test
```

Expected: PASS. If the environment blocks Apple test infrastructure, record the exact failure output in the task notes and continue to the `build-for-testing` verification step.

- [ ] **Step 3: Run build-for-testing**

Run:

```bash
xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath .derived-data build-for-testing
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual Xcode smoke test**

Run the app in Xcode or with:

```bash
open .derived-data/Build/Products/Debug/Takes.app
```

Verify manually:

- Top transport appears with `Open`, dropdown, play/pause, rewind, switch, and signed time readout.
- `Open` accepts one file and fills Track A.
- A second one-file open fills Track B.
- A third one-file open replaces the active track.
- Two-file open loads A then B.
- More than two files shows an inline error.
- Placeholder waveform lanes render for loaded tracks.
- Positive offset creates leading blank space.
- Negative offset extends the visible timeline left of zero.
- The playhead line spans both waveform lanes.
- Clicking and dragging in a waveform lane seeks.
- Clicking the track info area changes the active track.
- Gear popup contains gain only.
- Offset controls are visible for both tracks.
- Row-specific drop replaces that row.
- General window drop uses shared assignment rules.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Document waveform timeline UI behavior"
```

---

## Final Integration

- [ ] Run:

```bash
git status --short
```

Expected: clean worktree.

- [ ] Run:

```bash
xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath .derived-data build-for-testing
```

Expected: BUILD SUCCEEDED.

- [ ] Run the full test suite:

```bash
xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath .derived-data test
```

Expected: all tests pass. If blocked by sandboxed Apple test infrastructure, record the exact failure and rely on `build-for-testing` plus focused test output from earlier tasks.
