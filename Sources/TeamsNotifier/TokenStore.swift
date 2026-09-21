import Foundation
import Security

/// Keychain-backed secret store. Only the refresh token and learned owner
/// identity persist; access/skype tokens live in memory with expiries.
public final class TokenStore: Sendable {
    public static let service = "com.teamsnotifier.tokens"

    private let queue = DispatchQueue(label: "teamsnotifier.tokenstore")

    public init() {}

    // MARK: Refresh token

    public func readRefreshToken() -> String? {
        queue.sync { read(key: "refreshToken") }
    }

    public func writeRefreshToken(_ token: String) {
        queue.sync { write(key: "refreshToken", value: token) }
    }

    public func clearRefreshToken() {
        queue.sync { delete(key: "refreshToken") }
    }

    // MARK: Learned owner identity (from AAD token claims)

    public func readOwnerMRI() -> String? { queue.sync { read(key: "ownerMRI") } }
    public func writeOwnerMRI(_ mri: String) { queue.sync { write(key: "ownerMRI", value: mri) } }
    public func readOwnerUPN() -> String? { queue.sync { read(key: "ownerUPN") } }
    public func writeOwnerUPN(_ upn: String) { queue.sync { write(key: "ownerUPN", value: upn) } }

    // MARK: Keychain primitives

    private func read(key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    private func write(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func delete(key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
