import Combine
import Foundation

@MainActor
final class ConversationSessionViewModel: ObservableObject {
    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var activeInputName = "Not recording"
    @Published var transcript = ""
    @Published private(set) var summary: MeetingSummary?
    @Published private(set) var errorMessage: String?
    @Published private(set) var transcriptLanguage: String?
    @Published private(set) var transcriptDurationSeconds: Double?
    @Published private(set) var audioLevel: Double = 0

    private let recorder: MeetingRecorder
    private let transcriber: SpeechTranscriber
    private let summaryService: SummaryService
    private let meetingProcessor: MeetingProcessingService?
    private var timer: Timer?
    private var meterTimer: Timer?

    init(
        recorder: MeetingRecorder,
        transcriber: SpeechTranscriber,
        summaryService: SummaryService,
        meetingProcessor: MeetingProcessingService? = nil
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.summaryService = summaryService
        self.meetingProcessor = meetingProcessor
    }

    var primaryButtonTitle: String {
        switch phase {
        case .idle, .transcriptReady, .completed, .failed:
            return "Start Recording"
        case .recording:
            return "Stop Recording"
        case .transcribing:
            return "Transcribing..."
        case .summarizing:
            return "Summarizing..."
        }
    }

    var canTapPrimaryButton: Bool {
        switch phase {
        case .transcribing, .summarizing:
            return false
        case .idle, .recording, .transcriptReady, .completed, .failed:
            return true
        }
    }

    var canGenerateSummary: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && summary == nil && phase != .recording && phase != .transcribing && phase != .summarizing
    }

    var summaryButtonTitle: String {
        switch phase {
        case .summarizing:
            return "Generating summary..."
        default:
            return summary == nil ? "Generate summary" : "Summary ready"
        }
    }

    var elapsedText: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func primaryAction() {
        switch phase {
        case .idle, .transcriptReady, .completed, .failed:
            Task { await startRecording() }
        case .recording:
            Task { await stopAndTranscribe() }
        case .transcribing, .summarizing:
            break
        }
    }

    @discardableResult
    func startRecording() async -> Bool {
        errorMessage = nil
        summary = nil
        transcript = ""
        transcriptLanguage = nil
        transcriptDurationSeconds = nil

        let micAllowed = await recorder.requestPermission()
        guard micAllowed else {
            fail("Microphone permission is required to record meetings.")
            return false
        }

        if meetingProcessor == nil {
            let speechAllowed = await transcriber.requestAuthorization()
            guard speechAllowed else {
                fail("Speech Recognition permission is required to transcribe meetings.")
                return false
            }
        }

        do {
            _ = try recorder.start()
            activeInputName = recorder.activeInputName
            audioLevel = 0
            elapsedSeconds = 0
            phase = .recording
            startTimer()
            return true
        } catch {
            fail(error.localizedDescription)
            return false
        }
    }

    func stopAndTranscribe() async {
        stopTimer()

        do {
            let recordingURL = try recorder.stop()
            phase = .transcribing
            if let meetingProcessor {
                let result = try await meetingProcessor.transcribe(recordingURL: recordingURL)
                transcript = result.transcript
                transcriptLanguage = result.language
                transcriptDurationSeconds = result.durationSeconds
            } else {
                transcript = try await transcriber.transcribe(fileURL: recordingURL)
            }
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fail("Transcription finished, but no speech was detected.")
                return
            }
            phase = .transcriptReady
        } catch {
            fail(error.localizedDescription)
        }
    }

    func generateSummary() async {
        guard canGenerateSummary else {
            return
        }

        do {
            phase = .summarizing
            summary = try await summaryService.summarize(transcript: transcript)
            phase = .completed
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }

        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.audioLevel = self.recorder.currentAudioLevel
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        meterTimer?.invalidate()
        meterTimer = nil
        audioLevel = 0
    }

    private func fail(_ message: String) {
        stopTimer()
        phase = .failed
        errorMessage = message
    }
}

enum RecordingPhase: Equatable {
    case idle
    case recording
    case transcribing
    case transcriptReady
    case summarizing
    case completed
    case failed

    var label: String {
        switch self {
        case .idle:
            return "Ready"
        case .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing"
        case .transcriptReady:
            return "Transcript ready"
        case .summarizing:
            return "Summarizing"
        case .completed:
            return "Summary ready"
        case .failed:
            return "Needs attention"
        }
    }
}
