import Foundation
import Testing
@testable import CodexFuelGauge

@Suite("System dashboard presentation")
struct SystemDashboardPresentationTests {
    @Test("Memory values use compact binary units")
    func formatsMemoryValues() {
        #expect(SystemMetricPresentation.memory(512 * 1_048_576) == "512 MB")
        #expect(SystemMetricPresentation.memory(1_073_741_824) == "1.0 GB")
    }

    @Test("Network values use compact per-second units")
    func formatsNetworkRates() {
        #expect(SystemMetricPresentation.rate(1_048_576) == "1.0 MB/s")
        #expect(SystemMetricPresentation.rate(512) == "512 B/s")
    }

    @Test("Missing and finite percentages have stable labels")
    func formatsPercentages() {
        #expect(SystemMetricPresentation.percent(nil) == "--")
        #expect(SystemMetricPresentation.percent(42.4) == "42%")
    }

    @Test("Metric cards reserve one shared visual height")
    func usesSharedMetricCardHeight() {
        #expect(SystemMetricCardLayout.cardHeight == 84)
    }
}
