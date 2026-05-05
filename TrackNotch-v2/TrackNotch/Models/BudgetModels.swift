//
//  BudgetModels.swift
//  AgentNotch
//
//  Models for per-provider budget tracking and alerts
//

import Foundation

// MARK: - Budget Manager

/// Manages budget configurations and alert thresholds across all providers
@MainActor
final class BudgetManager: ObservableObject {
    static let shared = BudgetManager()

    @Published private(set) var configs: [LLMProvider: BudgetConfig] = [:]
    @Published private(set) var firedAlerts: Set<String> = []

    private let configsKey = "budgetConfigs_v1"

    private init() {
        load()
    }

    // MARK: - Public API

    func config(for provider: LLMProvider) -> BudgetConfig {
        configs[provider] ?? BudgetConfig.defaultConfig(for: provider)
    }

    func setLimit(_ usd: Double, for provider: LLMProvider) {
        let c = config(for: provider)
        configs[provider] = BudgetConfig(
            provider: provider,
            limitUSD: usd,
            alertAt: c.alertAt
        )
        save()
    }

    func setAlertThreshold(_ fraction: Double, for provider: LLMProvider) {
        let c = config(for: provider)
        configs[provider] = BudgetConfig(
            provider: provider,
            limitUSD: c.limitUSD,
            alertAt: fraction
        )
        save()
    }

    /// Returns true if the provider has crossed its alert threshold and notification should fire
    func shouldAlert(for usage: ProviderUsage) -> Bool {
        let c = config(for: usage.provider)
        let threshold = c.alertAt * 100  // convert fraction to percentage
        let alertKey = "\(usage.provider.rawValue)_\(Int(threshold))"
        guard usage.percentage >= threshold,
              !firedAlerts.contains(alertKey) else { return false }
        firedAlerts.insert(alertKey)
        return true
    }

    /// Reset fired alerts (e.g. after usage window resets)
    func resetAlerts(for provider: LLMProvider) {
        firedAlerts = firedAlerts.filter { !$0.hasPrefix(provider.rawValue) }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: configsKey),
              let decoded = try? JSONDecoder().decode([String: BudgetConfig].self, from: data) else {
            return
        }
        for (key, value) in decoded {
            if let provider = LLMProvider(rawValue: key) {
                configs[provider] = value
            }
        }
    }

    private func save() {
        let mapped = Dictionary(uniqueKeysWithValues: configs.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(mapped) {
            UserDefaults.standard.set(data, forKey: configsKey)
        }
    }
}

// MARK: - Alert Severity

enum BudgetAlertSeverity {
    case warning   // reached alertAt threshold
    case critical  // reached 95%+
    case exceeded  // reached 100%

    var emoji: String {
        switch self {
        case .warning:  return "⚠️"
        case .critical: return "🔴"
        case .exceeded: return "🚨"
        }
    }
}
