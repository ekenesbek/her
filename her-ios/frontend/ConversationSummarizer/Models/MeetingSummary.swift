import Foundation

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
        summaryStatus: String = "generated"
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
    }

    var isGenerated: Bool {
        summaryStatus != "unavailable"
    }
}
