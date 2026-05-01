import Foundation

protocol MeetingProcessingService {
    func process(recordingURL: URL) async throws -> MeetingProcessingResult
}

struct MeetingProcessingResult {
    let transcript: String
    let summary: MeetingSummary
}

enum MeetingProcessingServiceFactory {
    static func make() -> MeetingProcessingService? {
        guard let endpoint = AppConfig.meetingProcessEndpoint else {
            return nil
        }

        return BackendMeetingProcessingService(endpoint: endpoint)
    }
}

struct BackendMeetingProcessingService: MeetingProcessingService {
    let endpoint: URL
    private let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func process(recordingURL: URL) async throws -> MeetingProcessingResult {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try makeMultipartBody(fileURL: recordingURL, boundary: boundary)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MeetingProcessingError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MeetingProcessingError.backendFailed(statusCode: httpResponse.statusCode)
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

        let decoded = try decoder.decode(BackendMeetingResponse.self, from: data)
        return MeetingProcessingResult(
            transcript: decoded.transcript,
            summary: decoded.summary.asMeetingSummary()
        )
    }

    private func makeMultipartBody(fileURL: URL, boundary: String) throws -> Data {
        var body = Data()
        let fileData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: audio/mp4\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")
        return body
    }
}

private struct BackendMeetingResponse: Decodable {
    let transcript: String
    let title: String
    let overview: String
    let decisions: [String]
    let actionItems: [String]
    let followUps: [String]
    let generatedAt: Date

    var summary: BackendSummaryPayload {
        BackendSummaryPayload(
            title: title,
            overview: overview,
            decisions: decisions,
            actionItems: actionItems,
            followUps: followUps,
            generatedAt: generatedAt
        )
    }
}

private struct BackendSummaryPayload: Decodable {
    let title: String
    let overview: String
    let decisions: [String]
    let actionItems: [String]
    let followUps: [String]
    let generatedAt: Date

    func asMeetingSummary() -> MeetingSummary {
        MeetingSummary(
            title: title,
            overview: overview,
            decisions: decisions,
            actionItems: actionItems,
            followUps: followUps,
            generatedAt: generatedAt
        )
    }
}

enum MeetingProcessingError: LocalizedError {
    case invalidResponse
    case backendFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Meeting backend returned an invalid response."
        case .backendFailed(let statusCode):
            return "Meeting backend returned HTTP \(statusCode)."
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
