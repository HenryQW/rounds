import Foundation
import RoundsCore
import Security

/// The signed app and its embedded service authenticate each other before sending Keychain data.
@objc(RoundsLinearKeychain)
private protocol LinearKeychainProtocol {
    @objc(readItem:account:withReply:) func readItem(_ service: String, account: String, reply: (Data?, Int32) -> Void)
    @objc(saveItem:account:data:withReply:) func saveItem(_ service: String, account: String, data: Data, reply: (Int32) -> Void)
    @objc(removeItem:account:withReply:) func removeItem(_ service: String, account: String, reply: (Int32) -> Void)
}

/// One Rounds item in the login Keychain: the Linear key, or the values of one push channel. Call on keychainIO.
/// Signed builds go through the embedded service, whose code signature stays the same across app updates, so the
/// user's Always Allow stays valid. An ad-hoc development build uses the login Keychain directly.
struct KeychainItem {
    let service: String
    let account: String

    static let linearKey = KeychainItem(service: "com.henryqw.rounds.linear", account: "api-key")
    static func push(_ channel: PushChannel) -> KeychainItem { KeychainItem(service: "com.henryqw.rounds.push", account: channel.rawValue) }

    private static let helper = "com.henryqw.rounds.linear-keychain"
    private static let requirement = "identifier \"\(helper)\" and certificate leaf = H\"981b67fc67872c2a9dd89da60aa84ed6690c62a8\""
    private static let usesHelper = Bundle.main.object(forInfoDictionaryKey: "RoundsLinearKeychainHelper") as? Bool == true

    struct StatusError: Error {
        let status: OSStatus
    }

    /// The item's data, or nil when there is no item.
    func read() throws -> Data? {
        var data: Data?
        var status = errSecNotAvailable
        if Self.usesHelper {
            Self.withHelper { $0.readItem(service, account: account) { (data, status) = ($0, $1) } }
        } else {
            var value: CFTypeRef?
            status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &value)
            data = value as? Data
        }
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data else { throw StatusError(status: errSecDecode) }
        return data
    }

    /// Update, then add: a failed write keeps the old value.
    func save(_ data: Data) throws {
        var status = errSecNotAvailable
        if Self.usesHelper {
            Self.withHelper { $0.saveItem(service, account: account, data: data) { status = $0 } }
        } else {
            let changes = [kSecValueData as String: data]
            status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(changes) { $1 } as CFDictionary, nil)
            }
        }
        try check(status)
    }

    func delete() throws {
        var status = errSecNotAvailable
        if Self.usesHelper {
            Self.withHelper { $0.removeItem(service, account: account) { status = $0 } }
        } else {
            status = SecItemDelete(query as CFDictionary)
        }
        if status != errSecItemNotFound { try check(status) }
    }

    private static func withHelper(_ action: (LinearKeychainProtocol) -> Void) {
        let connection = NSXPCConnection(serviceName: helper)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: LinearKeychainProtocol.self)
        connection.activate()
        defer { connection.invalidate() }
        let remote = connection.synchronousRemoteObjectProxyWithErrorHandler { error in
            log.error("keychain: helper failed (\((error as NSError).code))")
        }
        if let helper = remote as? LinearKeychainProtocol { action(helper) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            log.error("keychain: \(service, privacy: .public) operation failed (\(status))")
            throw StatusError(status: status)
        }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

/// The Linear API key. Call on keychainIO.
enum LinearKey {
    static func read() throws -> String {
        guard let data = try KeychainItem.linearKey.read() else { return "" }
        guard let key = String(data: data, encoding: .utf8) else { throw KeychainItem.StatusError(status: errSecDecode) }
        return key
    }

    static func save(_ key: String) throws { try KeychainItem.linearKey.save(Data(key.utf8)) }

    static func delete() throws { try KeychainItem.linearKey.delete() }
}
