import Foundation

public enum BackendError: LocalizedError, Sendable {
    case notConfigured
    case invalidURL
    case invalidResponse
    case backendFailed(statusCode: Int, detail: String?)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Backend is not configured."
        case .invalidURL:
            return "Backend URL is invalid."
        case .invalidResponse:
            return "Backend returned an invalid response."
        case let .backendFailed(statusCode, detail):
            if let detail, !detail.isEmpty {
                return "Backend failed (\(statusCode)): \(detail)"
            }
            return "Backend failed (\(statusCode))."
        }
    }
}
