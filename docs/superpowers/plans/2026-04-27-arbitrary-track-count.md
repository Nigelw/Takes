# Arbitrary Track Count Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Takes's fixed two-track model with an ordered, capped list of up to 32 loaded tracks that can be appended, removed, replaced, and switched instantly by UI order.

**Architecture:** Move session state from `trackA`/`trackB` to `tracks: [SessionTrack]` plus `activeTrackID`. Generalize timeline math to operate on N tracks, then refactor `PlaybackController` to keep runtime audio nodes keyed by stable track ID. Update SwiftUI last so it renders the new ordered model and calls the new controller APIs.

**Tech Stack:** Swift, SwiftUI, AppKit drag/drop bridging, AVFoundation `AVAudioEngine`, Swift Testing, Xcode scheme `Takes`.

---

## File Structure

- Modify `Sources/Takes/Models.swift`
  - Add `SessionTrack`.
  - Replace fixed `trackA`, `trackB`, and `TrackSide` session state with an ordered collection.
  - Replace `tooManyImportFiles` with capped/best-effort import error cases.
- Modify `Sources/Takes/TransportMapping.swift`
  - Add N-track `timelineRange(tracks:)`.
  - Keep compatibility helpers only as temporary shims if needed during the refactor.
- Modify `Sources/Takes/LibraryTrackSelectionLoader.swift`
  - Remove the two-track selection cap.
  - Keep Music view-order parsing.
- Modify `Sources/Takes/PlaybackController.swift`
  - Replace fixed player/mixer/file properties with `runtimeTracksByID`.
  - Implement append, row replacement, removal, active-track cycling, cap enforcement, and best-effort batch import.
  - Remove overlap warning state.
- Modify `Sources/Takes/ContentView.swift`
  - Render dynamic rows from `session.tracks`.
  - Use row IDs for active selection, gain, offset, row replacement, and removal.
  - Add scrollable track list and empty drop target.
- Modify `Tests/TakesTests/TransportMappingTests.swift`
  - Update timeline tests to N-track helpers.
- Modify `Tests/TakesTests/SessionTests.swift`
  - Replace A/B session/import tests with ordered-track tests.
  - Update Music selection tests.

## Task 1: Model And Timeline Foundation

**Files:**
- Modify: `Sources/Takes/Models.swift`
- Modify: `Sources/Takes/TransportMapping.swift`
- Test: `Tests/TakesTests/SessionTests.swift`
- Test: `Tests/TakesTests/TransportMappingTests.swift`

- [ ] **Step 1: Replace readiness tests with ordered-track expectations**

In `Tests/TakesTests/SessionTests.swift`, replace `sessionReadinessRequiresTwoTracksAndOverlap`, `sessionRemainsPlayableWithSingleTrackOrNoOverlapAsLongAsDurationExists`, and `sessionUsesSignedTimelineBoundsForPlaybackReadiness` with:

```swift
@Test
func sessionReadinessUsesOrderedTracks() {
    var session = ComparisonSession()
    #expect(!session.isPlayable)
    #expect(!session.canSwitchPlayback)
    #expect(session.activeTrackID == nil)

    let first = SessionTrack(loadedTrack: makeTrack(name: "a.wav"))
    session.tracks = [first]
    session.activeTrackID = first.id
    session.timelineEnd = 12

    #expect(session.isPlayable)
    #expect(!session.canSwitchPlayback)
    #expect(session.activeTrackID == first.id)

    let second = SessionTrack(loadedTrack: makeTrack(name: "b.wav"))
    session.tracks.append(second)

    #expect(session.isPlayable)
    #expect(session.canSwitchPlayback)
}

@Test
func sessionUsesSignedTimelineBoundsForPlaybackReadiness() {
    let first = SessionTrack(loadedTrack: makeTrack(name: "a.wav"))
    var session = ComparisonSession(tracks: [first], activeTrackID: first.id)
    #expect(!session.isPlayable)

    session.timelineStart = -4
    session.timelineEnd = 120
    session.transportPosition = -4

    #expect(session.isPlayable)
    #expect(session.duration == 124)
}
```

- [ ] **Step 2: Replace two-track timeline tests with N-track timeline tests**

In `Tests/TakesTests/TransportMappingTests.swift`, replace the three `timelineRange...` tests with:

```swift
@Test
func timelineRangeIncludesZeroAndLoadedTrackRangeForSingleTrack() throws {
    let track = makeTrack(duration: 10, offset: 6)

    let range = try #require(TransportMapping.timelineRange(tracks: [track]))

    #expect(range.lowerBound == 0)
    #expect(range.upperBound == 16)
}

@Test
func timelineRangeExpandsBelowZeroForNegativeOffsetsAcrossManyTracks() throws {
    let first = makeTrack(duration: 10, offset: 0)
    let second = makeTrack(duration: 8, offset: -12)
    let third = makeTrack(duration: 4, offset: 20)

    let range = try #require(TransportMapping.timelineRange(tracks: [first, second, third]))

    #expect(range.lowerBound == -12)
    #expect(range.upperBound == 24)
}

@Test
func timelineRangeReturnsNilWithoutTracks() {
    #expect(TransportMapping.timelineRange(tracks: []) == nil)
}
```

- [ ] **Step 3: Run the focused tests and verify they fail**

Run:

```bash
xcodebuild test -scheme Takes -only-testing:TakesTests/SessionTests/sessionReadinessUsesOrderedTracks -only-testing:TakesTests/SessionTests/sessionUsesSignedTimelineBoundsForPlaybackReadiness -only-testing:TakesTests/TransportMappingTests/timelineRangeIncludesZeroAndLoadedTrackRangeForSingleTrack -only-testing:TakesTests/TransportMappingTests/timelineRangeExpandsBelowZeroForNegativeOffsetsAcrossManyTracks -only-testing:TakesTests/TransportMappingTests/timelineRangeReturnsNilWithoutTracks
```

Expected: fail to compile because `SessionTrack`, `tracks`, `activeTrackID`, `canSwitchPlayback`, and `TransportMapping.timelineRange(tracks:)` do not exist yet.

- [ ] **Step 4: Implement ordered session model**

In `Sources/Takes/Models.swift`, remove `TrackSide` and replace `ComparisonSession` with:

```swift
struct SessionTrack: Identifiable, Equatable {
    let id: UUID
    var loadedTrack: LoadedTrack

    init(id: UUID = UUID(), loadedTrack: LoadedTrack) {
        self.id = id
        self.loadedTrack = loadedTrack
    }
}

struct ComparisonSession: Equatable {
    var tracks: [SessionTrack] = []
    var activeTrackID: SessionTrack.ID?
    var isPlaying = false
    var transportPosition: TimeInterval = 0
    var timelineStart: TimeInterval = 0
    var timelineEnd: TimeInterval = 0

    var duration: TimeInterval {
        max(0, timelineEnd - timelineStart)
    }

    var isPlayable: Bool {
        !tracks.isEmpty && timelineEnd > timelineStart
    }

    var canSwitchPlayback: Bool {
        tracks.count >= 2
    }

    var activeTrackIndex: Int? {
        guard let activeTrackID else { return nil }
        return tracks.firstIndex { $0.id == activeTrackID }
    }
}
```

Keep `LoadedTrack`, `PlaybackError`, and `TimeInterval` formatting in the same file for now.

- [ ] **Step 5: Implement N-track timeline helper**

In `Sources/Takes/TransportMapping.swift`, replace `timelineRange(trackA:trackB:)` with:

```swift
static func timelineRange(tracks: [LoadedTrack]) -> ClosedRange<TimeInterval>? {
    let ranges = tracks.map { track in
        transportBounds(duration: track.duration, offset: track.offsetSeconds)
    }

    guard !ranges.isEmpty else { return nil }

    let lower = min(0, ranges.map(\.lowerBound).min() ?? 0)
    let upper = max(0, ranges.map(\.upperBound).max() ?? 0)
    guard upper > lower else { return nil }
    return lower...upper
}
```

Leave `overlapRange` and `validOverlapDuration` in place only if old tests or code still reference them during this task; they will be removed or ignored later when `overlapWarning` is deleted.

- [ ] **Step 6: Run the focused tests and verify they pass or reveal remaining compile references**

Run:

```bash
xcodebuild test -scheme Takes -only-testing:TakesTests/SessionTests/sessionReadinessUsesOrderedTracks -only-testing:TakesTests/SessionTests/sessionUsesSignedTimelineBoundsForPlaybackReadiness -only-testing:TakesTests/TransportMappingTests/timelineRangeIncludesZeroAndLoadedTrackRangeForSingleTrack -only-testing:TakesTests/TransportMappingTests/timelineRangeExpandsBelowZeroForNegativeOffsetsAcrossManyTracks -only-testing:TakesTests/TransportMappingTests/timelineRangeReturnsNilWithoutTracks
```

Expected: the new tests pass after remaining compile errors from A/B references in unrelated source files are fixed in later tasks. If the full target cannot compile yet because `PlaybackController` and `ContentView` still reference `TrackSide`, proceed to Task 3 before expecting a green build.

- [ ] **Step 7: Commit the model and timeline foundation**

```bash
git add Sources/Takes/Models.swift Sources/Takes/TransportMapping.swift Tests/TakesTests/SessionTests.swift Tests/TakesTests/TransportMappingTests.swift
git commit -m "Refactor session model for ordered tracks"
```

## Task 2: Music Selection Allows More Than Two Tracks

**Files:**
- Modify: `Sources/Takes/LibraryTrackSelectionLoader.swift`
- Test: `Tests/TakesTests/SessionTests.swift`

- [ ] **Step 1: Replace Music two-track cap tests**

In `Tests/TakesTests/SessionTests.swift`, replace `musicSelectionScriptUsesSharedTooManySelectionMessage` and `musicSelectionParsingRejectsMoreThanTwoTracks` with:

```swift
@Test
func musicSelectionScriptDoesNotRejectMoreThanTwoTracks() {
    let script = LibraryTrackSelectionLoader.musicSelectionScript

    #expect(!script.contains("Select one or two audio files."))
    #expect(!script.contains("(count of selectedTracks) > 2"))
}

@Test
func musicSelectionParsingSortsManyTracksByViewOrder() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
    let thirdURL = tempDirectory.appending(path: UUID().uuidString + ".m4a")
    let firstURL = tempDirectory.appending(path: UUID().uuidString + ".mp3")
    let secondURL = tempDirectory.appending(path: UUID().uuidString + ".wav")

    FileManager.default.createFile(atPath: thirdURL.path, contents: Data())
    FileManager.default.createFile(atPath: firstURL.path, contents: Data())
    FileManager.default.createFile(atPath: secondURL.path, contents: Data())
    defer {
        try? FileManager.default.removeItem(at: thirdURL)
        try? FileManager.default.removeItem(at: firstURL)
        try? FileManager.default.removeItem(at: secondURL)
    }

    let output = """
    9\t\(thirdURL.path)
    2\t\(firstURL.path)
    5\t\(secondURL.path)
    """

    let urls = try LibraryTrackSelectionLoader.parseSelectionOutput(output)

    #expect(urls == [firstURL, secondURL, thirdURL])
}
```

- [ ] **Step 2: Run the Music selection tests and verify they fail**

Run:

```bash
xcodebuild test -scheme Takes -only-testing:TakesTests/SessionTests/musicSelectionScriptDoesNotRejectMoreThanTwoTracks -only-testing:TakesTests/SessionTests/musicSelectionParsingSortsManyTracksByViewOrder
```

Expected: fail because the AppleScript and parser still reject selections above two tracks.

- [ ] **Step 3: Remove Music selection cap**

In `Sources/Takes/LibraryTrackSelectionLoader.swift`, delete this AppleScript line:

```applescript
if (count of selectedTracks) > 2 then error "Select one or two audio files."
```

In `parseSelectionOutput(_:)`, delete this guard:

```swift
guard entries.count <= 2 else {
    throw PlaybackError.librarySelectionFailed("Select one or two audio files.")
}
```

Keep the existing `entries.isEmpty` guard and sorted parse behavior.

- [ ] **Step 4: Run the Music selection tests and verify they pass**

Run:

```bash
xcodebuild test -scheme Takes -only-testing:TakesTests/SessionTests/musicSelectionScriptDoesNotRejectMoreThanTwoTracks -only-testing:TakesTests/SessionTests/musicSelectionParsingSortsManyTracksByViewOrder
```

Expected: pass.

- [ ] **Step 5: Commit Music selection update**

```bash
git add Sources/Takes/LibraryTrackSelectionLoader.swift Tests/TakesTests/SessionTests.swift
git commit -m "Allow Music selection to return many tracks"
```

## Task 3: Import Result And Ordered Append Semantics

**Files:**
- Modify: `Sources/Takes/Models.swift`
- Modify: `Sources/Takes/PlaybackController.swift`
- Test: `Tests/TakesTests/SessionTests.swift`

- [ ] **Step 1: Add best-effort import tests**

In `Tests/TakesTests/SessionTests.swift`, replace `importAssignmentsUseSharedOpenRules`, `importAssignmentsRejectMoreThanTwoFiles`, `importAssignmentsLoadTwoSelectionsIntoTrackAThenTrackB`, `importedFilesStopAfterFirstLoadFailure`, `importedFilesDoNotPartiallyApplyWhenSecondLoadFails`, and `replacementPreservesExistingSideSettings` with:

```swift
@MainActor
@Test
func importedFilesAppendSuccessesAndReportFailures() async throws {
    let first = try makeTemporaryAudioFile(name: "first.wav")
    let missing = URL(fileURLWithPath: "/tmp/missing-second.wav")
    let third = try makeTemporaryAudioFile(name: "third.wav")
    defer {
        try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: third.deletingLastPathComponent())
    }

    let controller = PlaybackController(loader: FakeAudioFileLoader(failingURLs: [missing]))

    await controller.loadImportedFiles([first, missing, third])

    #expect(controller.session.tracks.map { $0.loadedTrack.displayName } == ["first.wav", "third.wav"])
    #expect(controller.session.activeTrackID == controller.session.tracks.first?.id)
    #expect(controller.playbackError?.localizedDescription.contains("missing-second.wav") == true)
}

@MainActor
@Test
func importedFilesAppendToExistingTracksAndPreserveSettings() async throws {
    let first = try makeTemporaryAudioFile(name: "first.wav")
    let second = try makeTemporaryAudioFile(name: "second.wav")
    defer {
        try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
    }

    let controller = PlaybackController()
    await controller.loadImportedFiles([first])
    let existingID = try #require(controller.session.tracks.first?.id)
    controller.setGain(existingID, db: -6)
    controller.setOffset(existingID, seconds: 1.25)

    await controller.loadImportedFiles([second])

    #expect(controller.session.tracks.count == 2)
    #expect(controller.session.tracks[0].id == existingID)
    #expect(controller.session.tracks[0].loadedTrack.gainDB == -6)
    #expect(controller.session.tracks[0].loadedTrack.offsetSeconds == 1.25)
    #expect(controller.session.tracks[1].loadedTrack.displayName == "second.wav")
}

@MainActor
@Test
func importedFilesRespectThirtyTwoTrackCap() async throws {
    let urls = try (0..<33).map { index in
        try makeTemporaryAudioFile(name: "track-\(index).wav")
    }
    defer {
        for url in urls {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    let controller = PlaybackController()

    await controller.loadImportedFiles(urls)

    #expect(controller.session.tracks.count == PlaybackController.maximumTrackCount)
    #expect(controller.playbackError?.localizedDescription.contains("Takes currently supports up to 32 loaded tracks.") == true)
    #expect(controller.playbackError?.localizedDescription.contains("track-32.wav") == true)
}
```

- [ ] **Step 2: Run the import tests and verify they fail**

Run:

```bash
xcodebuild test -scheme Takes -only-testing:TakesTests/SessionTests/importedFilesAppendSuccessesAndReportFailures -only-testing:TakesTests/SessionTests/importedFilesAppendToExistingTracksAndPreserveSettings -only-testing:TakesTests/SessionTests/importedFilesRespectThirtyTwoTrackCap
```

Expected: fail to compile because `setGain`/`setOffset` still use `TrackSide`, `maximumTrackCount` does not exist, and `loadImportedFiles` is still atomic.

- [ ] **Step 3: Add grouped import error model**

In `Sources/Takes/Models.swift`, add this before `PlaybackError`:

```swift
struct ImportFailure: Equatable {
    let fileName: String
    let message: String

    init(url: URL, message: String) {
        fileName = url.lastPathComponent.ifEmpty(url.path)
        self.message = message
    }
}
```

Update `PlaybackError` cases by removing `tooManyImportFiles` and adding:

```swift
case importFailures([ImportFailure])
case trackLimitExceeded(limit: Int, skippedFileNames: [String])
```

Add these `errorDescription` branches:

```swift
case let .importFailures(failures):
    let details = failures.map { "\($0.fileName): \($0.message)" }.joined(separator: "\n")
    return "Some files could not be loaded.\n\(details)"
case let .trackLimitExceeded(limit, skippedFileNames):
    let skipped = skippedFileNames.joined(separator: "\n")
    return "Takes currently supports up to \(limit) loaded tracks.\nSkipped:\n\(skipped)"
```

Move the existing private `String.ifEmpty(_:)` extension from `AudioFileLoader.swift` into `Models.swift` as an internal file-private extension so `ImportFailure` and `AudioFileLoader` can both use the same behavior. Remove the duplicate extension from `AudioFileLoader.swift`.

- [ ] **Step 4: Refactor controller append APIs without dynamic runtime nodes yet**

In `Sources/Takes/PlaybackController.swift`, add:

```swift
static let maximumTrackCount = 32
```

Replace `PreparedTrackLoad.side` with:

```swift
private struct PreparedTrackLoad {
    let metadata: LoadedTrack
    let file: AVAudioFile
}
```

Change `prepareTrackLoad` to:

```swift
private func prepareTrackLoad(from url: URL) throws -> PreparedTrackLoad {
    let metadata = try loader.loadTrackMetadata(from: url)
    let file = try loader.makeAudioFile(from: url)
    return PreparedTrackLoad(metadata: metadata, file: file)
}
```

Replace `loadImportedFiles(_:)` with this best-effort shape:

```swift
func loadImportedFiles(_ urls: [URL]) async {
    guard !urls.isEmpty else { return }

    var preparedLoads: [PreparedTrackLoad] = []
    var failures: [ImportFailure] = []
    var skipped: [String] = []
    var remainingSlots = Self.maximumTrackCount - session.tracks.count

    for url in urls {
        guard remainingSlots > 0 else {
            skipped.append(url.lastPathComponent)
            continue
        }

        do {
            preparedLoads.append(try prepareTrackLoad(from: url))
            remainingSlots -= 1
        } catch let error as PlaybackError {
            failures.append(ImportFailure(url: url, message: error.localizedDescription))
        } catch {
            failures.append(ImportFailure(url: url, message: PlaybackError.failedToOpenFile(url).localizedDescription))
        }
    }

    let wasPlaying = session.isPlaying
    let resumePosition = currentTransportPosition()

    for preparedLoad in preparedLoads {
        appendPreparedTrackLoad(preparedLoad)
    }

    finishTrackLoading(preferZero: session.tracks.count == preparedLoads.count)

    if wasPlaying {
        seek(to: resumePosition)
        play()
    }

    if !failures.isEmpty {
        playbackError = .importFailures(failures)
    }
    if !skipped.isEmpty {
        playbackError = .trackLimitExceeded(limit: Self.maximumTrackCount, skippedFileNames: skipped)
    }
}
```

Add:

```swift
private func appendPreparedTrackLoad(_ preparedLoad: PreparedTrackLoad) {
    let sessionTrack = SessionTrack(loadedTrack: preparedLoad.metadata)
    session.tracks.append(sessionTrack)
    audioFilesByTrackID[sessionTrack.id] = preparedLoad.file
    if session.activeTrackID == nil {
        session.activeTrackID = sessionTrack.id
    }
}
```

For this task, introduce this temporary storage near the old `audioFileA`/`audioFileB` properties and remove the old audio file properties:

```swift
private var audioFilesByTrackID: [SessionTrack.ID: AVAudioFile] = [:]
```

Do not finish dynamic player/mixer runtime in this task; Task 5 handles that. The project may still not compile until fixed side-based methods are replaced in Task 4.

- [ ] **Step 5: Replace gain and offset signatures by track ID**

In `Sources/Takes/PlaybackController.swift`, replace `setGain(_ side: TrackSide, db: Float)` with:

```swift
func setGain(_ trackID: SessionTrack.ID, db: Float) {
    guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
    session.tracks[index].loadedTrack.gainDB = db
    applyAudibility()
}
```

Replace `setOffset(_ side: TrackSide, seconds: TimeInterval)` with:

```swift
func setOffset(_ trackID: SessionTrack.ID, seconds: TimeInterval) {
    guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
    session.tracks[index].loadedTrack.offsetSeconds = seconds

    recalculateSessionDuration()

    guard session.isPlaying else { return }
    do {
        try reschedulePlayers(startingAt: session.transportPosition)
        startScheduledPlayers()
        playbackStartedFromTransport = session.transportPosition
        playbackStartedAt = CACurrentMediaTime()
        applyAudibility()
    } catch let error as PlaybackError {
        playbackError = error
    } catch {
        playbackError = .schedulingFailed
    }
}
```

Add a temporary `startScheduledPlayers()` that will be completed in Task 5:

```swift
private func startScheduledPlayers() {
    // Task 5 replaces this with dynamic runtime player starts.
}
```

- [ ] **Step 6: Run the import tests**

Run:

```bash
xcodebuild test -scheme Takes -only-testing:TakesTests/SessionTests/importedFilesAppendSuccessesAndReportFailures -only-testing:TakesTests/SessionTests/importedFilesAppendToExistingTracksAndPreserveSettings -only-testing:TakesTests/SessionTests/importedFilesRespectThirtyTwoTrackCap
```

Expected: these may still fail to compile until Task 4 and Task 5 remove remaining side-based controller references. Do not commit broken code unless executing this plan in a branch where intermediate compile failures are acceptable; otherwise complete Tasks 4 and 5 before the commit.

## Task 4: Active Selection, Switching, Replacement, And Removal

**Files:**
- Modify: `Sources/Takes/PlaybackController.swift`
- Test: `Tests/TakesTests/SessionTests.swift`

- [ ] **Step 1: Add active selection and removal tests**

In `Tests/TakesTests/SessionTests.swift`, add:

```swift
@MainActor
@Test
func switchPlaybackCyclesThroughTrackOrderAndWraps() async throws {
    let urls = try (0..<3).map { try makeTemporaryAudioFile(name: "track-\($0).wav") }
    defer {
        for url in urls {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    let controller = PlaybackController()
    await controller.loadImportedFiles(urls)

    let ids = controller.session.tracks.map(\.id)
    #expect(controller.session.activeTrackID == ids[0])

    controller.toggleActiveTrack()
    #expect(controller.session.activeTrackID == ids[1])

    controller.toggleActiveTrack()
    #expect(controller.session.activeTrackID == ids[2])

    controller.toggleActiveTrack()
    #expect(controller.session.activeTrackID == ids[0])
}

@MainActor
@Test
func removingActiveTrackPausesAndSelectsNextOrPrevious() async throws {
    let urls = try (0..<3).map { try makeTemporaryAudioFile(name: "track-\($0).wav") }
    defer {
        for url in urls {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    let controller = PlaybackController()
    await controller.loadImportedFiles(urls)
    let ids = controller.session.tracks.map(\.id)
    controller.selectActiveTrack(ids[1])
    controller.session.isPlaying = true

    controller.removeTrack(ids[1])

    #expect(!controller.session.isPlaying)
    #expect(controller.session.activeTrackID == ids[2])

    controller.session.isPlaying = true
    controller.removeTrack(ids[2])

    #expect(!controller.session.isPlaying)
    #expect(controller.session.activeTrackID == ids[0])
}

@MainActor
@Test
func removingFinalTrackClearsActiveSelectionAndTimeline() async throws {
    let url = try makeTemporaryAudioFile(name: "only.wav")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let controller = PlaybackController()
    await controller.loadImportedFiles([url])
    let id = try #require(controller.session.tracks.first?.id)

    controller.removeTrack(id)

    #expect(controller.session.tracks.isEmpty)
    #expect(controller.session.activeTrackID == nil)
    #expect(controller.session.timelineStart == 0)
    #expect(controller.session.timelineEnd == 0)
    #expect(controller.session.transportPosition == 0)
}

@MainActor
@Test
func replacingTrackResetsGainAndOffsetButKeepsRowActive() async throws {
    let first = try makeTemporaryAudioFile(name: "first.wav")
    let replacement = try makeTemporaryAudioFile(name: "replacement.wav")
    defer {
        try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: replacement.deletingLastPathComponent())
    }

    let controller = PlaybackController()
    await controller.loadImportedFiles([first])
    let id = try #require(controller.session.tracks.first?.id)
    controller.setGain(id, db: -12)
    controller.setOffset(id, seconds: 2)

    await controller.replaceTrack(id, with: replacement)

    #expect(controller.session.tracks.count == 1)
    #expect(controller.session.tracks[0].id == id)
    #expect(controller.session.tracks[0].loadedTrack.displayName == "replacement.wav")
    #expect(controller.session.tracks[0].loadedTrack.gainDB == 0)
    #expect(controller.session.tracks[0].loadedTrack.offsetSeconds == 0)
    #expect(controller.session.activeTrackID == id)
}
```

- [ ] **Step 2: Run the active/removal tests and verify they fail**

Run:

```bash
xcodebuild test -scheme Takes -only-testing:TakesTests/SessionTests/switchPlaybackCyclesThroughTrackOrderAndWraps -only-testing:TakesTests/SessionTests/removingActiveTrackPausesAndSelectsNextOrPrevious -only-testing:TakesTests/SessionTests/removingFinalTrackClearsActiveSelectionAndTimeline -only-testing:TakesTests/SessionTests/replacingTrackResetsGainAndOffsetButKeepsRowActive
```

Expected: fail because ID-based selection, removal, and replacement APIs do not exist.

- [ ] **Step 3: Implement ID-based active selection**

In `Sources/Takes/PlaybackController.swift`, replace `toggleActiveTrack()` and `selectActiveTrack(_:)` with:

```swift
func toggleActiveTrack() {
    guard session.canSwitchPlayback else { return }
    let currentIndex = session.activeTrackIndex ?? -1
    let nextIndex = currentIndex + 1 < session.tracks.count ? currentIndex + 1 : 0
    session.activeTrackID = session.tracks[nextIndex].id
    applyAudibility()
}

func selectActiveTrack(_ trackID: SessionTrack.ID) {
    guard session.tracks.contains(where: { $0.id == trackID }) else { return }
    session.activeTrackID = trackID
    applyAudibility()
}
```

- [ ] **Step 4: Implement replacement**

In `Sources/Takes/PlaybackController.swift`, add:

```swift
func replaceTrack(_ trackID: SessionTrack.ID, with url: URL) async {
    guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }

    do {
        let preparedLoad = try prepareTrackLoad(from: url)
        let wasPlaying = session.isPlaying
        let resumePosition = currentTransportPosition()

        session.tracks[index].loadedTrack = preparedLoad.metadata
        audioFilesByTrackID[trackID] = preparedLoad.file
        playbackError = nil
        recalculateSessionDuration(preferZero: false)

        if wasPlaying {
            try reschedulePlayers(startingAt: resumePosition)
            startScheduledPlayers()
            session.isPlaying = true
            playbackStartedFromTransport = session.transportPosition
            playbackStartedAt = CACurrentMediaTime()
            startTimer()
        }

        applyAudibility()
    } catch let error as PlaybackError {
        playbackError = error
    } catch {
        playbackError = .failedToOpenFile(url)
    }
}
```

This resets gain and offset because `preparedLoad.metadata` is used directly and does not preserve settings.

- [ ] **Step 5: Implement removal**

In `Sources/Takes/PlaybackController.swift`, add:

```swift
func removeTrack(_ trackID: SessionTrack.ID) {
    guard let removedIndex = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
    let removedActiveTrack = session.activeTrackID == trackID

    if removedActiveTrack {
        pause()
    }

    session.tracks.remove(at: removedIndex)
    audioFilesByTrackID.removeValue(forKey: trackID)

    if removedActiveTrack {
        if session.tracks.isEmpty {
            session.activeTrackID = nil
        } else if removedIndex < session.tracks.count {
            session.activeTrackID = session.tracks[removedIndex].id
        } else {
            session.activeTrackID = session.tracks[session.tracks.count - 1].id
        }
    } else if let activeTrackID = session.activeTrackID,
              !session.tracks.contains(where: { $0.id == activeTrackID }) {
        session.activeTrackID = session.tracks.first?.id
    }

    recalculateSessionDuration()
    applyAudibility()
}
```

Task 5 will extend this to detach runtime nodes.

- [ ] **Step 6: Run the active/removal tests**

Run:

```bash
xcodebuild test -scheme Takes -only-testing:TakesTests/SessionTests/switchPlaybackCyclesThroughTrackOrderAndWraps -only-testing:TakesTests/SessionTests/removingActiveTrackPausesAndSelectsNextOrPrevious -only-testing:TakesTests/SessionTests/removingFinalTrackClearsActiveSelectionAndTimeline -only-testing:TakesTests/SessionTests/replacingTrackResetsGainAndOffsetButKeepsRowActive
```

Expected: pass once remaining compile errors from dynamic playback are resolved in Task 5.

## Task 5: Dynamic Playback Runtime

**Files:**
- Modify: `Sources/Takes/PlaybackController.swift`
- Test: `Tests/TakesTests/SessionTests.swift`

- [ ] **Step 1: Add natural end behavior test for pure helper**

In `Tests/TakesTests/SessionTests.swift`, add:

```swift
@Test
func endOfPlaybackPositionStopsAtTimelineEnd() {
    #expect(PlaybackController.transportPositionAtNaturalEnd(timelineEnd: 12.5) == 12.5)
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
xcodebuild test -scheme Takes -only-testing:TakesTests/SessionTests/endOfPlaybackPositionStopsAtTimelineEnd
```

Expected: fail because `transportPositionAtNaturalEnd(timelineEnd:)` does not exist.

- [ ] **Step 3: Add dynamic runtime type and storage**

In `Sources/Takes/PlaybackController.swift`, remove `playerA`, `playerB`, `mixerA`, `mixerB`, `audioFileA`, `audioFileB`, and `audioFilesByTrackID`.

Add:

```swift
private struct RuntimeTrack {
    let file: AVAudioFile
    let player: AVAudioPlayerNode
    let mixer: AVAudioMixerNode
}

private var runtimeTracksByID: [SessionTrack.ID: RuntimeTrack] = [:]
```

- [ ] **Step 4: Replace runtime attach/apply helpers**

Add:

```swift
private func attachRuntimeTrack(for trackID: SessionTrack.ID, file: AVAudioFile) {
    if let existing = runtimeTracksByID.removeValue(forKey: trackID) {
        existing.player.stop()
        engine.detach(existing.player)
        engine.detach(existing.mixer)
    }

    let player = AVAudioPlayerNode()
    let mixer = AVAudioMixerNode()
    engine.attach(player)
    engine.attach(mixer)
    engine.connect(player, to: mixer, format: nil)
    engine.connect(mixer, to: engine.mainMixerNode, format: nil)
    runtimeTracksByID[trackID] = RuntimeTrack(file: file, player: player, mixer: mixer)
}

private func detachRuntimeTrack(for trackID: SessionTrack.ID) {
    guard let runtime = runtimeTracksByID.removeValue(forKey: trackID) else { return }
    runtime.player.stop()
    engine.detach(runtime.player)
    engine.detach(runtime.mixer)
}
```

Update `appendPreparedTrackLoad(_:)` to call `attachRuntimeTrack(for:file:)`:

```swift
private func appendPreparedTrackLoad(_ preparedLoad: PreparedTrackLoad) {
    let sessionTrack = SessionTrack(loadedTrack: preparedLoad.metadata)
    session.tracks.append(sessionTrack)
    configureEngine()
    attachRuntimeTrack(for: sessionTrack.id, file: preparedLoad.file)
    if session.activeTrackID == nil {
        session.activeTrackID = sessionTrack.id
    }
}
```

Update `replaceTrack(_:with:)` to call:

```swift
attachRuntimeTrack(for: trackID, file: preparedLoad.file)
```

Update `removeTrack(_:)` to call:

```swift
detachRuntimeTrack(for: trackID)
```

- [ ] **Step 5: Simplify engine configuration**

Replace `configureEngine()` with:

```swift
private func configureEngine() {
    guard !engineConfigured else { return }
    engineConfigured = true
    applyAudibility()
}
```

This method now marks the engine as usable; individual track nodes are attached when tracks are appended or replaced.

- [ ] **Step 6: Replace scheduling and player starts**

Replace `reschedulePlayers(startingAt:)` with:

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

    for sessionTrack in session.tracks {
        guard let runtime = runtimeTracksByID[sessionTrack.id] else { continue }
        runtime.player.stop()
        scheduleTrack(sessionTrack.loadedTrack, file: runtime.file, on: runtime.player, atGlobalTime: transport)
    }

    session.transportPosition = transport
}
```

Replace `startScheduledPlayers()` with:

```swift
private func startScheduledPlayers() {
    for sessionTrack in session.tracks where runtimeTracksByID[sessionTrack.id] != nil {
        runtimeTracksByID[sessionTrack.id]?.player.play()
    }
}
```

Update `play()` after `reschedulePlayers` to call `startScheduledPlayers()` instead of starting A/B players.

Update `pause()` to pause all runtime players:

```swift
for runtime in runtimeTracksByID.values {
    runtime.player.pause()
}
```

Update `stop()` to stop all runtime players:

```swift
for runtime in runtimeTracksByID.values {
    runtime.player.stop()
}
```

Update `seek(to:)` and `setOffset(_:seconds:)` to call `startScheduledPlayers()` after rescheduling.

- [ ] **Step 7: Replace audibility**

Replace `applyAudibility()` with:

```swift
private func applyAudibility() {
    guard engineConfigured else { return }

    for sessionTrack in session.tracks {
        guard let runtime = runtimeTracksByID[sessionTrack.id] else { continue }
        let gain = TransportMapping.linearGain(fromDB: sessionTrack.loadedTrack.gainDB)
        runtime.mixer.outputVolume = session.activeTrackID == sessionTrack.id ? gain : 0
    }
}
```

- [ ] **Step 8: Remove overlap warning and update timeline recalculation**

Remove:

```swift
@Published private(set) var overlapWarning: String?
```

Replace `recalculateSessionDuration(preferZero:)` with:

```swift
private func recalculateSessionDuration(preferZero: Bool = false) {
    let loadedTracks = session.tracks.map(\.loadedTrack)
    guard let range = TransportMapping.timelineRange(tracks: loadedTracks) else {
        session.timelineStart = 0
        session.timelineEnd = 0
        session.transportPosition = 0
        playbackError = nil
        return
    }

    session.timelineStart = range.lowerBound
    session.timelineEnd = range.upperBound
    session.transportPosition = Self.transportPositionAfterTimelineRecalculation(
        currentPosition: session.transportPosition,
        timelineStart: session.timelineStart,
        timelineEnd: session.timelineEnd,
        preferZero: preferZero || session.transportPosition == 0
    )

    playbackError = nil
}
```

- [ ] **Step 9: Park natural end at timeline end**

Add:

```swift
nonisolated static func transportPositionAtNaturalEnd(timelineEnd: TimeInterval) -> TimeInterval {
    timelineEnd
}
```

Update `refreshTransportTick()`:

```swift
private func refreshTransportTick() {
    guard session.isPlaying else { return }
    let transport = currentTransportPosition()
    session.transportPosition = transport
    if transport >= session.timelineEnd {
        for runtime in runtimeTracksByID.values {
            runtime.player.stop()
        }
        session.isPlaying = false
        session.transportPosition = Self.transportPositionAtNaturalEnd(timelineEnd: session.timelineEnd)
        playbackStartedAt = nil
        playbackStartedFromTransport = session.transportPosition
        timer?.invalidate()
        applyAudibility()
    }
}
```

- [ ] **Step 10: Run controller and mapping tests**

Run:

```bash
xcodebuild test -scheme Takes -only-testing:TakesTests/SessionTests -only-testing:TakesTests/TransportMappingTests
```

Expected: tests pass after remaining A/B references in tests and source are removed. If `ContentView` compile errors remain, complete Task 6 before committing.

- [ ] **Step 11: Commit dynamic playback runtime**

```bash
git add Sources/Takes/PlaybackController.swift Sources/Takes/Models.swift Sources/Takes/TransportMapping.swift Tests/TakesTests/SessionTests.swift Tests/TakesTests/TransportMappingTests.swift
git commit -m "Support dynamic playback tracks"
```

## Task 6: Dynamic SwiftUI Track List

**Files:**
- Modify: `Sources/Takes/ContentView.swift`
- Test: compile with `xcodebuild test`

- [ ] **Step 1: Replace side-based UI state**

In `Sources/Takes/ContentView.swift`, replace:

```swift
@State private var dropTargetSide: TrackSide?
@State private var gainPopoverSide: TrackSide?
```

with:

```swift
@State private var dropTargetTrackID: SessionTrack.ID?
@State private var gainPopoverTrackID: SessionTrack.ID?
```

- [ ] **Step 2: Remove overlap warning UI**

Delete this block from `body`:

```swift
if let warning = controller.overlapWarning {
    Text(warning)
        .font(.callout)
        .foregroundStyle(.orange)
}
```

- [ ] **Step 3: Update transport controls**

In `transportBar`, replace `controller.session.canToggleComparison` with:

```swift
controller.session.canSwitchPlayback
```

Keep the `Switch Playback` button action as:

```swift
controller.toggleActiveTrack()
```

- [ ] **Step 4: Make timeline height dynamic**

Replace:

```swift
private var trackTimelineHeight: CGFloat {
    trackRowHeight * 2 + trackTimelineDividerHeight
}
```

with:

```swift
private var trackTimelineHeight: CGFloat {
    let rowCount = max(controller.session.tracks.count, 1)
    let dividerCount = max(rowCount - 1, 0)
    return trackRowHeight * CGFloat(rowCount) + trackTimelineDividerHeight * CGFloat(dividerCount)
}
```

- [ ] **Step 5: Replace fixed A/B timeline section**

Replace `trackTimelineSection` with:

```swift
private var trackTimelineSection: some View {
    GeometryReader { proxy in
        let infoWidth: CGFloat = 240
        let waveformWidth = max(proxy.size.width - infoWidth, 1)
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    if controller.session.tracks.isEmpty {
                        emptyTrackDropTarget(infoWidth: infoWidth)
                    } else {
                        ForEach(Array(controller.session.tracks.enumerated()), id: \.element.id) { index, sessionTrack in
                            if index > 0 {
                                Divider()
                                    .frame(height: trackTimelineDividerHeight)
                            }
                            trackRow(index: index, sessionTrack: sessionTrack, infoWidth: infoWidth)
                        }
                    }
                }
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if controller.session.isPlayable {
                    Rectangle()
                        .fill(.blue)
                        .frame(width: 2, height: trackTimelineHeight - 16)
                        .offset(
                            x: infoWidth + xPosition(for: controller.session.transportPosition, width: waveformWidth),
                            y: 8
                        )
                }
            }
        }
    }
    .frame(minHeight: min(trackTimelineHeight, 360))
}
```

Add:

```swift
private func emptyTrackDropTarget(infoWidth: CGFloat) -> some View {
    HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
            Text("No tracks loaded")
                .font(.headline)
            Text("Drop audio files here")
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: infoWidth, height: trackRowHeight, alignment: .leading)

        Text("Drop audio files here")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: trackRowHeight, alignment: .leading)
            .padding(.leading, 16)
    }
    .frame(height: trackRowHeight)
}
```

- [ ] **Step 6: Replace row rendering signatures**

Replace `trackRow(side:track:infoWidth:)` with:

```swift
private func trackRow(
    index: Int,
    sessionTrack: SessionTrack,
    infoWidth: CGFloat
) -> some View {
    HStack(spacing: 0) {
        trackInfoArea(index: index, sessionTrack: sessionTrack)
            .frame(width: infoWidth, height: trackRowHeight, alignment: .leading)
            .background(backgroundStyle(for: sessionTrack.id))
            .contentShape(Rectangle())
            .onTapGesture {
                controller.selectActiveTrack(sessionTrack.id)
            }

        waveformLane(index: index, sessionTrack: sessionTrack)
            .frame(maxWidth: .infinity)
            .frame(height: trackRowHeight)
    }
    .frame(height: trackRowHeight)
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: dropBinding(for: sessionTrack.id)) { providers in
        loadDroppedURLs(from: providers, targetTrackID: sessionTrack.id)
    }
}
```

Replace `trackInfoArea(side:track:)` with:

```swift
private func trackInfoArea(index: Int, sessionTrack: SessionTrack) -> some View {
    let track = sessionTrack.loadedTrack
    return VStack(alignment: .leading, spacing: 8) {
        HStack {
            Text("Track \(index + 1)")
                .font(.headline)
            if controller.session.activeTrackID == sessionTrack.id {
                Text("Active")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15), in: Capsule())
            }
            Spacer()
            gainButton(sessionTrack: sessionTrack)
            Button {
                controller.removeTrack(sessionTrack.id)
            } label: {
                Image(systemName: "xmark")
                    .accessibilityLabel("Remove Track \(index + 1)")
            }
            .buttonStyle(.borderless)
        }

        Text(track.displayName)
            .font(.callout.weight(.medium))
            .lineLimit(1)
        Text(track.metadataSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

        offsetControl(sessionTrack: sessionTrack)
    }
    .padding(12)
}
```

- [ ] **Step 7: Replace gain and offset controls**

Replace `gainButton(side:track:)` and `gainPopoverContent(side:track:)` with:

```swift
private func gainButton(sessionTrack: SessionTrack) -> some View {
    Button {
        gainPopoverTrackID = sessionTrack.id
    } label: {
        Image(systemName: "gearshape")
            .accessibilityLabel("Track Settings")
    }
    .buttonStyle(.borderless)
    .popover(
        isPresented: Binding(
            get: { gainPopoverTrackID == sessionTrack.id },
            set: { isPresented in
                gainPopoverTrackID = isPresented ? sessionTrack.id : nil
            }
        ),
        arrowEdge: .trailing
    ) {
        gainPopoverContent(sessionTrack: sessionTrack)
            .padding()
            .frame(width: 300)
    }
}

private func gainPopoverContent(sessionTrack: SessionTrack) -> some View {
    let gainValue = Int(sessionTrack.loadedTrack.gainDB.rounded())
    return VStack(alignment: .leading, spacing: 10) {
        Text("Gain")
            .font(.headline)
        Text("\(gainValue) dB")
            .foregroundStyle(.secondary)
        HStack(spacing: 10) {
            ResettableSlider(
                value: Binding(
                    get: { Double(gainValue) },
                    set: { controller.setGain(sessionTrack.id, db: Float(Int($0.rounded()))) }
                ),
                range: -24...24,
                resetValue: 0
            )
            NumericControlRow(
                value: Binding(
                    get: { gainValue },
                    set: { controller.setGain(sessionTrack.id, db: Float($0)) }
                ),
                configuration: .gain
            )
        }
    }
}
```

Replace `offsetControl(side:track:)` with:

```swift
private func offsetControl(sessionTrack: SessionTrack) -> some View {
    let offsetMs = Int((sessionTrack.loadedTrack.offsetSeconds * 1000).rounded())
    return VStack(alignment: .leading, spacing: 4) {
        Text("Offset \(offsetMs) ms")
            .font(.caption)
            .foregroundStyle(.secondary)
        NumericControlRow(
            value: Binding(
                get: { offsetMs },
                set: { controller.setOffset(sessionTrack.id, seconds: Double($0) / 1000) }
            ),
            configuration: .offset
        )
    }
}
```

- [ ] **Step 8: Replace waveform lane and color**

Replace `waveformLane(side:track:)` with:

```swift
private func waveformLane(index: Int, sessionTrack: SessionTrack) -> some View {
    let track = sessionTrack.loadedTrack
    return GeometryReader { proxy in
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(.background.opacity(0.01))

            placeholderWaveform(index: index)
                .frame(
                    width: max(CGFloat(track.duration / timelineSpan) * proxy.size.width, 1),
                    height: 58
                )
                .offset(
                    x: xPosition(for: track.offsetSeconds, width: proxy.size.width)
                )
                .foregroundStyle(trackColor(index: index).opacity(0.55))

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

private func placeholderWaveform(index: Int) -> some View {
    Canvas { context, size in
        let barCount = 96
        let barWidth = max(size.width / CGFloat(barCount * 2), 1)
        for barIndex in 0..<barCount {
            let phase = Double(barIndex) * 0.37 + Double(index) * 0.43
            let amplitude = 0.25 + 0.7 * abs(sin(phase) * cos(phase * 0.43))
            let height = size.height * amplitude
            let x = CGFloat(barIndex) * size.width / CGFloat(barCount)
            let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .foreground)
        }
    }
}

private func trackColor(index: Int) -> Color {
    let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
    return colors[index % colors.count]
}
```

- [ ] **Step 9: Replace drop target helpers**

Replace `backgroundStyle(for:)` and `dropBinding(for:)` with:

```swift
private func backgroundStyle(for trackID: SessionTrack.ID) -> some ShapeStyle {
    if dropTargetTrackID == trackID {
        return AnyShapeStyle(.blue.opacity(0.16))
    }
    return AnyShapeStyle(.quaternary.opacity(0.4))
}

private func dropBinding(for trackID: SessionTrack.ID) -> Binding<Bool> {
    Binding(
        get: { dropTargetTrackID == trackID },
        set: { isTargeted in
            dropTargetTrackID = isTargeted ? trackID : nil
        }
    )
}
```

- [ ] **Step 10: Replace drop loading function**

Change the top-level `.onDrop` call to:

```swift
loadDroppedURLs(from: providers, targetTrackID: nil)
```

Replace `loadDroppedURLs(from:side:)` with:

```swift
private func loadDroppedURLs(from providers: [NSItemProvider], targetTrackID: SessionTrack.ID?) -> Bool {
    let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    guard !fileProviders.isEmpty else { return false }

    var urlsByProvider = Array<URL?>(repeating: nil, count: fileProviders.count)
    let group = DispatchGroup()

    for (index, provider) in fileProviders.enumerated() {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url = extractDroppedFileURL(from: item)
            DispatchQueue.main.async {
                urlsByProvider[index] = url
                group.leave()
            }
        }
    }

    group.notify(queue: .main) {
        let urls = urlsByProvider.compactMap(\.self)
        Task { @MainActor in
            if let targetTrackID, urls.count == 1 {
                await controller.replaceTrack(targetTrackID, with: urls[0])
            } else {
                await controller.loadImportedFiles(urls)
            }
        }
    }

    return true
}
```

- [ ] **Step 11: Run the full test suite to verify compilation**

Run:

```bash
xcodebuild test -scheme Takes
```

Expected: all tests pass. Fix any remaining references to `TrackSide`, `trackA`, `trackB`, `canToggleComparison`, or `overlapWarning`.

- [ ] **Step 12: Commit dynamic UI list**

```bash
git add Sources/Takes/ContentView.swift Sources/Takes/PlaybackController.swift Tests/TakesTests/SessionTests.swift
git commit -m "Render dynamic track list"
```

## Task 7: Final Cleanup And Verification

**Files:**
- Modify as needed: `Sources/Takes/Models.swift`
- Modify as needed: `Sources/Takes/PlaybackController.swift`
- Modify as needed: `Sources/Takes/TransportMapping.swift`
- Modify as needed: `Sources/Takes/ContentView.swift`
- Modify as needed: `Tests/TakesTests/SessionTests.swift`
- Modify as needed: `Tests/TakesTests/TransportMappingTests.swift`

- [ ] **Step 1: Search for obsolete A/B and overlap symbols**

Run:

```bash
rg -n "TrackSide|trackA|trackB|playerA|playerB|mixerA|mixerB|audioFileA|audioFileB|canToggleComparison|overlapWarning|tooManyImportFiles|Select one or two audio files" Sources Tests
```

Expected: no matches. If matches remain, remove or replace them with ordered-track equivalents.

- [ ] **Step 2: Search for old two-track timeline calls**

Run:

```bash
rg -n "timelineRange\\(trackA|overlapRange|validOverlapDuration" Sources Tests
```

Expected: no matches unless `overlapRange` and `validOverlapDuration` are intentionally kept unused in `TransportMapping.swift`. If they are unused, delete them to keep the transport model focused.

- [ ] **Step 3: Run the full automated suite**

Run:

```bash
xcodebuild test -scheme Takes
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Build the app**

Run:

```bash
xcodebuild build -scheme Takes
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual verification checklist**

Run the app from Xcode or with the built product and verify:

- Opening three or more audio files appends all successful files.
- Opening files after tracks already exist appends instead of replacing.
- Selecting more than 32 files loads 32 and reports skipped files.
- A mixed successful/failed import appends successes and shows one grouped error.
- Loading multiple selected Music tracks preserves Music view order.
- `Switch Playback` is disabled with one track.
- `Switch Playback` cycles through at least three tracks in row order and wraps.
- Removing a non-active track keeps playback running.
- Removing the active track pauses playback and selects next, or previous when the removed track was last.
- Dropping one file on a row replaces that row and resets gain/offset.
- Dropping multiple files on a row appends.
- Appending while playback is running keeps playback running.
- Natural playback end parks the transport at the timeline end.
- A long list scrolls and row controls remain usable.

- [ ] **Step 6: Commit final cleanup**

```bash
git add Sources/Takes/Models.swift Sources/Takes/PlaybackController.swift Sources/Takes/TransportMapping.swift Sources/Takes/ContentView.swift Sources/Takes/LibraryTrackSelectionLoader.swift Tests/TakesTests/SessionTests.swift Tests/TakesTests/TransportMappingTests.swift
git commit -m "Finish arbitrary track count support"
```

## Self-Review Notes

- Spec coverage: model, 32-track cap, append imports, best-effort errors, Music parsing, row replacement, removal, switching, dynamic playback scheduling, timeline union, overlap-warning removal, UI list behavior, and tests are all covered by tasks.
- Scope check: this is one cohesive feature because the fixed two-track model spans session state, playback runtime, and UI. The plan decomposes it into testable slices but does not split it into separate feature specs.
- Type consistency: the plan consistently uses `SessionTrack.ID`, `activeTrackID`, `canSwitchPlayback`, `runtimeTracksByID`, and `TransportMapping.timelineRange(tracks:)`.
