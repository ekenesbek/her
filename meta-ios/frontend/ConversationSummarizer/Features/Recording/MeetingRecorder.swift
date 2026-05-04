import AVFoundation
import Foundation

final class MeetingRecorder {
    private var recorder: AVAudioRecorder?
    private var currentRecordingURL: URL?
    private var selectedInputName = "iPhone microphone"

    var activeInputName: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? selectedInputName
    }

    var currentAudioLevel: Double {
        guard let recorder, recorder.isRecording else {
            return 0
        }

        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        guard power.isFinite else {
            return 0
        }

        let normalized = (Double(power) + 60) / 60
        return min(max(normalized, 0), 1)
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    func start() throws -> URL {
        let audioSession = AVAudioSession.sharedInstance()
        let route = try Self.configurePreferredRecordingRoute(in: audioSession)
        selectedInputName = route.inputName

        let directory = try Self.recordingsDirectory()
        var didStart = false
        defer {
            if !didStart {
                try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }

        let attempts = Self.recordingAttempts(in: directory, session: audioSession)
        for attempt in attempts {
            let recorder = try AVAudioRecorder(url: attempt.fileURL, settings: attempt.settings)
            recorder.isMeteringEnabled = true

            guard recorder.prepareToRecord(), recorder.record() else {
                try? FileManager.default.removeItem(at: attempt.fileURL)
                continue
            }

            self.recorder = recorder
            currentRecordingURL = attempt.fileURL
            selectedInputName = Self.activeInputName(in: audioSession, fallback: route.inputName)
            didStart = true
            return attempt.fileURL
        }

        let inputName = Self.activeInputName(in: audioSession, fallback: route.inputName)
        let formats = attempts.map(\.name).joined(separator: ", ")
        throw RecordingError.failedToStart(inputName: inputName, detail: "Tried \(formats).")
    }

    func stop() throws -> URL {
        guard let currentRecordingURL else {
            throw RecordingError.noActiveRecording
        }

        recorder?.stop()
        recorder = nil
        self.currentRecordingURL = nil
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        selectedInputName = "iPhone microphone"
        return currentRecordingURL
    }

    private static func configurePreferredRecordingRoute(in session: AVAudioSession) throws -> RecordingRoute {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)

        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        if let glassesInput = preferredBluetoothInput(in: session) {
            try session.setPreferredInput(glassesInput)
            return RecordingRoute(inputName: glassesInput.portName)
        }

        try session.setActive(false, options: .notifyOthersOnDeactivation)
        try session.setCategory(
            .record,
            mode: .measurement,
            options: []
        )

        if let builtInMic = preferredBuiltInMic(in: session) {
            try? session.setPreferredInput(builtInMic)
        }

        try session.setActive(true, options: .notifyOthersOnDeactivation)
        return RecordingRoute(inputName: "iPhone microphone")
    }

    private static func recordingsDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    private static func recordingSampleRate(from session: AVAudioSession) -> Double {
        let sampleRate = session.sampleRate
        guard sampleRate.isFinite, sampleRate >= 8_000 else {
            return 16_000
        }
        return min(sampleRate, 48_000)
    }

    private static func recordingAttempts(in directory: URL, session: AVAudioSession) -> [RecordingAttempt] {
        let baseName = "meeting-\(timestamp())"
        let sampleRate = recordingSampleRate(from: session)
        return [
            RecordingAttempt(
                name: "AAC m4a",
                fileURL: directory.appendingPathComponent("\(baseName).m4a"),
                settings: [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                    AVEncoderBitRateKey: 64_000
                ]
            ),
            RecordingAttempt(
                name: "PCM caf",
                fileURL: directory.appendingPathComponent("\(baseName).caf"),
                settings: [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false
                ]
            )
        ]
    }

    private static func activeInputName(in session: AVAudioSession, fallback: String) -> String {
        session.currentRoute.inputs.first?.portName ?? fallback
    }

    private static func preferredBuiltInMic(in session: AVAudioSession) -> AVAudioSessionPortDescription? {
        session.availableInputs?.first { input in
            input.portType == .builtInMic
        }
    }

    private static func preferredBluetoothInput(in session: AVAudioSession) -> AVAudioSessionPortDescription? {
        let inputs = session.availableInputs ?? []
        return inputs.first { input in
            input.portType == .bluetoothHFP && isLikelyGlassesName(input.portName)
        } ?? inputs.first { input in
            input.portType == .bluetoothHFP
        }
    }

    private static func isLikelyGlassesName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("meta")
            || normalized.contains("ray-ban")
            || normalized.contains("rayban")
            || normalized.contains("glasses")
            || normalized.contains("smart glasses")
            || normalized.contains("stories")
    }
}

private struct RecordingRoute {
    let inputName: String
}

private struct RecordingAttempt {
    let name: String
    let fileURL: URL
    let settings: [String: Any]
}

enum RecordingError: LocalizedError {
    case failedToStart(inputName: String, detail: String)
    case noActiveRecording

    var errorDescription: String? {
        switch self {
        case let .failedToStart(inputName, detail):
            return "Recording could not start on \(inputName). \(detail) Check microphone permission and try again."
        case .noActiveRecording:
            return "No active recording was found."
        }
    }
}
