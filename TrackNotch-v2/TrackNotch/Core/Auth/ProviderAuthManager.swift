import Foundation
import Security

/// Manages API key + OAuth token storage via Keychain.
///
/// **Single-item storage strategy.** All secrets for all providers live in ONE
/// Keychain entry (`service=com.tracknotch.app account=all_secrets`) as a JSON
/// blob. This means the OS shows AT MOST ONE auth prompt per launch, regardless
/// of how many providers are configured. Per-item storage (the previous
/// approach) caused N prompts on every launch under ad-hoc signing because the
/// legacy file keychain attaches a per-item ACL.
///
/// On first launch after upgrading from per-item storage, this class
/// automatically migrates any pre-existing per-account entries into the new
/// blob and deletes the originals.
@MainActor
final class ProviderAuthManager: ObservableObject {
    static let shared = ProviderAuthManager()

    @Published var connectionStates: [LLMProvider: ProviderConnectionState] = [:]
    @Published private(set) var lastKeychainError: String?

    /// In-memory cache. Source of truth between launches is the JSON blob in
    /// Keychain; we read it once at init and write it back on every change.
    private var keyCache: [LLMProvider: String] = [:]
    private var oauthCache: [LLMProvider: String] = [:]

    private init() {
        loadPersistedStates()
        loadFromKeychain()
        migrateLegacyEntriesIfNeeded()
    }

    // MARK: - Public API

    func saveAPIKey(_ value: String, for provider: LLMProvider) {
        // Snapshot in case keychain write fails; we'll roll the cache back so
        // in-session state matches what's actually persisted on disk.
        let previous = keyCache[provider]
        keyCache[provider] = value
        if persistBlob() {
            connectionStates[provider] = .connected
            persistState(for: provider, connected: true)
        } else {
            // Roll back so the user isn't misled into thinking the key is
            // saved when it would be lost on next launch.
            if let previous { keyCache[provider] = previous }
            else { keyCache.removeValue(forKey: provider) }
        }
    }

    func loadAPIKey(for provider: LLMProvider) -> String? {
        keyCache[provider]
    }

    func disconnect(_ provider: LLMProvider) {
        let previous = keyCache[provider]
        keyCache.removeValue(forKey: provider)
        if persistBlob() {
            connectionStates[provider] = .notConfigured
            persistState(for: provider, connected: false)
        } else {
            // Restore the in-memory key so it matches what's still in the
            // keychain. Otherwise the user sees "disconnected" but the key
            // would reappear on next launch.
            if let previous { keyCache[provider] = previous }
        }
    }

    func saveOAuthToken(_ value: String, for provider: LLMProvider) {
        let previous = oauthCache[provider]
        oauthCache[provider] = value
        if !persistBlob() {
            if let previous { oauthCache[provider] = previous }
            else { oauthCache.removeValue(forKey: provider) }
        }
    }

    func loadOAuthToken(for provider: LLMProvider) -> String? {
        oauthCache[provider]
    }

    func disconnectOAuth(_ provider: LLMProvider) {
        let previous = oauthCache[provider]
        oauthCache.removeValue(forKey: provider)
        if !persistBlob() {
            if let previous { oauthCache[provider] = previous }
        }
    }

    func clearPersistedState(for provider: LLMProvider) {
        persistState(for: provider, connected: false)
    }

    // MARK: - Single-blob persistence

    private static let blobAccount = "all_secrets"
    private static let service = "com.tracknotch.app"

    /// Wire format. Versioned so future schema changes can migrate cleanly.
    private struct SecretsBlob: Codable {
        var version: Int = 1
        var apiKeys: [String: String]   = [:]   // keyed by LLMProvider.rawValue
        var oauthTokens: [String: String] = [:]
    }

    private func loadFromKeychain() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.blobAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecMatchLimit as String)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let blob = try? JSONDecoder().decode(SecretsBlob.self, from: data) else {
                TNLog.warn("[Auth] Keychain blob present but undecodable; treating as empty", category: .auth)
                return
            }
            applyBlob(blob)
            TNLog.info("[Auth] Loaded \(blob.apiKeys.count) API keys + \(blob.oauthTokens.count) OAuth tokens (single keychain read)", category: .auth)
        case errSecItemNotFound:
            // First launch with the new format, or after wipe. Caches stay empty.
            return
        default:
            TNLog.warn("[Auth] Keychain blob read failed: OSStatus \(status)", category: .auth)
        }
    }

    /// Write the current in-memory caches back as the single keychain blob.
    /// Returns true on success.
    @discardableResult
    private func persistBlob() -> Bool {
        var blob = SecretsBlob()
        for (provider, value) in keyCache { blob.apiKeys[provider.rawValue] = value }
        for (provider, value) in oauthCache { blob.oauthTokens[provider.rawValue] = value }

        guard let data = try? JSONEncoder().encode(blob) else {
            lastKeychainError = "Failed to encode secrets blob"
            return false
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.blobAccount
        ]

        // Update if exists, otherwise add. We don't delete-and-add because
        // that triggers two ACL grants instead of one.
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            lastKeychainError = nil
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                lastKeychainError = nil
                return true
            }
            lastKeychainError = "Keychain add failed: OSStatus \(addStatus)"
            TNLog.error("[Auth] Keychain add failed: OSStatus \(addStatus)", category: .auth)
            return false
        }
        lastKeychainError = "Keychain update failed: OSStatus \(updateStatus)"
        TNLog.error("[Auth] Keychain update failed: OSStatus \(updateStatus)", category: .auth)
        return false
    }

    private func applyBlob(_ blob: SecretsBlob) {
        for (raw, value) in blob.apiKeys {
            guard let provider = LLMProvider(rawValue: raw) else { continue }
            keyCache[provider] = value
        }
        for (raw, value) in blob.oauthTokens {
            guard let provider = LLMProvider(rawValue: raw) else { continue }
            oauthCache[provider] = value
        }
    }

    // MARK: - Legacy migration

    /// On first launch after upgrading from per-item storage, scan for the old
    /// `apikey_*` / `oauthtoken_*` accounts under our service, fold them into
    /// the new blob, write the blob, and delete the legacy entries.
    private func migrateLegacyEntriesIfNeeded() {
        // Skip if blob already populated — migration is one-time. (We can't
        // easily distinguish "blob exists with no values" from "no blob", but
        // the worst case is a no-op pass that re-checks legacy entries each
        // launch; checking the cache state is sufficient.)
        var didMigrate = false

        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var listResult: AnyObject?
        let listStatus = SecItemCopyMatching(listQuery as CFDictionary, &listResult)
        guard listStatus == errSecSuccess, let items = listResult as? [[String: Any]] else { return }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            // Skip the new blob entry itself.
            if account == Self.blobAccount { continue }
            // Only migrate accounts that match our legacy naming.
            let isLegacyAPIKey = account.hasPrefix("apikey_")
            let isLegacyOAuth = account.hasPrefix("oauthtoken_")
            guard isLegacyAPIKey || isLegacyOAuth else { continue }

            guard let value = readSingleKeychainValue(account: account) else { continue }

            if isLegacyAPIKey {
                let raw = String(account.dropFirst("apikey_".count))
                if let provider = LLMProvider(rawValue: raw), keyCache[provider] == nil {
                    keyCache[provider] = value
                }
            } else if isLegacyOAuth {
                let raw = String(account.dropFirst("oauthtoken_".count))
                if let provider = LLMProvider(rawValue: raw), oauthCache[provider] == nil {
                    oauthCache[provider] = value
                }
            }
            didMigrate = true
        }

        guard didMigrate else { return }

        TNLog.info("[Auth] Migrating legacy per-account keychain entries to single blob", category: .auth)
        if persistBlob() {
            // Delete legacy entries only after a successful blob write.
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String else { continue }
                if account == Self.blobAccount { continue }
                guard account.hasPrefix("apikey_") || account.hasPrefix("oauthtoken_") else { continue }
                let delQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: Self.service,
                    kSecAttrAccount as String: account
                ]
                SecItemDelete(delQuery as CFDictionary)
            }
            // Restore connection state for migrated providers.
            for provider in keyCache.keys {
                connectionStates[provider] = .connected
                persistState(for: provider, connected: true)
            }
        }
    }

    private func readSingleKeychainValue(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Connection state persistence (no secrets, just the connected/not flag)

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
}
