import Foundation
import Security

enum KeychainStore {
    private static let service = "app.beacon.ios"
    private static let aprsAccount = "aprs-is-passcode"

    static var aprsPasscode: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: aprsAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: aprsAccount
            ]
            SecItemDelete(query as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var item = query
            item[kSecValueData as String] = Data(newValue.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
