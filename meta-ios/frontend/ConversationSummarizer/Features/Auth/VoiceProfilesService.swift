import Foundation

struct VoiceProfile: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let durationSeconds: Double?
    let createdAt: Date
}

enum VoiceProfilesError: LocalizedError {
    case backendUnavailable
    case backendFailed(statusCode: Int, detail: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            return "Backend is not configured."
        case let .backendFailed(statusCode, detail):
            if let detail, !detail.isEmpty {
                return "Voice profiles error (\(statusCode)): \(detail)"
            }
            return "Voice profiles error (\(statusCode))"
        case .invalidResponse:
            return "Backend returned an invalid voice profile response."
        }
    }
}

struct VoiceProfilesService {
    let baseURL: URL
    private let session: URLSession

    init?(baseURL: URL? = AppConfig.backendBaseURL, session: URLSession = .shared) {
        guard let baseURL else {
            return nil
        }
        self.baseURL = baseURL
        self.session = session
    }

    func list() async throws -> [VoiceProfile] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/voice-profiles"))
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try ensureOK(response: response, data: data)

        let decoder = decoder()
        struct Wrapper: Decodable { let profiles: [VoiceProfile] }
        return try decoder.decode(Wrapper.self, from: data).profiles
    }

    func enroll(name: String, audioURL: URL) async throws -> VoiceProfile {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/voice-profiles"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"name\"\r\n\r\n".data(using: .utf8)!)
        body.append((name + "\r\n").data(using: .utf8)!)

        let fileData = try Data(contentsOf: audioURL)
        let filename = audioURL.lastPathComponent
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType(for: audioURL))\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try ensureOK(response: response, data: data)

        return try decoder().decode(VoiceProfile.self, from: data)
    }

    func delete(id: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/voice-profiles/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try ensureOK(response: response, data: data)
    }

    private func authHeader() -> String {
        if let token = TokenSource.shared.token {
            return "Bearer \(token)"
        }
        return ""
    }

    private func ensureOK(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceProfilesError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let detail = String(data: data, encoding: .utf8)
            throw VoiceProfilesError.backendFailed(statusCode: httpResponse.statusCode, detail: detail)
        }
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: raw) {
                return date
            }
            if let date = ISO8601DateFormatter.standard.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date.")
        }
        return decoder
    }

    private func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "caf": return "audio/x-caf"
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
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
