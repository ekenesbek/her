import Foundation

public struct Subscription: Codable, Equatable, Sendable {
    public let plan: String
    public let recordingLimitSeconds: Int
    public let recordingUsedSeconds: Int
    public let recordingRemainingSeconds: Int
    public let askAiEnabled: Bool
    public let periodStartedAt: Date?
    public let periodEndsAt: Date?
    public let source: String?

    public init(
        plan: String,
        recordingLimitSeconds: Int,
        recordingUsedSeconds: Int,
        recordingRemainingSeconds: Int,
        askAiEnabled: Bool,
        periodStartedAt: Date? = nil,
        periodEndsAt: Date? = nil,
        source: String? = nil
    ) {
        self.plan = plan
        self.recordingLimitSeconds = recordingLimitSeconds
        self.recordingUsedSeconds = recordingUsedSeconds
        self.recordingRemainingSeconds = recordingRemainingSeconds
        self.askAiEnabled = askAiEnabled
        self.periodStartedAt = periodStartedAt
        self.periodEndsAt = periodEndsAt
        self.source = source
    }

    public static let empty = Subscription(
        plan: "free",
        recordingLimitSeconds: 0,
        recordingUsedSeconds: 0,
        recordingRemainingSeconds: 0,
        askAiEnabled: false
    )

    public var remainingMinutes: Int {
        max(0, recordingRemainingSeconds / 60)
    }

    public var remainingMinutesText: String {
        "\(remainingMinutes) min left"
    }

    public var limitMinutes: Int {
        max(0, recordingLimitSeconds / 60)
    }

    /// Short alias for `recordingLimitSeconds`.
    public var limitSeconds: Int { recordingLimitSeconds }

    /// Short alias for `recordingUsedSeconds`.
    public var usedSeconds: Int { recordingUsedSeconds }

    /// Short alias for `recordingRemainingSeconds`.
    public var remainingSeconds: Int { recordingRemainingSeconds }
}
