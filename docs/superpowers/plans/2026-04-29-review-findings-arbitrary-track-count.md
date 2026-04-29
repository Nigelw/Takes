# Arbitrary Track Count Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the final review findings for arbitrary track count support: best-effort Music selection, row drop replacement semantics, and menu rewind behavior.

**Architecture:** Keep the current ordered `SessionTrack` and ID-based playback model. Add a parsed Music selection result that can carry both valid URLs and per-item failures, then feed valid URLs through the existing best-effort import path while preserving grouped errors. Keep UI drop behavior local to `ContentView` by deciding row replacement from original provider count, and align the app command menu rewind with the existing toolbar/key-monitor timeline-start behavior.

**Tech Stack:** Swift, SwiftUI, AppKit drag/drop bridging, AVFoundation, Swift Testing, Xcode scheme `TrackSwitch`.

---

## File Structure

- Modify `Sources/TrackSwitch/Models.swift`
  - Add a lightweight Music/import selection result type if needed.
  - Reuse existing `ImportFailure` and `PlaybackError.importSummary`.
- Modify `Sources/TrackSwitch/LibraryTrackSelectionLoader.swift`
  - Change Music AppleScript output so nonlocal tracks are emitted as per-row failures instead of aborting the whole selection.
  - Change parsing to return valid URLs plus failures instead of throwing on the first bad row.
- Modify `Sources/TrackSwitch/PlaybackController.swift`
  - Add a helper that imports already-collected valid Music URLs and merges parse/Music failures with import/cap failures.
  - Keep general file imports unchanged.
- Modify `Sources/TrackSwitch/ContentView.swift`
  - Decide row replacement using `fileProviders.count == 1`, not resolved `urls.count == 1`.
- Modify `Sources/TrackSwitch/TrackSwitchApp.swift`
  - Change command-menu rewind to seek to `controller.session.timelineStart`.
- Modify `Tests/TrackSwitchTests/SessionTests.swift`
  - Add focused tests for mixed Music selection parsing/import, row-drop decision logic if exposed as a pure helper, and menu rewind helper if exposed.

## Task 1: Music Selection Best-Effort Parsing

**Files:**
- Modify: `Sources/TrackSwitch/LibraryTrackSelectionLoader.swift`
- Modify: `Sources/TrackSwitch/Models.swift`
- Test: `Tests/TrackSwitchTests/SessionTests.swift`

- [ ] **Step 1: Add failing parser test for mixed Music output**

Add this test to `SessionTests` near the existing Music selection parsing tests:

```swift
@Test
func musicSelectionParsingKeepsValidTracksAndReportsInvalidRows() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
    let validURL = tempDirectory.appending(path: UUID().uuidString + ".wav")
    FileManager.default.createFile(atPath: validURL.path, contents: Data())
    defer { try? FileManager.default.removeItem(at: validURL) }

    let output = """
    OK\t2\t\(validURL.path)
    ERROR\t4\tCloud Song\tThe selected Music track is not a local file.
    OK\t6\t/tmp/does-not-exist-\(UUID().uuidString).wav
    """

    let result = LibraryTrackSelectionLoader.parseSelectionOutput(output)

    #expect(result.urls == [validURL])
    #expect(result.failures.count == 2)
    #expect(result.failures[0].fileName == "Cloud Song")
    #expect(result.failures[0].message == "The selected Music track is not a local file.")
    #expect(result.failures[1].message == "The selected track path does not exist on disk.")
}
```

- [ ] **Step 2: Run the focused parser test and verify it fails**

Run:

```bash
xcodebuild test -scheme TrackSwitch -only-testing:TrackSwitchTests/SessionTests/musicSelectionParsingKeepsValidTracksAndReportsInvalidRows
```

Expected: compile failure because `parseSelectionOutput(_:)` still returns `[URL]`.

- [ ] **Step 3: Add a Music selection result model**

In `Models.swift`, add this near `ImportFailure`:

```swift
struct MusicSelectionResult: Equatable {
    let urls: [URL]
    let failures: [ImportFailure]
}
```

- [ ] **Step 4: Update the Music selection protocol and parser signature**

In `LibraryTrackSelectionLoader.swift`, change the protocol and implementation signatures:

```swift
protocol LibraryTrackSelecting {
    func selectedTracks() throws -> MusicSelectionResult
}
```

```swift
func selectedTracks() throws -> MusicSelectionResult {
    // existing app availability and AppleScript execution checks stay here
}
```

Change:

```swift
static func parseSelectionOutput(_ output: String) throws -> [URL]
```

to:

```swift
static func parseSelectionOutput(_ output: String) -> MusicSelectionResult
```

- [ ] **Step 5: Change AppleScript to emit OK and ERROR rows**

Replace the AppleScript loop body in `musicSelectionScript` with:

```applescript
repeat with selectedTrack in selectedTracks
    set trackName to ""
    try
        set trackName to name of selectedTrack as text
    on error
        set trackName to "Selected Music Track"
    end try

    try
        set trackLocation to location of selectedTrack
        set end of outputLines to ("OK" & tab & (index of selectedTrack as text) & tab & POSIX path of trackLocation)
    on error
        set end of outputLines to ("ERROR" & tab & (index of selectedTrack as text) & tab & trackName & tab & "The selected Music track is not a local file.")
    end try
end repeat
```

- [ ] **Step 6: Implement best-effort parser**

Replace `parseSelectionOutput(_:)` and `parseSelectionEntry(_:)` with:

```swift
static func parseSelectionOutput(_ output: String) -> MusicSelectionResult {
    let entries = output
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard !entries.isEmpty else {
        return MusicSelectionResult(
            urls: [],
            failures: [ImportFailure(fileName: "Music", message: "Music did not return a local file path.")]
        )
    }

    let parsed = entries.compactMap(parseSelectionEntry(_:)).sorted { $0.index < $1.index }
    return MusicSelectionResult(
        urls: parsed.compactMap(\.url),
        failures: parsed.compactMap(\.failure)
    )
}

private static func parseSelectionEntry(_ entry: String) -> (index: Int, url: URL?, failure: ImportFailure?)? {
    let components = entry.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard components.count >= 3,
          let index = Int(components[1].trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return (
            index: Int.max,
            url: nil,
            failure: ImportFailure(fileName: "Music", message: "Could not read the selected track order from Music.")
        )
    }

    switch components[0] {
    case "OK":
        let path = components[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return (
                index: index,
                url: nil,
                failure: ImportFailure(fileName: "Music", message: "Music did not return a local file path.")
            )
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (
                index: index,
                url: nil,
                failure: ImportFailure(url: url, message: "The selected track path does not exist on disk.")
            )
        }

        return (index: index, url: url, failure: nil)

    case "ERROR":
        let name = components.indices.contains(2) ? components[2] : "Music"
        let message = components.indices.contains(3) ? components[3] : "Could not read the selected track from Music."
        return (
            index: index,
            url: nil,
            failure: ImportFailure(fileName: name.ifEmpty("Music"), message: message)
        )

    default:
        return (
            index: index,
            url: nil,
            failure: ImportFailure(fileName: "Music", message: "Could not read the selected track from Music.")
        )
    }
}
```

Also add this initializer to `ImportFailure` in `Models.swift`:

```swift
init(fileName: String, message: String) {
    self.fileName = fileName.ifEmpty("Unknown file")
    self.message = message
}
```

- [ ] **Step 7: Update existing Music parser tests**

Change existing assertions that expect `[URL]` from:

```swift
let urls = try LibraryTrackSelectionLoader.parseSelectionOutput(output)
#expect(urls == [firstURL, secondURL, thirdURL])
```

to:

```swift
let result = LibraryTrackSelectionLoader.parseSelectionOutput(output)
#expect(result.urls == [firstURL, secondURL, thirdURL])
#expect(result.failures.isEmpty)
```

- [ ] **Step 8: Run Music parser tests**

Run:

```bash
xcodebuild test -scheme TrackSwitch -only-testing:TrackSwitchTests/SessionTests/musicSelectionParsingSortsTwoTracksByViewOrder -only-testing:TrackSwitchTests/SessionTests/musicSelectionParsingSortsManyTracksByViewOrder -only-testing:TrackSwitchTests/SessionTests/musicSelectionParsingKeepsValidTracksAndReportsInvalidRows
```

Expected: pass.

## Task 2: Merge Music Selection Failures With Import Results

**Files:**
- Modify: `Sources/TrackSwitch/PlaybackController.swift`
- Test: `Tests/TrackSwitchTests/SessionTests.swift`

- [ ] **Step 1: Add fake Music selector using the new protocol**

Replace or add a fake selector in `SessionTests`:

```swift
private struct FakeLibraryTrackSelector: LibraryTrackSelecting {
    let result: MusicSelectionResult

    func selectedTracks() throws -> MusicSelectionResult {
        result
    }
}
```

- [ ] **Step 2: Add failing controller test for mixed Music import**

Add this test:

```swift
@MainActor
@Test
func musicSelectionAppendsValidTracksAndReportsSelectionFailures() async throws {
    let valid = try makeTemporaryAudioFile(name: "music-valid.wav")
    defer { try? FileManager.default.removeItem(at: valid.deletingLastPathComponent()) }

    let controller = PlaybackController(
        libraryTrackSelector: FakeLibraryTrackSelector(
            result: MusicSelectionResult(
                urls: [valid],
                failures: [
                    ImportFailure(fileName: "Cloud Song", message: "The selected Music track is not a local file.")
                ]
            )
        )
    )

    await controller.loadSelectedLibraryTracks()

    #expect(controller.session.tracks.map { $0.loadedTrack.displayName } == ["music-valid.wav"])
    #expect(controller.playbackError?.localizedDescription.contains("Cloud Song") == true)
    #expect(controller.playbackError?.localizedDescription.contains("The selected Music track is not a local file.") == true)
}
```

- [ ] **Step 3: Run the focused controller test and verify it fails**

Run:

```bash
xcodebuild test -scheme TrackSwitch -only-testing:TrackSwitchTests/SessionTests/musicSelectionAppendsValidTracksAndReportsSelectionFailures
```

Expected: compile failure until `PlaybackController.loadSelectedLibraryTracks()` uses `selectedTracks()`.

- [ ] **Step 4: Refactor import summary construction into a helper**

In `PlaybackController.swift`, add:

```swift
private func setImportSummary(failures: [ImportFailure], skippedFileNames: [String]) {
    switch (failures.isEmpty, skippedFileNames.isEmpty) {
    case (false, false):
        playbackError = .importSummary(
            failures: failures,
            skippedFileNames: skippedFileNames,
            limit: Self.maximumTrackCount
        )
    case (false, true):
        playbackError = .importFailures(failures)
    case (true, false):
        playbackError = .trackLimitExceeded(limit: Self.maximumTrackCount, skippedFileNames: skippedFileNames)
    case (true, true):
        break
    }
}
```

Then replace the existing `switch (failures.isEmpty, skippedFileNames.isEmpty)` in `loadImportedFiles(_:)` with:

```swift
setImportSummary(failures: failures, skippedFileNames: skippedFileNames)
```

- [ ] **Step 5: Add internal import helper for preexisting failures**

Change `loadImportedFiles(_:)` to delegate to:

```swift
func loadImportedFiles(_ urls: [URL]) async {
    await loadImportedFiles(urls, preexistingFailures: [])
}

private func loadImportedFiles(_ urls: [URL], preexistingFailures: [ImportFailure]) async {
    guard !urls.isEmpty || !preexistingFailures.isEmpty else { return }

    let wasPlaying = session.isPlaying
    var preparedLoads: [PreparedTrackLoad] = []
    var failures = preexistingFailures
    var skippedFileNames: [String] = []

    // keep the existing loop, append/restore logic, then call:
    setImportSummary(failures: failures, skippedFileNames: skippedFileNames)
}
```

Preserve the existing body exactly except for initializing `failures` from `preexistingFailures` and using `setImportSummary`.

- [ ] **Step 6: Update Music load path**

Change `loadSelectedLibraryTracks()` to:

```swift
func loadSelectedLibraryTracks() async {
    do {
        let selection = try libraryTrackSelector.selectedTracks()
        await loadImportedFiles(selection.urls, preexistingFailures: selection.failures)
    } catch let error as PlaybackError {
        playbackError = error
    } catch {
        playbackError = .librarySelectionFailed("Could not load the selected track from Music.")
    }
}
```

- [ ] **Step 7: Run Music controller tests**

Run:

```bash
xcodebuild test -scheme TrackSwitch -only-testing:TrackSwitchTests/SessionTests/musicSelectionAppendsValidTracksAndReportsSelectionFailures -only-testing:TrackSwitchTests/SessionTests/importedFilesReportFailuresAndTrackCapSkipsTogether
```

Expected: pass.

## Task 3: Row Drop Replacement Uses Provider Count

**Files:**
- Modify: `Sources/TrackSwitch/ContentView.swift`
- Test: `Tests/TrackSwitchTests/SessionTests.swift`

- [ ] **Step 1: Add pure helper tests**

Add this helper test near numeric/UI logic tests:

```swift
@Test
func rowDropActionReplacesOnlyWhenOriginalProviderCountIsOne() {
    let trackID = UUID()

    #expect(ContentView.dropAction(targetTrackID: trackID, fileProviderCount: 1, resolvedURLCount: 1) == .replace(trackID))
    #expect(ContentView.dropAction(targetTrackID: trackID, fileProviderCount: 2, resolvedURLCount: 1) == .append)
    #expect(ContentView.dropAction(targetTrackID: nil, fileProviderCount: 1, resolvedURLCount: 1) == .append)
}
```

- [ ] **Step 2: Run the focused helper test and verify it fails**

Run:

```bash
xcodebuild test -scheme TrackSwitch -only-testing:TrackSwitchTests/SessionTests/rowDropActionReplacesOnlyWhenOriginalProviderCountIsOne
```

Expected: compile failure because `ContentView.dropAction` does not exist.

- [ ] **Step 3: Add a testable drop action helper**

Inside `ContentView`, add:

```swift
enum DropAction: Equatable {
    case append
    case replace(SessionTrack.ID)
}

static func dropAction(
    targetTrackID: SessionTrack.ID?,
    fileProviderCount: Int,
    resolvedURLCount: Int
) -> DropAction {
    if let targetTrackID, fileProviderCount == 1, resolvedURLCount == 1 {
        return .replace(targetTrackID)
    }
    return .append
}
```

- [ ] **Step 4: Use provider count in drop handling**

Replace:

```swift
if let targetTrackID, urls.count == 1 {
    await controller.replaceTrack(targetTrackID, with: urls[0])
} else {
    await controller.loadImportedFiles(urls)
}
```

with:

```swift
switch Self.dropAction(
    targetTrackID: targetTrackID,
    fileProviderCount: fileProviders.count,
    resolvedURLCount: urls.count
) {
case let .replace(trackID):
    await controller.replaceTrack(trackID, with: urls[0])
case .append:
    await controller.loadImportedFiles(urls)
}
```

- [ ] **Step 5: Run the focused drop test**

Run:

```bash
xcodebuild test -scheme TrackSwitch -only-testing:TrackSwitchTests/SessionTests/rowDropActionReplacesOnlyWhenOriginalProviderCountIsOne
```

Expected: pass.

## Task 4: Command Menu Rewind Uses Timeline Start

**Files:**
- Modify: `Sources/TrackSwitch/TrackSwitchApp.swift`

- [ ] **Step 1: Change the menu command**

In `TrackSwitchApp.swift`, replace:

```swift
controller.seek(to: 0)
```

with:

```swift
controller.seek(to: controller.session.timelineStart)
```

- [ ] **Step 2: Search for any remaining rewind-to-zero paths**

Run:

```bash
rg -n "seek\\(to: 0\\)|Rewind" Sources Tests README.md
```

Expected: no `seek(to: 0)` command-menu path remains. Toolbar/key monitor should continue using `timelineStart`.

## Task 5: Full Verification

**Files:**
- No source edits expected.

- [ ] **Step 1: Run stale-symbol searches**

Run:

```bash
rg -n "TrackSide|trackA|trackB|playerA|playerB|mixerA|mixerB|audioFileA|audioFileB|canToggleComparison|overlapWarning|tooManyImportFiles|Select one or two audio files" Sources Tests README.md
rg -n "timelineRange\\(trackA|overlapRange|validOverlapDuration" Sources Tests README.md
```

Expected: both commands produce no matches.

- [ ] **Step 2: Run the full test suite**

Run:

```bash
xcodebuild test -scheme TrackSwitch
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Run a full build**

Run:

```bash
xcodebuild build -scheme TrackSwitch
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Review final diff**

Run:

```bash
git diff --stat
git diff
```

Expected:
- Music selection no longer aborts an entire selection because one selected item is nonlocal or missing.
- General imports still use the same best-effort cap/failure behavior.
- Single-file row drops still replace.
- Multi-provider row drops append even if only one URL resolves.
- Menu rewind seeks to `timelineStart`.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/TrackSwitch/Models.swift Sources/TrackSwitch/LibraryTrackSelectionLoader.swift Sources/TrackSwitch/PlaybackController.swift Sources/TrackSwitch/ContentView.swift Sources/TrackSwitch/TrackSwitchApp.swift Tests/TrackSwitchTests/SessionTests.swift
git commit -m "Fix arbitrary track review findings"
```
