import Foundation

/// Fetches usage and balance data from OpenAI's API.
/// Polls every 5 minutes.
@MainActor
final class OpenAIUsageFetcher: ObservableObject {
    static let shared = OpenAIUsageFetcher()

    @Published private(set) var totalCostUSD: Double = 0
    @Published private(set) var creditLimitUSD: Double?   // from user's budget setting
    @Published private(set) var lastFetchError: String?
    @Published private(set) var lastFetchedAt: Date?
    @Published private(set) var isActivelyConsuming: Bool = false

    private var pollTimer: Timer?
    private let idleInterval: TimeInterval = 300   // 5 min when idle
    private let activeInterval: TimeInterval = 60  // 1 min when cost is changing
    private var backoffInterval: TimeInterval = 0  // >0 when rate-limited
    private var previousCost: Double = 0
    private var isFirstFetch: Bool = true          // skip activity detection on first fetch
    private var activeStreakCount: Int = 0          // consecutive polls with cost change
    private var activityTimer: Timer?
    private let activityTimeout: TimeInterval = 90  // bridge 60s active poll gaps
    private var lastFetchMonth: Int = 0            // month of last fetch (1-12)

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard ProviderAuthManager.shared.loadAPIKey(for: .openAIAPI) != nil else {
            TNLog.info("[OpenAI] No API key configured — skipping start", category: .provider)
            return
        }
        ProviderRegistry.shared.updateUsage(toProviderUsage())
        Task {
            await fetchBalance()
            await fetchCosts()
        }
        schedulePoll(interval: idleInterval)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        Task {
            await fetchBalance()
            await fetchCosts()
        }
    }

    private func schedulePoll(interval: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.fetchBalance()
                await self?.fetchCosts()
                self?.adjustPollRate()
            }
        }
    }

    private func adjustPollRate() {
        // If rate-limited, use backoff interval instead of normal polling
        if backoffInterval > 0 {
            TNLog.info("[OpenAI] Rate-limited — next poll in \(Int(backoffInterval))s", category: .provider)
            schedulePoll(interval: backoffInterval)
            return
        }

        let costChanged = totalCostUSD != previousCost
        previousCost = totalCostUSD

        // First fetch seeds previousCost — don't treat loading existing spend as "active"
        if isFirstFetch {
            isFirstFetch = false
            TNLog.debug("[OpenAI] First fetch — seeded cost at $\(String(format: "%.4f", totalCostUSD))", category: .provider)
            schedulePoll(interval: idleInterval)
            return
        }

        if costChanged {
            activeStreakCount += 1
            markActivity()
            TNLog.debug("[OpenAI] Cost changed — polling every \(Int(activeInterval))s", category: .provider)
            schedulePoll(interval: activeInterval)
        } else {
            if activeStreakCount > 0 {
                // Was active, now idle — do one more fast poll then back off
                activeStreakCount = 0
                TNLog.debug("[OpenAI] Cost stable — one more fast poll then backing off", category: .provider)
                schedulePoll(interval: activeInterval)
            } else {
                TNLog.debug("[OpenAI] Idle — polling every \(Int(idleInterval))s", category: .provider)
                schedulePoll(interval: idleInterval)
            }
        }
    }

    // MARK: - Balance / Credit

    private func fetchBalance() async {
        // The user's budget setting is the credit limit — no API endpoint needed.
        // OpenAI removed /v1/organization/billing/subscription (404) and
        // /v1/dashboard/billing/credit_grants requires a browser session key (403).
        // The costs endpoint works — that's all we need.
        let budget = AppSettings.shared.openAIMonthlyBudget
        if budget > 0 {
            creditLimitUSD = budget
        }
        ProviderRegistry.shared.updateUsage(toProviderUsage())
    }

    // MARK: - Costs (monthly spend)

    private func fetchCosts() async {
        guard let apiKey = ProviderAuthManager.shared.loadAPIKey(for: .openAIAPI) else {
            lastFetchError = "No API key"
            return
        }

        let cal = Calendar.current
        let now = Date()
        let currentMonth = cal.component(.month, from: now)
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let startTimestamp = Int(startOfMonth.timeIntervalSince1970)

        // Reset accumulated cost when the calendar month changes
        if lastFetchMonth != 0 && currentMonth != lastFetchMonth {
            totalCostUSD = 0
            previousCost = 0
            TNLog.info("[OpenAI] Month changed — resetting cost accumulator", category: .provider)
        }
        lastFetchMonth = currentMonth

        // Try /v1/organization/costs (admin key)
        if let result = await tryEndpoint(
            url: "https://api.openai.com/v1/organization/costs?start_time=\(startTimestamp)",
            apiKey: apiKey,
            label: "costs"
        ) {
            if let json = result as? [String: Any],
               let dataArr = json["data"] as? [[String: Any]] {
                var total = 0.0
                for bucket in dataArr {
                    if let results = bucket["results"] as? [[String: Any]] {
                        for result in results {
                            if let amount = result["amount"] as? [String: Any],
                               let value = amount["value"] as? Double {
                                total += value
                            }
                        }
                    }
                }
                totalCostUSD = total
                lastFetchError = nil
                lastFetchedAt = Date()
                ProviderRegistry.shared.updateUsage(toProviderUsage())
                TNLog.debug("[OpenAI] Costs (org): $\(String(format: "%.4f", total))", category: .provider)
                return
            } else {
                TNLog.warn("[OpenAI] Costs endpoint returned unexpected shape: \(String(describing: result))", category: .provider)
            }
        }

        // Fallback: /v1/dashboard/billing/usage (older endpoint, works with some key types)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let startDate = df.string(from: startOfMonth)
        let endDate = df.string(from: Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now)
        if let result = await tryEndpoint(
            url: "https://api.openai.com/v1/dashboard/billing/usage?start_date=\(startDate)&end_date=\(endDate)",
            apiKey: apiKey,
            label: "billing/usage"
        ) {
            if let json = result as? [String: Any],
               let totalUsage = json["total_usage"] as? Double {
                // total_usage is in cents
                let cost = totalUsage / 100.0
                totalCostUSD = cost
                lastFetchError = nil
                lastFetchedAt = Date()
                ProviderRegistry.shared.updateUsage(toProviderUsage())
                TNLog.debug("[OpenAI] Costs (dashboard): $\(String(format: "%.4f", cost))", category: .provider)
                return
            } else {
                TNLog.warn("[OpenAI] Dashboard billing returned unexpected shape: \(String(describing: result))", category: .provider)
            }
        }

        // All cost endpoints failed — still update with balance info if we have it
        lastFetchError = "Could not fetch costs"
        ProviderRegistry.shared.updateUsage(toProviderUsage())
        TNLog.warn("[OpenAI] All cost endpoints failed — pill shows balance if available", category: .provider)
    }

    // MARK: - Network helper

    private func tryEndpoint(url: String, apiKey: String, label: String) async -> Any? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                backoffInterval = 0 // clear any previous backoff
                let json = try? JSONSerialization.jsonObject(with: data)
                TNLog.debug("[OpenAI] \(label): 200 OK", category: .provider)
                return json
            } else if status == 429 {
                // Exponential backoff: 60s → 120s → 240s, capped at 15 min
                backoffInterval = min(max(backoffInterval * 2, 60), 900)
                TNLog.warn("[OpenAI] \(label): rate-limited (429) — backing off \(Int(backoffInterval))s", category: .provider)
            } else {
                let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
                TNLog.warn("[OpenAI] \(label): HTTP \(status) — \(body)", category: .provider)
            }
        } catch {
            TNLog.error("[OpenAI] \(label): \(error.localizedDescription)", category: .provider)
        }
        return nil
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
        let displayCost = totalCostUSD
        let displayLimit = creditLimitUSD

        let pct: Double
        if let limit = displayLimit, limit > 0 {
            pct = min(displayCost / limit * 100, 100)
        } else {
            pct = 0
        }

        return ProviderUsage(
            provider: .openAIAPI,
            billingType: .apiToken,
            window: .monthly,
            percentage: pct,
            resetsAt: nil,
            tokensUsed: nil,
            tokensLimit: nil,
            costUsedUSD: displayCost > 0 ? displayCost : nil,
            costLimitUSD: displayLimit,
            modelBreakdown: [],
            fetchedAt: lastFetchedAt ?? Date(),
            isActivelyConsuming: isActivelyConsuming,
            fetchError: lastFetchError
        )
    }
}
