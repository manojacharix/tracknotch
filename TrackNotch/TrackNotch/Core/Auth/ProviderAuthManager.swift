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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.tracknotch.app",
            kSecValueData as String: data
        ]
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.tracknotch.app"
        ]
        SecItemDelete(query as CFDictionary)
        keyCache.removeValue(forKey: provider)
        connectionStates[provider] = .notConfigured
        persistState(for: provider, connected: false)
    }

    // MARK: - OAuth Token (for rate-limit header probing)

    func saveOAuthToken(_ value: String, for provider: LLMProvider) {
        let key = oauthKeychainKey(for: provider)
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.tracknotch.app",
            kSecValueData as String: data
        ]
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.tracknotch.app"
        ]
        SecItemDelete(query as CFDictionary)
        oauthCache.removeValue(forKey: provider)
    }

    private func oauthKeychainKey(for provider: LLMProvider) -> String {
        "oauthtoken_\(provider.rawValue)"
    }

    // MARK: - Batch Keychain load (single access)

    /// Loads all stored API keys for our service.
    /// Two-step strategy avoids the `errSecParam (-50)` failure that
    /// `kSecReturnData + kSecReturnAttributes + kSecMatchLimitAll` triggers
    /// together on some macOS versions:
    ///   1. List accounts (attributes only) with `kSecMatchLimitAll`.
    ///   2. Fetch data per account with `kSecMatchLimitOne`.
    private func loadAllKeysFromKeychain() {
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tracknotch.app",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var listResult: AnyObject?
        let listStatus = SecItemCopyMatching(listQuery as CFDictionary, &listResult)
        if listStatus == errSecItemNotFound {
            TNLog.info("[Auth] Keychain returned no items", category: .auth)
            return
        }
        if listStatus != errSecSuccess {
            TNLog.warn("[Auth] Keychain account list failed: OSStatus \(listStatus)", category: .auth)
            return
        }
        guard let items = listResult as? [[String: Any]] else { return }
        TNLog.info("[Auth] Found \(items.count) keychain entries — fetching values", category: .auth)

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            guard let value = readKeychainValue(account: account) else { continue }

            // Map keychain account back to provider
            if account.hasPrefix("oauthtoken_") {
                for provider in LLMProvider.allCases {
                    if account == oauthKeychainKey(for: provider) {
                        oauthCache[provider] = value
                        break
                    }
                }
            } else {
                for provider in LLMProvider.apiKeyProviders {
                    if account == keychainKey(for: provider) {
                        keyCache[provider] = value
                        break
                    }
                }
            }
        }
    }

    /// Fetches a single keychain value by account name. Used by the two-step
    /// batch loader above.
    private func readKeychainValue(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tracknotch.app",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
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
