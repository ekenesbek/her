import Foundation

struct StoredMeeting: Identifiable, Equatable {
    let id: String
    let transcript: String
    let language: String?
    let durationSeconds: Double?
    let source: String?
    let deviceName: String?
    let locationName: String?
    let createdAt: Date
    let summary: MeetingSummary

    var title: String {
        summary.title
    }

    var overview: String {
        summary.overview
    }

    var sourceLabel: String {
        if let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return source
        }
        if let deviceName, !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return deviceName
        }
        return "recording"
    }

    var displayLocation: String {
        locationName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? locationName! : "location unavailable"
    }

    var durationText: String {
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
}

@MainActor
final class MeetingsStore: ObservableObject {
    @Published private(set) var meetings: [StoredMeeting] = []
    @Published private(set) var errorMessage: String?

    private let service: MeetingsService?

    init(service: MeetingsService? = MeetingsServiceFactory.make()) {
        self.service = service
    }

    func refresh() async {
        guard let service else {
            meetings = []
            return
        }

        do {
            meetings = try await service.listMeetings()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

protocol MeetingsService {
    func listMeetings() async throws -> [StoredMeeting]
}

enum MeetingsServiceFactory {
    static func make() -> MeetingsService? {
        guard let endpoint = AppConfig.meetingsEndpoint else {
            return nil
        }
        return BackendMeetingsService(endpoint: endpoint)
    }
}

struct BackendMeetingsService: MeetingsService {
    let endpoint: URL
    private let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func listMeetings() async throws -> [StoredMeeting] {
        let (data, response) = try await session.data(from: endpoint)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw MeetingsServiceError.backendFailed
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

        return try decoder.decode(BackendMeetingListResponse.self, from: data).meetings.map(\.storedMeeting)
    }
}

private struct BackendMeetingListResponse: Decodable {
    let meetings: [BackendMeetingRecord]
}

private struct BackendMeetingRecord: Decodable {
    let id: String
    let transcript: String
    let language: String?
    let durationSeconds: Double?
    let source: String?
    let deviceName: String?
    let locationName: String?
    let createdAt: Date
    let title: String
    let overview: String
    let keyTopics: [String]?
    let decisions: [String]
    let actionItems: [String]
    let followUps: [String]
    let generatedAt: Date

    var storedMeeting: StoredMeeting {
        StoredMeeting(
            id: id,
            transcript: transcript,
            language: language,
            durationSeconds: durationSeconds,
            source: source,
            deviceName: deviceName,
            locationName: locationName,
            createdAt: createdAt,
            summary: MeetingSummary(
                title: title,
                overview: overview,
                keyTopics: keyTopics ?? [],
                decisions: decisions,
                actionItems: actionItems,
                followUps: followUps,
                generatedAt: generatedAt
            )
        )
    }
}

enum MeetingsServiceError: LocalizedError {
    case backendFailed

    var errorDescription: String? {
        switch self {
        case .backendFailed:
            return "Meetings backend returned an error."
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
