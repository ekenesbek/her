import Foundation

public struct BackendClient: Sendable {
    public let config: BackendConfig
    private let session: URLSession
    private let tokenSource: TokenSource

    public init(
        config: BackendConfig,
        session: URLSession = .shared,
        tokenSource: TokenSource = .shared
    ) {
        self.config = config
        self.session = session
        self.tokenSource = tokenSource
    }

    // MARK: - Auth

    public func signInWithApple(
        identityToken: String,
        fullName: String?,
        email: String?
    ) async throws -> AuthSession {
        let body = AppleSignInBody(identityToken: identityToken, fullName: fullName, email: email)
        return try await postAuth(path: "v1/auth/apple", body: body)
    }

    public func signInWithGoogle(idToken: String) async throws -> AuthSession {
        try await postAuth(path: "v1/auth/google", body: GoogleSignInBody(idToken: idToken))
    }

    public func desktopSession(
        createIfMissing: Bool = false,
        name: String? = nil,
        email: String? = nil
    ) async throws -> AuthSession {
        let body = DesktopSignInBody(createIfMissing: createIfMissing, email: email, name: name)
        return try await postAuth(path: "v1/auth/desktop", body: body)
    }

    public func currentUser() async throws -> AuthUser {
        try await get(path: "v1/auth/me")
    }

    // MARK: - Meetings

    public func meetings() async throws -> [Meeting] {
        let payload: MeetingListEnvelope = try await get(path: "v1/meetings")
        return payload.meetings.map(\.meeting)
    }

    public func meeting(id: String) async throws -> Meeting {
        let payload: MeetingPayload = try await get(path: "v1/meetings/\(id)")
        return payload.meeting
    }

    public func meetingAudioURL(meetingId: String) -> URL {
        config.baseURL.appendingPathComponent("v1/meetings/\(meetingId)/audio")
    }

    // MARK: - Chat

    public func chatMessages(meetingId: String) async throws -> [ChatMessage] {
        let payload: ChatListEnvelope = try await get(path: "v1/meetings/\(meetingId)/chat")
        return payload.messages
    }

    public func ask(meetingId: String, question: String) async throws -> String {
        let payload: ChatResponse = try await post(
            path: "v1/meetings/\(meetingId)/chat",
            body: ChatRequest(question: question)
        )
        return payload.answer
    }

    // MARK: - Subscription

    public func subscription() async throws -> Subscription {
        try await get(path: "v1/subscription")
    }

    // MARK: - Voice profiles

    public func voiceProfiles() async throws -> [VoiceProfile] {
        let payload: VoiceProfileListEnvelope = try await get(path: "v1/voice-profiles")
        return payload.profiles
    }

    public func renameVoiceProfile(id: String, name: String) async throws -> VoiceProfile {
        try await patch(path: "v1/voice-profiles/\(id)", body: VoiceProfileRenameBody(name: name))
    }

    public func deleteVoiceProfile(id: String) async throws {
        try await delete(path: "v1/voice-profiles/\(id)")
    }

    // MARK: - Low-level

    private func get<Response: Decodable>(path: String) async throws -> Response {
        let request = try makeRequest(path: path, method: "GET")
        return try await send(request)
    }

    private func patch<Response: Decodable, Body: Encodable>(path: String, body: Body) async throws -> Response {
        var request = try makeRequest(path: path, method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.herBackend().encode(body)
        return try await send(request)
    }

    private func post<Response: Decodable, Body: Encodable>(path: String, body: Body) async throws -> Response {
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.herBackend().encode(body)
        return try await send(request)
    }

    private func delete(path: String) async throws {
        let request = try makeRequest(path: path, method: "DELETE")
        try await sendVoid(request)
    }

    private func postAuth<Body: Encodable>(path: String, body: Body) async throws -> AuthSession {
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.herBackend().encode(body)
        let payload: AuthResponseBody = try await send(request)
        return AuthSession(
            token: payload.token,
            expiresAt: payload.expiresAt,
            user: payload.user,
            isNewUser: payload.isNewUser
        )
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        let url = config.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let authToken = tokenSource.token {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BackendError.backendFailed(
                statusCode: httpResponse.statusCode,
                detail: Self.errorDetail(from: data)
            )
        }
        return try JSONDecoder.herBackend().decode(Response.self, from: data)
    }

    private func sendVoid(_ request: URLRequest) async throws {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BackendError.backendFailed(
                statusCode: httpResponse.statusCode,
                detail: Self.errorDetail(from: data)
            )
        }
    }

    private static func errorDetail(from data: Data) -> String? {
        struct Envelope: Decodable { let detail: String? }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           let detail = envelope.detail,
           !detail.isEmpty {
            return detail
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Wire envelopes

private struct AppleSignInBody: Encodable {
    let identityToken: String
    let fullName: String?
    let email: String?
}

private struct GoogleSignInBody: Encodable {
    let idToken: String
}

private struct DesktopSignInBody: Encodable {
    let createIfMissing: Bool
    let email: String?
    let name: String?
}

private struct AuthResponseBody: Decodable {
    let token: String
    let expiresAt: Date
    let user: AuthUser
    let isNewUser: Bool?
}

private struct MeetingListEnvelope: Decodable {
    let meetings: [MeetingPayload]
}

private struct MeetingPayload: Decodable {
    let id: String
    let transcript: String
    let segments: [TranscriptSegment]?
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
    let outline: [OutlineItem]?
    let memoryCandidates: [MemoryCandidate]?
    let generatedAt: Date?
    let summaryStatus: String?
    let summaryMode: String?

    var meeting: Meeting {
        Meeting(
            id: id,
            title: title,
            overview: overview,
            transcript: transcript,
            segments: segments ?? [],
            keyTopics: keyTopics ?? [],
            decisions: decisions,
            actionItems: actionItems,
            followUps: followUps,
            outline: outline ?? [],
            memoryCandidates: memoryCandidates ?? [],
            language: language,
            durationSeconds: durationSeconds,
            source: source,
            deviceName: deviceName,
            locationName: locationName,
            hasAudio: hasAudio ?? false,
            createdAt: createdAt,
            generatedAt: generatedAt,
            summaryStatus: summaryStatus,
            summaryMode: summaryMode
        )
    }
}

private struct VoiceProfileListEnvelope: Decodable {
    let profiles: [VoiceProfile]
}

private struct VoiceProfileRenameBody: Encodable {
    let name: String
}

private struct ChatListEnvelope: Decodable {
    let messages: [ChatMessage]
}

private struct ChatRequest: Encodable {
    let question: String
}

private struct ChatResponse: Decodable {
    let answer: String
}
