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

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 300  // 5 minutes

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard ProviderAuthManager.shared.loadAPIKey(for: .anthropicAPI) != nil else {
            print("[Anthropic] No API key configured — skipping start")
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

        // Anthropic usage API: current month
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
            guard http.statusCode == 200 else {
                lastFetchError = "HTTP \(http.statusCode)"
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastFetchError = "Invalid JSON"
                return
            }

            parseUsage(json)
            lastFetchError = nil
            lastFetchedAt = Date()
            ProviderRegistry.shared.updateUsage(toProviderUsage())
        } catch {
            lastFetchError = error.localizedDescription
        }
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
    private static func priceFor(_ model: String) -> (input: Double, output: Double) {
        // Try exact match first, then prefix match for versioned model IDs
        if let p = pricing[model] { return p }
        for (key, p) in pricing where model.hasPrefix(key) { return p }
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

        totalInputTokens = input
        totalOutputTokens = output
        totalCostUSD = cost
        modelBreakdown = perModel.map {
            ModelUsage(modelName: $0.key, tokensUsed: $0.value.input + $0.value.output, costUSD: $0.value.cost)
        }.sorted { $0.tokensUsed > $1.tokensUsed }

        print("[Anthropic] Usage: \(input) input + \(output) output tokens, estimated cost: $\(String(format: "%.4f", cost))")
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
            isActivelyConsuming: false
        )
    }
}
