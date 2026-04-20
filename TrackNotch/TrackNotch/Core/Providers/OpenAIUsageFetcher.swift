import Foundation

/// Fetches usage and balance data from OpenAI's API.
/// Polls every 5 minutes.
@MainActor
final class OpenAIUsageFetcher: ObservableObject {
    static let shared = OpenAIUsageFetcher()

    @Published private(set) var totalCostUSD: Double = 0
    @Published private(set) var balanceUSD: Double?       // remaining credit balance
    @Published private(set) var creditLimitUSD: Double?   // total credit limit
    @Published private(set) var lastFetchError: String?
    @Published private(set) var lastFetchedAt: Date?

    private var pollTimer: Timer?
    private let idleInterval: TimeInterval = 300   // 5 min when idle
    private let activeInterval: TimeInterval = 60  // 1 min when cost is changing
    private var previousCost: Double = 0
    private var activeStreakCount: Int = 0          // consecutive polls with cost change

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard ProviderAuthManager.shared.loadAPIKey(for: .openAIAPI) != nil else { return }
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
        let costChanged = totalCostUSD != previousCost
        previousCost = totalCostUSD

        if costChanged {
            activeStreakCount += 1
            print("[OpenAI] Cost changed — polling every \(Int(activeInterval))s")
            schedulePoll(interval: activeInterval)
        } else {
            if activeStreakCount > 0 {
                // Was active, now idle — do one more fast poll then back off
                activeStreakCount = 0
                print("[OpenAI] Cost stable — one more fast poll then backing off")
                schedulePoll(interval: activeInterval)
            } else {
                print("[OpenAI] Idle — polling every \(Int(idleInterval))s")
                schedulePoll(interval: idleInterval)
            }
        }
    }

    // MARK: - Balance / Credit

    private func fetchBalance() async {
        guard let apiKey = ProviderAuthManager.shared.loadAPIKey(for: .openAIAPI) else { return }

        // Try /v1/organization/billing/subscription — returns plan info + credit balance
        if let result = await tryEndpoint(
            url: "https://api.openai.com/v1/organization/billing/subscription",
            apiKey: apiKey,
            label: "subscription"
        ) {
            if let json = result as? [String: Any] {
                print("[OpenAI] subscription response keys: \(json.keys.sorted())")

                // hard_limit_usd = total credit limit, soft_limit_usd = billing threshold
                if let hardLimit = json["hard_limit_usd"] as? Double {
                    creditLimitUSD = hardLimit
                }
                if let softLimit = json["soft_limit_usd"] as? Double, creditLimitUSD == nil {
                    creditLimitUSD = softLimit
                }

                // system_hard_limit_usd is another field some accounts have
                if let sysLimit = json["system_hard_limit_usd"] as? Double, creditLimitUSD == nil {
                    creditLimitUSD = sysLimit
                }

                ProviderRegistry.shared.updateUsage(toProviderUsage())
                return
            }
        }

        // Try /v1/dashboard/billing/credit_grants — shows prepaid credit balance
        if let result = await tryEndpoint(
            url: "https://api.openai.com/v1/dashboard/billing/credit_grants",
            apiKey: apiKey,
            label: "credit_grants"
        ) {
            if let json = result as? [String: Any] {
                print("[OpenAI] credit_grants response keys: \(json.keys.sorted())")
                // total_available, total_granted, total_used
                if let available = json["total_available"] as? Double {
                    balanceUSD = available
                }
                if let granted = json["total_granted"] as? Double {
                    creditLimitUSD = granted
                }
                ProviderRegistry.shared.updateUsage(toProviderUsage())
            }
        }
    }

    // MARK: - Costs (monthly spend)

    private func fetchCosts() async {
        guard let apiKey = ProviderAuthManager.shared.loadAPIKey(for: .openAIAPI) else {
            lastFetchError = "No API key"
            return
        }

        let cal = Calendar.current
        let now = Date()
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let startTimestamp = Int(startOfMonth.timeIntervalSince1970)

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
                print("[OpenAI] Costs: $\(total)")
                return
            }
        }

        // Costs endpoint failed — still update with balance info if we have it
        lastFetchError = "Could not fetch costs"
        ProviderRegistry.shared.updateUsage(toProviderUsage())
        print("[OpenAI] Costs fetch failed — pill shows balance if available")
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
                let json = try? JSONSerialization.jsonObject(with: data)
                print("[OpenAI] \(label): 200 OK")
                return json
            } else {
                let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
                print("[OpenAI] \(label): HTTP \(status) — \(body)")
            }
        } catch {
            print("[OpenAI] \(label): \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - Usage conversion

    func toProviderUsage() -> ProviderUsage {
        // Primary: show monthly spend
        // If we got a balance from the API, show that instead
        let displayCost = balanceUSD ?? totalCostUSD
        // Only show a limit if we got one from the API (not user-set budget)
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
            costUsedUSD: displayCost,
            costLimitUSD: displayLimit,
            modelBreakdown: [],
            fetchedAt: lastFetchedAt ?? Date(),
            isActivelyConsuming: false
        )
    }
}
