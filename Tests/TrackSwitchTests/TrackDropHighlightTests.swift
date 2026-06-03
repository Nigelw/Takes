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
    func importActionControlUsesHeaderSplitButtonMetrics() {
        #expect(ImportActionControlMetrics.controlWidth == 118)
        #expect(ImportActionControlMetrics.controlHeight == 34)
        #expect(ImportActionControlMetrics.primaryButtonWidth == 84)
        #expect(ImportActionControlMetrics.menuButtonWidth == 33)
    }

    @Test
    func compactTrackControlsFitWithinTrackInfoColumn() {
        let availableControlWidth = TrackInfoLayoutMetrics.infoWidth
            - TrackInfoLayoutMetrics.horizontalPadding * 2
            - TrackInfoLayoutMetrics.numberButtonWidth
            - TrackInfoLayoutMetrics.numberToContentSpacing

        let requiredControlWidth = NumericControlMetrics.offsetControlWidth
            + TrackInfoLayoutMetrics.controlSpacing
            + NumericControlMetrics.gainControlWidth

        #expect(requiredControlWidth <= availableControlWidth)
    }

    @Test
    func transportButtonsUseMockupScale() {
        #expect(TransportControlMetrics.buttonWidth == 72)
        #expect(TransportControlMetrics.buttonHeight == 52)
        #expect(TransportControlMetrics.buttonSpacing == 28)
        #expect(TransportControlMetrics.cornerRadius == 10)
    }

    @Test
    func transportButtonsResolveGeneratedAssetNames() {
        #expect(TransportControlAssetName.name(for: .rewind, state: .normal) == "PlaybackControlRewindNormal")
        #expect(TransportControlAssetName.name(for: .play, state: .active) == "PlaybackControlPlayActive")
        #expect(TransportControlAssetName.name(for: .pause, state: .activePressed) == "PlaybackControlPauseActivePressed")
        #expect(TransportControlAssetName.name(for: .trackSwitch, state: .disabled) == "PlaybackControlSwitchDisabled")
    }
}
