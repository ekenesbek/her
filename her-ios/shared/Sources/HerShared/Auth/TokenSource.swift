import Foundation

public final class TokenSource: @unchecked Sendable {
    public static let shared = TokenSource()

    private let lock = NSLock()
    private var stored: String?

    private init() {}

    public var token: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func update(token: String?) {
        lock.lock()
        defer { lock.unlock() }
        stored = token
    }
}
