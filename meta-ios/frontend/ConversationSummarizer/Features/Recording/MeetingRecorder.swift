import AVFoundation
import Foundation

final class MeetingRecorder {
    private var recorder: AVAudioRecorder?
    private var currentRecordingURL: URL?

    var activeInputName: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "iPhone microphone"
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
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let directory = try Self.recordingsDirectory()
        let fileURL = directory.appendingPathComponent("meeting-\(Self.timestamp()).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 64_000
        ]

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()

        guard recorder.record() else {
            throw RecordingError.failedToStart
        }

        self.recorder = recorder
        currentRecordingURL = fileURL
        return fileURL
    }

    func stop() throws -> URL {
        guard let currentRecordingURL else {
            throw RecordingError.noActiveRecording
        }

        recorder?.stop()
        recorder = nil
        self.currentRecordingURL = nil
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return currentRecordingURL
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
}

enum RecordingError: LocalizedError {
    case failedToStart
    case noActiveRecording

    var errorDescription: String? {
        switch self {
        case .failedToStart:
            return "Recording could not start."
        case .noActiveRecording:
            return "No active recording was found."
        }
    }
}
