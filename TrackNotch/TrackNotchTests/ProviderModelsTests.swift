import XCTest
@testable import TrackNotch

final class ProviderModelsTests: XCTestCase {

    // MARK: - usageLevel thresholds

    func test_usageLevel_low_under20() {
        let u = makeUsage(percentage: 0)
        XCTAssertEqual(u.usageLevel, .low)
        let u2 = makeUsage(percentage: 19.999)
        XCTAssertEqual(u2.usageLevel, .low)
    }

    func test_usageLevel_medium_20to74() {
        XCTAssertEqual(makeUsage(percentage: 20).usageLevel, .medium)
        XCTAssertEqual(makeUsage(percentage: 74.999).usageLevel, .medium)
    }

    func test_usageLevel_high_75plus() {
        XCTAssertEqual(makeUsage(percentage: 75).usageLevel, .high)
        XCTAssertEqual(makeUsage(percentage: 200).usageLevel, .high)
    }

    // MARK: - remaining

    func test_remaining_clampsToZero() {
        XCTAssertEqual(makeUsage(percentage: 130).remaining, 0)
        XCTAssertEqual(makeUsage(percentage: 0).remaining, 100)
        XCTAssertEqual(makeUsage(percentage: 42).remaining, 58)
    }

    // MARK: - formatters

    func test_formattedTokens_humanizesScale() {
        XCTAssertEqual(makeUsage(tokensUsed: 999).formattedTokens, "999")
        XCTAssertEqual(makeUsage(tokensUsed: 1_500).formattedTokens, "1.5K")
        XCTAssertEqual(makeUsage(tokensUsed: 2_400_000).formattedTokens, "2.4M")
        XCTAssertNil(makeUsage(tokensUsed: nil).formattedTokens)
    }

    func test_formattedCost_oneDecimal() {
        XCTAssertEqual(makeUsage(costUsedUSD: 12.345).formattedCost, "$12.3")
        XCTAssertEqual(makeUsage(costUsedUSD: 0).formattedCost, "$0.0")
        XCTAssertNil(makeUsage(costUsedUSD: nil).formattedCost)
    }

    func test_formattedResetsIn_zeroWhenPast() {
        let past = makeUsage(resetsAt: Date(timeIntervalSinceNow: -10))
        XCTAssertEqual(past.formattedResetsIn, "—")
    }

    func test_formattedResetsIn_minutes() {
        // Add 30s buffer so the test still passes even if a few hundred ms elapse
        // between the Date() creation and the formatter call.
        let in30m = makeUsage(resetsAt: Date(timeIntervalSinceNow: 30 * 60 + 30))
        XCTAssertEqual(in30m.formattedResetsIn, "30m")
    }

    func test_formattedResetsIn_hoursMinutes() {
        let in2h15 = makeUsage(resetsAt: Date(timeIntervalSinceNow: 2 * 3600 + 15 * 60 + 30))
        XCTAssertEqual(in2h15.formattedResetsIn, "2h 15m")
    }

    func test_formattedResetsIn_days() {
        let in3d = makeUsage(resetsAt: Date(timeIntervalSinceNow: 3 * 24 * 3600 + 4 * 3600 + 30))
        XCTAssertEqual(in3d.formattedResetsIn, "3d 4h")
    }

    // MARK: - ProviderConnectionState

    func test_connectionState_isConnected_onlyForConnected() {
        XCTAssertTrue(ProviderConnectionState.connected.isConnected)
        XCTAssertFalse(ProviderConnectionState.notConfigured.isConnected)
        XCTAssertFalse(ProviderConnectionState.connecting.isConnected)
        XCTAssertFalse(ProviderConnectionState.error("nope").isConnected)
        XCTAssertFalse(ProviderConnectionState.sessionExpired.isConnected)
    }

    func test_connectionState_displayText_errorPassthrough() {
        XCTAssertEqual(ProviderConnectionState.error("invalid key").displayText, "invalid key")
    }

    // MARK: - LLMProvider partitioning

    func test_apiKeyProviders_andLocalProviders_disjointAndComplete() {
        let api = Set(LLMProvider.apiKeyProviders)
        let local = Set(LLMProvider.localProviders)
        XCTAssertTrue(api.isDisjoint(with: local))
        XCTAssertEqual(api.union(local), Set(LLMProvider.allCases))
    }

    func test_localProviders_areAllAutoDetected() {
        for p in LLMProvider.localProviders {
            XCTAssertTrue(p.isAutoDetected, "\(p) should be auto-detected")
        }
    }

    // MARK: - Helpers

    private func makeUsage(
        percentage: Double = 0,
        tokensUsed: Int? = nil,
        costUsedUSD: Double? = nil,
        resetsAt: Date? = nil
    ) -> ProviderUsage {
        ProviderUsage(
            provider: .openAIAPI,
            billingType: .apiToken,
            window: .monthly,
            percentage: percentage,
            resetsAt: resetsAt,
            tokensUsed: tokensUsed,
            tokensLimit: nil,
            costUsedUSD: costUsedUSD,
            costLimitUSD: nil,
            modelBreakdown: [],
            fetchedAt: Date(),
            isActivelyConsuming: false
        )
    }

    // TODO(sonnet):
    // - Round-trip Codable for LLMProvider, BudgetConfig, UsageWindow.
    // - Color(hex:) parses 6-char hex correctly and clamps invalid input to black.
    // - ModelUsage equality semantics.
}
