import XCTest
@testable import TrackNotch

@MainActor
final class ProviderRegistryLingerTests: XCTestCase {

    func test_idleProvider_lingersInActiveList() async throws {
        let registry = ProviderRegistry.shared

        // Drive an active update, then an idle update — the provider must remain
        // in `activeProviders` for the linger window so the pill doesn't flicker.
        registry.updateUsage(makeUsage(.openAIAPI, active: true))
        XCTAssertTrue(registry.activeProviders.contains(.openAIAPI))

        registry.updateUsage(makeUsage(.openAIAPI, active: false))
        XCTAssertTrue(registry.activeProviders.contains(.openAIAPI),
                      "provider should still be visible during the linger window")
    }

    func test_lingerExpires_after4Seconds() async throws {
        let registry = ProviderRegistry.shared

        registry.updateUsage(makeUsage(.openAIAPI, active: true))
        registry.updateUsage(makeUsage(.openAIAPI, active: false))

        try await Task.sleep(nanoseconds: 4_500_000_000) // 4.5s — covers the 4s linger
        XCTAssertFalse(registry.activeProviders.contains(.openAIAPI),
                       "after the linger expires, the provider drops out of activeProviders")
    }

    func test_returningToActive_cancelsLinger() async throws {
        let registry = ProviderRegistry.shared

        registry.updateUsage(makeUsage(.anthropicAPI, active: true))
        registry.updateUsage(makeUsage(.anthropicAPI, active: false)) // begin linger
        try await Task.sleep(nanoseconds: 1_000_000_000)              // 1s into linger
        registry.updateUsage(makeUsage(.anthropicAPI, active: true))  // back to active

        // Wait past the original linger window — provider must still be active
        // because re-activation cancelled the linger timer.
        try await Task.sleep(nanoseconds: 4_000_000_000)
        XCTAssertTrue(registry.activeProviders.contains(.anthropicAPI))
    }

    func test_updateUsage_skipsRedundantWrites() {
        let registry = ProviderRegistry.shared
        let first  = makeUsage(.codex, active: true, percentage: 42)
        let second = makeUsage(.codex, active: true, percentage: 42)

        registry.updateUsage(first)
        let snapshot = registry.activeProviders
        registry.updateUsage(second)
        XCTAssertEqual(registry.activeProviders, snapshot,
                       "a no-op update must not re-trigger lingering or order changes")
    }

    // MARK: - Helpers

    private func makeUsage(
        _ provider: LLMProvider,
        active: Bool,
        percentage: Double = 50
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            billingType: .apiToken,
            window: .monthly,
            percentage: percentage,
            resetsAt: nil,
            tokensUsed: nil, tokensLimit: nil,
            costUsedUSD: 1.23, costLimitUSD: nil,
            modelBreakdown: [],
            fetchedAt: Date(),
            isActivelyConsuming: active
        )
    }

    // TODO(sonnet):
    // - Mock `URLSession` via `URLProtocol` and assert OpenAIUsageFetcher backs off
    //   correctly on 429, parses /v1/organization/costs payloads, and falls back
    //   to dashboard billing on 404.
    // - Verify ProviderRegistry.connectedProviders ordering follows orderedProviders.
    // - Verify alert refire after percentage drops >20pts (window reset path).
}
