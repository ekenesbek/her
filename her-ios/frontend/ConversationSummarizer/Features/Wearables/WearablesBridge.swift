import AVFoundation
import Combine
import Foundation

@MainActor
final class WearablesBridge: ObservableObject {
    @Published private(set) var state: WearablesState = .notDetected(activeRoute: "Checking audio route")
    @Published private(set) var audioRoute = WearablesAudioRoute.empty

    private var routeObserver: NSObjectProtocol?

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
    }

    func refreshAudioRoute() {
        refreshAudioRoute(configureSession: true)
    }

    func refreshAudioRoute(configureSession: Bool) {
        if configureSession {
            do {
                try configureAudioSessionForDiscovery(activate: false)
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
        }

        audioRoute = Self.makeAudioRouteSnapshot()
        updateStateFromAudioRoute()
    }

    func handleCallback(url: URL) async {
        _ = url
        refreshAudioRoute()
    }

    func connectDetectedAudioRoute() {
        do {
            try configureAudioSessionForDiscovery(activate: false)

            audioRoute = Self.makeAudioRouteSnapshot()

            if let device = audioRoute.primaryDetectedDevice {
                state = .detected(device)
            } else {
                state = .failed("No Bluetooth audio route detected. Pair or select the glasses in iOS Bluetooth, then refresh.")
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
                self?.refreshAudioRoute(configureSession: false)
            }
        }
    }

    private func updateStateFromAudioRoute() {
        if let detectedDevice = audioRoute.primaryDetectedDevice {
            state = .detected(detectedDevice)
        } else {
            state = .notDetected(activeRoute: audioRoute.routeSummary)
        }
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
    case failed(String)

    var title: String {
        switch self {
        case .notDetected:
            return "Using iPhone microphone"
        case let .detected(device):
            if device.supportsInput && device.isActive {
                return "Using \(device.name)"
            }
            if device.supportsInput {
                return "\(device.name) microphone ready"
            }
            return "\(device.name) output only"
        case .failed:
            return "Audio route issue"
        }
    }

    var detail: String {
        switch self {
        case let .notDetected(activeRoute):
            return "Route: \(activeRoute)"
        case let .detected(device):
            return device.detailText
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
            return "\(routeType) is active as output only. Recording will use the iPhone mic unless an HFP input is available."
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
