import AuthenticationServices
import Foundation
import UIKit

enum AppleSignInError: LocalizedError {
    case missingIdentityToken
    case authorizationFailed(String)
    case noPresentationAnchor

    var errorDescription: String? {
        switch self {
        case .missingIdentityToken:
            return "Apple did not return an identity token."
        case .authorizationFailed(let detail):
            return detail
        case .noPresentationAnchor:
            return "No window is available to present Apple Sign-In."
        }
    }
}

struct AppleSignInResult {
    let identityToken: String
    let fullName: String?
    let email: String?
}

@MainActor
final class AppleSignInService: NSObject {
    private var continuation: CheckedContinuation<AppleSignInResult, Error>?

    func signIn() async throws -> AppleSignInResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName, .email]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }
}

extension AppleSignInService: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            continuation?.resume(throwing: AppleSignInError.missingIdentityToken)
            continuation = nil
            return
        }

        guard let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8) else {
            continuation?.resume(throwing: AppleSignInError.missingIdentityToken)
            continuation = nil
            return
        }

        let fullName: String? = {
            guard let components = credential.fullName else { return nil }
            let formatter = PersonNameComponentsFormatter()
            formatter.style = .default
            let formatted = formatter.string(from: components)
            return formatted.isEmpty ? nil : formatted
        }()

        let result = AppleSignInResult(
            identityToken: identityToken,
            fullName: fullName,
            email: credential.email
        )
        continuation?.resume(returning: result)
        continuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        continuation?.resume(throwing: AppleSignInError.authorizationFailed(error.localizedDescription))
        continuation = nil
    }
}

extension AppleSignInService: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
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
