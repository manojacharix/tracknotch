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
    /// Providers that have been genuinely active at least once this session.
    /// Guards linger from firing on the very first updateUsage() call at startup.
    private var hasBeenActive: Set<LLMProvider> = []

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
            // If auth.json exists, use API-based rate-limit fetcher for real % data.
            // Otherwise fall back to the local SQLite thread-count estimate.
            let authPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/auth.json").path
            if FileManager.default.fileExists(atPath: authPath) {
                let cxf = CodexUsageFetcher.shared
                cxf.start()
                updateUsage(cxf.toProviderUsage())
                cxf.objectWillChange.sink { [weak self] _ in
                    Task { @MainActor in self?.updateUsage(cxf.toProviderUsage()) }
                }.store(in: &cancellables)
                // Also subscribe to monitor for activity / token count updates
                cx.objectWillChange.sink { [weak self] _ in
                    Task { @MainActor in self?.updateUsage(cxf.toProviderUsage()) }
                }.store(in: &cancellables)
            } else {
                updateUsage(cx.toProviderUsage())
                cx.objectWillChange.sink { [weak self] _ in
                    Task { @MainActor in self?.updateUsage(cx.toProviderUsage()) }
                }.store(in: &cancellables)
            }
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

        // Antigravity (Google's VS Code-based AI IDE; Gemini-backed)
        let ag = AntigravityMonitor.shared
        ag.start()
        if ag.isInstalled {
            markAutoConnected(.antigravity)
            updateUsage(ag.toProviderUsage())
            ag.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.updateUsage(ag.toProviderUsage()) }
            }.store(in: &cancellables)
        } else {
            evictStaleConnection(.antigravity)
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
        // isSessionActive drives activeProviders directly (not via usageMap).
        // Force objectWillChange so SwiftUI recomputes activeProviders when session state flips.
        monitor.$isSessionActive
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
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

    /// Monotonically incremented on every real (post-dedupe) StripView
    /// mouseEntered. Consumers (NotchRootView's hover gate) snapshot this
    /// value at the moment they want to gate hover, then wait for it to
    /// strictly exceed the snapshot before allowing hover to fire again.
    /// Event-counted gating is immune to mid-animation hover thrash and
    /// stale-flag races that timer-based gates suffer from.
    @Published var stripEnterCount: Int = 0

    /// Providers actively consuming OR still within the 2s linger window after going idle.
    ///
    /// When an Anthropic API key is configured AND claudeCode is active, suppress claudeCode
    /// from the active set. Claude Code CLI writes JSONL files even when billing via API key
    /// — both monitors fire, but only the API icon should light up the pill in that case.
    /// We use key presence (not isActivelyConsuming) because AnthropicUsageFetcher only polls
    /// every 5 minutes, so its isActivelyConsuming is almost always false during active use.
    var activeProviders: [LLMProvider] {
        let anthropicAPIConnected = connectionStates[.anthropicAPI]?.isConnected == true
        let claudeSessionActive = ClaudeCodeMonitor.shared.isSessionActive
        return orderedProviders.filter { provider in
            guard let usage = usageMap[provider] else { return false }
            if provider == .claudeCode && anthropicAPIConnected { return false }
            // Session-active keeps Claude in the active set through inter-turn gaps
            // (up to 30s after Stop) so the icon doesn't retract between messages.
            if provider == .claudeCode && claudeSessionActive { return true }
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
            // Mark that this provider has been active at least once this session.
            hasBeenActive.insert(provider)
        } else if !lingering.contains(provider) {
            // Only linger if the provider was genuinely active earlier this session.
            // Without this guard, the very first updateUsage() call on startup
            // (isActivelyConsuming=false, first-ever update) would immediately start
            // a 4s linger — making the icon show up on launch as if hovering.
            guard hasBeenActive.contains(provider) else { return }
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
                        self.hasBeenActive.remove(provider)
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
