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
