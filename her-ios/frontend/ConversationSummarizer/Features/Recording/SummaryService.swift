import Foundation

protocol SummaryService {
    func summarize(transcript: String, mode: MeetingSummaryMode) async throws -> MeetingSummary
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
    func summarize(transcript: String, mode: MeetingSummaryMode) async throws -> MeetingSummary {
        if mode == .fullTranscript {
            return MeetingSummary(
                title: mode.title,
                overview: transcript,
                keyTopics: [mode.title],
                decisions: [],
                actionItems: [],
                followUps: [],
                outline: [MeetingOutlineItem(start: 0, title: mode.title)],
                generatedAt: Date(),
                summaryStatus: "generated",
                summaryMode: mode
            )
        }

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
            title: mode == .reasoning ? makeTitle(from: transcript) : mode.title,
            overview: overview.isEmpty ? "No transcript content was available to summarize." : overview,
            keyTopics: makeKeyTopics(from: transcript, sentences: sentences),
            decisions: decisions.isEmpty ? ["No explicit decisions detected."] : decisions,
            actionItems: actionItems.isEmpty ? ["No explicit action items detected."] : actionItems,
            followUps: followUps.isEmpty ? ["No follow-ups detected."] : followUps,
            outline: [MeetingOutlineItem(start: 0, title: makeTitle(from: transcript))],
            generatedAt: Date(),
            summaryStatus: "generated",
            summaryMode: mode
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

    func summarize(transcript: String, mode: MeetingSummaryMode) async throws -> MeetingSummary {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = TokenSource.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(SummaryRequest(transcript: transcript, summaryMode: mode.rawValue))

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
            outline: decoded.outline ?? [],
            generatedAt: decoded.generatedAt,
            summaryStatus: decoded.summaryStatus ?? "generated",
            summaryMode: decoded.summaryMode ?? mode
        )
    }
}

private struct SummaryRequest: Encodable {
    let transcript: String
    let summaryMode: String
}

private struct BackendSummaryResponse: Decodable {
    let title: String
    let overview: String
    let keyTopics: [String]?
    let decisions: [String]
    let actionItems: [String]
    let followUps: [String]
    let outline: [MeetingOutlineItem]?
    let generatedAt: Date
    let summaryStatus: String?
    let summaryMode: MeetingSummaryMode?
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

protocol MeetingChatService {
    func messages(meetingId: String) async throws -> [MeetingChatPersistedMessage]
    func ask(meetingId: String, question: String) async throws -> String
    func ask(meetingId: String, question: String, onPartial: @escaping (String) -> Void) async throws -> String
}

enum MeetingChatServiceFactory {
    static func make() -> MeetingChatService? {
        guard let endpoint = AppConfig.meetingsEndpoint else {
            return nil
        }
        return BackendMeetingChatService(meetingsEndpoint: endpoint)
    }
}

struct BackendMeetingChatService: MeetingChatService {
    let meetingsEndpoint: URL
    private let session: URLSession

    init(meetingsEndpoint: URL, session: URLSession = .shared) {
        self.meetingsEndpoint = meetingsEndpoint
        self.session = session
    }

    func messages(meetingId: String) async throws -> [MeetingChatPersistedMessage] {
        var request = URLRequest(url: meetingsEndpoint.appendingPathComponent(meetingId).appendingPathComponent("chat"))
        if let token = TokenSource.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw SummaryError.backendFailed
        }

        return try Self.decoder().decode(MeetingChatListResponse.self, from: data).messages
    }

    func ask(meetingId: String, question: String) async throws -> String {
        try await askOnce(meetingId: meetingId, question: question)
    }

    func ask(meetingId: String, question: String, onPartial: @escaping (String) -> Void) async throws -> String {
        var request = URLRequest(url: meetingsEndpoint.appendingPathComponent(meetingId).appendingPathComponent("chat").appendingPathComponent("stream"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let token = TokenSource.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(MeetingChatRequest(question: question))

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            return try await askOnce(meetingId: meetingId, question: question)
        }

        var answer = ""
        var eventName = "message"
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                eventName = "message"
                continue
            }
            if line.hasPrefix("event:") {
                eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard line.hasPrefix("data:") else {
                continue
            }

            let dataString = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if eventName == "done" {
                break
            }
            if eventName == "error" {
                throw SummaryError.backendFailed
            }
            guard let data = dataString.data(using: .utf8) else {
                continue
            }

            let payload = try JSONDecoder().decode(MeetingChatStreamPayload.self, from: data)
            if let delta = payload.delta, !delta.isEmpty {
                answer += delta
                onPartial(answer)
            }
            if payload.done == true {
                break
            }
        }

        return answer.isEmpty ? try await askOnce(meetingId: meetingId, question: question) : answer
    }

    private func askOnce(meetingId: String, question: String) async throws -> String {
        var request = URLRequest(url: meetingsEndpoint.appendingPathComponent(meetingId).appendingPathComponent("chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = TokenSource.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(MeetingChatRequest(question: question))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw SummaryError.backendFailed
        }

        return try JSONDecoder().decode(MeetingChatResponse.self, from: data).answer
    }

    private static func decoder() -> JSONDecoder {
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
        return decoder
    }
}

struct MeetingChatPersistedMessage: Decodable, Equatable, Identifiable {
    let id: String
    let role: String
    let content: String
    let createdAt: Date
}

private struct MeetingChatListResponse: Decodable {
    let messages: [MeetingChatPersistedMessage]
}

private struct MeetingChatRequest: Encodable {
    let question: String
}

private struct MeetingChatResponse: Decodable {
    let answer: String
}

private struct MeetingChatStreamPayload: Decodable {
    let delta: String?
    let done: Bool?
}

private extension ISO8601DateFormatter {
    static let standard = ISO8601DateFormatter()

    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
