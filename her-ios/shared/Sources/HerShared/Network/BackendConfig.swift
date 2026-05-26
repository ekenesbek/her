import Foundation

public struct BackendConfig: Equatable, Sendable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public static let defaultBackendURLString = "http://51.195.200.207:8787"

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BackendConfig? {
        let rawURL = environment["HER_BACKEND_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (rawURL?.isEmpty == false ? rawURL! : Self.defaultBackendURLString)
        guard let baseURL = URL(string: resolved) else {
            return nil
        }
        return BackendConfig(baseURL: baseURL)
    }

    public var allowsDesktopBootstrap: Bool {
        guard let host = baseURL.host?.lowercased() else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}
