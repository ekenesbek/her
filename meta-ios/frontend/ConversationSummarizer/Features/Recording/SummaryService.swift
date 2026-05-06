import Foundation

protocol SummaryService {
    func summarize(transcript: String) async throws -> MeetingSummary
}

enum SummaryServiceFactory {
    static func make() -> SummaryService {
        if let endpoint = AppConfig.summaryEndpoint ?? AppConfig.backendSummaryEndpoint {
            return BackendSummaryService(endpoint: endpoint)
        }

        return LocalSummaryService()
    }
}

struct LocalSummaryService: SummaryService {
    func summarize(transcript: String) async throws -> MeetingSummary {
        let sentences = transcript
            .split(whereSeparator: { ".!?\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let overview = sentences.prefix(3).joined(separator: ". ")
        let actionItems = extractSentences(
            from: sentences,
            matching: ["action", "todo", "owner", "need to", "should", "must", "next step", "нужно", "надо", "сделать", "ответственный"]
        )
        let decisions = extractSentences(
            from: sentences,
            matching: ["decided", "agreed", "approved", "confirmed", "decision", "решили", "договорились", "подтвердили"]
        )
        let followUps = extractSentences(
            from: sentences,
            matching: ["follow up", "next meeting", "later", "check", "confirm", "следующий", "проверить", "уточнить", "созвон"]
        )

        return MeetingSummary(
            title: makeTitle(from: transcript),
            overview: overview.isEmpty ? "No transcript content was available to summarize." : overview,
            keyTopics: makeKeyTopics(from: transcript, sentences: sentences),
            decisions: decisions.isEmpty ? ["No explicit decisions detected."] : decisions,
            actionItems: actionItems.isEmpty ? ["No explicit action items detected."] : actionItems,
            followUps: followUps.isEmpty ? ["No follow-ups detected."] : followUps,
            generatedAt: Date()
        )
    }

    private func extractSentences(from sentences: [String], matching keywords: [String]) -> [String] {
        sentences
            .filter { sentence in
                let lowercased = sentence.lowercased()
                return keywords.contains { lowercased.contains($0) }
            }
            .prefix(5)
            .map { String($0) }
    }

    private func makeTitle(from transcript: String) -> String {
        let words = transcript
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .prefix(6)
            .joined(separator: " ")

        return words.isEmpty ? "Meeting summary" : String(words)
    }

    private func makeKeyTopics(from transcript: String, sentences: [String]) -> [String] {
        let words = transcript
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 3 }

        var counts: [String: Int] = [:]
        for word in words {
            counts[word, default: 0] += 1
        }

        let ranked = counts.sorted { left, right in
            if left.value == right.value {
                return left.key < right.key
            }
            return left.value > right.value
        }
        .prefix(4)
        .map(\.key)

        if ranked.isEmpty {
            return Array(sentences.prefix(3))
        }
        return Array(ranked)
    }
}

struct BackendSummaryService: SummaryService {
    let endpoint: URL
    private let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func summarize(transcript: String) async throws -> MeetingSummary {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = TokenSource.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(SummaryRequest(transcript: transcript))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw SummaryError.backendFailed
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: rawValue) {
                return date
            }
            if let date = ISO8601DateFormatter.standard.date(from: rawValue) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date.")
        }

        let decoded = try decoder.decode(BackendSummaryResponse.self, from: data)
        return MeetingSummary(
            title: decoded.title,
            overview: decoded.overview,
            keyTopics: decoded.keyTopics ?? [],
            decisions: decoded.decisions,
            actionItems: decoded.actionItems,
            followUps: decoded.followUps,
            generatedAt: decoded.generatedAt
        )
    }
}

private struct SummaryRequest: Encodable {
    let transcript: String
}

private struct BackendSummaryResponse: Decodable {
    let title: String
    let overview: String
    let keyTopics: [String]?
    let decisions: [String]
    let actionItems: [String]
    let followUps: [String]
    let generatedAt: Date
}

enum SummaryError: LocalizedError {
    case backendFailed

    var errorDescription: String? {
        switch self {
        case .backendFailed:
            return "Summary backend returned an error."
        }
    }
}

private extension ISO8601DateFormatter {
    static let standard = ISO8601DateFormatter()

    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
