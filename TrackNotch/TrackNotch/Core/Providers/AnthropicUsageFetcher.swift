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
        guard ProviderAuthManager.shared.loadAPIKey(for: .anthropicAPI) != nil else { return }
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

    private func parseUsage(_ json: [String: Any]) {
        // Response shape: { "data": [{ "uncached_input_tokens": N, "output_tokens": N, "model": "..." }, ...] }
        var input = 0
        var output = 0
        var perModel: [String: (input: Int, output: Int)] = [:]

        if let data = json["data"] as? [[String: Any]] {
            for entry in data {
                let i = (entry["uncached_input_tokens"] as? Int ?? 0) + (entry["cache_read_input_tokens"] as? Int ?? 0)
                let o = entry["output_tokens"] as? Int ?? 0
                input += i
                output += o
                if let model = entry["model"] as? String {
                    let prev = perModel[model] ?? (0, 0)
                    perModel[model] = (prev.input + i, prev.output + o)
                }
            }
        }

        totalInputTokens = input
        totalOutputTokens = output
        modelBreakdown = perModel.map {
            ModelUsage(modelName: $0.key, tokensUsed: $0.value.input + $0.value.output, costUSD: nil)
        }.sorted { $0.tokensUsed > $1.tokensUsed }
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
