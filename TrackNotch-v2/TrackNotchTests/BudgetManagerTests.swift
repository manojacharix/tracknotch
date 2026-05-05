import XCTest
@testable import TrackNotch

@MainActor
final class BudgetManagerTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // Isolate UserDefaults state — BudgetManager reads/writes UserDefaults.standard.
        let suite = UserDefaults.standard
        suite.removeObject(forKey: "budgetConfigs_v1")
    }

    func test_setLimit_persists() {
        let mgr = BudgetManager.shared
        mgr.setLimit(42.0, for: .openAIAPI)
        XCTAssertEqual(mgr.config(for: .openAIAPI).limitUSD, 42.0)
    }

    func test_shouldAlert_firesOnceAtThreshold() {
        let mgr = BudgetManager.shared
        mgr.setAlertThreshold(0.8, for: .openAIAPI) // 80%

        let below = makeUsage(.openAIAPI, percentage: 79.999)
        let at    = makeUsage(.openAIAPI, percentage: 80.0)
        let above = makeUsage(.openAIAPI, percentage: 95.0)

        XCTAssertFalse(mgr.shouldAlert(for: below), "below threshold should not fire")
        XCTAssertTrue(mgr.shouldAlert(for: at), "at threshold fires once")
        XCTAssertFalse(mgr.shouldAlert(for: above), "already-fired threshold does not refire")
    }

    func test_resetAlerts_allowsRefire() {
        let mgr = BudgetManager.shared
        mgr.setAlertThreshold(0.5, for: .anthropicAPI)

        let crossed = makeUsage(.anthropicAPI, percentage: 60)
        XCTAssertTrue(mgr.shouldAlert(for: crossed))
        XCTAssertFalse(mgr.shouldAlert(for: crossed))

        mgr.resetAlerts(for: .anthropicAPI)
        XCTAssertTrue(mgr.shouldAlert(for: crossed), "after reset, alert fires again")
    }

    func test_resetAlerts_isPerProvider() {
        let mgr = BudgetManager.shared
        mgr.setAlertThreshold(0.5, for: .openAIAPI)
        mgr.setAlertThreshold(0.5, for: .anthropicAPI)

        _ = mgr.shouldAlert(for: makeUsage(.openAIAPI, percentage: 60))
        _ = mgr.shouldAlert(for: makeUsage(.anthropicAPI, percentage: 60))

        mgr.resetAlerts(for: .openAIAPI)

        XCTAssertTrue(mgr.shouldAlert(for: makeUsage(.openAIAPI, percentage: 60)),
                      "openAI alert should refire after its reset")
        XCTAssertFalse(mgr.shouldAlert(for: makeUsage(.anthropicAPI, percentage: 60)),
                       "anthropic alert should remain fired")
    }

    func test_defaultConfig_whenNoneSet() {
        let mgr = BudgetManager.shared
        let cfg = mgr.config(for: .codex)
        XCTAssertEqual(cfg.limitUSD, BudgetConfig.defaultConfig(for: .codex).limitUSD)
        XCTAssertEqual(cfg.alertAt, BudgetConfig.defaultConfig(for: .codex).alertAt)
    }

    // MARK: - Helpers

    private func makeUsage(_ provider: LLMProvider, percentage: Double) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            billingType: .apiToken,
            window: .monthly,
            percentage: percentage,
            resetsAt: nil,
            tokensUsed: nil, tokensLimit: nil,
            costUsedUSD: nil, costLimitUSD: nil,
            modelBreakdown: [],
            fetchedAt: Date(),
            isActivelyConsuming: true
        )
    }

    // TODO(sonnet):
    // - Round-trip persistence: setLimit on instance A, re-load and read on instance B.
    //   Requires extracting BudgetManager from singleton OR clearing+rebuilding via UserDefaults.
    // - Threshold equality at 100% triggers exactly once.
    // - Threshold = 0 should fire immediately at any non-zero usage.
}
