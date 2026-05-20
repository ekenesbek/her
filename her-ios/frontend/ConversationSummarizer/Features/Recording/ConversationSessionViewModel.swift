import AVFoundation
import Combine
import Foundation
import Network
import UIKit

private let connectivityPendingMessage = "Recording is saved locally. Upload will start automatically when internet is back."
private let connectivityRetryErrorCodes: Set<Int> = [
    URLError.Code.notConnectedToInternet.rawValue,
    URLError.Code.networkConnectionLost.rawValue,
    URLError.Code.timedOut.rawValue,
    URLError.Code.cannotFindHost.rawValue,
    URLError.Code.cannotConnectToHost.rawValue,
    URLError.Code.dnsLookupFailed.rawValue,
    URLError.Code.dataNotAllowed.rawValue,
    URLError.Code.internationalRoamingOff.rawValue
]

struct BackgroundProcessingRecording: Identifiable, Equatable {
    let id: String
    let recordingPath: String
    let jobId: String?
    let meetingId: String?
    let locationName: String?
    let submittedAt: Date
    let lastErrorCode: Int?
    let lastErrorMessage: String?

    var isQuotaBlocked: Bool {
        lastErrorCode == 402
    }

    var isWaitingForConnectivity: Bool {
        guard let lastErrorCode else {
            return false
        }
        return connectivityRetryErrorCodes.contains(lastErrorCode)
    }

    var title: String {
        if isQuotaBlocked {
            return "Recording saved locally"
        }
        if isWaitingForConnectivity {
            return "Waiting for internet"
        }
        if lastErrorMessage != nil {
            return "Upload will retry"
        }
        if meetingId != nil {
            return "Summarizing recording"
        }
        return jobId == nil ? "Uploading recording" : "Transcribing recording"
    }

    var statusLabel: String {
        if isQuotaBlocked {
            return "limit"
        }
        if isWaitingForConnectivity {
            return "offline"
        }
        if lastErrorMessage != nil {
            return "retry"
        }
        if meetingId != nil {
            return "summarizing"
        }
        return jobId == nil ? "uploading" : "transcribing"
    }

    var detailLine: String {
        if isQuotaBlocked {
            return "\(displayLocation) · saved locally, upgrade or restore Plus to upload"
        }
        if isWaitingForConnectivity {
            return "\(displayLocation) · saved locally, upload starts when online"
        }
        if lastErrorMessage != nil {
            return "\(displayLocation) · saved locally, retrying automatically"
        }
        return "\(displayLocation) · backend processing"
    }

    var processingTag: String {
        if isQuotaBlocked {
            return "LIMIT"
        }
        if isWaitingForConnectivity {
            return "OFFLINE"
        }
        if lastErrorMessage != nil {
            return "RETRY"
        }
        if meetingId != nil {
            return "SUMMARY"
        }
        return jobId == nil ? "UPLOAD" : "TRANSCRIPT"
    }

    var displayLocation: String {
        let trimmed = locationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "location unavailable" : trimmed
    }

    var displayTime: String {
        Self.timeFormatter.string(from: submittedAt)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

enum RecordingNoticeStyle: Equatable {
    case info
    case success
    case warning
    case error
}

@MainActor
final class ConversationSessionViewModel: ObservableObject {
    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var activeInputName = "Not recording"
    @Published var transcript = ""
    @Published private(set) var transcriptSegments: [MeetingTranscriptSegment] = []
    @Published private(set) var summary: MeetingSummary?
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeStyle: RecordingNoticeStyle = .error
    @Published private(set) var transcriptLanguage: String?
    @Published private(set) var transcriptDurationSeconds: Double?
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var currentMeetingId: String?
    @Published private(set) var backgroundProcessedMeetingId: String?
    @Published private(set) var backgroundProcessingUpdateCounter = 0
    @Published private(set) var backgroundProcessingRecordings: [BackgroundProcessingRecording] = []

    private let recorder: MeetingRecorder
    private let summaryService: SummaryService
    private let meetingProcessor: MeetingProcessingService?
    private let meetingsService: MeetingsService?
    private var timer: Timer?
    private var meterTimer: Timer?
    private var lastProcessedRecordingURL: URL?
    private var lastProcessedLocationName: String?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var intentObservers: [NSObjectProtocol] = []
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var backgroundProcessingPaths: Set<String> = []
    private var scheduledRetryPaths: Set<String> = []
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "her.meeting-processing.network")
    private var networkIsSatisfied: Bool?

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
        refreshBackgroundProcessingRecordings()
        registerIntentObservers()
        registerAudioSessionObservers()
        startNetworkMonitor()
    }

    deinit {
        intentObservers.forEach { NotificationCenter.default.removeObserver($0) }
        audioSessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        networkMonitor.cancel()
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
                if self.phase == .interrupted {
                    _ = await self.continueRecording()
                } else if self.phase != .recording {
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
                } else if self.phase == .interrupted {
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
                } else if self.phase == .interrupted {
                    _ = await self.continueRecording()
                } else if self.canTapPrimaryButton {
                    _ = await self.startRecording()
                }
            }
        }
        intentObservers = [start, stop, toggle]
    }

    private func registerAudioSessionObservers() {
        let center = NotificationCenter.default
        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleAudioSessionInterruption(notification)
            }
        }
        audioSessionObservers = [interruption]
    }

    private func startNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            Task { @MainActor in
                self?.handleNetworkPathUpdate(isSatisfied: isSatisfied)
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    private func handleNetworkPathUpdate(isSatisfied: Bool) {
        let previous = networkIsSatisfied
        networkIsSatisfied = isSatisfied
        guard isSatisfied else {
            return
        }

        let pendingJobs = PendingMeetingProcessingJobStore.loadAll().filter { $0.lastErrorCode != 402 }
        guard !pendingJobs.isEmpty else {
            return
        }

        if previous == false {
            setNotice("Internet is back. Uploading saved recording now.", style: .info)
        }
        resumePendingProcessingsInBackground(pendingJobs)
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
        case .interrupted:
            return "Continue Recording"
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
        case .idle, .recording, .interrupted, .transcriptReady, .completed, .failed:
            return true
        }
    }

    var canGenerateSummary: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && summary == nil && phase != .recording && phase != .interrupted && phase != .transcribing && phase != .summarizing
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
        case .interrupted:
            Task { await continueRecording() }
        case .transcribing, .summarizing:
            break
        }
    }

    func showMessage(_ message: String, style: RecordingNoticeStyle = .error) {
        setNotice(message, style: style)
    }

    @discardableResult
    func startRecording() async -> Bool {
        setNotice(nil)
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
            refreshElapsedFromRecorder()
            phase = .recording
            startTimer()
            playFeedback("Recording.", success: true)
            return true
        } catch {
            fail(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func continueRecording() async -> Bool {
        setNotice(nil)

        let micAllowed = await recorder.requestPermission()
        guard micAllowed else {
            fail("Microphone permission is required to continue recording.")
            return false
        }

        guard meetingProcessor != nil else {
            fail("Transcription backend is not configured. Set BackendAPIURL in Info.plist.")
            return false
        }

        do {
            _ = try recorder.continueRecording()
            activeInputName = recorder.activeInputName
            audioLevel = 0
            refreshElapsedFromRecorder()
            phase = .recording
            startTimer()
            playFeedback("Recording resumed.", success: true)
            return true
        } catch {
            fail(error.localizedDescription)
            return false
        }
    }

    func recoverIfNeeded() async {
        reconcileRecordingState()
        refreshBackgroundProcessingRecordings()
        guard phase == .idle || phase == .failed else {
            return
        }
        let pendingJobs = PendingMeetingProcessingJobStore.loadAll()
        if !pendingJobs.isEmpty {
            if phase == .failed {
                clearCurrentSessionForBackgroundProcessing()
            }
            resumePendingProcessingsInBackground(pendingJobs)
            return
        }
        guard phase == .idle else {
            return
        }
        guard let recovery = MeetingRecorder.recoverOrphanedRecording() else {
            return
        }
        guard meetingProcessor != nil else {
            setNotice("Found an unfinished recording but the backend is not configured.", style: .error)
            return
        }

        let pending = PendingMeetingProcessingJob(
            jobId: nil,
            meetingId: nil,
            recordingPath: recovery.url.path,
            source: "recording",
            deviceName: nil,
            locationName: nil,
            submittedAt: recovery.startedAt ?? Date()
        )
        PendingMeetingProcessingJobStore.save(pending)
        MeetingRecorder.clearActiveRecording()
        refreshBackgroundProcessingRecordings()
        setNotice("Recovered an unfinished recording. Backend processing will continue in the background.", style: .info)
        resumePendingProcessingsInBackground([pending])
    }

    func reconcileRecordingState() {
        guard phase == .recording, recorder.captureStoppedUnexpectedly else {
            return
        }
        markRecordingInterrupted(reason: "Recording paused because iOS stopped microphone capture.")
    }

    @discardableResult
    func stopAndTranscribe(locationName: String? = nil) async -> BackgroundProcessingRecording? {
        guard phase == .recording || phase == .interrupted else {
            return nil
        }
        stopTimer()
        refreshElapsedFromRecorder()

        do {
            let recordingURL = try recorder.stop()
            lastProcessedRecordingURL = recordingURL
            lastProcessedLocationName = cleanLocationName(locationName)
            guard meetingProcessor != nil else {
                fail("Transcription backend is not configured. Set BackendAPIURL in Info.plist.")
                return nil
            }
            let pending = PendingMeetingProcessingJob(
                jobId: nil,
                meetingId: nil,
                recordingPath: recordingURL.path,
                source: "recording",
                deviceName: activeInputName == "Not recording" ? nil : activeInputName,
                locationName: lastProcessedLocationName,
                submittedAt: Date()
            )
            PendingMeetingProcessingJobStore.save(pending)
            MeetingRecorder.clearActiveRecording()
            refreshBackgroundProcessingRecordings()
            clearCurrentSessionForBackgroundProcessing()
            playFeedback("Saved. Processing in background.", success: true)
            setNotice("Recording saved. Backend is uploading, transcribing, and generating the summary in the background.", style: .info)
            resumePendingProcessingsInBackground([pending])
            return backgroundRecording(for: pending)
        } catch is CancellationError {
            phase = .failed
            let message = PendingMeetingProcessingJobStore.load() == nil
                ? "Recording processing was interrupted before the backend accepted it. Reopen Her to retry from the saved local audio."
                : "Recording upload was accepted or is pending. Backend processing will continue; reopen Her to refresh the result."
            setNotice(message, style: .warning)
        } catch {
            fail(error.localizedDescription)
        }
        return nil
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
        refreshElapsedFromRecorder()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }
                if self.phase == .recording, self.recorder.captureStoppedUnexpectedly {
                    self.markRecordingInterrupted(reason: "Recording paused because iOS stopped microphone capture.")
                    return
                }
                self.refreshElapsedFromRecorder()
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
        setNotice(message, style: .error)
    }

    private func applyProcessingResult(_ result: MeetingProcessingResult) {
        transcript = result.transcript
        transcriptSegments = result.segments
        transcriptLanguage = result.language
        transcriptDurationSeconds = result.durationSeconds
        summary = result.summary
        currentMeetingId = result.meetingId
        if let duration = result.durationSeconds, duration.isFinite, duration > 0 {
            elapsedSeconds = Int(duration.rounded())
        }
    }

    private func resumePendingProcessingsInBackground(_ pendingJobs: [PendingMeetingProcessingJob], force: Bool = false) {
        refreshBackgroundProcessingRecordings()
        let inactiveJobs = pendingJobs.filter { !backgroundProcessingPaths.contains($0.recordingPath) }
        let jobsToResume = inactiveJobs.filter { force || $0.lastErrorCode != 402 }
        guard !jobsToResume.isEmpty else {
            if inactiveJobs.contains(where: { $0.lastErrorCode == 402 }) {
                setNotice("A saved recording is waiting locally because the monthly recording limit was reached. Upgrade or restore Plus, then tap the recording to retry upload.", style: .warning)
            }
            return
        }

        if networkIsSatisfied == false {
            markPendingJobsWaitingForConnectivity(jobsToResume)
            setNotice(connectivityPendingMessage, style: .info)
            return
        }

        if jobsToResume.count == 1, let pending = jobsToResume.first {
            let message = pending.jobId == nil
                ? "Retrying previous recording upload so backend processing can continue."
                : "Checking backend processing for the previous recording."
            setNotice(message, style: .info)
        } else {
            setNotice("Retrying \(jobsToResume.count) previous recordings so backend processing can continue.", style: .info)
        }

        for pending in jobsToResume {
            backgroundProcessingPaths.insert(pending.recordingPath)
            Task { @MainActor in
                await self.resumePendingProcessing(pending, foreground: false)
            }
        }
    }

    private func resumePendingProcessing(_ pending: PendingMeetingProcessingJob, foreground: Bool = true) async {
        defer {
            backgroundProcessingPaths.remove(pending.recordingPath)
        }

        guard let meetingProcessor else {
            setNotice("Found a pending recording but the backend is not configured.", style: .error)
            return
        }
        let recordingURL = URL(fileURLWithPath: pending.recordingPath)
        guard FileManager.default.fileExists(atPath: recordingURL.path) else {
            PendingMeetingProcessingJobStore.clear(matching: pending)
            refreshBackgroundProcessingRecordings()
            if foreground {
                setNotice("This local recording audio is no longer available.", style: .error)
            } else if PendingMeetingProcessingJobStore.loadAll().isEmpty {
                setNotice(nil)
            }
            return
        }

        if foreground {
            lastProcessedRecordingURL = recordingURL
            lastProcessedLocationName = pending.locationName
            activeInputName = pending.deviceName ?? "Backend processing"
            phase = .transcribing
            let message = pending.jobId == nil
                ? "Retrying recording upload so backend processing can continue."
                : "Checking backend processing for the last recording."
            setNotice(message, style: .info)
        }

        do {
            let result = try await processPendingRecording(pending, with: meetingProcessor)
            PendingMeetingProcessingJobStore.clear(matching: pending)
            refreshBackgroundProcessingRecordings()
            if let meetingId = result.meetingId {
                MeetingAudioFileStore.save(url: recordingURL, meetingId: meetingId, locationName: pending.locationName)
            }
            if foreground {
                applyProcessingResult(result)
                if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fail("Transcription finished, but no speech was detected.")
                    return
                }
                phase = summary == nil ? .transcriptReady : .completed
            } else if result.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setNotice("Previous recording finished, but no speech was detected.", style: .warning)
            } else {
                notifyBackgroundProcessingUpdated(meetingId: result.meetingId)
                let message = result.summary == nil
                    ? "Previous recording transcript is saved. Generate a summary from the conversation detail."
                    : "Previous recording transcript and summary are saved."
                setNotice(message, style: .success)
            }
        } catch is CancellationError {
            refreshBackgroundProcessingRecordings()
            if foreground {
                phase = .failed
            }
            setNotice("Backend processing is still pending. Reopen Her to refresh the result.", style: .info)
        } catch let error as MeetingProcessingError {
            savePendingFailure(from: error, pending: pending, foreground: foreground)
        } catch {
            if let errorCode = connectivityErrorCode(from: error) {
                let failed = pending.withFailure(statusCode: errorCode, message: connectivityPendingMessage)
                PendingMeetingProcessingJobStore.save(failed)
                refreshBackgroundProcessingRecordings()
                schedulePendingRetry(for: failed)
                setNotice(connectivityPendingMessage, style: .info)
                if foreground {
                    phase = .failed
                }
                return
            }
            let failed = pending.withFailure(statusCode: nil, message: error.localizedDescription)
            PendingMeetingProcessingJobStore.save(failed)
            refreshBackgroundProcessingRecordings()
            schedulePendingRetry(for: failed)
            setNotice("Pending recording could not be processed. The local audio is still saved and Her will retry automatically. \(error.localizedDescription)", style: .warning)
            if foreground {
                phase = .failed
            }
        }
    }

    private func markPendingJobsWaitingForConnectivity(_ jobs: [PendingMeetingProcessingJob]) {
        for pending in jobs where pending.lastErrorCode != 402 {
            PendingMeetingProcessingJobStore.save(
                pending.withFailure(
                    statusCode: URLError.Code.notConnectedToInternet.rawValue,
                    message: connectivityPendingMessage
                )
            )
        }
        refreshBackgroundProcessingRecordings()
    }

    private func connectivityErrorCode(from error: Error) -> Int? {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain,
              connectivityRetryErrorCodes.contains(nsError.code) else {
            return nil
        }
        return nsError.code
    }

    private func processPendingRecording(
        _ pending: PendingMeetingProcessingJob,
        with meetingProcessor: MeetingProcessingService
    ) async throws -> MeetingProcessingResult {
        let recordingURL = URL(fileURLWithPath: pending.recordingPath)
        if let jobId = pending.jobId {
            return try await pollPendingJob(id: jobId, pending: pending, with: meetingProcessor)
        }

        do {
            let job = try await withBackgroundTask(named: "Upload meeting recording") {
                try await meetingProcessor.submitJob(
                    recordingURL: recordingURL,
                    source: pending.source,
                    deviceName: pending.deviceName,
                    locationName: pending.locationName,
                    summaryMode: .reasoning
                )
            }
            let submitted = pending.withJobId(job.id)
            PendingMeetingProcessingJobStore.save(submitted)
            refreshBackgroundProcessingRecordings()
            return try await pollPendingJob(id: job.id, pending: submitted, with: meetingProcessor)
        } catch MeetingProcessingError.backendFailed(statusCode: 404, detail: _) {
            let result = try await withBackgroundTask(named: "Process meeting recording") {
                try await meetingProcessor.process(
                    recordingURL: recordingURL,
                    source: pending.source,
                    deviceName: pending.deviceName,
                    locationName: pending.locationName,
                    summaryMode: .reasoning
                )
            }
            PendingMeetingProcessingJobStore.clear(matching: pending)
            return result
        }
    }

    private func pollPendingJob(
        id: String,
        pending: PendingMeetingProcessingJob,
        with meetingProcessor: MeetingProcessingService
    ) async throws -> MeetingProcessingResult {
        var trackedPending = pending
        let recordingURL = URL(fileURLWithPath: pending.recordingPath)
        for _ in 0..<900 {
            let snapshot = try await meetingProcessor.fetchJob(id: id)
            if let result = snapshot.result {
                if let meetingId = result.meetingId, trackedPending.meetingId != meetingId {
                    trackedPending = trackedPending.withMeetingId(meetingId)
                    PendingMeetingProcessingJobStore.save(trackedPending)
                    MeetingAudioFileStore.save(url: recordingURL, meetingId: meetingId, locationName: pending.locationName)
                    refreshBackgroundProcessingRecordings()
                    notifyBackgroundProcessingUpdated(meetingId: meetingId)
                }
                if snapshot.isCompleted {
                    return result
                }
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw MeetingProcessingError.timedOut
    }

    private func withBackgroundTask<T>(
        named name: String,
        operation: () async throws -> T
    ) async throws -> T {
        var taskIdentifier: UIBackgroundTaskIdentifier = .invalid
        taskIdentifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            if taskIdentifier != .invalid {
                UIApplication.shared.endBackgroundTask(taskIdentifier)
                taskIdentifier = .invalid
            }
        }
        defer {
            if taskIdentifier != .invalid {
                UIApplication.shared.endBackgroundTask(taskIdentifier)
            }
        }
        return try await operation()
    }

    func retryBackgroundProcessing(_ recording: BackgroundProcessingRecording) {
        let jobs = PendingMeetingProcessingJobStore.loadAll().filter { $0.recordingPath == recording.recordingPath }
        guard !jobs.isEmpty else {
            refreshBackgroundProcessingRecordings()
            setNotice("That recording has already finished or is no longer pending.", style: .success)
            return
        }
        if backgroundProcessingPaths.contains(recording.recordingPath) {
            setNotice("That recording is already processing in the background.", style: .info)
            return
        }
        resumePendingProcessingsInBackground(jobs, force: true)
    }

    private func clearCurrentSessionForBackgroundProcessing() {
        phase = .idle
        activeInputName = "Not recording"
        audioLevel = 0
        transcript = ""
        transcriptSegments = []
        transcriptLanguage = nil
        transcriptDurationSeconds = nil
        summary = nil
        currentMeetingId = nil
        elapsedSeconds = 0
    }

    private func refreshBackgroundProcessingRecordings() {
        backgroundProcessingRecordings = PendingMeetingProcessingJobStore.loadAll().map(backgroundRecording(for:))
    }

    private func notifyBackgroundProcessingUpdated(meetingId: String?) {
        backgroundProcessedMeetingId = meetingId
        backgroundProcessingUpdateCounter += 1
    }

    private func backgroundRecording(for pending: PendingMeetingProcessingJob) -> BackgroundProcessingRecording {
        BackgroundProcessingRecording(
            id: pending.meetingId ?? pending.jobId ?? pending.recordingPath,
            recordingPath: pending.recordingPath,
            jobId: pending.jobId,
            meetingId: pending.meetingId,
            locationName: pending.locationName,
            submittedAt: pending.submittedAt,
            lastErrorCode: pending.lastErrorCode,
            lastErrorMessage: pending.lastErrorMessage
        )
    }

    private func savePendingFailure(
        from error: MeetingProcessingError,
        pending: PendingMeetingProcessingJob,
        foreground: Bool
    ) {
        let statusCode: Int?
        let message: String
        switch error {
        case let .backendFailed(code, detail):
            statusCode = code
            message = pendingFailureMessage(statusCode: code, detail: detail)
        default:
            statusCode = nil
            message = error.localizedDescription
        }
        PendingMeetingProcessingJobStore.save(
            pending.withFailure(statusCode: statusCode, message: message)
        )
        refreshBackgroundProcessingRecordings()
        if statusCode == 402 {
            setNotice(message, style: .warning)
        } else {
            schedulePendingRetry(for: pending.withFailure(statusCode: statusCode, message: message))
            setNotice(message.replacingOccurrences(
                of: "tap the recording to retry",
                with: "Her will retry automatically"
            ), style: .warning)
        }
        if foreground {
            phase = .failed
        }
    }

    private func pendingFailureMessage(statusCode: Int, detail: String?) -> String {
        if statusCode == 402 {
            return "Recording is saved locally, but upload is blocked by the monthly recording limit. Upgrade or restore Plus, then tap this recording to retry."
        }
        if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Pending recording could not be processed. The local audio is still saved; tap the recording to retry. \(detail)"
        }
        return "Pending recording could not be processed. The local audio is still saved; tap the recording to retry. Backend returned HTTP \(statusCode)."
    }

    private func refreshElapsedFromRecorder() {
        let duration = recorder.recordedDurationSeconds
        guard duration.isFinite, duration >= 0 else {
            return
        }
        elapsedSeconds = Int(duration.rounded())
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
        let rawType = (rawValue as? UInt) ?? (rawValue as? NSNumber)?.uintValue
        guard let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }

        switch type {
        case .began:
            guard phase == .recording else {
                return
            }
            markRecordingInterrupted(reason: "Recording paused by a phone call.")
        case .ended:
            guard phase == .interrupted else {
                return
            }
            setNotice("Recording is paused. Continue recording or finish with \(elapsedText) of captured audio.", style: .info)
        @unknown default:
            break
        }
    }

    private func markRecordingInterrupted(reason: String) {
        stopTimer()
        _ = recorder.finishInterruptedSegment()
        refreshElapsedFromRecorder()
        activeInputName = "Recording interrupted"
        audioLevel = 0
        phase = .interrupted
        setNotice("\(reason) Captured \(elapsedText). Continue recording or finish with the saved audio.", style: .warning)
    }

    private func setNotice(_ message: String?, style: RecordingNoticeStyle = .error) {
        noticeStyle = style
        errorMessage = message
    }

    private func schedulePendingRetry(for pending: PendingMeetingProcessingJob) {
        guard pending.lastErrorCode != 402,
              !scheduledRetryPaths.contains(pending.recordingPath) else {
            return
        }
        scheduledRetryPaths.insert(pending.recordingPath)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self.scheduledRetryPaths.remove(pending.recordingPath)
            let jobs = PendingMeetingProcessingJobStore.loadAll().filter { $0.recordingPath == pending.recordingPath }
            guard let latest = jobs.first,
                  latest.lastErrorCode != 402,
                  !self.backgroundProcessingPaths.contains(latest.recordingPath) else {
                return
            }
            self.resumePendingProcessingsInBackground([latest], force: true)
        }
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
    case interrupted
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
        case .interrupted:
            return "Recording interrupted"
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

private struct PendingMeetingProcessingJob: Codable, Equatable {
    let jobId: String?
    let meetingId: String?
    let recordingPath: String
    let source: String?
    let deviceName: String?
    let locationName: String?
    let submittedAt: Date
    var lastErrorCode: Int? = nil
    var lastErrorMessage: String? = nil

    func withJobId(_ jobId: String) -> PendingMeetingProcessingJob {
        PendingMeetingProcessingJob(
            jobId: jobId,
            meetingId: meetingId,
            recordingPath: recordingPath,
            source: source,
            deviceName: deviceName,
            locationName: locationName,
            submittedAt: submittedAt,
            lastErrorCode: nil,
            lastErrorMessage: nil
        )
    }

    func withMeetingId(_ meetingId: String) -> PendingMeetingProcessingJob {
        PendingMeetingProcessingJob(
            jobId: jobId,
            meetingId: meetingId,
            recordingPath: recordingPath,
            source: source,
            deviceName: deviceName,
            locationName: locationName,
            submittedAt: submittedAt,
            lastErrorCode: nil,
            lastErrorMessage: nil
        )
    }

    func withFailure(statusCode: Int?, message: String) -> PendingMeetingProcessingJob {
        PendingMeetingProcessingJob(
            jobId: jobId,
            meetingId: meetingId,
            recordingPath: recordingPath,
            source: source,
            deviceName: deviceName,
            locationName: locationName,
            submittedAt: submittedAt,
            lastErrorCode: statusCode,
            lastErrorMessage: message
        )
    }
}

private enum PendingMeetingProcessingJobStore {
    private static let defaultsKey = "her.meeting.pendingProcessingJob"
    private static let queueDefaultsKey = "her.meeting.pendingProcessingJobs"

    static func save(_ job: PendingMeetingProcessingJob) {
        var jobs = loadAll().filter { existing in
            if existing.recordingPath == job.recordingPath {
                return false
            }
            if let existingJobId = existing.jobId, let jobId = job.jobId, existingJobId == jobId {
                return false
            }
            if let existingMeetingId = existing.meetingId, let meetingId = job.meetingId, existingMeetingId == meetingId {
                return false
            }
            return true
        }
        jobs.append(job)
        saveAll(jobs)
    }

    static func load() -> PendingMeetingProcessingJob? {
        loadAll().first
    }

    static func loadAll() -> [PendingMeetingProcessingJob] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: queueDefaultsKey),
           let jobs = try? JSONDecoder().decode([PendingMeetingProcessingJob].self, from: data) {
            return jobs
        }

        guard let data = defaults.data(forKey: defaultsKey),
              let legacyJob = try? JSONDecoder().decode(PendingMeetingProcessingJob.self, from: data) else {
            return []
        }
        return [legacyJob]
    }

    static func clear(matching job: PendingMeetingProcessingJob) {
        let jobs = loadAll().filter { current in
            if current == job || current.recordingPath == job.recordingPath {
                return false
            }
            if let currentJobId = current.jobId, let jobId = job.jobId, currentJobId == jobId {
                return false
            }
            if let currentMeetingId = current.meetingId, let meetingId = job.meetingId, currentMeetingId == meetingId {
                return false
            }
            return true
        }
        saveAll(jobs)
    }

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: queueDefaultsKey)
    }

    private static func saveAll(_ jobs: [PendingMeetingProcessingJob]) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: defaultsKey)
        guard !jobs.isEmpty else {
            defaults.removeObject(forKey: queueDefaultsKey)
            return
        }
        let sortedJobs = jobs.sorted { $0.submittedAt > $1.submittedAt }
        guard let data = try? JSONEncoder().encode(sortedJobs) else {
            return
        }
        defaults.set(data, forKey: queueDefaultsKey)
    }
}
