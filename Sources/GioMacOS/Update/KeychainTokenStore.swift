import Foundation
import Security

/// UP-09: the optional GitHub token (only needed while the release
/// repository is private), kept in the login Keychain as a generic
/// password. Gio reads it to send requests and never shows or logs it.
public protocol UpdateTokenStoring: Sendable {
    func read() -> String?
    /// Whether a token is saved, without reading its value (the Keychain
    /// never prompts for this, so the app can ask at launch).
    var hasToken: Bool { get }
    /// False when the Keychain refused.
    func save(_ token: String) -> Bool
    func clear() -> Bool
}

extension UpdateTokenStoring {
    public var hasToken: Bool {
        read() != nil
    }
}

/// The three Keychain calls the token store makes; a seam so the save
/// sequence is tested without touching the real Keychain.
public struct KeychainCalls: Sendable {
    public var copyMatching: @Sendable ([String: Any]) -> (OSStatus, CFTypeRef?)
    public var add: @Sendable ([String: Any]) -> OSStatus
    public var delete: @Sendable ([String: Any]) -> OSStatus

    public init(
        copyMatching: @escaping @Sendable ([String: Any]) -> (OSStatus, CFTypeRef?),
        add: @escaping @Sendable ([String: Any]) -> OSStatus,
        delete: @escaping @Sendable ([String: Any]) -> OSStatus
    ) {
        self.copyMatching = copyMatching
        self.add = add
        self.delete = delete
    }

    public static let system = KeychainCalls(
        copyMatching: { query in
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item)
        },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        delete: { SecItemDelete($0 as CFDictionary) }
    )
}

public struct KeychainTokenStore: UpdateTokenStoring {
    public static let service = "dev.gio.windowmanager.update-token"
    public static let account = "github"

    private let keychain: KeychainCalls

    public init(keychain: KeychainCalls = .system) {
        self.keychain = keychain
    }

    /// Explicitly a local (never iCloud-synchronized) item.
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = keychain.copyMatching(request)
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    public var hasToken: Bool {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return keychain.copyMatching(request).0 == errSecSuccess
    }

    /// UP-15: delete, then add. Never updates an existing item: one created
    /// beforehand by another program could carry an access list that lets
    /// that program read the token, while an added item always carries the
    /// access list Gio creates (Gio only).
    public func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        let deleted = keychain.delete(query)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            return false
        }
        var item = query
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrLabel as String] = "Gio update token (GitHub)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return keychain.add(item) == errSecSuccess
    }

    public func clear() -> Bool {
        let status = keychain.delete(query)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
