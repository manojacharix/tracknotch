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

    private init() {
        loadPersistedStates()
        loadAllKeysFromKeychain()
    }

    // MARK: - Save / Load API key

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
        SecItemAdd(query as CFDictionary, nil)
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

    // MARK: - Batch Keychain load (single access)

    /// Loads all stored API keys for our service in one Keychain query.
    private func loadAllKeysFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tracknotch.app",
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let value = String(data: data, encoding: .utf8) else { continue }

            // Map keychain account back to provider
            for provider in LLMProvider.apiKeyProviders {
                if account == keychainKey(for: provider) {
                    keyCache[provider] = value
                    break
                }
            }
        }
    }

    // MARK: - Persistence (connected/not — key stays in Keychain)

    private let defaultsKey = "providerConnectedStates"

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
