import AVFoundation
import Foundation

final class MeetingRecorder {
    private static let activeRecordingDefaultsKey = "app.recording.activeURL"
    private static let activeRecordingStartedAtKey = "app.recording.activeStartedAt"
    private static let activeRecordingSegmentsKey = "app.recording.segmentURLs"

    private var recorder: AVAudioRecorder?
    private var currentRecordingURL: URL?
    private var completedSegmentURLs: [URL] = []
    private var selectedInputName = "iPhone microphone"

    var activeInputName: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? selectedInputName
    }

    var recordedDurationSeconds: Double {
        let completedDuration = completedSegmentURLs.reduce(0) { total, url in
            total + Self.audioDurationSeconds(for: url)
        }
        let activeDuration = recorder?.currentTime ?? 0
        return max(0, completedDuration + activeDuration)
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
        completedSegmentURLs.removeAll()
        Self.clearActiveRecording()
        return try startSegment()
    }

    func continueRecording() throws -> URL {
        try startSegment()
    }

    func finishInterruptedSegment() -> URL? {
        guard let currentRecordingURL else {
            return nil
        }

        recorder?.stop()
        recorder = nil
        self.currentRecordingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        selectedInputName = "iPhone microphone"
        Self.clearActiveRecording()

        guard Self.isUsableRecording(currentRecordingURL) else {
            try? FileManager.default.removeItem(at: currentRecordingURL)
            return nil
        }

        completedSegmentURLs.append(currentRecordingURL)
        Self.persistCompletedSegments(completedSegmentURLs)
        return currentRecordingURL
    }

    func stop() throws -> URL {
        if currentRecordingURL != nil {
            _ = finishInterruptedSegment()
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            selectedInputName = "iPhone microphone"
            Self.clearActiveRecording()
        }

        guard !completedSegmentURLs.isEmpty else {
            throw RecordingError.noActiveRecording
        }

        let finalizedURL = try Self.finalizedRecordingURL(from: completedSegmentURLs)
        completedSegmentURLs.removeAll()
        return finalizedURL
    }

    private func startSegment() throws -> URL {
        guard recorder == nil else {
            throw RecordingError.alreadyRecording
        }

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
            Self.persistActiveRecording(url: attempt.fileURL)
            return attempt.fileURL
        }

        let inputName = Self.activeInputName(in: audioSession, fallback: route.inputName)
        let formats = attempts.map(\.name).joined(separator: ", ")
        throw RecordingError.failedToStart(inputName: inputName, detail: "Tried \(formats).")
    }

    static func persistActiveRecording(url: URL) {
        let defaults = UserDefaults.standard
        defaults.set(url.path, forKey: activeRecordingDefaultsKey)
        defaults.set(Date(), forKey: activeRecordingStartedAtKey)
    }

    static func clearActiveRecording() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: activeRecordingDefaultsKey)
        defaults.removeObject(forKey: activeRecordingStartedAtKey)
        defaults.removeObject(forKey: activeRecordingSegmentsKey)
    }

    static func recoverOrphanedRecording() -> (url: URL, startedAt: Date?)? {
        let defaults = UserDefaults.standard
        let segmentPaths = defaults.stringArray(forKey: activeRecordingSegmentsKey) ?? []
        var paths = segmentPaths
        if let activePath = defaults.string(forKey: activeRecordingDefaultsKey) {
            paths.append(activePath)
        }
        let uniquePaths = Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }
        guard !uniquePaths.isEmpty else {
            return nil
        }
        let urls = uniquePaths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) && fileSizeBytes($0) > 4_096 }
        guard !urls.isEmpty else {
            clearActiveRecording()
            return nil
        }

        guard urls.count > 1 else {
            let startedAt = defaults.object(forKey: activeRecordingStartedAtKey) as? Date
            return (urls[0], startedAt)
        }

        guard let url = try? finalizedRecordingURL(from: urls) else {
            clearActiveRecording()
            return nil
        }

        let startedAt = defaults.object(forKey: activeRecordingStartedAtKey) as? Date
        return (url, startedAt)
    }

    private static func persistCompletedSegments(_ urls: [URL]) {
        UserDefaults.standard.set(urls.map(\.path), forKey: activeRecordingSegmentsKey)
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
            mode: .default,
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

    private static func recordingAttempts(in directory: URL, session: AVAudioSession) -> [RecordingAttempt] {
        let baseName = "meeting-\(timestamp())"
        let sampleRate: Double = 16_000
        return [
            RecordingAttempt(
                name: "AAC m4a",
                fileURL: directory.appendingPathComponent("\(baseName).m4a"),
                settings: [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                    AVEncoderBitRateKey: 96_000
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

    private static func isUsableRecording(_ url: URL) -> Bool {
        fileSizeBytes(url) > 4_096 && audioDurationSeconds(for: url) > 0.05
    }

    private static func fileSizeBytes(_ url: URL) -> Int64 {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        return attributes[.size] as? Int64 ?? 0
    }

    private static func audioDurationSeconds(for url: URL) -> Double {
        let duration = AVURLAsset(url: url).duration.seconds
        guard duration.isFinite, duration > 0 else {
            return 0
        }
        return duration
    }

    private static func finalizedRecordingURL(from segments: [URL]) throws -> URL {
        let usableSegments = segments.filter { isUsableRecording($0) }
        guard let first = usableSegments.first else {
            throw RecordingError.noActiveRecording
        }
        guard usableSegments.count > 1 else {
            return first
        }

        let outputURL = try recordingsDirectory().appendingPathComponent("meeting-\(timestamp())-combined.m4a")
        try? FileManager.default.removeItem(at: outputURL)

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecordingError.failedToCombineSegments
        }

        var cursor = CMTime.zero
        for url in usableSegments {
            let asset = AVURLAsset(url: url)
            guard let assetTrack = asset.tracks(withMediaType: .audio).first else {
                continue
            }
            let range = CMTimeRange(start: .zero, duration: asset.duration)
            try compositionTrack.insertTimeRange(range, of: assetTrack, at: cursor)
            cursor = cursor + asset.duration
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecordingError.failedToCombineSegments
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a

        let semaphore = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously {
            semaphore.signal()
        }
        semaphore.wait()

        guard exporter.status == .completed, FileManager.default.fileExists(atPath: outputURL.path) else {
            throw exporter.error ?? RecordingError.failedToCombineSegments
        }

        return outputURL
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
    case alreadyRecording
    case failedToStart(inputName: String, detail: String)
    case failedToCombineSegments
    case noActiveRecording

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already active."
        case let .failedToStart(inputName, detail):
            return "Recording could not start on \(inputName). \(detail) Check microphone permission and try again."
        case .failedToCombineSegments:
            return "Recording segments could not be combined."
        case .noActiveRecording:
            return "No active recording was found."
        }
    }
}
