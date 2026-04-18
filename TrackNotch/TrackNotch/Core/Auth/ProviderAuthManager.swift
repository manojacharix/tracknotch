import Foundation
import Security

/// Manages API key storage per provider via Keychain.
/// Local file monitors (Claude Code, Cursor, etc.) don't need auth — they auto-connect.
@MainActor
final class ProviderAuthManager: ObservableObject {
    static let shared = ProviderAuthManager()

    @Published var connectionStates: [LLMProvider: ProviderConnectionState] = [:]

    private init() {
        loadPersistedStates()
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
        connectionStates[provider] = .connected
        persistState(for: provider, connected: true)
    }

    func loadAPIKey(for provider: LLMProvider) -> String? {
        let key = keychainKey(for: provider)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.tracknotch.app",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func disconnect(_ provider: LLMProvider) {
        let key = keychainKey(for: provider)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.tracknotch.app"
        ]
        SecItemDelete(query as CFDictionary)
        connectionStates[provider] = .notConfigured
        persistState(for: provider, connected: false)
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
