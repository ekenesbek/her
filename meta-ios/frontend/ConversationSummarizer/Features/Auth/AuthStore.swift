import Foundation
import Security

struct AuthSession: Codable, Equatable {
    let token: String
    let expiresAt: Date
    let user: AuthUser
}

struct AuthUser: Codable, Equatable {
    let id: String
    let provider: String
    let email: String?
    let name: String?
}

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var session: AuthSession?

    private let keychainKey = "app.auth.session"

    init() {
        let restored = Self.read(key: keychainKey)
        session = restored
        TokenSource.shared.update(token: restored?.token)
    }

    var isAuthenticated: Bool {
        session != nil
    }

    var token: String? {
        session?.token
    }

    func setSession(_ session: AuthSession) {
        self.session = session
        Self.write(key: keychainKey, value: session)
        TokenSource.shared.update(token: session.token)
    }

    func clear() {
        session = nil
        Self.delete(key: keychainKey)
        TokenSource.shared.update(token: nil)
    }

    private static func read(key: String) -> AuthSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AuthSession.self, from: data)
    }

    private static func write(key: String, value: AuthSession) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else {
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class TokenSource: @unchecked Sendable {
    static let shared = TokenSource()

    private let lock = NSLock()
    private var stored: String?

    private init() {}

    var token: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func update(token: String?) {
        lock.lock()
        defer { lock.unlock() }
        stored = token
    }
}
