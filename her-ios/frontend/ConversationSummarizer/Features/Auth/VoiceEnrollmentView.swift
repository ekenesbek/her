import AVFoundation
import SwiftUI

@MainActor
final class VoiceEnrollmentRecorder: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording(elapsed: Int)
        case ready(URL)
        case uploading
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private let targetDuration: Int = 60

    var elapsedSeconds: Int {
        switch phase {
        case let .recording(elapsed): return elapsed
        default: return 0
        }
    }

    var canStop: Bool {
        if case .recording(let elapsed) = phase { return elapsed >= 5 }
        return false
    }

    func start() async {
        let allowed: Bool = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard allowed else {
            phase = .failed("Microphone permission denied.")
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)

            if let glasses = Self.preferredGlassesInput(in: session) {
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.allowBluetoothHFP, .defaultToSpeaker]
                )
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                try? session.setPreferredInput(glasses)
            } else {
                try session.setCategory(.record, mode: .default, options: [])
                if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                    try? session.setPreferredInput(builtIn)
                }
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            }
        } catch {
            phase = .failed(Self.recordingErrorMessage(for: error))
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enroll-\(UUID().uuidString).m4a")
        let hardwareRate = session.sampleRate
        let sampleRate = (hardwareRate >= 8_000 && hardwareRate <= 48_000) ? hardwareRate : 44_100
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 64_000
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.prepareToRecord() else {
                phase = .failed("Could not prepare recorder (rate=\(Int(sampleRate))Hz, route=\(session.currentRoute.inputs.first?.portName ?? "unknown")).")
                return
            }
            guard recorder.record() else {
                phase = .failed("Could not start recording — microphone may be in use by another app.")
                return
            }
            self.recorder = recorder
            self.startedAt = Date()
            self.phase = .recording(elapsed: 0)
            startTimer(targetURL: url)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func stop() {
        finalizeRecording()
    }

    func reset() {
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        startedAt = nil
        recorder = nil
        phase = .idle
    }

    func setUploading() {
        phase = .uploading
    }

    func setFailed(_ message: String) {
        phase = .failed(message)
    }

    private static func preferredGlassesInput(in session: AVAudioSession) -> AVAudioSessionPortDescription? {
        let inputs = session.availableInputs ?? []
        return inputs.first { input in
            input.portType == .bluetoothHFP && isLikelyGlassesName(input.portName)
        }
    }

    private static func isLikelyGlassesName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("meta")
            || normalized.contains("ray-ban")
            || normalized.contains("rayban")
            || normalized.contains("glasses")
            || normalized.contains("stories")
    }

    private static func recordingErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain || nsError.domain == "NSOSStatusErrorDomain" {
            if let code = AVAudioSession.ErrorCode(rawValue: nsError.code) {
                switch code {
                case .cannotInterruptOthers, .cannotStartRecording, .isBusy, .insufficientPriority:
                    return "Microphone is busy — end the phone call or close other audio apps and try again."
                case .siriIsRecording:
                    return "Siri is using the microphone. Wait for it to finish and try again."
                default:
                    break
                }
            }
        }
        return error.localizedDescription
    }

    private func startTimer(targetURL: URL) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                let elapsed = Int(Date().timeIntervalSince(startedAt))
                if elapsed >= self.targetDuration {
                    self.finalizeRecording()
                } else {
                    self.phase = .recording(elapsed: elapsed)
                }
            }
        }
    }

    private func finalizeRecording() {
        guard let recorder, let url = recorder.url as URL? else { return }
        recorder.stop()
        timer?.invalidate()
        timer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        self.recorder = nil
        self.startedAt = nil
        phase = .ready(url)
    }
}

struct VoiceEnrollmentView: View {
    @Binding var isPresented: Bool
    let onSaved: (VoiceProfile) -> Void

    @StateObject private var recorder = VoiceEnrollmentRecorder()
    @State private var name: String = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Teach Her your voice")
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .italic()

                Text("Record yourself speaking naturally for about a minute. Say a few sentences in the language you usually use. We'll extract a voice fingerprint and use it to label you in future conversations.")
                    .font(.system(size: 14, design: .serif))
                    .foregroundColor(.secondary)
                    .lineSpacing(4)

                TextField("Display name (e.g. Erasul)", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.words)

                statusView

                Spacer()

                actionButton
            }
            .padding(20)
            .navigationTitle("Voice profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .alert(
                "Error",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch recorder.phase {
        case .idle:
            Label("Tap Record to begin", systemImage: "waveform")
                .foregroundColor(.secondary)
        case let .recording(elapsed):
            VStack(alignment: .leading, spacing: 6) {
                Text("Recording… \(elapsed)s / 60s")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                ProgressView(value: Double(elapsed), total: 60)
                    .tint(.red)
            }
        case .ready:
            Label("Recording captured. Save when you're ready.", systemImage: "checkmark.circle")
                .foregroundColor(.green)
        case .uploading:
            ProgressView("Uploading…")
        case .failed(let detail):
            Label(detail, systemImage: "exclamationmark.triangle")
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch recorder.phase {
        case .idle, .failed:
            Button(action: { Task { await recorder.start() } }) {
                Text("Record")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(.red)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        case .recording:
            Button(action: { recorder.stop() }) {
                Text(recorder.canStop ? "Stop" : "Hold (need ≥ 5s)")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(recorder.canStop ? Color.gray : Color.gray.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .disabled(!recorder.canStop)
        case .ready(let url):
            HStack(spacing: 12) {
                Button("Re-record") { recorder.reset() }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.3)))
                Button(action: { Task { await save(url: url) } }) {
                    Text("Save profile")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(name.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray : Color.black)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        case .uploading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 50)
        }
    }

    @MainActor
    private func save(url: URL) async {
        guard let service = VoiceProfilesService() else {
            errorMessage = "Backend not configured."
            return
        }
        recorder.setUploading()
        do {
            let profile = try await service.enroll(name: name, audioURL: url)
            try? FileManager.default.removeItem(at: url)
            onSaved(profile)
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
            recorder.setFailed(error.localizedDescription)
        }
    }
}
