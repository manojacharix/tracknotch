//
//  ProviderRegistry.swift
//  TrackNotch
//
//  Central aggregator for all provider usage managers.
//  Initializes local file monitors (zero auth) + API fetchers (API key).
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

    /// Linger timers: keep a provider visible after it stops actively consuming.
    /// 4s gives enough runway to bridge polling gaps and the full collapse animation
    /// without the icon flickering out mid-session.
    private static let lingerDuration: TimeInterval = 4
    private var lingerTimers: [LLMProvider: Timer] = [:]
    @Published private var lingering: Set<LLMProvider> = []

    private init() {
        loadProviderOrder()
        requestNotificationPermission()
        syncAuthStates()
        observeAuthManager()
    }

    // MARK: - Startup

    /// Call this once from the app delegate to spin up monitors and fetchers.
    func bootstrap() {
        startLocalMonitors()
        startAPIFetchers()
    }

    private func startLocalMonitors() {
        // Claude Code
        let cc = ClaudeCodeMonitor.shared
        cc.start()
        if cc.isInstalled {
            markAutoConnected(.claudeCode)
            startClaudeUsageTracking(monitor: cc)
        } else {
            evictStaleConnection(.claudeCode)
        }

        // Codex
        let cx = CodexMonitor.shared
        cx.start()
        if cx.isInstalled {
            markAutoConnected(.codex)
            updateUsage(cx.toProviderUsage())
            cx.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.updateUsage(cx.toProviderUsage()) }
            }.store(in: &cancellables)
        } else {
            evictStaleConnection(.codex)
        }

        // Cursor
        let cu = CursorMonitor.shared
        cu.start()
        if cu.isInstalled {
            markAutoConnected(.cursorIDE)
            updateUsage(cu.toProviderUsage())
            cu.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.updateUsage(cu.toProviderUsage()) }
            }.store(in: &cancellables)
        } else {
            evictStaleConnection(.cursorIDE)
        }

        // ChatGPT Desktop
        let cd = ChatGPTDesktopMonitor.shared
        cd.start()
        if cd.isInstalled {
            markAutoConnected(.chatGPTDesktop)
            updateUsage(cd.toProviderUsage())
            cd.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.updateUsage(cd.toProviderUsage()) }
            }.store(in: &cancellables)
        } else {
            evictStaleConnection(.chatGPTDesktop)
        }
    }

    /// Clears any stale persisted connection state for a provider that failed install detection.
    /// Prevents previously-connected providers from reappearing after uninstall.
    private func evictStaleConnection(_ provider: LLMProvider) {
        connectionStates[provider] = .notConfigured
        ProviderAuthManager.shared.connectionStates[provider] = .notConfigured
        ProviderAuthManager.shared.clearPersistedState(for: provider)
        usageMap.removeValue(forKey: provider)
    }

    /// Sets up Claude Code usage tracking. If an OAuth token is available, uses the
    /// rate-limit header fetcher (authoritative 5h/7d %). Otherwise falls back to local JSONL estimate.
    func startClaudeUsageTracking(monitor: ClaudeCodeMonitor) {
        // Cancel any existing subscriptions for Claude Code
        if ProviderAuthManager.shared.loadOAuthToken(for: .claudeCode) != nil {
            // Authoritative: probe Anthropic API for real rate-limit headers
            let fetcher = ClaudeRateLimitFetcher.shared
            fetcher.start()
            updateUsage(fetcher.toProviderUsage(monitor: monitor))
            fetcher.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateUsage(fetcher.toProviderUsage(monitor: monitor))
                }
            }.store(in: &cancellables)
            // Also subscribe to monitor for activity state changes
            monitor.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateUsage(fetcher.toProviderUsage(monitor: monitor))
                }
            }.store(in: &cancellables)
        } else {
            // Fallback: local JSONL weekly estimate
            updateUsage(monitor.toProviderUsage())
            monitor.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.updateUsage(monitor.toProviderUsage()) }
            }.store(in: &cancellables)
        }
    }

    private func startAPIFetchers() {
        // Only start if an API key is already saved.
        // Seed an empty ProviderUsage so the dropdown pill renders immediately
        // (DropdownContent.visibleProviders requires `usageMap[$0] != nil`).
        if ProviderAuthManager.shared.loadAPIKey(for: .openAIAPI) != nil {
            connectionStates[.openAIAPI] = .connected
            if usageMap[.openAIAPI] == nil {
                usageMap[.openAIAPI] = ProviderUsage.empty(provider: .openAIAPI)
            }
            OpenAIUsageFetcher.shared.start()
        }
        if ProviderAuthManager.shared.loadAPIKey(for: .anthropicAPI) != nil {
            connectionStates[.anthropicAPI] = .connected
            if usageMap[.anthropicAPI] == nil {
                usageMap[.anthropicAPI] = ProviderUsage.empty(provider: .anthropicAPI)
            }
            AnthropicUsageFetcher.shared.start()
        }
    }

    private func markAutoConnected(_ provider: LLMProvider) {
        connectionStates[provider] = .connected
        ProviderAuthManager.shared.connectionStates[provider] = .connected
    }

    // MARK: - Active Providers (for wing display)

    /// True while the cursor is hovering over the external monitor panel.
    @Published var isExternalHovered: Bool = false

    /// Providers actively consuming OR still within the 2s linger window after going idle.
    var activeProviders: [LLMProvider] {
        orderedProviders.filter { provider in
            guard let usage = usageMap[provider] else { return false }
            return usage.isActivelyConsuming || lingering.contains(provider)
        }
    }

    /// All connected providers (for dropdown / settings)
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
        let missing = LLMProvider.allCases.filter { !loaded.contains($0) }
        orderedProviders = loaded + missing
    }

    // MARK: - Usage Updates

    func updateUsage(_ usage: ProviderUsage) {
        // If usage dropped significantly vs last reading, the window reset — clear fired alerts
        if let prev = usageMap[usage.provider], usage.percentage < prev.percentage - 20 {
            BudgetManager.shared.resetAlerts(for: usage.provider)
        }

        // Skip update if nothing meaningful changed — prevents unnecessary SwiftUI redraws
        if let existing = usageMap[usage.provider],
           existing.percentage == usage.percentage
            && existing.isActivelyConsuming == usage.isActivelyConsuming
            && existing.tokensUsed == usage.tokensUsed
            && existing.costUsedUSD == usage.costUsedUSD
            && existing.secondaryPercentage == usage.secondaryPercentage
            && existing.fetchError == usage.fetchError {
            return
        }

        usageMap[usage.provider] = usage
        manageLingerTimer(for: usage.provider, isActive: usage.isActivelyConsuming)
    }

    private func manageLingerTimer(for provider: LLMProvider, isActive: Bool) {
        if isActive {
            // Cancel any pending removal — provider is active again
            lingerTimers[provider]?.invalidate()
            lingerTimers[provider] = nil
            lingering.remove(provider)
        } else if !lingering.contains(provider) {
            // Not active and not already lingering — start linger window
            lingering.insert(provider)
            let timer = Timer.scheduledTimer(withTimeInterval: Self.lingerDuration, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.lingering.remove(provider)
                    self?.lingerTimers[provider] = nil
                }
            }
            lingerTimers[provider] = timer
        }
    }

    func updateConnectionState(_ state: ProviderConnectionState, for provider: LLMProvider) {
        connectionStates[provider] = state
    }

    /// Seeds an empty ProviderUsage entry so the dropdown pill renders immediately
    /// after key save. The next fetcher poll overwrites it with real data.
    /// No-op if usage is already populated.
    func seedEmptyUsageIfNeeded(for provider: LLMProvider) {
        if usageMap[provider] == nil {
            usageMap[provider] = ProviderUsage.empty(provider: provider)
        }
    }

    // MARK: - Auth sync

    private func syncAuthStates() {
        for (provider, state) in ProviderAuthManager.shared.connectionStates {
            connectionStates[provider] = state
        }
    }

    private func observeAuthManager() {
        ProviderAuthManager.shared.$connectionStates
            .receive(on: RunLoop.main)
            .sink { [weak self] states in
                guard let self else { return }
                for (provider, state) in states {
                    let wasConnected = self.connectionStates[provider]?.isConnected == true
                    self.connectionStates[provider] = state
                    // Remove pill when a provider is disconnected
                    if wasConnected && !state.isConnected {
                        self.usageMap.removeValue(forKey: provider)
                        self.lingering.remove(provider)
                        self.lingerTimers[provider]?.invalidate()
                        self.lingerTimers[provider] = nil
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
