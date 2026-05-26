import Foundation
import HerShared

@MainActor
final class HerAuthStore: ObservableObject {
    @Published private(set) var session: AuthSession?
    @Published private(set) var errorMessage: String?

    private let keychain = KeychainSessionStore(account: "app.auth.session")
    private let environmentToken: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        environmentToken = environment["HER_AUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let restored = keychain.read()
        session = restored
        TokenSource.shared.update(token: restored?.token ?? environmentToken)
    }

    var token: String? {
        session?.token ?? environmentToken
    }

    var hasEnvironmentToken: Bool {
        environmentToken != nil
    }

    func setSession(_ session: AuthSession) {
        self.session = session
        errorMessage = nil
        keychain.write(session)
        TokenSource.shared.update(token: session.token)
    }

    func updateUser(_ user: AuthUser, isNewUser: Bool? = nil) {
        guard let session else {
            return
        }
        setSession(
            AuthSession(
                token: session.token,
                expiresAt: session.expiresAt,
                user: user,
                isNewUser: isNewUser ?? session.isNewUser
            )
        )
    }

    func persistEnvironmentToken(user: AuthUser) {
        guard let environmentToken else {
            return
        }
        setSession(
            AuthSession(
                token: environmentToken,
                expiresAt: KeychainSessionStore.expirationDate(fromJWT: environmentToken)
                    ?? Date().addingTimeInterval(60 * 60 * 24 * 30),
                user: user,
                isNewUser: false
            )
        )
    }

    func clear() {
        session = nil
        errorMessage = nil
        keychain.delete()
        TokenSource.shared.update(token: environmentToken)
    }

    func setError(_ message: String?) {
        errorMessage = message
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
