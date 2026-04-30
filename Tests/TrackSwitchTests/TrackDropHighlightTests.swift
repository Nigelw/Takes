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
        #expect(ImportActionMenuItem.allCases.map(\.title) == ["Open...", "Get Apple Music Selection"])
    }

    @Test
    func importActionControlUsesCompactSplitButtonMetrics() {
        #expect(ImportActionControlMetrics.controlWidth == 86)
        #expect(ImportActionControlMetrics.controlHeight == 34)
        #expect(ImportActionControlMetrics.primaryButtonWidth == 48)
        #expect(ImportActionControlMetrics.menuButtonWidth == 37)
    }
}
