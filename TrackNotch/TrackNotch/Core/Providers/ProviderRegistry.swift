//
//  ProviderRegistry.swift
//  TrackNotch
//
//  Central aggregator for all provider usage managers.
//

import Foundation
import Combine
import UserNotifications

@MainActor
final class ProviderRegistry: ObservableObject {
    static let shared = ProviderRegistry()

    @Published private(set) var usageMap: [LLMProvider: ProviderUsage] = [:]
    @Published private(set) var connectionStates: [LLMProvider: ProviderConnectionState] = [:]

    /// User-defined display order, persisted to UserDefaults
    @Published private(set) var orderedProviders: [LLMProvider] = LLMProvider.allCases

    private static let orderKey = "providerOrder"
    private var cancellables = Set<AnyCancellable>()

    private init() {
        loadProviderOrder()
        requestNotificationPermission()
    }

    // MARK: - Active Providers (for wing display)

    /// Providers currently being actively used (show in wing)
    var activeProviders: [LLMProvider] {
        orderedProviders.filter {
            connectionStates[$0]?.isConnected == true &&
            (usageMap[$0]?.percentage ?? 0) > 0
        }
    }

    /// All connected providers (for dropdown panel), in user-defined order
    var connectedProviders: [LLMProvider] {
        orderedProviders.filter { connectionStates[$0]?.isConnected == true }
    }

    // MARK: - Provider Order

    func saveProviderOrder(_ order: [LLMProvider]) {
        orderedProviders = order
        let raw = order.map(\.rawValue)
        UserDefaults.standard.set(raw, forKey: Self.orderKey)
    }

    private func loadProviderOrder() {
        guard let raw = UserDefaults.standard.array(forKey: Self.orderKey) as? [String] else { return }
        let loaded = raw.compactMap(LLMProvider.init(rawValue:))
        // Merge: keep loaded order, append any new providers not yet saved
        let missing = LLMProvider.allCases.filter { !loaded.contains($0) }
        orderedProviders = loaded + missing
    }

    // MARK: - Usage Updates

    func updateUsage(_ usage: ProviderUsage) {
        usageMap[usage.provider] = usage
    }

    func updateConnectionState(_ state: ProviderConnectionState, for provider: LLMProvider) {
        connectionStates[provider] = state
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
