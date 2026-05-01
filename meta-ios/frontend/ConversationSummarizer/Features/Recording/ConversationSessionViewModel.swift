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

    private let recorder: MeetingRecorder
    private let transcriber: SpeechTranscriber
    private let summaryService: SummaryService
    private let meetingProcessor: MeetingProcessingService?
    private var timer: Timer?

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
        case .idle, .completed, .failed:
            return "Start Recording"
        case .recording:
            return "Stop and Summarize"
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
        case .idle, .recording, .completed, .failed:
            return true
        }
    }

    var elapsedText: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func primaryAction() {
        switch phase {
        case .idle, .completed, .failed:
            Task { await startRecording() }
        case .recording:
            Task { await stopAndSummarize() }
        case .transcribing, .summarizing:
            break
        }
    }

    private func startRecording() async {
        errorMessage = nil
        summary = nil
        transcript = ""

        let micAllowed = await recorder.requestPermission()
        guard micAllowed else {
            fail("Microphone permission is required to record meetings.")
            return
        }

        if meetingProcessor == nil {
            let speechAllowed = await transcriber.requestAuthorization()
            guard speechAllowed else {
                fail("Speech Recognition permission is required to transcribe meetings.")
                return
            }
        }

        do {
            _ = try recorder.start()
            activeInputName = recorder.activeInputName
            elapsedSeconds = 0
            phase = .recording
            startTimer()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func stopAndSummarize() async {
        stopTimer()

        do {
            let recordingURL = try recorder.stop()
            phase = .transcribing
            if let meetingProcessor {
                let result = try await meetingProcessor.process(recordingURL: recordingURL)
                transcript = result.transcript
                summary = result.summary
            } else {
                transcript = try await transcriber.transcribe(fileURL: recordingURL)
                phase = .summarizing
                summary = try await summaryService.summarize(transcript: transcript)
            }
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
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
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
        case .summarizing:
            return "Summarizing"
        case .completed:
            return "Summary ready"
        case .failed:
            return "Needs attention"
        }
    }
}
