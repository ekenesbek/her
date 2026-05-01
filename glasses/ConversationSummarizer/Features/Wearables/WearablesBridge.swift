import AVFoundation
import Combine
import Foundation

#if canImport(MWDATCore)
import MWDATCore
#endif

@MainActor
final class WearablesBridge: ObservableObject {
    @Published private(set) var state: WearablesState = .notDetected(activeRoute: "Checking audio route")
    @Published private(set) var audioRoute = WearablesAudioRoute.empty

    #if canImport(MWDATCore)
    private var activeSession: Any?
    #endif

    private var routeObserver: NSObjectProtocol?

    var isDATLinked: Bool {
        #if canImport(MWDATCore)
        return true
        #else
        return false
        #endif
    }

    init() {
        configure()
        startRouteMonitoring()
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
    }

    func configure() {
        refreshAudioRoute()

        #if canImport(MWDATCore)
        do {
            try Wearables.configure()
            state = .ready(audioRoute.primaryDetectedDevice)
        } catch {
            state = .failed(error.localizedDescription)
        }
        #endif
    }

    func refreshAudioRoute() {
        do {
            try configureAudioSessionForDiscovery(activate: false)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        audioRoute = Self.makeAudioRouteSnapshot()
        updateStateFromAudioRoute()
    }

    func startRegistration() {
        #if canImport(MWDATCore)
        do {
            try Wearables.shared.startRegistration()
            state = .registrationStarted
        } catch {
            state = .failed(error.localizedDescription)
        }
        #else
        state = .failed("Meta Wearables DAT is not linked in this build. Bluetooth audio detection is available.")
        #endif
    }

    func handleCallback(url: URL) async {
        #if canImport(MWDATCore)
        do {
            _ = try await Wearables.shared.handleUrl(url)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
        #else
        _ = url
        #endif
    }

    func startGlassesSession() {
        #if canImport(MWDATCore)
        Task {
            do {
                let wearables = Wearables.shared
                let selector = AutoDeviceSelector(wearables: wearables)
                let session = try wearables.createSession(deviceSelector: selector)
                activeSession = session
                try session.start()
                refreshAudioRoute()
                state = .sessionStarted(audioRoute.primaryDetectedDevice)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
        #else
        connectDetectedAudioRoute()
        #endif
    }

    func connectDetectedAudioRoute() {
        do {
            try configureAudioSessionForDiscovery(activate: true)

            let session = AVAudioSession.sharedInstance()
            if let input = Self.preferredBluetoothInput(in: session) {
                try session.setPreferredInput(input)
            }

            audioRoute = Self.makeAudioRouteSnapshot()

            if let device = audioRoute.primaryDetectedDevice, device.supportsInput {
                state = .sessionStarted(device)
            } else if let device = audioRoute.primaryDetectedDevice {
                state = .failed("\(device.name) is connected as audio output only. Select the hands-free Bluetooth route for microphone input.")
            } else {
                state = .failed("No glasses audio route detected. Pair the glasses in iOS Bluetooth, then refresh.")
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func startRouteMonitoring() {
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAudioRoute()
            }
        }
    }

    private func updateStateFromAudioRoute() {
        let detectedDevice = audioRoute.primaryDetectedDevice

        #if canImport(MWDATCore)
        switch state {
        case .registrationStarted:
            break
        case .sessionStarted:
            state = .sessionStarted(detectedDevice)
        default:
            state = .ready(detectedDevice)
        }
        #else
        if let detectedDevice {
            state = .detected(detectedDevice)
        } else {
            state = .notDetected(activeRoute: audioRoute.routeSummary)
        }
        #endif
    }

    private func configureAudioSessionForDiscovery(activate: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )

        if activate {
            try session.setActive(true, options: [])
        }
    }

    private static func makeAudioRouteSnapshot() -> WearablesAudioRoute {
        let session = AVAudioSession.sharedInstance()
        var devicesByName: [String: WearableDevice] = [:]

        func register(_ port: AVAudioSessionPortDescription, supportsInput: Bool, isActive: Bool) {
            guard isBluetooth(port.portType) || isLikelyGlassesName(port.portName) else {
                return
            }

            let key = port.portName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let existing = devicesByName[key]
            let device = WearableDevice(
                id: existing?.id ?? "\(port.portType.rawValue)-\(port.uid)",
                name: existing?.name ?? displayName(for: port),
                supportsInput: (existing?.supportsInput ?? false) || supportsInput,
                isActive: (existing?.isActive ?? false) || isActive,
                isLikelyGlasses: (existing?.isLikelyGlasses ?? false) || isLikelyGlassesName(port.portName),
                routeType: existing?.routeType ?? routeTypeName(for: port.portType)
            )
            devicesByName[key] = device
        }

        session.availableInputs?.forEach { input in
            register(input, supportsInput: true, isActive: false)
        }
        session.currentRoute.inputs.forEach { input in
            register(input, supportsInput: true, isActive: true)
        }
        session.currentRoute.outputs.forEach { output in
            register(output, supportsInput: false, isActive: true)
        }

        let devices = devicesByName.values.sorted { left, right in
            if left.isLikelyGlasses != right.isLikelyGlasses {
                return left.isLikelyGlasses
            }
            if left.supportsInput != right.supportsInput {
                return left.supportsInput
            }
            if left.isActive != right.isActive {
                return left.isActive
            }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }

        return WearablesAudioRoute(
            inputName: session.currentRoute.inputs.first.map(displayName(for:)) ?? "iPhone microphone",
            outputNames: session.currentRoute.outputs.map(displayName(for:)),
            availableInputNames: session.availableInputs?.map(displayName(for:)) ?? [],
            detectedDevices: devices
        )
    }

    private static func preferredBluetoothInput(in session: AVAudioSession) -> AVAudioSessionPortDescription? {
        let inputs = session.availableInputs ?? []
        return inputs.first { input in
            isBluetooth(input.portType) && isLikelyGlassesName(input.portName)
        } ?? inputs.first { input in
            isBluetooth(input.portType)
        }
    }

    private static func isBluetooth(_ portType: AVAudioSession.Port) -> Bool {
        switch portType {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return true
        default:
            return false
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

    private static func routeTypeName(for portType: AVAudioSession.Port) -> String {
        switch portType {
        case .bluetoothHFP:
            return "Bluetooth mic"
        case .bluetoothA2DP:
            return "Bluetooth audio"
        case .bluetoothLE:
            return "Bluetooth LE"
        default:
            return portType.rawValue
        }
    }

    private static func displayName(for port: AVAudioSessionPortDescription) -> String {
        switch port.portType {
        case .builtInMic:
            return "iPhone microphone"
        case .builtInSpeaker:
            return "Speaker"
        case .builtInReceiver:
            return "Receiver"
        case .headphones:
            return "Headphones"
        case .headsetMic:
            return "Headset mic"
        case .airPlay:
            return "AirPlay"
        case .carAudio:
            return "Car audio"
        case .usbAudio:
            return "USB audio"
        default:
            return port.portName
        }
    }
}

enum WearablesState: Equatable {
    case notDetected(activeRoute: String)
    case detected(WearableDevice)
    case ready(WearableDevice?)
    case registrationStarted
    case sessionStarted(WearableDevice?)
    case failed(String)

    var title: String {
        switch self {
        case .notDetected:
            return "Glasses not detected"
        case let .detected(device):
            return "\(device.name) detected"
        case .ready:
            return "Meta DAT ready"
        case .registrationStarted:
            return "Registration opened"
        case let .sessionStarted(device):
            if let device {
                return "\(device.name) selected"
            }
            return "Glasses session active"
        case .failed:
            return "Wearables error"
        }
    }

    var detail: String {
        switch self {
        case let .notDetected(activeRoute):
            return "Route: \(activeRoute)"
        case let .detected(device):
            return device.detailText
        case let .ready(device):
            if let device {
                return "Meta DAT is linked. Audio route sees \(device.name)."
            }
            return "Meta DAT is linked. No glasses audio route is active yet."
        case .registrationStarted:
            return "Finish the Meta AI app flow and return to this app."
        case let .sessionStarted(device):
            if let device {
                return "Recording will use \(device.name) when iOS keeps it as the active microphone route."
            }
            return "Recording will use the current iOS audio route."
        case let .failed(message):
            return message
        }
    }
}

struct WearableDevice: Equatable, Identifiable {
    let id: String
    let name: String
    let supportsInput: Bool
    let isActive: Bool
    let isLikelyGlasses: Bool
    let routeType: String

    var detailText: String {
        if supportsInput && isActive {
            return "\(routeType) is active for input."
        }
        if supportsInput {
            return "\(routeType) is available as microphone input."
        }
        if isActive {
            return "\(routeType) is active as output."
        }
        return "\(routeType) is available."
    }
}

struct WearablesAudioRoute: Equatable {
    static let empty = WearablesAudioRoute(
        inputName: "iPhone microphone",
        outputNames: [],
        availableInputNames: [],
        detectedDevices: []
    )

    let inputName: String
    let outputNames: [String]
    let availableInputNames: [String]
    let detectedDevices: [WearableDevice]

    var primaryDetectedDevice: WearableDevice? {
        detectedDevices.first
    }

    var routeSummary: String {
        let output = outputNames.isEmpty ? "iPhone speaker" : outputNames.joined(separator: ", ")
        return "\(inputName) -> \(output)"
    }
}
