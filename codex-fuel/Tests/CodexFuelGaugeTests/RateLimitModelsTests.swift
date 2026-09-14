import Foundation
import Testing
@testable import CodexFuelGauge

@Suite("Rate-limit models")
struct RateLimitModelsTests {
    @Test("Single buckets decode and unknown fields are ignored")
    func decodesSingleBucketAndIgnoresUnknownFields() throws {
        let data = Data(#"""
        {
          "rateLimits": {
            "limitId": "codex",
            "limitName": null,
            "primary": {"usedPercent": 27, "windowDurationMins": 10080, "resetsAt": 1787275064},
            "secondary": null,
            "credits": {"hasCredits": false, "unlimited": false, "balance": "0"},
            "planType": "plus",
            "futureField": {"anything": true}
          },
          "futureTopLevelField": 123
        }
        """#.utf8)

        let result = try JSONDecoder().decode(RateLimitsResult.self, from: data)
        let snapshot = RateLimitSnapshot(result: result)

        #expect(snapshot.buckets.keys.sorted() == ["codex"])
        #expect(snapshot.mainRemainingPercent == 73)
        #expect(snapshot.windows.first?.window.windowDurationMins == 10_080)
        #expect(snapshot.buckets["codex"]?.planType == "plus")
    }

    @Test("The gauge uses the most constrained window")
    func usesMostConstrainedWindowAcrossMultipleBuckets() throws {
        let data = Data(#"""
        {
          "rateLimits": null,
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": {"usedPercent": 20, "windowDurationMins": 10080, "resetsAt": 1787275064},
              "secondary": {"usedPercent": 91, "windowDurationMins": 300, "resetsAt": 1787000000}
            },
            "codex_other": {
              "limitId": "codex_other",
              "limitName": "Spark",
              "primary": {"usedPercent": 45, "windowDurationMins": 60, "resetsAt": null}
            }
          },
          "rateLimitResetCredits": {"availableCount": 2, "credits": []}
        }
        """#.utf8)

        let result = try JSONDecoder().decode(RateLimitsResult.self, from: data)
        let snapshot = RateLimitSnapshot(result: result)

        #expect(snapshot.windows.count == 3)
        #expect(snapshot.mainRemainingPercent == 9)
        #expect(snapshot.resetCreditCount == 2)
    }

    @Test("Remaining percentages are clamped")
    func clampsRemainingPercentage() {
        #expect(QuotaWindow(usedPercent: -5, windowDurationMins: nil, resetsAt: nil).remainingPercent == 100)
        #expect(QuotaWindow(usedPercent: 120, windowDurationMins: nil, resetsAt: nil).remainingPercent == 0)
    }

    @Test("Partial real-time updates preserve omitted bucket fields")
    func partialUpdatesPreserveExistingDetails() {
        let initial = LimitBucket(
            limitId: "codex",
            limitName: "Codex",
            primary: QuotaWindow(usedPercent: 20, windowDurationMins: 10_080, resetsAt: 1_000),
            secondary: QuotaWindow(usedPercent: 40, windowDurationMins: 300, resetsAt: 2_000),
            credits: Credits(hasCredits: true, unlimited: false, balance: "5"),
            spendControlReached: false,
            planType: "plus",
            rateLimitReachedType: nil
        )
        let result = RateLimitsResult(rateLimits: initial, rateLimitsByLimitId: nil, rateLimitResetCredits: nil)
        var snapshot = RateLimitSnapshot(result: result)
        let update = LimitBucket(
            limitId: "codex",
            limitName: nil,
            primary: QuotaWindow(usedPercent: 31, windowDurationMins: nil, resetsAt: nil),
            secondary: nil,
            credits: nil,
            spendControlReached: nil,
            planType: nil,
            rateLimitReachedType: nil
        )

        snapshot.merge(bucket: update)

        #expect(snapshot.buckets["codex"]?.primary?.usedPercent == 31)
        #expect(snapshot.buckets["codex"]?.primary?.windowDurationMins == 10_080)
        #expect(snapshot.buckets["codex"]?.secondary?.usedPercent == 40)
        #expect(snapshot.buckets["codex"]?.planType == "plus")
    }

    @Test("Empty responses have no gauge value")
    func emptyResponseHasNoMainPercentage() throws {
        let result = try JSONDecoder().decode(RateLimitsResult.self, from: Data(#"{}"#.utf8))
        #expect(RateLimitSnapshot(result: result).mainRemainingPercent == nil)
    }

    @Test("Display windows sort five-hour before seven-day and format both menu percentages")
    func formatsMultipleQuotaWindowsForDisplay() {
        let bucket = LimitBucket(
            limitId: "codex",
            limitName: "Codex",
            primary: QuotaWindow(usedPercent: 9, windowDurationMins: 10_080, resetsAt: 1_000),
            secondary: QuotaWindow(usedPercent: 27, windowDurationMins: 300, resetsAt: 2_000),
            credits: nil,
            spendControlReached: nil,
            planType: "plus",
            rateLimitReachedType: nil
        )
        let snapshot = RateLimitSnapshot(result: RateLimitsResult(
            rateLimits: bucket,
            rateLimitsByLimitId: nil,
            rateLimitResetCredits: nil
        ))

        #expect(snapshot.displayWindows.map { $0.window.windowDurationMins } == [300, 10_080])
        #expect(snapshot.displayWindows.map(\.durationLabel) == ["5 小时窗口", "7 天窗口"])
        #expect(snapshot.menuTitle == "73% | 91%")
        #expect(snapshot.menuAccessibilityTitle == "5 小时窗口 73%，7 天窗口 91%")
        #expect(QuotaWindowPresentation.resetLabel(
            for: snapshot.displayWindows[0].window,
            now: Date(timeIntervalSince1970: 1_000)
        ) == "16 分钟后重置")
    }

    @Test("Single quota window keeps a compact menu percentage")
    func formatsSingleQuotaWindowForMenu() {
        let bucket = LimitBucket(
            limitId: "codex",
            limitName: "Codex",
            primary: QuotaWindow(usedPercent: 27, windowDurationMins: 10_080, resetsAt: nil),
            secondary: nil,
            credits: nil,
            spendControlReached: nil,
            planType: nil,
            rateLimitReachedType: nil
        )
        let snapshot = RateLimitSnapshot(result: RateLimitsResult(
            rateLimits: bucket,
            rateLimitsByLimitId: nil,
            rateLimitResetCredits: nil
        ))

        #expect(snapshot.menuTitle == "73%")
    }
}
