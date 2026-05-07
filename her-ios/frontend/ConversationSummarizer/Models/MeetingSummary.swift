import Foundation

struct MeetingSummary: Codable, Equatable, Identifiable {
    var id = UUID()
    let title: String
    let overview: String
    let keyTopics: [String]
    let decisions: [String]
    let actionItems: [String]
    let followUps: [String]
    let generatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        overview: String,
        keyTopics: [String] = [],
        decisions: [String],
        actionItems: [String],
        followUps: [String],
        generatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.overview = overview
        self.keyTopics = keyTopics
        self.decisions = decisions
        self.actionItems = actionItems
        self.followUps = followUps
        self.generatedAt = generatedAt
    }
}
