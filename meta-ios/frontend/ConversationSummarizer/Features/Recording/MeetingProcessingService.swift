import Foundation

protocol MeetingProcessingService {
    func transcribe(recordingURL: URL) async throws -> MeetingProcessingResult
}

struct MeetingProcessingResult {
    let transcript: String
    let language: String?
    let durationSeconds: Double?
}

enum MeetingProcessingServiceFactory {
    static func make() -> MeetingProcessingService? {
        guard let endpoint = AppConfig.transcriptionEndpoint else {
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

    func transcribe(recordingURL: URL) async throws -> MeetingProcessingResult {
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
            throw MeetingProcessingError.backendFailed(
                statusCode: httpResponse.statusCode,
                detail: Self.backendErrorDetail(from: data)
            )
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

        let decoded = try decoder.decode(BackendTranscriptResponse.self, from: data)
        return MeetingProcessingResult(
            transcript: decoded.transcript,
            language: decoded.language,
            durationSeconds: decoded.durationSeconds
        )
    }

    private func makeMultipartBody(fileURL: URL, boundary: String) throws -> Data {
        var body = Data()
        let fileData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent

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
    let language: String?
    let durationSeconds: Double?
}

enum MeetingProcessingError: LocalizedError {
    case invalidResponse
    case backendFailed(statusCode: Int, detail: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Meeting backend returned an invalid response."
        case let .backendFailed(statusCode, detail):
            if let detail, !detail.isEmpty {
                return "Meeting backend returned HTTP \(statusCode): \(detail)"
            }
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
