import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class ConversationSessionViewModel: ObservableObject {
    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var activeInputName = "Not recording"
    @Published var transcript = ""
    @Published private(set) var transcriptSegments: [MeetingTranscriptSegment] = []
    @Published private(set) var summary: MeetingSummary?
    @Published private(set) var errorMessage: String?
    @Published private(set) var transcriptLanguage: String?
    @Published private(set) var transcriptDurationSeconds: Double?
    @Published private(set) var audioLevel: Double = 0

    private let recorder: MeetingRecorder
    private let summaryService: SummaryService
    private let meetingProcessor: MeetingProcessingService?
    private let meetingsService: MeetingsService?
    private var timer: Timer?
    private var meterTimer: Timer?
    private var lastProcessedRecordingURL: URL?
    private var lastProcessedLocationName: String?
    private var currentMeetingId: String?

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var intentObservers: [NSObjectProtocol] = []

    init(
        recorder: MeetingRecorder,
        summaryService: SummaryService,
        meetingProcessor: MeetingProcessingService? = nil,
        meetingsService: MeetingsService? = nil
    ) {
        self.recorder = recorder
        self.summaryService = summaryService
        self.meetingProcessor = meetingProcessor
        self.meetingsService = meetingsService
        registerIntentObservers()
    }

    deinit {
        intentObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func registerIntentObservers() {
        let center = NotificationCenter.default
        let start = center.addObserver(
            forName: Notification.Name("her.recording.startRequested"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.phase != .recording {
                    _ = await self.startRecording()
                }
            }
        }
        let stop = center.addObserver(
            forName: Notification.Name("her.recording.stopRequested"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.phase == .recording {
                    await self.stopAndTranscribe()
                }
            }
        }
        let toggle = center.addObserver(
            forName: Notification.Name("her.recording.toggleRequested"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.phase == .recording {
                    await self.stopAndTranscribe()
                } else if self.canTapPrimaryButton {
                    _ = await self.startRecording()
                }
            }
        }
        intentObservers = [start, stop, toggle]
    }

    private func playFeedback(_ phrase: String, success: Bool) {
        UINotificationFeedbackGenerator().notificationOccurred(success ? .success : .warning)
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 0.85
        speechSynthesizer.speak(utterance)
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
        transcriptSegments = []
        lastProcessedRecordingURL = nil
        transcriptLanguage = nil
        transcriptDurationSeconds = nil
        lastProcessedLocationName = nil
        currentMeetingId = nil

        let micAllowed = await recorder.requestPermission()
        guard micAllowed else {
            fail("Microphone permission is required to record meetings.")
            return false
        }

        guard meetingProcessor != nil else {
            fail("Transcription backend is not configured. Set BackendAPIURL in Info.plist.")
            return false
        }

        do {
            _ = try recorder.start()
            activeInputName = recorder.activeInputName
            audioLevel = 0
            elapsedSeconds = 0
            phase = .recording
            startTimer()
            playFeedback("Recording.", success: true)
            return true
        } catch {
            fail(error.localizedDescription)
            return false
        }
    }

    func recoverIfNeeded() async {
        guard phase == .idle, let recovery = MeetingRecorder.recoverOrphanedRecording() else {
            return
        }
        guard let meetingProcessor else {
            errorMessage = "Found an unfinished recording but the backend is not configured."
            return
        }

        phase = .transcribing
        do {
            let result = try await meetingProcessor.process(
                recordingURL: recovery.url,
                source: "recording",
                deviceName: nil,
                locationName: nil,
                summaryMode: .reasoning
            )
            applyProcessingResult(result)
            if let meetingId = result.meetingId {
                MeetingAudioFileStore.save(url: recovery.url, meetingId: meetingId, locationName: nil)
            }
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                phase = .failed
                errorMessage = "Recovered recording but no speech was detected."
            } else if summary != nil {
                phase = .completed
            } else {
                phase = .transcriptReady
            }
        } catch {
            phase = .failed
            errorMessage = "Recovered recording could not be transcribed: \(error.localizedDescription)"
            return
        }

        MeetingRecorder.clearActiveRecording()
    }

    func stopAndTranscribe(locationName: String? = nil) async {
        stopTimer()
        playFeedback("Stopped, transcribing.", success: true)

        do {
            let recordingURL = try recorder.stop()
            lastProcessedRecordingURL = recordingURL
            lastProcessedLocationName = cleanLocationName(locationName)
            phase = .transcribing
            guard let meetingProcessor else {
                fail("Transcription backend is not configured. Set BackendAPIURL in Info.plist.")
                return
            }
            let result = try await meetingProcessor.process(
                recordingURL: recordingURL,
                source: "recording",
                deviceName: activeInputName == "Not recording" ? nil : activeInputName,
                locationName: lastProcessedLocationName,
                summaryMode: .reasoning
            )
            applyProcessingResult(result)
            if let meetingId = result.meetingId {
                MeetingAudioFileStore.save(url: recordingURL, meetingId: meetingId, locationName: lastProcessedLocationName)
            }
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fail("Transcription finished, but no speech was detected.")
                return
            }
            phase = summary == nil ? .transcriptReady : .completed
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
            if let currentMeetingId, let meetingsService {
                let saved = try await meetingsService.generateSummary(meetingId: currentMeetingId, mode: .reasoning)
                summary = saved.summary
                phase = .completed
                return
            }

            let generated = try await summaryService.summarize(transcript: transcript, mode: .reasoning)
            summary = generated

            if let meetingsService {
                let payload = MeetingSavePayload(
                    transcript: transcript,
                    segments: transcriptSegments,
                    language: transcriptLanguage,
                    durationSeconds: transcriptDurationSeconds,
                    source: nil,
                    deviceName: activeInputName == "Not recording" ? nil : activeInputName,
                    locationName: lastProcessedLocationName,
                    summary: generated
                )
                if let saved = try? await meetingsService.saveMeeting(payload) {
                    currentMeetingId = saved.id
                    if let lastProcessedRecordingURL {
                        MeetingAudioFileStore.save(url: lastProcessedRecordingURL, meetingId: saved.id, locationName: lastProcessedLocationName)
                    }
                }
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

    private func applyProcessingResult(_ result: MeetingProcessingResult) {
        transcript = result.transcript
        transcriptSegments = result.segments
        transcriptLanguage = result.language
        transcriptDurationSeconds = result.durationSeconds
        summary = result.summary
        currentMeetingId = result.meetingId
    }

    private func cleanLocationName(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed.lowercased() == "location unavailable" {
            return nil
        }
        return trimmed
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
