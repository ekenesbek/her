import Foundation

public struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public let start: Double
    public let end: Double
    public let text: String
    public let speaker: String?

    public init(id: UUID = UUID(), start: Double, end: Double, text: String, speaker: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case text
        case speaker
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.start = try container.decode(Double.self, forKey: .start)
        self.end = try container.decode(Double.self, forKey: .end)
        self.text = try container.decode(String.self, forKey: .text)
        self.speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
    }
}

public struct OutlineItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public let start: Double
    public let title: String

    public init(id: UUID = UUID(), start: Double, title: String) {
        self.id = id
        self.start = start
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case start
        case title
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.start = try container.decode(Double.self, forKey: .start)
        self.title = try container.decode(String.self, forKey: .title)
    }

    public var timeText: String {
        let total = max(0, Int(start.rounded()))
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}

public struct MemoryCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let meetingId: String
    public let kind: String
    public let text: String
    public let confidence: Double
    public let sensitivity: String
    public let status: String
    public let source: String
    public let createdAt: Date

    public init(
        id: String,
        meetingId: String,
        kind: String,
        text: String,
        confidence: Double,
        sensitivity: String,
        status: String,
        source: String,
        createdAt: Date
    ) {
        self.id = id
        self.meetingId = meetingId
        self.kind = kind
        self.text = text
        self.confidence = confidence
        self.sensitivity = sensitivity
        self.status = status
        self.source = source
        self.createdAt = createdAt
    }

    public var confidencePercent: Int {
        Int((confidence * 100).rounded())
    }

    public var confidenceText: String {
        "\(confidencePercent)%"
    }

    public var kindLabel: String {
        kind.replacingOccurrences(of: "_", with: " ").uppercased()
    }
}

public struct Meeting: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let overview: String
    public let transcript: String
    public let segments: [TranscriptSegment]
    public let keyTopics: [String]
    public let decisions: [String]
    public let actionItems: [String]
    public let followUps: [String]
    public let outline: [OutlineItem]
    public let memoryCandidates: [MemoryCandidate]
    public let language: String?
    public let durationSeconds: Double?
    public let source: String?
    public let deviceName: String?
    public let locationName: String?
    public let hasAudio: Bool
    public let createdAt: Date
    public let generatedAt: Date?
    public let summaryStatus: String?
    public let summaryMode: String?

    public init(
        id: String,
        title: String,
        overview: String,
        transcript: String,
        segments: [TranscriptSegment] = [],
        keyTopics: [String] = [],
        decisions: [String] = [],
        actionItems: [String] = [],
        followUps: [String] = [],
        outline: [OutlineItem] = [],
        memoryCandidates: [MemoryCandidate] = [],
        language: String? = nil,
        durationSeconds: Double? = nil,
        source: String? = nil,
        deviceName: String? = nil,
        locationName: String? = nil,
        hasAudio: Bool = false,
        createdAt: Date,
        generatedAt: Date? = nil,
        summaryStatus: String? = nil,
        summaryMode: String? = nil
    ) {
        self.id = id
        self.title = title
        self.overview = overview
        self.transcript = transcript
        self.segments = segments
        self.keyTopics = keyTopics
        self.decisions = decisions
        self.actionItems = actionItems
        self.followUps = followUps
        self.outline = outline
        self.memoryCandidates = memoryCandidates
        self.language = language
        self.durationSeconds = durationSeconds
        self.source = source
        self.deviceName = deviceName
        self.locationName = locationName
        self.hasAudio = hasAudio
        self.createdAt = createdAt
        self.generatedAt = generatedAt
        self.summaryStatus = summaryStatus
        self.summaryMode = summaryMode
    }

    public var sourceLabel: String {
        if let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return source
        }
        if let deviceName, !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return deviceName
        }
        return "recording"
    }

    public var displayLocation: String {
        guard let locationName, !locationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "location unavailable"
        }
        return locationName
    }

    public var durationText: String {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else {
            return "duration unavailable"
        }
        let totalSeconds = Int(durationSeconds.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 {
            return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
        }
        return "\(seconds)s"
    }

    public var timeText: String {
        Self.timeFormatter.string(from: createdAt)
    }

    public var dateText: String {
        if Calendar.current.isDateInToday(createdAt) {
            return "today"
        }
        return Self.dateFormatter.string(from: createdAt).lowercased()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

public struct VoiceProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let durationSeconds: Double?
    public let sampleCount: Int
    public let createdAt: Date

    public init(
        id: String,
        name: String,
        durationSeconds: Double?,
        sampleCount: Int,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.durationSeconds = durationSeconds
        self.sampleCount = sampleCount
        self.createdAt = createdAt
    }
}

public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let role: String
    public let content: String
    public let createdAt: Date

    public init(id: String, role: String, content: String, createdAt: Date) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}
