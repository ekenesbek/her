import Foundation
import Speech

final class SpeechTranscriber {
    private let recognizer: SFSpeechRecognizer?

    init(locale: Locale = .autoupdatingCurrent) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func transcribe(fileURL: URL) async throws -> String {
        guard let recognizer else {
            throw TranscriptionError.recognizerUnavailable
        }

        guard recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var didResume = false

            func finish(_ result: Result<String, Error>) {
                lock.lock()
                defer { lock.unlock() }

                guard !didResume else {
                    return
                }

                didResume = true
                continuation.resume(with: result)
            }

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    finish(.failure(error))
                    return
                }

                guard let result, result.isFinal else {
                    return
                }

                let transcript = result.bestTranscription.formattedString
                finish(.success(transcript))
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                task.cancel()
                finish(.failure(TranscriptionError.timeout))
            }
        }
    }
}

enum TranscriptionError: LocalizedError {
    case recognizerUnavailable
    case timeout

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognition is not available for the current locale."
        case .timeout:
            return "Speech recognition timed out."
        }
    }
}

