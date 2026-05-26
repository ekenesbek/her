import AuthenticationServices
import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

public enum AppleSignInError: LocalizedError {
    case missingIdentityToken
    case authorizationFailed(String)
    case noPresentationAnchor

    public var errorDescription: String? {
        switch self {
        case .missingIdentityToken:
            return "Apple did not return an identity token."
        case let .authorizationFailed(detail):
            return detail
        case .noPresentationAnchor:
            return "No window is available to present Apple Sign-In."
        }
    }

    public static func authorizationError(from error: Error) -> AppleSignInError {
        let nsError = error as NSError
        if nsError.domain == ASAuthorizationError.errorDomain,
           nsError.code == ASAuthorizationError.Code.unknown.rawValue {
            return .authorizationFailed(
                "Apple Sign-In did not reach the backend. The app needs the Sign in with Apple capability and provisioning to obtain a native identity token."
            )
        }
        return .authorizationFailed(error.localizedDescription)
    }
}

public struct AppleSignInResult: Sendable {
    public let identityToken: String
    public let fullName: String?
    public let email: String?

    public init(identityToken: String, fullName: String?, email: String?) {
        self.identityToken = identityToken
        self.fullName = fullName
        self.email = email
    }
}

@MainActor
public final class AppleSignInService: NSObject, ObservableObject {
    private var continuation: CheckedContinuation<AppleSignInResult, Error>?

    public override init() {
        super.init()
    }

    public func signIn() async throws -> AppleSignInResult {
        guard Self.hasPresentationAnchor() else {
            throw AppleSignInError.noPresentationAnchor
        }

        return try await withCheckedThrowingContinuation { continuation in
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

    private static func hasPresentationAnchor() -> Bool {
        #if canImport(UIKit)
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene,
               windowScene.windows.first(where: { $0.isKeyWindow }) != nil {
                return true
            }
        }
        return false
        #elseif canImport(AppKit)
        return NSApplication.shared.keyWindow != nil || NSApplication.shared.windows.first != nil
        #else
        return false
        #endif
    }
}

extension AppleSignInService: ASAuthorizationControllerDelegate {
    public func authorizationController(
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

        continuation?.resume(
            returning: AppleSignInResult(
                identityToken: identityToken,
                fullName: fullName,
                email: credential.email
            )
        )
        continuation = nil
    }

    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        continuation?.resume(throwing: AppleSignInError.authorizationError(from: error))
        continuation = nil
    }
}

extension AppleSignInService: ASAuthorizationControllerPresentationContextProviding {
    public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if canImport(UIKit)
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene,
               let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
        }
        return ASPresentationAnchor()
        #elseif canImport(AppKit)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
