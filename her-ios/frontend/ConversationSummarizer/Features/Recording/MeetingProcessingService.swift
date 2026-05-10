import Foundation

protocol MeetingProcessingService {
    func process(recordingURL: URL, source: String?, deviceName: String?, locationName: String?) async throws -> MeetingProcessingResult
}

struct MeetingProcessingResult {
    let transcript: String
    let segments: [MeetingTranscriptSegment]
    let language: String?
    let durationSeconds: Double?
    let summary: MeetingSummary?
    let meetingId: String?
}

enum MeetingProcessingServiceFactory {
    static func make() -> MeetingProcessingService? {
        guard let jobsEndpoint = AppConfig.meetingJobsEndpoint else {
            return nil
        }

        return BackendMeetingProcessingService(
            jobsEndpoint: jobsEndpoint,
            legacyTranscriptionEndpoint: AppConfig.transcriptionEndpoint
        )
    }
}

struct BackendMeetingProcessingService: MeetingProcessingService {
    let jobsEndpoint: URL
    let legacyTranscriptionEndpoint: URL?
    private let session: URLSession

    init(jobsEndpoint: URL, legacyTranscriptionEndpoint: URL?, session: URLSession = .shared) {
        self.jobsEndpoint = jobsEndpoint
        self.legacyTranscriptionEndpoint = legacyTranscriptionEndpoint
        self.session = session
    }

    func process(recordingURL: URL, source: String?, deviceName: String?, locationName: String?) async throws -> MeetingProcessingResult {
        do {
            let submitted = try await submitJob(
                recordingURL: recordingURL,
                source: source,
                deviceName: deviceName,
                locationName: locationName
            )
            return try await pollJob(id: submitted.id)
        } catch MeetingProcessingError.backendFailed(statusCode: 404, detail: _) {
            guard let legacyTranscriptionEndpoint else {
                throw MeetingProcessingError.backendFailed(statusCode: 404, detail: "Meeting job endpoint is unavailable.")
            }
            return try await transcribeLegacy(recordingURL: recordingURL, endpoint: legacyTranscriptionEndpoint)
        }
    }

    private func submitJob(recordingURL: URL, source: String?, deviceName: String?, locationName: String?) async throws -> BackendMeetingJobResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: jobsEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = TokenSource.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try makeMultipartBody(
            fileURL: recordingURL,
            boundary: boundary,
            fields: [
                "source": source,
                "device_name": deviceName,
                "location_name": locationName
            ]
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MeetingProcessingError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MeetingProcessingError.backendFailed(
                statusCode: httpResponse.statusCode,
                detail: Self.backendErrorDetail(from: data)
            )
        }

        return try Self.decoder().decode(BackendMeetingJobResponse.self, from: data)
    }

    private func pollJob(id: String) async throws -> MeetingProcessingResult {
        var request = URLRequest(url: jobsEndpoint.appendingPathComponent(id))
        request.timeoutInterval = 30
        if let token = TokenSource.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        for _ in 0..<900 {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MeetingProcessingError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw MeetingProcessingError.backendFailed(
                    statusCode: httpResponse.statusCode,
                    detail: Self.backendErrorDetail(from: data)
                )
            }

            let job = try Self.decoder().decode(BackendMeetingJobResponse.self, from: data)
            switch job.status {
            case "completed":
                guard let meeting = job.meeting else {
                    throw MeetingProcessingError.invalidResponse
                }
                return MeetingProcessingResult(
                    transcript: meeting.transcript,
                    segments: meeting.segments ?? [],
                    language: meeting.language,
                    durationSeconds: meeting.durationSeconds,
                    summary: meeting.summary,
                    meetingId: meeting.id
                )
            case "failed":
                throw MeetingProcessingError.backendFailed(statusCode: 500, detail: job.error)
            default:
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        throw MeetingProcessingError.timedOut
    }

    private func transcribeLegacy(recordingURL: URL, endpoint: URL) async throws -> MeetingProcessingResult {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = TokenSource.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try makeMultipartBody(fileURL: recordingURL, boundary: boundary)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MeetingProcessingError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MeetingProcessingError.backendFailed(
                statusCode: httpResponse.statusCode,
                detail: Self.backendErrorDetail(from: data)
            )
        }

        let decoded = try Self.decoder().decode(BackendTranscriptResponse.self, from: data)
        return MeetingProcessingResult(
            transcript: decoded.transcript,
            segments: decoded.segments ?? [],
            language: decoded.language,
            durationSeconds: decoded.durationSeconds,
            summary: nil,
            meetingId: nil
        )
    }

    private func makeMultipartBody(fileURL: URL, boundary: String, fields: [String: String?] = [:]) throws -> Data {
        var body = Data()
        let fileData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent

        for (name, value) in fields {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString(value)
            body.appendString("\r\n")
        }

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: \(contentType(for: fileURL))\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")
        return body
    }

    private func contentType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "m4a", "mp4":
            return "audio/mp4"
        case "caf":
            return "audio/x-caf"
        case "wav":
            return "audio/wav"
        default:
            return "application/octet-stream"
        }
    }

    private static func backendErrorDetail(from data: Data) -> String? {
        guard !data.isEmpty else {
            return nil
        }

        if let payload = try? JSONDecoder().decode(BackendErrorResponse.self, from: data) {
            if let detail = payload.detailText, !detail.isEmpty {
                return detail
            }
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

private struct BackendErrorResponse: Decodable {
    let detail: Detail

    var detailText: String? {
        switch detail {
        case .text(let value):
            return value
        case .items(let items):
            return items.compactMap(\.message).joined(separator: " ")
        }
    }

    enum Detail: Decodable {
        case text(String)
        case items([BackendErrorItem])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .text(value)
                return
            }
            self = .items((try? container.decode([BackendErrorItem].self)) ?? [])
        }
    }
}

private struct BackendErrorItem: Decodable {
    let msg: String?

    var message: String? {
        msg
    }
}

private struct BackendTranscriptResponse: Decodable {
    let transcript: String
    let segments: [MeetingTranscriptSegment]?
    let language: String?
    let durationSeconds: Double?
}

private struct BackendMeetingJobResponse: Decodable {
    let id: String
    let status: String
    let meetingId: String?
    let error: String?
    let meeting: BackendProcessedMeeting?
}

private struct BackendProcessedMeeting: Decodable {
    let id: String
    let transcript: String
    let segments: [MeetingTranscriptSegment]?
    let language: String?
    let durationSeconds: Double?
    let title: String
    let overview: String
    let keyTopics: [String]?
    let decisions: [String]
    let actionItems: [String]
    let followUps: [String]
    let outline: [MeetingOutlineItem]?
    let generatedAt: Date
    let summaryStatus: String?

    var summary: MeetingSummary? {
        let status = summaryStatus ?? "generated"
        if status == "unavailable" {
            return nil
        }
        return MeetingSummary(
            title: title,
            overview: overview,
            keyTopics: keyTopics ?? [],
            decisions: decisions,
            actionItems: actionItems,
            followUps: followUps,
            outline: outline ?? [],
            generatedAt: generatedAt,
            summaryStatus: status
        )
    }
}

enum MeetingProcessingError: LocalizedError {
    case invalidResponse
    case backendFailed(statusCode: Int, detail: String?)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Meeting backend returned an invalid response."
        case let .backendFailed(statusCode, detail):
            if let detail, !detail.isEmpty {
                return "Meeting backend returned HTTP \(statusCode): \(detail)"
            }
            return "Meeting backend returned HTTP \(statusCode)."
        case .timedOut:
            return "Meeting backend did not finish processing in time."
        }
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        append(Data(value.utf8))
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
