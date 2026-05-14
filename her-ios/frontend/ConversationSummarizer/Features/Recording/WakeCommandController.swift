import AVFoundation
import Foundation
import Speech

extension Notification.Name {
    static let herWakeWordDetected = Notification.Name("her.recording.wakeWordDetected")
    static let herWakeStartRecordingRequested = Notification.Name("her.recording.wakeStartRequested")
    static let herWakeStopRecordingRequested = Notification.Name("her.recording.wakeStopRequested")
}

@MainActor
private enum WakeListeningMode {
    case normal
    case recordingStop
}

@MainActor
final class WakeCommandController: ObservableObject {
    @Published private(set) var state: WakeCommandState = .off
    @Published private(set) var lastHeard = ""
    @Published private(set) var lastAction = ""
    @Published private(set) var isAvailable = true
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: defaultsKey)
            refresh()
        }
    }

    private let defaults = UserDefaults.standard
    private let defaultsKey = "app.wakeCommands.enabled"
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var assistantName = "Her"
    private var appIsActive = false
    private var wakeWindowUntil: Date?
    private var restartWorkItem: DispatchWorkItem?
    private var resetAwakeWorkItem: DispatchWorkItem?
    private var lastTrigger: (intent: WakeCommandIntent, date: Date)?
    private var lastWakeNotificationAt: Date?
    private var listeningMode: WakeListeningMode = .normal

    init() {
        isEnabled = defaults.bool(forKey: defaultsKey)
    }

    var shortStatus: String {
        switch state {
        case .off:
            return "off"
        case .listening:
            return listeningMode == .recordingStop ? "stop" : "listening"
        case .awake:
            return "awake"
        case .triggered:
            return "sent"
        case .paused:
            return "paused"
        case .unavailable:
            return "blocked"
        }
    }

    var statusText: String {
        switch state {
        case .off:
            return "Wake commands are off."
        case .listening:
            if listeningMode == .recordingStop {
                return "Listening for stop recording."
            }
            return "Listening for \"\(wakeWord)\"."
        case .awake:
            return "Heard \"\(wakeWord)\". Waiting for start or stop."
        case let .triggered(message):
            return message
        case let .paused(reason):
            return reason
        case let .unavailable(reason):
            return reason
        }
    }

    var wakeWord: String {
        let trimmed = assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Her" : trimmed
    }

    func configure(assistantName: String) {
        let cleaned = assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.assistantName = cleaned.isEmpty ? "Her" : cleaned
        refresh()
    }

    func setAppActive(_ active: Bool) {
        appIsActive = active
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else {
            refresh()
            return
        }
        isEnabled = enabled
    }

    func pauseForRecording() {
        listeningMode = .normal
        wakeWindowUntil = nil
        restartWorkItem?.cancel()
        resetAwakeWorkItem?.cancel()
        stopRecognitionTask()
        state = .paused("Recording is using the microphone.")
    }

    func listenForStopWhileRecording() {
        restartWorkItem?.cancel()
        resetAwakeWorkItem?.cancel()
        wakeWindowUntil = nil

        guard isEnabled else {
            stopListening(nextState: .off)
            return
        }

        guard isWakeWordUsable else {
            stopListening(nextState: .unavailable("Choose an assistant name with at least four letters before enabling wake commands."))
            return
        }

        guard appIsActive else {
            stopListening(nextState: .paused("Open Her to use wake commands."))
            return
        }

        if audioEngine.isRunning {
            if listeningMode == .recordingStop {
                state = .listening
                return
            }
            stopRecognitionTask()
        }

        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.startListening(mode: .recordingStop)
            }
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    func resumeAfterRecordingIfNeeded() {
        guard isEnabled else {
            state = .off
            return
        }
        refresh()
    }

    func refresh() {
        restartWorkItem?.cancel()
        if !isEnabled {
            stopListening(nextState: .off)
            return
        }

        guard isWakeWordUsable else {
            stopListening(nextState: .unavailable("Choose an assistant name with at least four letters before enabling wake commands."))
            return
        }

        guard appIsActive else {
            stopListening(nextState: .paused("Open Her to use wake commands."))
            return
        }

        if audioEngine.isRunning {
            if listeningMode != .normal {
                stopRecognitionTask()
            } else {
                state = .listening
                return
            }
        }

        Task { await startListening(mode: .normal) }
    }

    private func startListening(mode: WakeListeningMode) async {
        guard isEnabled else {
            stopListening(nextState: .off)
            return
        }

        guard isWakeWordUsable else {
            stopListening(nextState: .unavailable("Choose an assistant name with at least four letters before enabling wake commands."))
            return
        }

        guard appIsActive else {
            stopListening(nextState: .paused("Open Her to use wake commands."))
            return
        }

        guard await requestSpeechPermission() else {
            isAvailable = false
            stopListening(nextState: .unavailable("Speech recognition permission is required for wake commands."))
            return
        }

        guard await requestMicrophonePermission() else {
            isAvailable = false
            stopListening(nextState: .unavailable("Microphone permission is required for wake commands."))
            return
        }

        guard let recognizer = makeSpeechRecognizer(), recognizer.isAvailable else {
            isAvailable = false
            stopListening(nextState: .unavailable("Speech recognition is not available on this device right now."))
            return
        }

        stopRecognitionTask()
        do {
            try configureAudioSession(for: mode)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if #available(iOS 13.0, *), recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            if tapInstalled {
                inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true

            audioEngine.prepare()
            try audioEngine.start()
            listeningMode = mode
            isAvailable = true
            state = .listening

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    self?.handleRecognition(result: result, error: error)
                }
            }
        } catch {
            isAvailable = false
            let message = mode == .recordingStop
                ? "Voice stop is unavailable while recording. Use the Stop button."
                : "Wake command listener could not start: \(error.localizedDescription)"
            stopListening(nextState: mode == .recordingStop ? .paused(message) : .unavailable(message))
        }
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let transcript = result.bestTranscription.formattedString
            lastHeard = transcript
            process(transcript: transcript)
        }

        if case .triggered = state {
            return
        }

        if error != nil || result?.isFinal == true {
            restartSoon()
        }
    }

    private func process(transcript: String) {
        let normalizedTranscript = Self.normalized(transcript)
        guard !normalizedTranscript.isEmpty else { return }

        if listeningMode == .recordingStop {
            processRecordingStopTranscript(normalizedTranscript)
            return
        }

        let wakePhrase = matchedWakePhrase(in: normalizedTranscript)
        let heardWakeWord = wakePhrase != nil
        let commandText: String

        if heardWakeWord {
            wakeWindowUntil = Date().addingTimeInterval(4)
            state = .awake
            scheduleAwakeReset()
            notifyWakeWordDetected()
            commandText = trailingCommand(after: wakePhrase ?? Self.normalized(wakeWord), in: normalizedTranscript)
        } else if let wakeWindowUntil, wakeWindowUntil > Date() {
            commandText = normalizedTranscript
        } else {
            return
        }

        guard let intent = WakeCommandIntent.match(commandText) else {
            return
        }
        trigger(intent)
    }

    private func processRecordingStopTranscript(_ normalizedTranscript: String) {
        var commandCandidates = [normalizedTranscript]
        if let wakePhrase = matchedWakePhrase(in: normalizedTranscript) {
            commandCandidates.insert(trailingCommand(after: wakePhrase, in: normalizedTranscript), at: 0)
        }

        guard commandCandidates.contains(where: { WakeCommandIntent.match($0) == .stopRecording }) else {
            return
        }
        trigger(.stopRecording)
    }

    private func notifyWakeWordDetected() {
        let now = Date()
        if let lastWakeNotificationAt, now.timeIntervalSince(lastWakeNotificationAt) < 2 {
            return
        }
        lastWakeNotificationAt = now
        NotificationCenter.default.post(name: .herWakeWordDetected, object: nil)
    }

    private func trigger(_ intent: WakeCommandIntent) {
        let now = Date()
        if let lastTrigger,
           lastTrigger.intent == intent,
           now.timeIntervalSince(lastTrigger.date) < 3 {
            return
        }
        lastTrigger = (intent, now)
        wakeWindowUntil = nil
        resetAwakeWorkItem?.cancel()
        restartWorkItem?.cancel()
        stopRecognitionTask()

        switch intent {
        case .startRecording:
            lastAction = "start recording"
            state = .triggered("Starting recording from \"\(wakeWord)\".")
            NotificationCenter.default.post(name: .herWakeStartRecordingRequested, object: nil)
        case .stopRecording:
            lastAction = "stop recording"
            state = .triggered("Stopping recording from \"\(wakeWord)\".")
            NotificationCenter.default.post(name: .herWakeStopRecordingRequested, object: nil)
        }
    }

    private func restartSoon(delay: TimeInterval = 0.35) {
        let mode = listeningMode
        restartWorkItem?.cancel()
        stopRecognitionTask()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                if mode == .recordingStop {
                    await self?.startListening(mode: .recordingStop)
                } else {
                    self?.refresh()
                }
            }
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleAwakeReset() {
        resetAwakeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self,
                      case .awake = self.state,
                      let wakeWindowUntil = self.wakeWindowUntil,
                      wakeWindowUntil <= Date() else {
                    return
                }
                self.wakeWindowUntil = nil
                self.state = self.audioEngine.isRunning ? .listening : .off
            }
        }
        resetAwakeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2, execute: item)
    }

    private func stopListening(nextState: WakeCommandState) {
        restartWorkItem?.cancel()
        resetAwakeWorkItem?.cancel()
        stopRecognitionTask()
        state = nextState
    }

    private func stopRecognitionTask() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    private func configureAudioSession(for mode: WakeListeningMode) throws {
        let session = AVAudioSession.sharedInstance()
        if mode == .recordingStop {
            try session.setActive(true)
            return
        }

        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func makeSpeechRecognizer() -> SFSpeechRecognizer? {
        for locale in speechRecognizerLocales() {
            if let recognizer = SFSpeechRecognizer(locale: locale) {
                return recognizer
            }
        }
        return SFSpeechRecognizer()
    }

    private func speechRecognizerLocales() -> [Locale] {
        var identifiers: [String] = []
        if wakeWordUsesLatinLetters {
            identifiers.append("en_US")
        }
        identifiers.append(contentsOf: Locale.preferredLanguages)
        identifiers.append("en_US")

        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            guard !identifier.isEmpty, seen.insert(identifier).inserted else {
                return nil
            }
            return Locale(identifier: identifier)
        }
    }

    private func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private var isWakeWordUsable: Bool {
        Self.normalized(wakeWord).replacingOccurrences(of: " ", with: "").count >= 4
    }

    private func containsWakeWord(_ wakeWord: String, in transcript: String) -> Bool {
        transcript.split(separator: " ").contains { token in
            token == wakeWord || token.hasPrefix(wakeWord)
        } || transcript.contains(wakeWord)
    }

    private func matchedWakePhrase(in transcript: String) -> String? {
        let normalizedWakeWord = Self.normalized(wakeWord)
        let phrases = [
            "hey \(normalizedWakeWord)",
            "hi \(normalizedWakeWord)",
            "okay \(normalizedWakeWord)",
            "ok \(normalizedWakeWord)",
            normalizedWakeWord,
        ]
        return phrases.first { phrase in
            if phrase == normalizedWakeWord {
                return containsWakeWord(phrase, in: transcript)
            }
            return transcript.contains(phrase)
        }
    }

    private func trailingCommand(after wakeWord: String, in transcript: String) -> String {
        guard let range = transcript.range(of: wakeWord) else {
            return transcript
        }
        return String(transcript[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var wakeWordUsesLatinLetters: Bool {
        Self.normalized(wakeWord).range(of: "[a-z]", options: .regularExpression) != nil
    }

    nonisolated fileprivate static func normalized(_ value: String) -> String {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(separator: " ")
            .joined(separator: " ")
    }
}

enum WakeCommandState: Equatable {
    case off
    case listening
    case awake
    case triggered(String)
    case paused(String)
    case unavailable(String)
}

private enum WakeCommandIntent: Equatable {
    case startRecording
    case stopRecording

    static func match(_ text: String) -> WakeCommandIntent? {
        let normalized = WakeCommandController.normalized(text)
        guard !normalized.isEmpty else {
            return nil
        }

        if stopPhrases.contains(where: { normalized.contains($0) }) {
            return .stopRecording
        }
        if startPhrases.contains(where: { normalized.contains($0) }) {
            return .startRecording
        }
        return nil
    }

    private static let startPhrases = [
        "start recording",
        "begin recording",
        "record this",
        "start meeting",
        "record",
        "начни запись",
        "начать запись",
        "записывай",
        "запиши",
        "nachni zapis",
        "nachat zapis",
        "zapisyvai",
        "zapishi"
    ]

    private static let stopPhrases = [
        "stop recording",
        "finish recording",
        "end recording",
        "i m finished",
        "im finished",
        "we re done",
        "were done",
        "that s it",
        "thats it",
        "finished",
        "done",
        "stop",
        "останови запись",
        "закончи",
        "все",
        "всё",
        "стоп",
        "ostanovi zapis",
        "zakonchi",
        "vse",
        "vsyo"
    ]
}
