import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Takes

struct TrackDropHighlightTests {
    @Test
    func emptyTrackRowUsesDropHighlightWhenTargeted() {
        #expect(TrackDropHighlight.empty(isTargeted: true) == .dropTarget)
    }

    @Test
    func emptyTrackRowUsesDefaultHighlightWhenNotTargeted() {
        #expect(TrackDropHighlight.empty(isTargeted: false) == .normal)
    }

    @Test
    func trackReorderDragUsesDeclaredSystemType() {
        #expect(TrackReorderDrag.contentType == .plainText)
    }

    @Test
    func trackRowDropTargetAcceptsReorderAndFileDrops() {
        #expect(TrackRowDropTarget.acceptedContentTypeIdentifiers == [
            TrackReorderDrag.contentType.identifier,
            UTType.fileURL.identifier
        ])
    }

    @Test
    func trackRowDropKindPrioritizesFileDropsOverPlainTextReorderDrops() {
        #expect(TrackRowDropKind.kind(hasFileURLs: true, hasReorderItems: true) == .file)
        #expect(TrackRowDropKind.kind(hasFileURLs: true, hasReorderItems: false) == .file)
        #expect(TrackRowDropKind.kind(hasFileURLs: false, hasReorderItems: true) == .reorder)
        #expect(TrackRowDropKind.kind(hasFileURLs: false, hasReorderItems: false) == nil)
    }

    @Test
    func trackReorderInsertionPlacementUsesDropLocation() {
        #expect(TrackReorderInsertionPlacement.location(y: 10, rowHeight: 100) == .before)
        #expect(TrackReorderInsertionPlacement.location(y: 60, rowHeight: 100) == .after)
    }

    @Test
    func droppedFilesAlwaysAppendRegardlessOfFormerRowTarget() {
        let targetTrackID = UUID()

        #expect(DroppedFileImportAction.action(targetTrackID: nil) == .append)
        #expect(DroppedFileImportAction.action(targetTrackID: targetTrackID) == .append)
    }

    @Test
    func importActionMenuOffersFinderSelectionAndMusicSelection() {
        #expect(ImportActionMenuItem.dropdownItems.map(\.title) == [
            "Open Finder Selection",
            "Open Apple Music Selection"
        ])
    }

    @MainActor
    @Test
    func openFileCommandStateControlsImporterPresentation() {
        let state = OpenFileCommandState()

        #expect(!state.isImportingTracks)

        state.presentOpenDialog()

        #expect(state.isImportingTracks)

        state.dismissOpenDialog()

        #expect(!state.isImportingTracks)
    }

    @MainActor
    @Test
    func openFileCommandStatePerformsAppleMusicSelectionAction() {
        var loadCount = 0
        let state = OpenFileCommandState(loadAppleMusicSelection: {
            loadCount += 1
        })

        state.openAppleMusicSelection()

        #expect(loadCount == 1)
    }

    @MainActor
    @Test
    func openFileCommandStatePerformsFinderSelectionAction() {
        var loadCount = 0
        let state = OpenFileCommandState(loadFinderSelection: {
            loadCount += 1
        })

        state.openFinderSelection()

        #expect(loadCount == 1)
    }

    @MainActor
    @Test
    func openFileCommandStatePerformsShowActiveTrackInFinderAction() {
        var showCount = 0
        let state = OpenFileCommandState(showActiveTrackInFinder: {
            showCount += 1
        })

        state.showActiveTrackInFinder()

        #expect(showCount == 1)
    }

    @MainActor
    @Test
    func openFileCommandStatePerformsClearAllTracksAction() {
        var clearCount = 0
        let state = OpenFileCommandState(clearAllTracks: {
            clearCount += 1
        })

        state.clearAllTracks()

        #expect(clearCount == 1)
    }

    @Test
    func finderSelectionResolverReturnsAudioFileURLs() throws {
        let wav = URL(fileURLWithPath: "/tmp/selection.wav")
        let mp3 = URL(fileURLWithPath: "/tmp/selection.mp3")

        #expect(try FinderSelectionResolver.audioFileURLs(from: [wav, mp3]) == [wav, mp3])
    }

    @Test
    func finderSelectionResolverReturnsAudioFilesFromMixedSelection() throws {
        let wav = URL(fileURLWithPath: "/tmp/selection.wav")
        let text = URL(fileURLWithPath: "/tmp/notes.txt")
        let mp3 = URL(fileURLWithPath: "/tmp/selection.mp3")

        #expect(try FinderSelectionResolver.audioFileURLs(from: [wav, text, mp3]) == [wav, mp3])
    }

    @Test
    func finderSelectionResolverRejectsEmptySelection() {
        #expect(throws: PlaybackError.librarySelectionFailed("Finder has no selected files.")) {
            try FinderSelectionResolver.audioFileURLs(from: [])
        }
    }

    @Test
    func finderSelectionResolverRejectsSelectionWithNoAudioFiles() {
        let text = URL(fileURLWithPath: "/tmp/notes.txt")

        #expect(throws: PlaybackError.librarySelectionFailed("Finder selection does not include any audio files.")) {
            try FinderSelectionResolver.audioFileURLs(from: [text])
        }
    }

    @MainActor
    @Test
    func appFileOpenRouterQueuesURLsUntilHandlerIsConfigured() {
        let router = AppFileOpenRouter()
        let earlyURL = URL(fileURLWithPath: "/tmp/early.wav")
        let laterURL = URL(fileURLWithPath: "/tmp/later.mp3")
        var handledURLBatches: [[URL]] = []

        router.open([earlyURL])

        #expect(handledURLBatches.isEmpty)

        router.setHandler { urls in
            handledURLBatches.append(urls)
        }

        #expect(handledURLBatches == [[earlyURL]])

        router.open([laterURL])

        #expect(handledURLBatches == [[earlyURL], [laterURL]])
    }

    @Test
    func appOpenedURLResolverRecursivelyFindsAudioFilesInFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let nested = root.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let directAudio = root.appending(path: "direct.wav")
        let ignoredText = root.appending(path: "notes.txt")
        let nestedAudio = nested.appending(path: "nested.m4a")
        let directInputAudio = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp3")
        try Data().write(to: directAudio)
        try Data().write(to: ignoredText)
        try Data().write(to: nestedAudio)
        try Data().write(to: directInputAudio)
        defer { try? FileManager.default.removeItem(at: directInputAudio) }

        let resolvedURLs = AppOpenedURLResolver.audioFileURLs(from: [root, directInputAudio])

        #expect(
            resolvedURLs.map { $0.resolvingSymlinksInPath() }
                == [directAudio, nestedAudio, directInputAudio].map { $0.resolvingSymlinksInPath() }
        )
    }

    @Test
    func appUsesSingleMainWindowPolicy() {
        #expect(TakesWindowPolicy.mainWindowID == "main")
        #expect(TakesWindowPolicy.replacesDefaultNewItemCommands)
    }

    @Test
    func importActionControlUsesCompactSplitButtonMetrics() {
        #expect(ImportActionControlMetrics.controlWidth == 62)
        #expect(ImportActionControlMetrics.controlHeight == 34)
        #expect(ImportActionControlMetrics.primaryButtonWidth == 34)
        #expect(ImportActionControlMetrics.menuButtonWidth == 27)
    }

    @Test
    func importActionSplitButtonHitTestingFindsMenuSegmentOnMouseDown() {
        #expect(
            ImportActionSplitButtonHitTesting.segment(
                atX: 50,
                controlWidth: ImportActionControlMetrics.controlWidth,
                primaryWidth: ImportActionControlMetrics.primaryButtonWidth,
                menuWidth: ImportActionControlMetrics.menuButtonWidth,
                layoutDirection: .leftToRight
            ) == 1
        )
        #expect(
            ImportActionSplitButtonHitTesting.segment(
                atX: 16,
                controlWidth: ImportActionControlMetrics.controlWidth,
                primaryWidth: ImportActionControlMetrics.primaryButtonWidth,
                menuWidth: ImportActionControlMetrics.menuButtonWidth,
                layoutDirection: .leftToRight
            ) == 0
        )
        #expect(
            ImportActionSplitButtonHitTesting.segment(
                atX: ImportActionControlMetrics.controlWidth,
                controlWidth: ImportActionControlMetrics.controlWidth,
                primaryWidth: ImportActionControlMetrics.primaryButtonWidth,
                menuWidth: ImportActionControlMetrics.menuButtonWidth,
                layoutDirection: .leftToRight
            ) == 1
        )
        #expect(
            ImportActionSplitButtonHitTesting.segment(
                atX: 16,
                controlWidth: ImportActionControlMetrics.controlWidth,
                primaryWidth: ImportActionControlMetrics.primaryButtonWidth,
                menuWidth: ImportActionControlMetrics.menuButtonWidth,
                layoutDirection: .rightToLeft
            ) == 1
        )
        #expect(
            ImportActionSplitButtonHitTesting.segment(
                atX: ImportActionControlMetrics.controlWidth,
                controlWidth: ImportActionControlMetrics.controlWidth,
                primaryWidth: ImportActionControlMetrics.primaryButtonWidth,
                menuWidth: ImportActionControlMetrics.menuButtonWidth,
                layoutDirection: .rightToLeft
            ) == 0
        )
    }

    @Test
    func importActionSplitButtonMenuPlacementIsAnchoredBelowDropdownButton() {
        let bounds = NSRect(
            x: 0,
            y: 0,
            width: ImportActionControlMetrics.controlWidth,
            height: ImportActionControlMetrics.controlHeight
        )

        let leftToRightOrigin = ImportActionSplitButtonMenuPlacement.origin(
            bounds: bounds,
            menuWidth: ImportActionControlMetrics.menuButtonWidth,
            layoutDirection: .leftToRight,
            isFlipped: true
        )
        let rightToLeftOrigin = ImportActionSplitButtonMenuPlacement.origin(
            bounds: bounds,
            menuWidth: ImportActionControlMetrics.menuButtonWidth,
            layoutDirection: .rightToLeft,
            isFlipped: false
        )

        #expect(leftToRightOrigin.x == bounds.maxX - ImportActionControlMetrics.menuButtonWidth)
        #expect(leftToRightOrigin.y == bounds.maxY)
        #expect(rightToLeftOrigin.x == bounds.minX)
        #expect(rightToLeftOrigin.y == bounds.minY)
    }
}
