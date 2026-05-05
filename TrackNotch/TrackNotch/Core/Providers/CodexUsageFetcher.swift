import Foundation

/// Fetches Codex rate-limit data from ChatGPT's backend API.
/// Uses the bearer token stored in ~/.codex/auth.json.
/// Polls every 60s when Codex is actively consuming, 5 min otherwise.
@MainActor
final class CodexUsageFetcher: ObservableObject {
    static let shared = CodexUsageFetcher()

    @Published private(set) var usedPercent: Double = 0        // 0–100, primary window
    @Published private(set) var resetAt: Date?
    @Published private(set) var secondaryUsedPercent: Double?  // secondary window if present
    @Published private(set) var secondaryResetAt: Date?
    @Published private(set) var planType: String?
    @Published private(set) var lastFetchError: String?
    @Published private(set) var lastFetchedAt: Date?

    private var pollTimer: Timer?
    private let activeInterval: TimeInterval = 60
    private let idleInterval: TimeInterval = 300

    private let authPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json").path
    }()

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard loadToken() != nil else {
            TNLog.info("[CodexUsage] No auth token — skipping start", category: .provider)
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
        let interval = CodexMonitor.shared.isActivelyConsuming ? activeInterval : idleInterval
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.fetchUsage()
                self?.schedulePoll()
            }
        }
    }

    // MARK: - Auth

    private func loadToken() -> String? {
        guard let data = FileManager.default.contents(atPath: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            return nil
        }
        return accessToken
    }

    private func loadAccountId() -> String? {
        guard let data = FileManager.default.contents(atPath: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any] else { return nil }
        return tokens["account_id"] as? String
    }

    // MARK: - Fetch

    private func fetchUsage() async {
        guard let token = loadToken() else {
            lastFetchError = "No auth token"
            return
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accountId = loadAccountId() {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastFetchError = "No HTTP response"
                return
            }

            if http.statusCode == 401 {
                lastFetchError = "Token expired"
                TNLog.warn("[CodexUsage] 401 — token likely expired", category: .provider)
                return
            }
            guard http.statusCode == 200 else {
                lastFetchError = "HTTP \(http.statusCode)"
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastFetchError = "Invalid JSON"
                return
            }

            parseResponse(json)
            lastFetchError = nil
            lastFetchedAt = Date()
            ProviderRegistry.shared.updateUsage(toProviderUsage())
            TNLog.debug("[CodexUsage] usedPercent=\(String(format: "%.1f", usedPercent))% plan=\(planType ?? "?")", category: .provider)
        } catch {
            lastFetchError = error.localizedDescription
            TNLog.error("[CodexUsage] \(error.localizedDescription)", category: .provider)
        }
    }

    // MARK: - Parsing

    private func parseResponse(_ json: [String: Any]) {
        planType = json["plan_type"] as? String

        if let rateLimit = json["rate_limit"] as? [String: Any] {
            if let primary = rateLimit["primary_window"] as? [String: Any] {
                usedPercent = (primary["used_percent"] as? Double ?? 0) * 100
                if let resetStr = primary["reset_at"] as? String {
                    resetAt = ISO8601DateFormatter().date(from: resetStr)
                } else if let resetAfter = primary["reset_after_seconds"] as? Double {
                    resetAt = Date().addingTimeInterval(resetAfter)
                }
            }
            if let secondary = rateLimit["secondary_window"] as? [String: Any] {
                let pct = (secondary["used_percent"] as? Double ?? 0) * 100
                secondaryUsedPercent = pct > 0 ? pct : nil
                if let resetStr = secondary["reset_at"] as? String {
                    secondaryResetAt = ISO8601DateFormatter().date(from: resetStr)
                } else if let resetAfter = secondary["reset_after_seconds"] as? Double {
                    secondaryResetAt = Date().addingTimeInterval(resetAfter)
                }
            }
        }
    }

    // MARK: - Usage conversion

    func toProviderUsage() -> ProviderUsage {
        let monitor = CodexMonitor.shared
        var usage = ProviderUsage(
            provider: .codex,
            billingType: .subscription,
            window: .daily,
            percentage: usedPercent,
            resetsAt: resetAt,
            tokensUsed: monitor.todayTokens > 0 ? monitor.todayTokens : nil,
            tokensLimit: nil,
            costUsedUSD: nil,
            costLimitUSD: nil,
            modelBreakdown: monitor.modelBreakdown,
            fetchedAt: lastFetchedAt ?? Date(),
            isActivelyConsuming: monitor.isActivelyConsuming
        )
        usage.secondaryPercentage = secondaryUsedPercent
        usage.secondaryResetsAt = secondaryResetAt
        usage.fetchError = lastFetchError
        return usage
    }
}
