import Foundation
import Security

/// The LM Studio bearer token, kept out of SQLite and UserDefaults per plan
/// §12. `SecItemAdd`/`SecItemCopyMatching`/etc. are synchronous, thread-safe
/// system calls, so this needs neither an actor nor async methods.
public struct KeychainTokenStore: Sendable {
    private let service: String
    private let account: String

    public init(service: String = "com.maiku.Maiku.lmstudio", account: String = "apiToken") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func token() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
                throw MaikuError.keychainFailure("Stored token was not readable text.")
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw MaikuError.keychainFailure(
                SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)")
        }
    }

    /// Saves `token`, or deletes the stored token when `token` is nil/empty.
    public func save(_ token: String?) throws {
        guard let token, !token.isEmpty else {
            try clear()
            return
        }
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw MaikuError.keychainFailure(
                    SecCopyErrorMessageString(addStatus, nil) as String? ?? "status \(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            throw MaikuError.keychainFailure(
                SecCopyErrorMessageString(updateStatus, nil) as String? ?? "status \(updateStatus)")
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MaikuError.keychainFailure(
                SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)")
        }
    }
}
