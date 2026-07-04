import XCTest
@testable import Takes

/// Tests for `AnalogSourceAnalyzer` (min-statistics noise floor, noise
/// coherence, clicks, rumble, wow). Filled in by milestone M3a; the
/// placeholder below only pins the neutral stub contract.
final class AnalogSourceDSPTests: XCTestCase {
    func testStubReturnsNeutralMetrics() {
        let analyzer = AnalogSourceAnalyzer(sampleRate: 44_100, channelCount: 2)
        let metrics = analyzer.finalize()
        XCTAssertEqual(metrics.clickRatePerMinute, 0)
    }
}
