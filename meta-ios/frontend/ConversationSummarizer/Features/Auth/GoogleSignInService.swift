import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

enum GoogleSignInError: LocalizedError {
    case notConfigured
    case authorizationCancelled
    case authorizationFailed(String)
    case missingAuthorizationCode
    case tokenExchangeFailed(String)
    case missingIdToken

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google sign-in is not configured. Set GoogleClientID in Info.plist."
        case .authorizationCancelled:
            return "Google sign-in was cancelled."
        case .authorizationFailed(let detail):
            return detail
        case .missingAuthorizationCode:
            return "Google did not return an authorization code."
        case .tokenExchangeFailed(let detail):
            return "Google token exchange failed: \(detail)"
        case .missingIdToken:
            return "Google token response did not include an id_token."
        }
    }
}

struct GoogleSignInResult {
    let idToken: String
}

@MainActor
final class GoogleSignInService: NSObject {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func signIn() async throws -> GoogleSignInResult {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String,
              !clientID.isEmpty else {
            throw GoogleSignInError.notConfigured
        }

        let reversedScheme = "com.googleusercontent.apps." + clientID.replacingOccurrences(
            of: ".apps.googleusercontent.com",
            with: ""
        )
        let redirectURI = "\(reversedScheme):/oauth2redirect"

        let codeVerifier = Self.makeCodeVerifier()
        let codeChallenge = Self.makeCodeChallenge(verifier: codeVerifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authURL = components.url else {
            throw GoogleSignInError.authorizationFailed("Could not build Google auth URL.")
        }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let webSession = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: reversedScheme
            ) { url, error in
                if let nsError = error as? NSError,
                   nsError.domain == ASWebAuthenticationSessionError.errorDomain,
                   nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    continuation.resume(throwing: GoogleSignInError.authorizationCancelled)
                    return
                }
                if let error {
                    continuation.resume(throwing: GoogleSignInError.authorizationFailed(error.localizedDescription))
                    return
                }
                guard let url else {
                    continuation.resume(throwing: GoogleSignInError.missingAuthorizationCode)
                    return
                }
                continuation.resume(returning: url)
            }
            webSession.presentationContextProvider = self
            webSession.prefersEphemeralWebBrowserSession = false
            webSession.start()
        }

        guard let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
              let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw GoogleSignInError.missingAuthorizationCode
        }

        return try await exchangeCode(
            code: code,
            verifier: codeVerifier,
            clientID: clientID,
            redirectURI: redirectURI
        )
    }

    private func exchangeCode(
        code: String,
        verifier: String,
        clientID: String,
        redirectURI: String
    ) async throws -> GoogleSignInResult {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "code": code,
            "client_id": clientID,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        request.httpBody = body
            .map { "\($0.key)=\(Self.percentEncoded($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "unknown"
            throw GoogleSignInError.tokenExchangeFailed(detail)
        }

        let decoded = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        guard let idToken = decoded.id_token else {
            throw GoogleSignInError.missingIdToken
        }
        return GoogleSignInResult(idToken: idToken)
    }

    private static func percentEncoded(_ value: String) -> String {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func makeCodeChallenge(verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncodedString()
    }
}

extension GoogleSignInService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
        for scene in scenes {
            if let windowScene = scene as? UIWindowScene,
               let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
        }
        return ASPresentationAnchor()
    }
}

private struct GoogleTokenResponse: Decodable {
    let access_token: String?
    let id_token: String?
    let token_type: String?
    let expires_in: Int?
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
