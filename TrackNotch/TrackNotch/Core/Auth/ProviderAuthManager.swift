import Foundation
import Security

/// Manages API key storage per provider via Keychain.
/// Local file monitors (Claude Code, Cursor, etc.) don't need auth — they auto-connect.
/// Keys are loaded once at init into an in-memory cache to avoid repeated Keychain prompts.
@MainActor
final class ProviderAuthManager: ObservableObject {
    static let shared = ProviderAuthManager()

    @Published var connectionStates: [LLMProvider: ProviderConnectionState] = [:]

    /// In-memory cache — loaded once from Keychain at init
    private var keyCache: [LLMProvider: String] = [:]
    private var oauthCache: [LLMProvider: String] = [:]

    private init() {
        loadPersistedStates()
        loadAllKeysFromKeychain()
    }

    // MARK: - Save / Load API key

    @Published private(set) var lastKeychainError: String?

    func saveAPIKey(_ value: String, for provider: LLMProvider) {
        let key = keychainKey(for: provider)
        guard let data = value.data(using: .utf8) else { return }
        var query = baseItemQuery(account: key)
        query[kSecValueData as String] = data
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            lastKeychainError = "Failed to save API key: OSStatus \(status)"
            TNLog.error("[Auth] Keychain save failed for \(provider.rawValue): OSStatus \(status)", category: .auth)
            return
        }
        lastKeychainError = nil
        keyCache[provider] = value
        connectionStates[provider] = .connected
        persistState(for: provider, connected: true)
    }

    func loadAPIKey(for provider: LLMProvider) -> String? {
        return keyCache[provider]
    }

    func disconnect(_ provider: LLMProvider) {
        let key = keychainKey(for: provider)
        let query = baseItemQuery(account: key)
        SecItemDelete(query as CFDictionary)
        keyCache.removeValue(forKey: provider)
        connectionStates[provider] = .notConfigured
        persistState(for: provider, connected: false)
    }

    // MARK: - OAuth Token (for rate-limit header probing)

    func saveOAuthToken(_ value: String, for provider: LLMProvider) {
        let key = oauthKeychainKey(for: provider)
        guard let data = value.data(using: .utf8) else { return }
        var query = baseItemQuery(account: key)
        query[kSecValueData as String] = data
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            lastKeychainError = "Failed to save OAuth token: OSStatus \(status)"
            TNLog.error("[Auth] Keychain OAuth save failed for \(provider.rawValue): OSStatus \(status)", category: .auth)
            return
        }
        lastKeychainError = nil
        oauthCache[provider] = value
    }

    func loadOAuthToken(for provider: LLMProvider) -> String? {
        return oauthCache[provider]
    }

    func disconnectOAuth(_ provider: LLMProvider) {
        let key = oauthKeychainKey(for: provider)
        let query = baseItemQuery(account: key)
        SecItemDelete(query as CFDictionary)
        oauthCache.removeValue(forKey: provider)
    }

    private func oauthKeychainKey(for provider: LLMProvider) -> String {
        "oauthtoken_\(provider.rawValue)"
    }

    // MARK: - Batch Keychain load (single access)

    /// Loads all stored API keys and OAuth tokens for our service in a single
    /// `SecItemCopyMatching` call so macOS shows at most one auth prompt per
    /// launch. On macOS versions that reject the combined
    /// `kSecReturnData + kSecReturnAttributes + kSecMatchLimitAll` query with
    /// `errSecParam (-50)`, falls back to the legacy two-step path
    /// (list accounts, then fetch each value).
    private func loadAllKeysFromKeychain() {
        var combinedQuery = baseServiceQuery()
        combinedQuery[kSecReturnAttributes as String] = true
        combinedQuery[kSecReturnData as String] = true
        combinedQuery[kSecMatchLimit as String] = kSecMatchLimitAll
        var combinedResult: AnyObject?
        let status = SecItemCopyMatching(combinedQuery as CFDictionary, &combinedResult)

        if status == errSecItemNotFound {
            TNLog.info("[Auth] Keychain returned no items", category: .auth)
            return
        }

        if status == errSecSuccess, let items = combinedResult as? [[String: Any]] {
            TNLog.info("[Auth] Loaded \(items.count) keychain entries in single call", category: .auth)
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String,
                      let data = item[kSecValueData as String] as? Data,
                      let value = String(data: data, encoding: .utf8) else { continue }
                routeKeychainEntry(account: account, value: value)
            }
            return
        }

        // Legacy fallback: pre-macOS-13 systems may return errSecParam for the
        // combined query. Fall back to list-then-fetch-per-account.
        TNLog.warn("[Auth] Combined keychain query failed (OSStatus \(status)) — falling back to two-step load", category: .auth)
        loadAllKeysTwoStep()
    }

    /// Legacy two-step fallback: list accounts, then read each value.
    private func loadAllKeysTwoStep() {
        var listQuery = baseServiceQuery()
        listQuery[kSecReturnAttributes as String] = true
        listQuery[kSecMatchLimit as String] = kSecMatchLimitAll
        var listResult: AnyObject?
        let listStatus = SecItemCopyMatching(listQuery as CFDictionary, &listResult)
        if listStatus == errSecItemNotFound { return }
        if listStatus != errSecSuccess {
            TNLog.warn("[Auth] Keychain account list failed: OSStatus \(listStatus)", category: .auth)
            return
        }
        guard let items = listResult as? [[String: Any]] else { return }
        TNLog.info("[Auth] Found \(items.count) keychain entries — fetching values (two-step)", category: .auth)

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            guard let value = readKeychainValue(account: account) else { continue }
            routeKeychainEntry(account: account, value: value)
        }
    }

    /// Maps a keychain account name back to its provider and stores the value
    /// in the appropriate in-memory cache.
    private func routeKeychainEntry(account: String, value: String) {
        if account.hasPrefix("oauthtoken_") {
            for provider in LLMProvider.allCases where account == oauthKeychainKey(for: provider) {
                oauthCache[provider] = value
                return
            }
        } else {
            for provider in LLMProvider.apiKeyProviders where account == keychainKey(for: provider) {
                keyCache[provider] = value
                return
            }
        }
    }

    /// Fetches a single keychain value by account name. Used by the two-step
    /// batch loader above.
    private func readKeychainValue(account: String) -> String? {
        var query = baseItemQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Query builders

    /// Base query for a single keychain item (account + service).
    /// Uses the legacy file keychain — required for unsandboxed apps
    /// without a paid Developer ID (data-protection keychain rejects
    /// writes with errSecMissingEntitlement in that setup).
    private func baseItemQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tracknotch.app",
            kSecAttrAccount as String: account
        ]
    }

    /// Base query scoped to the service (no account) — for list/batch reads.
    private func baseServiceQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tracknotch.app"
        ]
    }

    // MARK: - Persistence (connected/not — key stays in Keychain)

    private let defaultsKey = "providerConnectedStates"

    func clearPersistedState(for provider: LLMProvider) {
        persistState(for: provider, connected: false)
    }

    private func persistState(for provider: LLMProvider, connected: Bool) {
        var states = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Bool] ?? [:]
        states[provider.rawValue] = connected
        UserDefaults.standard.set(states, forKey: defaultsKey)
    }

    private func loadPersistedStates() {
        let states = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Bool] ?? [:]
        for (raw, connected) in states {
            guard let provider = LLMProvider(rawValue: raw) else { continue }
            connectionStates[provider] = connected ? .connected : .notConfigured
        }
    }

    private func keychainKey(for provider: LLMProvider) -> String {
        "apikey_\(provider.rawValue)"
    }
}
