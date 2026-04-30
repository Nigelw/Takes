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
}
