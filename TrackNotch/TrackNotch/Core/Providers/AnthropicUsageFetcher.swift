import Foundation

/// Fetches usage data from Anthropic's usage API using the user's API key.
/// Polls every 5 minutes.
@MainActor
final class AnthropicUsageFetcher: ObservableObject {
    static let shared = AnthropicUsageFetcher()

    @Published private(set) var totalCostUSD: Double = 0
    @Published private(set) var totalInputTokens: Int = 0
    @Published private(set) var totalOutputTokens: Int = 0
    @Published private(set) var modelBreakdown: [ModelUsage] = []
    @Published private(set) var lastFetchError: String?
    @Published private(set) var lastFetchedAt: Date?
    @Published private(set) var isActivelyConsuming: Bool = false

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 300  // 5 minutes
    private var activityTimer: Timer?
    private let activityTimeout: TimeInterval = 90  // bridge 60s active poll gaps
    private var previousTokens: Int = 0
    private var isFirstFetch: Bool = true

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard ProviderAuthManager.shared.loadAPIKey(for: .anthropicAPI) != nil else {
            TNLog.info("[Anthropic] No API key configured — skipping start", category: .provider)
            return
        }
        Task { await fetchUsage() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.fetchUsage() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        Task { await fetchUsage() }
    }

    // MARK: - Fetching

    private func fetchUsage() async {
        guard let apiKey = ProviderAuthManager.shared.loadAPIKey(for: .anthropicAPI) else {
            lastFetchError = "No API key"
            return
        }

        // Admin keys (sk-ant-admin-…) hit /v1/organizations/usage_report/messages
        // for org-wide aggregate cost. Regular keys (sk-ant-api03-…) probe
        // /v1/messages and read rate-limit response headers.
        if apiKey.hasPrefix("sk-ant-admin") {
            await fetchViaAdminAPI(apiKey)
        } else {
            await fetchViaProbe(apiKey)
        }
    }

    // MARK: - Admin API path (org-wide aggregate cost)

    private func fetchViaAdminAPI(_ apiKey: String) async {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let cal = Calendar.current
        let now = Date()
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        let starting = formatter.string(from: startOfMonth)
        let ending = formatter.string(from: now)

        let urlString = "https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=\(starting)&ending_at=\(ending)"
        guard let url = URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString) else {
            lastFetchError = "Invalid URL"
            return
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastFetchError = "No HTTP response"
                return
            }
            // Admin endpoint may reject the key (key is actually a regular API key,
            // or admin permissions are missing). Fall back to the probe path so
            // the user still sees a working pill.
            if http.statusCode == 401 || http.statusCode == 403 {
                TNLog.info("[Anthropic] Admin endpoint rejected key (HTTP \(http.statusCode)) — falling back to probe", category: .provider)
                await fetchViaProbe(apiKey)
                return
            }
            guard http.statusCode == 200 else {
                lastFetchError = "HTTP \(http.statusCode)"
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastFetchError = "Invalid JSON"
                return
            }

            let prevTokens = previousTokens
            parseUsage(json)
            lastFetchError = nil
            lastFetchedAt = Date()
            // Skip activity detection on first fetch — loading existing usage isn't "active"
            if isFirstFetch {
                isFirstFetch = false
            } else if totalInputTokens + totalOutputTokens > prevTokens {
                markActivity()
            }
            ProviderRegistry.shared.updateUsage(toProviderUsage())
        } catch {
            lastFetchError = error.localizedDescription
        }
    }

    // MARK: - Probe path (regular API keys)

    /// Sends a 1-token POST to /v1/messages and reads `anthropic-ratelimit-*`
    /// response headers. Can't return aggregate monthly cost (those headers are
    /// per-window) but confirms the key is valid and surfaces a non-zero token
    /// count so the dropdown pill renders + activity arrow updates.
    private func fetchViaProbe(_ apiKey: String) async {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            lastFetchError = "Invalid URL"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // User-Agent matches the Claude Code CLI so rate-limit headers are scoped correctly.
        request.setValue("claude-code/2.1.5", forHTTPHeaderField: "User-Agent")
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
                lastFetchError = "Invalid API key"
                TNLog.warn("[Anthropic] Probe rejected key (401)", category: .provider)
                return
            }
            // 200 or 429 both populate rate-limit headers.
            let headers = http.allHeaderFields
            let inputLimit     = headerInt(headers, "anthropic-ratelimit-input-tokens-limit")
            let inputRemaining = headerInt(headers, "anthropic-ratelimit-input-tokens-remaining")
            let totalLimit     = headerInt(headers, "anthropic-ratelimit-tokens-limit")
            let totalRemaining = headerInt(headers, "anthropic-ratelimit-tokens-remaining")

            // Best-effort consumed estimate from whichever headers we got.
            let inputConsumed = max(0, (inputLimit ?? 0) - (inputRemaining ?? 0))
            let totalConsumed = max(0, (totalLimit ?? 0) - (totalRemaining ?? 0))
            let consumed = max(inputConsumed, totalConsumed)

            // Default to Sonnet input pricing for cost estimate.
            let estCost = Double(consumed) * 3.0 / 1_000_000

            let prevTokens = previousTokens
            previousTokens = totalInputTokens + totalOutputTokens
            totalInputTokens = consumed
            totalOutputTokens = 0
            totalCostUSD = estCost
            modelBreakdown = []

            lastFetchError = nil
            lastFetchedAt = Date()

            if isFirstFetch {
                isFirstFetch = false
            } else if consumed > prevTokens {
                markActivity()
            }

            TNLog.debug("[Anthropic] Probe: consumed=\(consumed) tokens, estCost=$\(String(format: "%.4f", estCost)) HTTP \(http.statusCode)", category: .provider)
            ProviderRegistry.shared.updateUsage(toProviderUsage())
        } catch {
            lastFetchError = error.localizedDescription
            TNLog.error("[Anthropic] Probe error: \(error.localizedDescription)", category: .provider)
        }
    }

    private func headerInt(_ headers: [AnyHashable: Any], _ name: String) -> Int? {
        guard let val = headers[name] as? String ?? headers[name.lowercased()] as? String else { return nil }
        return Int(val)
    }

    // MARK: - Pricing (per million tokens, USD)

    /// Approximate pricing for Anthropic models. Used to derive cost from token counts
    /// since the usage API doesn't return cost directly.
    private static let pricing: [String: (input: Double, output: Double)] = [
        "claude-sonnet-4-6":    (3.0,  15.0),
        "claude-opus-4-6":      (15.0, 75.0),
        "claude-haiku-4-5":     (0.80, 4.0),
        "claude-sonnet-4-5":    (3.0,  15.0),
        "claude-3-5-sonnet":    (3.0,  15.0),
        "claude-3-5-haiku":     (0.80, 4.0),
        "claude-3-opus":        (15.0, 75.0),
        "claude-3-sonnet":      (3.0,  15.0),
        "claude-3-haiku":       (0.25, 1.25),
    ]

    /// Best-effort model price lookup. Falls back to Sonnet pricing if model not found.
    private static var loggedUnknownModels = Set<String>()
    private static func priceFor(_ model: String) -> (input: Double, output: Double) {
        // Try exact match first, then prefix match for versioned model IDs
        if let p = pricing[model] { return p }
        for (key, p) in pricing where model.hasPrefix(key) { return p }
        if !loggedUnknownModels.contains(model) {
            loggedUnknownModels.insert(model)
            TNLog.warn("[Anthropic] Unknown model '\(model)' — using Sonnet pricing as fallback", category: .provider)
        }
        return (3.0, 15.0) // default to Sonnet pricing
    }

    private func parseUsage(_ json: [String: Any]) {
        // Response shape: { "data": [{ "uncached_input_tokens": N, "output_tokens": N, "model": "..." }, ...] }
        var input = 0
        var output = 0
        var cost = 0.0
        var perModel: [String: (input: Int, output: Int, cost: Double)] = [:]

        if let data = json["data"] as? [[String: Any]] {
            for entry in data {
                let i = (entry["uncached_input_tokens"] as? Int ?? 0) + (entry["cache_read_input_tokens"] as? Int ?? 0)
                let o = entry["output_tokens"] as? Int ?? 0
                let model = entry["model"] as? String ?? "unknown"
                let price = Self.priceFor(model)
                let entryCost = (Double(i) * price.input + Double(o) * price.output) / 1_000_000

                input += i
                output += o
                cost += entryCost

                let prev = perModel[model] ?? (0, 0, 0)
                perModel[model] = (prev.input + i, prev.output + o, prev.cost + entryCost)
            }
        }

        previousTokens = totalInputTokens + totalOutputTokens
        totalInputTokens = input
        totalOutputTokens = output
        totalCostUSD = cost
        modelBreakdown = perModel.map {
            ModelUsage(modelName: $0.key, tokensUsed: $0.value.input + $0.value.output, costUSD: $0.value.cost)
        }.sorted { $0.tokensUsed > $1.tokensUsed }

        TNLog.debug("[Anthropic] Usage: \(input) input + \(output) output tokens, estimated cost: $\(String(format: "%.4f", cost))", category: .provider)
    }

    // MARK: - Activity

    private func markActivity() {
        isActivelyConsuming = true
        activityTimer?.invalidate()
        activityTimer = Timer.scheduledTimer(withTimeInterval: activityTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.isActivelyConsuming = false }
        }
    }

    // MARK: - Usage conversion

    func toProviderUsage() -> ProviderUsage {
        let budget = AppSettings.shared.anthropicMonthlyBudget
        let pct = budget > 0 && totalCostUSD > 0 ? min(totalCostUSD / budget * 100, 100) : 0

        return ProviderUsage(
            provider: .anthropicAPI,
            billingType: .apiToken,
            window: .monthly,
            percentage: pct,
            resetsAt: nil,
            tokensUsed: totalInputTokens + totalOutputTokens,
            tokensLimit: nil,
            costUsedUSD: totalCostUSD > 0 ? totalCostUSD : nil,
            costLimitUSD: budget,
            modelBreakdown: modelBreakdown,
            fetchedAt: lastFetchedAt ?? Date(),
            isActivelyConsuming: isActivelyConsuming,
            fetchError: lastFetchError
        )
    }
}
