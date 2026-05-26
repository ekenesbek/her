import Foundation

public struct AuthUser: Codable, Equatable, Sendable {
    public let id: String
    public let provider: String
    public let email: String?
    public let name: String?

    public init(id: String, provider: String, email: String? = nil, name: String? = nil) {
        self.id = id
        self.provider = provider
        self.email = email
        self.name = name
    }

    public var displayName: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email.components(separatedBy: "@").first ?? email
        }
        return "Her"
    }
}

public struct AuthSession: Codable, Equatable, Sendable {
    public let token: String
    public let expiresAt: Date
    public let user: AuthUser
    public let isNewUser: Bool?

    public init(token: String, expiresAt: Date, user: AuthUser, isNewUser: Bool? = nil) {
        self.token = token
        self.expiresAt = expiresAt
        self.user = user
        self.isNewUser = isNewUser
    }

    public var isExistingAccount: Bool {
        isNewUser != true
    }
}
