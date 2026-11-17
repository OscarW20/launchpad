#if os(macOS)
import Foundation
import Security
import LaunchpadCore

/// Connector tokens and secret values, kept in the macOS Keychain (service "Launchpad").
final class KeychainSecretStore: SecretStore {
    private let service = "Launchpad"

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func secret(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Found, missing, or why the Keychain wouldn't answer (locked, access refused…), so a secret that's there but
    /// unreadable is never mistaken for one that isn't and replaced.
    func read(_ account: String) -> SecretRead {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data, let value = String(data: data, encoding: .utf8) else {
                return .failed("The Keychain item isn't readable text.")
            }
            return value.isEmpty ? .missing : .found(value)
        case errSecItemNotFound:
            return .missing
        default:
            return .failed((SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)")
        }
    }

    func setSecret(_ value: String?, for account: String) throws {
        let q = query(account)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}
#endif
