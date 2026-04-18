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

    /// Linger timers: keep a provider visible for 2s after it stops actively consuming,
    /// smoothing over the 1s poll gap so icons don't flicker in and out.
    private static let lingerDuration: TimeInterval = 2
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
            updateUsage(cc.toProviderUsage())
            cc.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateUsage(cc.toProviderUsage())
                }
            }.store(in: &cancellables)
        }

        // Codex
        let cx = CodexMonitor.shared
        cx.start()
        if cx.isInstalled {
            markAutoConnected(.codex)
            updateUsage(cx.toProviderUsage())
            cx.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateUsage(cx.toProviderUsage())
                }
            }.store(in: &cancellables)
        }

        // Cursor
        let cu = CursorMonitor.shared
        cu.start()
        if cu.isInstalled {
            markAutoConnected(.cursorIDE)
            updateUsage(cu.toProviderUsage())
            cu.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateUsage(cu.toProviderUsage())
                }
            }.store(in: &cancellables)
        }

        // ChatGPT Desktop
        let cd = ChatGPTDesktopMonitor.shared
        cd.start()
        if cd.isInstalled {
            markAutoConnected(.chatGPTDesktop)
            updateUsage(cd.toProviderUsage())
            cd.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateUsage(cd.toProviderUsage())
                }
            }.store(in: &cancellables)
        }
    }

    private func startAPIFetchers() {
        // Only start if an API key is already saved
        if ProviderAuthManager.shared.loadAPIKey(for: .openAIAPI) != nil {
            OpenAIUsageFetcher.shared.start()
        }
        if ProviderAuthManager.shared.loadAPIKey(for: .anthropicAPI) != nil {
            AnthropicUsageFetcher.shared.start()
        }
    }

    private func markAutoConnected(_ provider: LLMProvider) {
        connectionStates[provider] = .connected
        ProviderAuthManager.shared.connectionStates[provider] = .connected
    }

    // MARK: - Active Providers (for wing display)

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
                    self.connectionStates[provider] = state
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
