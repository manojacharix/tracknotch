import Foundation

/// Fetches usage data from OpenAI's billing API using the user's API key.
/// Polls every 5 minutes.
@MainActor
final class OpenAIUsageFetcher: ObservableObject {
    static let shared = OpenAIUsageFetcher()

    @Published private(set) var totalCostUSD: Double = 0
    @Published private(set) var totalTokens: Int = 0
    @Published private(set) var lastFetchError: String?
    @Published private(set) var lastFetchedAt: Date?

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 300  // 5 minutes

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard ProviderAuthManager.shared.loadAPIKey(for: .openAIAPI) != nil else { return }
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
        guard let apiKey = ProviderAuthManager.shared.loadAPIKey(for: .openAIAPI) else {
            lastFetchError = "No API key"
            return
        }

        // OpenAI billing API: current month's usage
        let cal = Calendar.current
        let now = Date()
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let startDate = formatter.string(from: startOfMonth)
        let endDate = formatter.string(from: now)

        let urlString = "https://api.openai.com/v1/dashboard/billing/usage?start_date=\(startDate)&end_date=\(endDate)"
        guard let url = URL(string: urlString) else {
            lastFetchError = "Invalid URL"
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

            // Response: { "total_usage": <cents>, "daily_costs": [...] }
            if let totalUsageCents = json["total_usage"] as? Double {
                totalCostUSD = totalUsageCents / 100.0
            }

            lastFetchError = nil
            lastFetchedAt = Date()
            ProviderRegistry.shared.updateUsage(toProviderUsage())
        } catch {
            lastFetchError = error.localizedDescription
        }
    }

    // MARK: - Usage conversion

    func toProviderUsage() -> ProviderUsage {
        let budget = AppSettings.shared.openAIMonthlyBudget
        let pct = budget > 0 ? min(totalCostUSD / budget * 100, 100) : 0

        return ProviderUsage(
            provider: .openAIAPI,
            billingType: .apiToken,
            window: .monthly,
            percentage: pct,
            resetsAt: nil,
            tokensUsed: totalTokens > 0 ? totalTokens : nil,
            tokensLimit: nil,
            costUsedUSD: totalCostUSD,
            costLimitUSD: budget,
            modelBreakdown: [],
            fetchedAt: lastFetchedAt ?? Date(),
            isActivelyConsuming: false
        )
    }
}
