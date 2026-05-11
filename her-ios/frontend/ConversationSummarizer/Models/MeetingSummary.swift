import Foundation

enum MeetingSummaryMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case reasoning = "reasoning"
    case fullTranscript = "full_transcript"
    case cleanDetailed = "clean_detailed"
    case meetingNote = "meeting_note"
    case callNote = "call_note"
    case strategicMeeting = "strategic_meeting"
    case conciseRewrite = "concise_rewrite"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reasoning:
            return "Reasoning Summary"
        case .fullTranscript:
            return "Full Transcript"
        case .cleanDetailed:
            return "Clean + Detailed"
        case .meetingNote:
            return "Meeting Note"
        case .callNote:
            return "Call Note"
        case .strategicMeeting:
            return "Strategic Minutes"
        case .conciseRewrite:
            return "Clear Rewrite"
        }
    }

    var icon: String {
        switch self {
        case .reasoning:
            return "sparkles"
        case .fullTranscript:
            return "doc.plaintext"
        case .cleanDetailed:
            return "text.badge.checkmark"
        case .meetingNote:
            return "note.text"
        case .callNote:
            return "phone"
        case .strategicMeeting:
            return "chart.bar.doc.horizontal"
        case .conciseRewrite:
            return "checkmark.circle"
        }
    }
}

struct MeetingOutlineItem: Codable, Equatable, Identifiable {
    var id = UUID()
    let start: Double
    let title: String

    init(id: UUID = UUID(), start: Double, title: String) {
        self.id = id
        self.start = start
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case start
        case title
    }
}

struct MeetingTranscriptSegment: Codable, Equatable, Identifiable {
    var id = UUID()
    let start: Double
    let end: Double
    let text: String
    let speaker: String?

    init(id: UUID = UUID(), start: Double, end: Double, text: String, speaker: String? = nil) {
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
}

struct MeetingSummary: Codable, Equatable, Identifiable {
    var id = UUID()
    let title: String
    let overview: String
    let keyTopics: [String]
    let decisions: [String]
    let actionItems: [String]
    let followUps: [String]
    let outline: [MeetingOutlineItem]
    let generatedAt: Date
    let summaryStatus: String
    let summaryMode: MeetingSummaryMode

    init(
        id: UUID = UUID(),
        title: String,
        overview: String,
        keyTopics: [String] = [],
        decisions: [String],
        actionItems: [String],
        followUps: [String],
        outline: [MeetingOutlineItem] = [],
        generatedAt: Date,
        summaryStatus: String = "generated",
        summaryMode: MeetingSummaryMode = .reasoning
    ) {
        self.id = id
        self.title = title
        self.overview = overview
        self.keyTopics = keyTopics
        self.decisions = decisions
        self.actionItems = actionItems
        self.followUps = followUps
        self.outline = outline
        self.generatedAt = generatedAt
        self.summaryStatus = summaryStatus
        self.summaryMode = summaryMode
    }

    var isGenerated: Bool {
        summaryStatus != "unavailable"
    }
}
