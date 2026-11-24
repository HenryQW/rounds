import Foundation
import Security

/// The signed app and its embedded service authenticate each other before sending Keychain data.
@objc(RoundsLinearKeychain)
private protocol LinearKeychainProtocol {
    @objc(readKeyWithReply:) func readKey(reply: (Data?, Int32) -> Void)
    @objc(saveKey:withReply:) func saveKey(_ data: Data, reply: (Int32) -> Void)
    @objc(removeKeyWithReply:) func removeKey(reply: (Int32) -> Void)
}

/// Call on keychainIO. An ad-hoc development build uses the login Keychain directly.
enum LinearKey {
    private static let service = "com.henryqw.rounds.linear-keychain"
    private static let requirement = "identifier \"\(service)\" and certificate leaf = H\"981b67fc67872c2a9dd89da60aa84ed6690c62a8\""
    private static let usesHelper = Bundle.main.object(forInfoDictionaryKey: "RoundsLinearKeychainHelper") as? Bool == true

    private struct StatusError: Error {
        let status: OSStatus
    }

    static func read() throws -> String {
        var data: Data?
        var status = errSecNotAvailable
        if usesHelper {
            withHelper { $0.readKey { (data, status) = ($0, $1) } }
        } else {
            var value: CFTypeRef?
            var query = item
            query[kSecReturnData as String] = true
            status = SecItemCopyMatching(query as CFDictionary, &value)
            data = value as? Data
        }
        if status == errSecItemNotFound { return "" }
        try check(status)
        guard let data, let key = String(data: data, encoding: .utf8) else { throw StatusError(status: errSecDecode) }
        return key
    }

    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        var status = errSecNotAvailable
        if usesHelper {
            withHelper { $0.saveKey(data) { status = $0 } }
        } else {
            let changes = [kSecValueData as String: data]
            status = SecItemUpdate(item as CFDictionary, changes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(item.merging(changes) { $1 } as CFDictionary, nil)
            }
        }
        try check(status)
    }

    static func delete() throws {
        var status = errSecNotAvailable
        if usesHelper {
            withHelper { $0.removeKey { status = $0 } }
        } else {
            status = SecItemDelete(item as CFDictionary)
        }
        if status != errSecItemNotFound { try check(status) }
    }

    private static func withHelper(_ action: (LinearKeychainProtocol) -> Void) {
        let connection = NSXPCConnection(serviceName: service)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: LinearKeychainProtocol.self)
        connection.activate()
        defer { connection.invalidate() }
        let remote = connection.synchronousRemoteObjectProxyWithErrorHandler { error in
            log.error("tickets: Linear Keychain helper failed (\((error as NSError).code))")
        }
        if let helper = remote as? LinearKeychainProtocol { action(helper) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            log.error("tickets: Linear Keychain operation failed (\(status))")
            throw StatusError(status: status)
        }
    }

    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.henryqw.rounds.linear", kSecAttrAccount as String: "api-key"]
    }
}
