import Foundation

/// Probes Anthropic's /v1/messages endpoint with a minimal request to extract
/// rate-limit utilization headers. Requires an OAuth token from `claude setup-token`.
///
/// Headers returned:
///   anthropic-ratelimit-unified-5h-utilization  (0.0–1.0)
///   anthropic-ratelimit-unified-5h-reset        (Unix epoch)
///   anthropic-ratelimit-unified-7d-utilization  (0.0–1.0)
///   anthropic-ratelimit-unified-7d-reset        (Unix epoch)
@MainActor
final class ClaudeRateLimitFetcher: ObservableObject {
    static let shared = ClaudeRateLimitFetcher()

    @Published private(set) var utilization5h: Double = 0   // 0–100
    @Published private(set) var reset5h: Date?
    @Published private(set) var utilization7d: Double = 0   // 0–100
    @Published private(set) var reset7d: Date?
    @Published private(set) var lastFetchError: String?
    @Published private(set) var lastFetchedAt: Date?

    private var pollTimer: Timer?
    private let idleInterval: TimeInterval = 300
    private let activeInterval: TimeInterval = 60
    private let defaultInterval: TimeInterval = 120

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard ProviderAuthManager.shared.loadOAuthToken(for: .claudeCode) != nil else {
            TNLog.info("[RateLimit] No OAuth token — skipping start", category: .provider)
            return
        }
        Task { await fetchUsage() }
        schedulePoll()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        Task { await fetchUsage() }
    }

    private func schedulePoll() {
        pollTimer?.invalidate()
        let interval: TimeInterval
        if ClaudeCodeMonitor.shared.isActivelyConsuming {
            interval = activeInterval
        } else if lastFetchedAt != nil {
            interval = idleInterval
        } else {
            interval = defaultInterval
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.fetchUsage()
                self?.schedulePoll()
            }
        }
    }

    // MARK: - Probe request

    private func fetchUsage() async {
        guard let token = ProviderAuthManager.shared.loadOAuthToken(for: .claudeCode) else {
            lastFetchError = "No OAuth token"
            return
        }

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // OAuth tokens (sk-ant-oat01-…) require Bearer + oauth beta header.
        // Impersonate the real Claude Code CLI so rate-limit headers are scoped correctly.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.5", forHTTPHeaderField: "User-Agent")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "."]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastFetchError = "No HTTP response"
                return
            }

            if http.statusCode == 401 {
                lastFetchError = "Invalid token"
                TNLog.warn("[RateLimit] 401 — OAuth token rejected", category: .provider)
                return
            }

            // Extract rate-limit headers (present on both 200 and 429 responses)
            let headers = http.allHeaderFields

            if let h5 = headerDouble(headers, "anthropic-ratelimit-unified-5h-utilization") {
                let new5h = h5 * 100
                if utilization5h != new5h { utilization5h = new5h }
            }
            if let r5 = headerEpoch(headers, "anthropic-ratelimit-unified-5h-reset") {
                if reset5h != r5 { reset5h = r5 }
            }
            if let h7 = headerDouble(headers, "anthropic-ratelimit-unified-7d-utilization") {
                let new7d = h7 * 100
                if utilization7d != new7d { utilization7d = new7d }
            }
            if let r7 = headerEpoch(headers, "anthropic-ratelimit-unified-7d-reset") {
                if reset7d != r7 { reset7d = r7 }
            }

            lastFetchError = nil
            lastFetchedAt = Date()

            TNLog.debug("[RateLimit] 5h: \(String(format: "%.1f", utilization5h))% | 7d: \(String(format: "%.1f", utilization7d))% | HTTP \(http.statusCode)", category: .provider)

        } catch {
            lastFetchError = error.localizedDescription
            TNLog.error("[RateLimit] \(error.localizedDescription)", category: .provider)
        }
    }

    // MARK: - Header parsing

    private func headerDouble(_ headers: [AnyHashable: Any], _ name: String) -> Double? {
        guard let val = headers[name] as? String ?? headers[name.lowercased()] as? String else { return nil }
        return Double(val)
    }

    private func headerEpoch(_ headers: [AnyHashable: Any], _ name: String) -> Date? {
        guard let val = headers[name] as? String ?? headers[name.lowercased()] as? String else { return nil }
        // Try Unix epoch first (numeric), then ISO8601
        if let epoch = Double(val) {
            return Date(timeIntervalSince1970: epoch)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: val)
    }

    // MARK: - Usage conversion

    func toProviderUsage(monitor: ClaudeCodeMonitor) -> ProviderUsage {
        ProviderUsage(
            provider: .claudeCode,
            billingType: .subscription,
            window: .fiveHour,
            percentage: utilization5h,
            resetsAt: reset5h,
            tokensUsed: monitor.weeklyTokens,
            tokensLimit: nil,
            costUsedUSD: nil,
            costLimitUSD: nil,
            modelBreakdown: monitor.modelBreakdown,
            fetchedAt: lastFetchedAt ?? Date(),
            isActivelyConsuming: monitor.isActivelyConsuming,
            secondaryPercentage: utilization7d,
            secondaryWindow: .weekly,
            secondaryResetsAt: reset7d,
            fetchError: lastFetchError
        )
    }
}
