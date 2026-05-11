import Foundation

struct StoredMeeting: Identifiable, Equatable {
    let id: String
    let transcript: String
    let segments: [MeetingTranscriptSegment]
    let language: String?
    let durationSeconds: Double?
    let source: String?
    let deviceName: String?
    let locationName: String?
    let hasAudio: Bool
    let createdAt: Date
    let summary: MeetingSummary

    var title: String {
        summary.title
    }

    var overview: String {
        summary.overview
    }

    var hasGeneratedSummary: Bool {
        summary.isGenerated
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

    func generateSummary(for meeting: StoredMeeting) async throws -> StoredMeeting {
        guard let service else {
            throw MeetingsServiceError.backendFailed
        }
        let updated = try await service.generateSummary(meetingId: meeting.id, mode: .reasoning)
        if let index = meetings.firstIndex(where: { $0.id == updated.id }) {
            meetings[index] = updated
        } else {
            meetings.insert(updated, at: 0)
        }
        return updated
    }
}

struct MeetingSavePayload {
    let transcript: String
    let segments: [MeetingTranscriptSegment]
    let language: String?
    let durationSeconds: Double?
    let source: String?
    let deviceName: String?
    let locationName: String?
    let summary: MeetingSummary
}

protocol MeetingsService {
    func listMeetings() async throws -> [StoredMeeting]
    func saveMeeting(_ payload: MeetingSavePayload) async throws -> StoredMeeting
    func generateSummary(meetingId: String, mode: MeetingSummaryMode) async throws -> StoredMeeting
}

protocol MeetingAudioDownloadService {
    func downloadAudio(meetingId: String) async throws -> URL
}

enum MeetingsServiceFactory {
    static func make() -> MeetingsService? {
        guard let endpoint = AppConfig.meetingsEndpoint else {
            return nil
        }
        return BackendMeetingsService(endpoint: endpoint)
    }
}

enum MeetingAudioDownloadServiceFactory {
    static func make() -> MeetingAudioDownloadService? {
        guard let endpoint = AppConfig.meetingsEndpoint else {
            return nil
        }
        return BackendMeetingAudioDownloadService(endpoint: endpoint)
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
        var request = URLRequest(url: endpoint)
        if let token = TokenSource.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw MeetingsServiceError.backendFailed
        }

        return try Self.decoder().decode(BackendMeetingListResponse.self, from: data).meetings.map(\.storedMeeting)
    }

    func saveMeeting(_ payload: MeetingSavePayload) async throws -> StoredMeeting {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = TokenSource.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(BackendMeetingSaveBody(payload: payload))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw MeetingsServiceError.backendFailed
        }

        return try Self.decoder().decode(BackendMeetingRecord.self, from: data).storedMeeting
    }

    func generateSummary(meetingId: String, mode: MeetingSummaryMode) async throws -> StoredMeeting {
        var request = URLRequest(url: endpoint.appendingPathComponent(meetingId).appendingPathComponent("summary"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = TokenSource.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(BackendSummaryModeBody(summaryMode: mode.rawValue))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw MeetingsServiceError.backendFailed
        }

        return try Self.decoder().decode(BackendMeetingRecord.self, from: data).storedMeeting
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

struct BackendMeetingAudioDownloadService: MeetingAudioDownloadService {
    let endpoint: URL
    private let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func downloadAudio(meetingId: String) async throws -> URL {
        if let localURL = MeetingAudioFileStore.load(meetingId: meetingId) {
            return localURL
        }

        var request = URLRequest(url: endpoint.appendingPathComponent(meetingId).appendingPathComponent("audio"))
        if let token = TokenSource.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (temporaryURL, response) = try await session.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw MeetingsServiceError.backendFailed
        }

        return try MeetingAudioFileStore.saveDownloadedAudio(
            temporaryURL: temporaryURL,
            meetingId: meetingId,
            suggestedFilename: response.suggestedFilename
        )
    }
}

private struct BackendMeetingSaveBody: Encodable {
    let transcript: String
    let segments: [MeetingTranscriptSegment]
    let language: String?
    let durationSeconds: Double?
    let source: String?
    let deviceName: String?
    let locationName: String?
    let title: String
    let overview: String
    let keyTopics: [String]
    let decisions: [String]
    let actionItems: [String]
    let followUps: [String]
    let outline: [MeetingOutlineItem]
    let generatedAt: Date
    let summaryStatus: String
    let summaryMode: String

    init(payload: MeetingSavePayload) {
        transcript = payload.transcript
        segments = payload.segments
        language = payload.language
        durationSeconds = payload.durationSeconds
        source = payload.source
        deviceName = payload.deviceName
        locationName = payload.locationName
        title = payload.summary.title
        overview = payload.summary.overview
        keyTopics = payload.summary.keyTopics
        decisions = payload.summary.decisions
        actionItems = payload.summary.actionItems
        followUps = payload.summary.followUps
        outline = payload.summary.outline
        generatedAt = payload.summary.generatedAt
        summaryStatus = payload.summary.summaryStatus
        summaryMode = payload.summary.summaryMode.rawValue
    }
}

private struct BackendSummaryModeBody: Encodable {
    let summaryMode: String
}

private struct BackendMeetingListResponse: Decodable {
    let meetings: [BackendMeetingRecord]
}

private struct BackendMeetingRecord: Decodable {
    let id: String
    let transcript: String
    let segments: [MeetingTranscriptSegment]?
    let language: String?
    let durationSeconds: Double?
    let source: String?
    let deviceName: String?
    let locationName: String?
    let hasAudio: Bool?
    let createdAt: Date
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

    var storedMeeting: StoredMeeting {
        StoredMeeting(
            id: id,
            transcript: transcript,
            segments: segments ?? [],
            language: language,
            durationSeconds: durationSeconds,
            source: source,
            deviceName: deviceName,
            locationName: locationName,
            hasAudio: hasAudio ?? false,
            createdAt: createdAt,
            summary: MeetingSummary(
                title: title,
                overview: overview,
                keyTopics: keyTopics ?? [],
                decisions: decisions,
                actionItems: actionItems,
                followUps: followUps,
                outline: outline ?? [],
                generatedAt: generatedAt,
                summaryStatus: summaryStatus ?? "generated",
                summaryMode: summaryMode ?? .reasoning
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

enum MeetingAudioFileStore {
    static func save(url: URL, meetingId: String) {
        UserDefaults.standard.set(url.path, forKey: key(meetingId))
    }

    static func load(meetingId: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key(meetingId)) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    static func saveDownloadedAudio(
        temporaryURL: URL,
        meetingId: String,
        suggestedFilename: String?
    ) throws -> URL {
        let directory = try audioDirectory()
        let fileExtension = cleanExtension(from: suggestedFilename)
        let destination = directory.appendingPathComponent("\(meetingId).\(fileExtension)")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        save(url: destination, meetingId: meetingId)
        return destination
    }

    private static func audioDirectory() throws -> URL {
        let baseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = baseURL.appendingPathComponent("MeetingAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func cleanExtension(from suggestedFilename: String?) -> String {
        guard
            let suggestedFilename,
            !suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "m4a"
        }
        let value = URL(fileURLWithPath: suggestedFilename).pathExtension
        return value.isEmpty ? "m4a" : value
    }

    private static func key(_ meetingId: String) -> String {
        "her.meeting.audioPath.\(meetingId)"
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
