import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TrackSwitch

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
    func trackReorderInsertionPlacementUsesDropLocation() {
        #expect(TrackReorderInsertionPlacement.location(y: 10, rowHeight: 100) == .before)
        #expect(TrackReorderInsertionPlacement.location(y: 60, rowHeight: 100) == .after)
    }

    @Test
    func importActionMenuOffersOpenAndMusicSelection() {
        #expect(ImportActionMenuItem.allCases.map(\.title) == ["Open...", "Open Apple Music Selection"])
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
        #expect(TrackSwitchWindowPolicy.mainWindowID == "main")
        #expect(TrackSwitchWindowPolicy.replacesDefaultNewItemCommands)
    }

    @Test
    func importActionControlUsesCompactSplitButtonMetrics() {
        #expect(ImportActionControlMetrics.controlWidth == 86)
        #expect(ImportActionControlMetrics.controlHeight == 34)
        #expect(ImportActionControlMetrics.primaryButtonWidth == 48)
        #expect(ImportActionControlMetrics.menuButtonWidth == 37)
    }
}
