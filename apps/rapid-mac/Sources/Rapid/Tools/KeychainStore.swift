import Foundation
import Security

/// Minimal Keychain wrapper for storing per-provider API keys.
///
/// We deliberately model the surface as a protocol so the test
/// suite can swap in an in-memory implementation rather than
/// touching the real system Keychain (which would prompt on
/// access, leak across test runs, and require manual cleanup).
protocol KeychainStoring: Sendable {
    func read(account: String) -> String?
    @discardableResult func write(account: String, secret: String) -> Bool
    @discardableResult func delete(account: String) -> Bool
}

/// Real-system implementation. Each entry is a ``kSecClassGenericPassword``
/// keyed by ``service = SystemKeychain.service`` + ``account``. We
/// use the generic-password class (not internet-password) because
/// Brave/Tavily keys are static credentials, not per-URL secrets.
///
/// Codex audit batch 6 finding (KeychainStore.swift:63, P2):
/// access policy is ``kSecAttrAccessibleWhenUnlockedThisDeviceOnly``.
/// The pre-audit shape used ``kSecAttrAccessibleAfterFirstUnlock``,
/// which (a) makes the key readable while the machine is locked
/// after the user's first post-boot login (any background process
/// running under the user account can read it) and (b) allows the
/// secret to be migrated off-device via Keychain sync / Time
/// Machine restore. ``WhenUnlockedThisDeviceOnly`` keeps the secret
/// readable only while the screen is unlocked and only on the
/// originating Mac.
struct SystemKeychain: KeychainStoring {
    static let service = "com.rapidmlx.rapid.api-keys"

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    @discardableResult
    func write(account: String, secret: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        // Try update first; if there's no existing item, fall
        // through to add. This is the canonical pattern for
        // "upsert" against the Keychain API. Update also bumps
        // the accessibility class so a pre-existing item written
        // with the prior (weaker) policy migrates forward on the
        // first write.
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound { return false }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    @discardableResult
    func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// In-memory backing for tests. Same surface as ``SystemKeychain``
/// but everything lives in a dictionary that dies with the
/// instance — no system-Keychain side effects, no popups, no
/// cross-test pollution. Thread-safe via a serial DispatchQueue
/// because the tool dispatcher may call into it from background
/// actor hops.
final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let queue = DispatchQueue(label: "rapid.in-memory-keychain")

    func read(account: String) -> String? {
        queue.sync { storage[account] }
    }

    @discardableResult
    func write(account: String, secret: String) -> Bool {
        queue.sync { storage[account] = secret }
        return true
    }

    @discardableResult
    func delete(account: String) -> Bool {
        queue.sync { _ = storage.removeValue(forKey: account) }
        return true
    }
}
