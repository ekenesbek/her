import Foundation

enum AuthClientError: LocalizedError {
    case backendUnavailable
    case backendFailed(statusCode: Int, detail: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            return "Backend is not configured."
        case let .backendFailed(statusCode, detail):
            if let detail, !detail.isEmpty {
                return "Auth failed (\(statusCode)): \(detail)"
            }
            return "Auth failed (\(statusCode))"
        case .invalidResponse:
            return "Auth backend returned an invalid response."
        }
    }
}

struct AuthClient {
    let baseURL: URL
    private let session: URLSession

    init?(baseURL: URL? = AppConfig.backendBaseURL, session: URLSession = .shared) {
        guard let baseURL else {
            return nil
        }
        self.baseURL = baseURL
        self.session = session
    }

    func signInWithApple(
        identityToken: String,
        fullName: String?,
        email: String?
    ) async throws -> AuthSession {
        let body = AppleSignInBody(
            identityToken: identityToken,
            fullName: fullName,
            email: email
        )
        return try await postAuth(path: "v1/auth/apple", body: body)
    }

    func signInWithGoogle(idToken: String) async throws -> AuthSession {
        let body = GoogleSignInBody(idToken: idToken)
        return try await postAuth(path: "v1/auth/google", body: body)
    }

    func fetchCurrentUser(token: String) async throws -> AuthUser {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/auth/me"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AuthClientError.backendFailed(
                statusCode: httpResponse.statusCode,
                detail: Self.errorDetail(from: data)
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AuthUser.self, from: data)
    }

    private func postAuth<Body: Encodable>(path: String, body: Body) async throws -> AuthSession {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AuthClientError.backendFailed(
                statusCode: httpResponse.statusCode,
                detail: Self.errorDetail(from: data)
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(AuthResponseBody.self, from: data)
        return AuthSession(token: payload.token, expiresAt: payload.expiresAt, user: payload.user)
    }

    private static func errorDetail(from data: Data) -> String? {
        struct DetailEnvelope: Decodable { let detail: String? }
        if let envelope = try? JSONDecoder().decode(DetailEnvelope.self, from: data),
           let detail = envelope.detail, !detail.isEmpty {
            return detail
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AuthResponseBody: Decodable {
    let token: String
    let expiresAt: Date
    let user: AuthUser
}

private struct AppleSignInBody: Encodable {
    let identityToken: String
    let fullName: String?
    let email: String?
}

private struct GoogleSignInBody: Encodable {
    let idToken: String
}
