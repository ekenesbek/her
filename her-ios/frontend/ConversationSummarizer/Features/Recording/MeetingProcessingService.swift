import Foundation

protocol MeetingProcessingService {
    func process(recordingURL: URL, source: String?, deviceName: String?, locationName: String?, summaryMode: MeetingSummaryMode) async throws -> MeetingProcessingResult
    func submitJob(recordingURL: URL, source: String?, deviceName: String?, locationName: String?, summaryMode: MeetingSummaryMode) async throws -> MeetingProcessingJob
    func fetchJob(id: String) async throws -> MeetingProcessingJobSnapshot
    func pollJob(id: String) async throws -> MeetingProcessingResult
}

struct MeetingProcessingJob {
    let id: String
}

struct MeetingProcessingJobSnapshot {
    let id: String
    let status: String
    let result: MeetingProcessingResult?

    var isCompleted: Bool {
        status == "completed"
    }
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

    func process(recordingURL: URL, source: String?, deviceName: String?, locationName: String?, summaryMode: MeetingSummaryMode) async throws -> MeetingProcessingResult {
        do {
            let submitted = try await submitJob(
                recordingURL: recordingURL,
                source: source,
                deviceName: deviceName,
                locationName: locationName,
                summaryMode: summaryMode
            )
            return try await pollJob(id: submitted.id)
        } catch MeetingProcessingError.backendFailed(statusCode: 404, detail: _) {
            guard let legacyTranscriptionEndpoint else {
                throw MeetingProcessingError.backendFailed(statusCode: 404, detail: "Meeting job endpoint is unavailable.")
            }
            return try await transcribeLegacy(recordingURL: recordingURL, endpoint: legacyTranscriptionEndpoint)
        }
    }

    func submitJob(recordingURL: URL, source: String?, deviceName: String?, locationName: String?, summaryMode: MeetingSummaryMode) async throws -> MeetingProcessingJob {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: jobsEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = TokenSource.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let bodyFileURL = try makeMultipartBodyFile(
            fileURL: recordingURL,
            boundary: boundary,
            fields: [
                "source": source,
                "device_name": deviceName,
                "location_name": locationName,
                "summary_mode": summaryMode.rawValue,
                "generate_summary": "true"
            ]
        )
        defer { try? FileManager.default.removeItem(at: bodyFileURL) }

        let (data, response) = try await session.upload(for: request, fromFile: bodyFileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MeetingProcessingError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MeetingProcessingError.backendFailed(
                statusCode: httpResponse.statusCode,
                detail: Self.backendErrorDetail(from: data)
            )
        }

        let decoded = try Self.decoder().decode(BackendMeetingJobResponse.self, from: data)
        return MeetingProcessingJob(id: decoded.id)
    }

    func fetchJob(id: String) async throws -> MeetingProcessingJobSnapshot {
        var request = URLRequest(url: jobsEndpoint.appendingPathComponent(id))
        request.timeoutInterval = 30
        if let token = TokenSource.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

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
        if job.status == "failed" {
            throw MeetingProcessingError.backendFailed(statusCode: 500, detail: job.error)
        }
        return MeetingProcessingJobSnapshot(
            id: job.id,
            status: job.status,
            result: job.meeting?.processingResult
        )
    }

    func pollJob(id: String) async throws -> MeetingProcessingResult {
        for _ in 0..<900 {
            let snapshot = try await fetchJob(id: id)
            switch snapshot.status {
            case "completed":
                guard let result = snapshot.result else {
                    throw MeetingProcessingError.invalidResponse
                }
                return result
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
        request.timeoutInterval = 900
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = TokenSource.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let bodyFileURL = try makeMultipartBodyFile(fileURL: recordingURL, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: bodyFileURL) }

        let (data, response) = try await session.upload(for: request, fromFile: bodyFileURL)
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

    private func makeMultipartBodyFile(fileURL: URL, boundary: String, fields: [String: String?] = [:]) throws -> URL {
        let bodyFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("her-upload-\(UUID().uuidString).body")
        FileManager.default.createFile(atPath: bodyFileURL.path, contents: nil)

        do {
            let output = try FileHandle(forWritingTo: bodyFileURL)
            defer { output.closeFile() }

            func writeString(_ value: String) {
                output.write(Data(value.utf8))
            }

            for (name, value) in fields {
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                writeString("--\(boundary)\r\n")
                writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                writeString(value)
                writeString("\r\n")
            }

            writeString("--\(boundary)\r\n")
            writeString("Content-Disposition: form-data; name=\"audio\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
            writeString("Content-Type: \(contentType(for: fileURL))\r\n\r\n")

            let input = try FileHandle(forReadingFrom: fileURL)
            defer { input.closeFile() }
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                output.write(chunk)
            }

            writeString("\r\n")
            writeString("--\(boundary)--\r\n")
            return bodyFileURL
        } catch {
            try? FileManager.default.removeItem(at: bodyFileURL)
            throw error
        }
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
    let summaryMode: MeetingSummaryMode?

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
            summaryStatus: status,
            summaryMode: summaryMode ?? .reasoning
        )
    }

    var processingResult: MeetingProcessingResult {
        MeetingProcessingResult(
            transcript: transcript,
            segments: segments ?? [],
            language: language,
            durationSeconds: durationSeconds,
            summary: summary,
            meetingId: id
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

private extension ISO8601DateFormatter {
    static let standard = ISO8601DateFormatter()

    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
