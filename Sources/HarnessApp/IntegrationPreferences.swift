import Foundation
import Security

enum OptionalIntegration: String, CaseIterable {
    case jev
    case omniRoute

    var enabledKey: String { "integration.\(rawValue).enabled" }
    var keychainService: String { "io.github.harness-mac.integration.\(rawValue)" }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: enabledKey)
    }

    func storedKey() -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var hasStoredKey: Bool {
        var query = keychainQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func saveKey(_ raw: String) throws {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw KeychainError.emptyKey }
        let data = Data(value.utf8)
        let status = SecItemUpdate(keychainQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.status(status) }
        var item = keychainQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.status(added) }
    }

    func removeKey() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
        UserDefaults.standard.set(false, forKey: enabledKey)
    }

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "api-key"]
    }
}

private enum KeychainError: LocalizedError {
    case emptyKey
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey: "Enter an API key before saving."
        case .status: "macOS Keychain could not save this key."
        }
    }
}
