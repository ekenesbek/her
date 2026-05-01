import Foundation

struct MeetingSummary: Codable, Equatable, Identifiable {
    var id = UUID()
    let title: String
    let overview: String
    let decisions: [String]
    let actionItems: [String]
    let followUps: [String]
    let generatedAt: Date
}

