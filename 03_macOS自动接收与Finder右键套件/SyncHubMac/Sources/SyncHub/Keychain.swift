// Keychain.swift — generic-password items under service "xyz.020814.synchub".
import Foundation
import Security

enum Keychain {
    static let service = "xyz.020814.synchub"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(account: String, password: String) -> Bool {
        let data = Data(password.utf8)
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var q = base(account)
        q[kSecValueData as String] = data
        q[kSecAttrLabel as String] = "SyncHub 跨端传输 (\(account))"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}
