import Foundation
import Security

struct ReceiverIdentity: Codable {
    let id: String
    let token: String

    static func load() throws -> Self {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "net.bitcreative.iospublish.receiver", kSecAttrAccount as String: "identity"]
        var result: CFTypeRef?
        let status = SecItemCopyMatching((query.merging([kSecReturnData as String: true]) { _, new in new }) as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return try JSONDecoder().decode(Self.self, from: data)
        }
        guard status == errSecItemNotFound else { throw IdentityError.keychain(status) }
        let identity = Self(id: UUID().uuidString, token: (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: ""))
        var item = query
        item[kSecValueData as String] = try JSONEncoder().encode(identity)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let saved = SecItemAdd(item as CFDictionary, nil)
        guard saved == errSecSuccess else { throw IdentityError.keychain(saved) }
        return identity
    }
}

private enum IdentityError: LocalizedError {
    case keychain(OSStatus)
    var errorDescription: String? { "Couldn’t load this device’s identity. Try opening Publish again." }
}
