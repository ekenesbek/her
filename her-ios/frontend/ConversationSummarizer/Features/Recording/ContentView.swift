import AVFoundation
import CoreLocation
import SwiftUI
import UserNotifications

struct RootView: View {
    @ObservedObject var wearablesBridge: WearablesBridge
    @StateObject private var settings = AppSettingsStore()
    @StateObject private var authStore = AuthStore()

    var body: some View {
        if settings.onboardingCompleted {
            ContentView(wearablesBridge: wearablesBridge, settings: settings, authStore: authStore)
        } else {
            OnboardingView(wearablesBridge: wearablesBridge, settings: settings, authStore: authStore)
        }
    }
}

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published private(set) var aiName: String
    @Published private(set) var ownerName: String
    @Published private(set) var signInProvider: SignInProvider?
    @Published private(set) var onboardingCompleted: Bool
    @Published private(set) var glassesSetupSkipped: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        aiName = defaults.string(forKey: Keys.aiName) ?? "Her"
        ownerName = defaults.string(forKey: Keys.ownerName) ?? ""
        signInProvider = defaults.string(forKey: Keys.signInProvider).flatMap(SignInProvider.init(rawValue:))
        onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)
        glassesSetupSkipped = defaults.bool(forKey: Keys.glassesSetupSkipped)
    }

    var aiDisplayName: String {
        let trimmed = aiName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Her" : trimmed
    }

    var ownerDisplayName: String {
        let trimmed = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Owner" : trimmed
    }

    var logoText: String {
        String(aiDisplayName.prefix(1)).lowercased()
    }

    func completeOnboarding(
        aiName: String,
        ownerName: String,
        signInProvider: SignInProvider,
        glassesSetupSkipped: Bool
    ) {
        self.aiName = Self.clean(aiName, fallback: "Her")
        self.ownerName = Self.clean(ownerName, fallback: "Owner")
        self.signInProvider = signInProvider
        self.glassesSetupSkipped = glassesSetupSkipped
        onboardingCompleted = true
        persist()
    }

    func completeOnboardingForExistingAccount(
        session: AuthSession,
        provider: SignInProvider,
        glassesSetupSkipped: Bool = true
    ) {
        completeOnboarding(
            aiName: aiDisplayName,
            ownerName: session.user.name ?? ownerDisplayName,
            signInProvider: provider,
            glassesSetupSkipped: glassesSetupSkipped
        )
    }

    func saveProfile(aiName: String, ownerName: String) {
        self.aiName = Self.clean(aiName, fallback: "Her")
        self.ownerName = Self.clean(ownerName, fallback: "Owner")
        persist()
    }

    func resetOnboarding() {
        aiName = "Her"
        ownerName = ""
        signInProvider = nil
        onboardingCompleted = false
        glassesSetupSkipped = false
        persist()
    }

    private func persist() {
        defaults.set(aiName, forKey: Keys.aiName)
        defaults.set(ownerName, forKey: Keys.ownerName)
        defaults.set(signInProvider?.rawValue, forKey: Keys.signInProvider)
        defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted)
        defaults.set(glassesSetupSkipped, forKey: Keys.glassesSetupSkipped)
    }

    private static func clean(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private enum Keys {
        static let aiName = "app.settings.aiName"
        static let ownerName = "app.settings.ownerName"
        static let signInProvider = "app.settings.signInProvider"
        static let onboardingCompleted = "app.settings.onboardingCompleted"
        static let glassesSetupSkipped = "app.settings.glassesSetupSkipped"
    }
}

enum SignInProvider: String, CaseIterable, Identifiable {
    case apple
    case google

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple:
            return "Apple Account"
        case .google:
            return "Google"
        }
    }

    var icon: String {
        switch self {
        case .apple:
            return "apple.logo"
        case .google:
            return "g.circle"
        }
    }
}

private final class LiveContextStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var locationName: String?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var isRequestingLocation = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
    }

    func refreshIfAuthorized() {
        guard CLLocationManager.locationServicesEnabled() else {
            locationName = nil
            return
        }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            requestCurrentLocation()
        case .notDetermined, .denied, .restricted:
            locationName = nil
        @unknown default:
            locationName = nil
        }
    }

    func prepareForRecording() {
        guard CLLocationManager.locationServicesEnabled() else {
            locationName = nil
            return
        }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            requestCurrentLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            locationName = nil
        @unknown default:
            locationName = nil
        }
    }

    func homeContextLabel(for date: Date) -> String {
        var parts = [Self.dayFormatter.string(from: date).lowercased()]
        if let locationName {
            parts.append(locationName.lowercased())
        }
        return parts.joined(separator: " · ")
    }

    var recordingLocationLabel: String {
        locationName ?? fallbackLocationLabel
    }

    var recordingLocationName: String? {
        locationName
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshIfAuthorized()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        isRequestingLocation = false
        guard let location = locations.last else {
            return
        }
        reverseGeocode(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        isRequestingLocation = false
    }

    private var fallbackLocationLabel: String {
        switch manager.authorizationStatus {
        case .notDetermined:
            return "location permission pending"
        case .denied, .restricted:
            return "location unavailable"
        case .authorizedAlways, .authorizedWhenInUse:
            return "location pending"
        @unknown default:
            return "location unavailable"
        }
    }

    private func requestCurrentLocation() {
        guard !isRequestingLocation else {
            return
        }
        isRequestingLocation = true
        manager.requestLocation()
    }

    private func reverseGeocode(_ location: CLLocation) {
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let self else {
                return
            }

            let name = Self.displayName(for: placemarks?.first)

            DispatchQueue.main.async {
                self.locationName = name
            }
        }
    }

    private static func displayName(for place: CLPlacemark?) -> String? {
        guard let place else {
            return nil
        }

        let street = joinedAddressPart([place.thoroughfare, place.subThoroughfare], separator: " ")
        let city = cleaned(place.locality)
            ?? cleaned(place.subAdministrativeArea)
            ?? cleaned(place.administrativeArea)
        if let street, let address = joinedAddressPart([street, city], separator: ", ") {
            return address
        }

        let namedPlace = cleaned(place.name)
        if let namedPlaceValue = namedPlace {
            let namedPlaceIsCity = city.map { $0 == namedPlaceValue } ?? false
            if !namedPlaceIsCity, let address = joinedAddressPart([namedPlaceValue, city], separator: ", ") {
                return address
            }
        }

        return city
            ?? namedPlace
            ?? cleaned(place.locality)
            ?? cleaned(place.subAdministrativeArea)
            ?? cleaned(place.administrativeArea)
            ?? cleaned(place.country)
    }

    private static func joinedAddressPart(_ parts: [String?], separator: String) -> String? {
        let cleanParts = parts.compactMap(cleaned)
        guard !cleanParts.isEmpty else {
            return nil
        }
        return cleanParts.joined(separator: separator)
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE · MMM d"
        return formatter
    }()
}

private enum MainRoute {
    case home
    case pair
    case deviceConnected
    case conversations
    case detail
    case memory
    case recording
    case her
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var wearablesBridge: WearablesBridge
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var authStore: AuthStore
    @StateObject private var viewModel: ConversationSessionViewModel
    @StateObject private var wakeCommands = WakeCommandController()
    @StateObject private var liveContext = LiveContextStore()
    @StateObject private var meetingsStore = MeetingsStore()
    @State private var route: MainRoute = .home
    @State private var recordingMuted = false
    @State private var selectedMeeting: StoredMeeting?

    init(wearablesBridge: WearablesBridge, settings: AppSettingsStore, authStore: AuthStore) {
        self.wearablesBridge = wearablesBridge
        self.settings = settings
        self.authStore = authStore
        _viewModel = StateObject(
            wrappedValue: ConversationSessionViewModel(
                recorder: MeetingRecorder(),
                summaryService: SummaryServiceFactory.make(),
                meetingProcessor: MeetingProcessingServiceFactory.make(),
                meetingsService: MeetingsServiceFactory.make()
            )
        )
    }

    var body: some View {
        NavigationView {
            ZStack {
                AppTheme.bg.ignoresSafeArea()

                switch route {
                case .home:
                    ExactHomeScreen(
                        viewModel: viewModel,
                        bridge: wearablesBridge,
                        settings: settings,
                        liveContext: liveContext,
                        meetings: meetingsStore.meetings,
                        onSettings: {
                            route = .her
                        },
                        onPair: showDeviceFlow,
                        onConversations: {
                            route = .conversations
                        },
                        onRecord: showRecording,
                        onMemory: {
                            route = .memory
                        },
                        onHer: {
                            route = .her
                        },
                        onSelectConversation: { meeting in
                            selectedMeeting = meeting
                            route = .detail
                        },
                        onGenerateSummary: {
                            Task { @MainActor in
                                await viewModel.generateSummary()
                            }
                        }
                    )
                case .pair:
                    ExactPairRayBanScreen(
                        bridge: wearablesBridge,
                        onBack: { route = .home },
                        onFinish: { route = .deviceConnected },
                        onSkip: { route = .home }
                    )
                case .deviceConnected:
                    ExactDeviceConnectedScreen(
                        bridge: wearablesBridge,
                        onBack: { route = .home },
                        onConnect: {
                            wearablesBridge.startGlassesSession()
                        },
                        onRecord: showRecording
                    )
                case .conversations:
                    ExactConversationsScreen(
                        meetings: meetingsStore.meetings,
                        onBackHome: { route = .home },
                        onSelect: { meeting in
                            selectedMeeting = meeting
                            route = .detail
                        },
                        onRecord: showRecording,
                        onMemory: { route = .memory },
                        onHer: { route = .her }
                    )
                case .detail:
                    ExactConversationDetailScreen(
                        meeting: selectedMeeting,
                        currentUserName: currentUserDisplayName,
                        onBack: { route = .conversations },
                        onGenerateSummary: { meeting in
                            selectedMeeting = try? await meetingsStore.generateSummary(for: meeting)
                        },
                        onUpdateTranscript: { meeting, transcript, segments in
                            let updated = try await meetingsStore.updateTranscript(
                                for: meeting,
                                transcript: transcript,
                                segments: segments
                            )
                            selectedMeeting = updated
                            return updated
                        },
                        onAssignSpeaker: { meeting, speaker, profileId, name in
                            let result = try await meetingsStore.assignSpeaker(
                                for: meeting,
                                speaker: speaker,
                                profileId: profileId,
                                name: name
                            )
                            selectedMeeting = result.meeting
                            return result
                        }
                    )
                case .memory:
                    ExactMemoryScreen(
                        recording: viewModel.phase == .recording,
                        onHome: { route = .home },
                        onConversations: { route = .conversations },
                        onRecord: showRecording,
                        onHer: { route = .her }
                    )
                case .recording:
                    ExactRecordingScreen(
                        viewModel: viewModel,
                        liveContext: liveContext,
                        muted: $recordingMuted,
                        currentUserName: currentUserDisplayName,
                        onStop: stopRecordingAndStay,
                        onContinue: continueInterruptedRecording,
                        onFinishInterrupted: finishInterruptedRecording,
                        onGenerateSummary: {
                            Task { @MainActor in
                                await viewModel.generateSummary()
                            }
                        },
                        onDismiss: { route = .home }
                    )
                case .her:
                    ExactSettingsHerScreen(
                        settings: settings,
                        bridge: wearablesBridge,
                        viewModel: viewModel,
                        wakeCommands: wakeCommands,
                        authStore: authStore,
                        onHome: { route = .home },
                        onConversations: { route = .conversations },
                        onRecord: showRecording,
                        onMemory: { route = .memory },
                        onPair: showDeviceFlow
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .onAppear {
            liveContext.refreshIfAuthorized()
            wakeCommands.configure(assistantName: settings.aiDisplayName)
            wakeCommands.setAppActive(scenePhase == .active)
            Task { @MainActor in
                await meetingsStore.refresh()
                await viewModel.recoverIfNeeded()
            }
        }
        .onChange(of: viewModel.phase) { newPhase in
            if shouldKeepCurrentRecordingOpen(for: newPhase) {
                route = .recording
            }
            if newPhase == .recording {
                wakeCommands.listenForStopWhileRecording()
            } else if newPhase == .interrupted {
                wakeCommands.pauseForRecording()
            } else {
                wakeCommands.resumeAfterRecordingIfNeeded()
            }
            if newPhase == .completed || newPhase == .transcriptReady {
                Task { @MainActor in
                    await openCurrentProcessedMeeting()
                }
            }
        }
        .onChange(of: settings.aiDisplayName) { newName in
            wakeCommands.configure(assistantName: newName)
        }
        .onChange(of: scenePhase) { newPhase in
            wakeCommands.setAppActive(newPhase == .active)
        }
        .onReceive(NotificationCenter.default.publisher(for: .herWakeWordDetected)) { _ in
            handleWakeWordDetected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .herWakeStartRecordingRequested)) { _ in
            handleWakeStartRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .herWakeStopRecordingRequested)) { _ in
            handleWakeStopRecording()
        }
    }

    private func shouldKeepCurrentRecordingOpen(for phase: RecordingPhase) -> Bool {
        switch phase {
        case .recording, .interrupted, .transcribing, .summarizing, .failed:
            return true
        case .idle, .transcriptReady, .completed:
            return false
        }
    }

    private func openCurrentProcessedMeeting() async {
        await meetingsStore.refresh()
        guard let meetingId = viewModel.currentMeetingId,
              let meeting = meetingsStore.meetings.first(where: { $0.id == meetingId }) else {
            return
        }
        selectedMeeting = meeting
        route = .detail
    }

    private func showRecording() {
        if viewModel.phase == .recording || viewModel.phase == .interrupted {
            recordingMuted = false
            route = .recording
            return
        }

        guard viewModel.canTapPrimaryButton else {
            return
        }

        Task { @MainActor in
            wakeCommands.pauseForRecording()
            wearablesBridge.refreshAudioRoute()
            liveContext.prepareForRecording()
            let didStart = await viewModel.startRecording()
            guard didStart else {
                wakeCommands.resumeAfterRecordingIfNeeded()
                return
            }

            recordingMuted = false
            route = .recording
        }
    }

    private func showDeviceFlow() {
        wearablesBridge.refreshAudioRoute()
        if wearablesBridge.audioRoute.primaryDetectedDevice == nil {
            route = .pair
        } else {
            route = .deviceConnected
        }
    }

    private func stopRecordingAndStay() {
        guard viewModel.phase == .recording else {
            return
        }

        Task { @MainActor in
            route = .recording
            wakeCommands.pauseForRecording()
            await viewModel.stopAndTranscribe(locationName: liveContext.recordingLocationName)
        }
    }

    private func continueInterruptedRecording() {
        guard viewModel.phase == .interrupted else {
            return
        }

        Task { @MainActor in
            liveContext.prepareForRecording()
            _ = await viewModel.continueRecording()
            recordingMuted = false
        }
    }

    private func finishInterruptedRecording() {
        guard viewModel.phase == .interrupted else {
            return
        }

        Task { @MainActor in
            route = .recording
            wakeCommands.pauseForRecording()
            await viewModel.stopAndTranscribe(locationName: liveContext.recordingLocationName)
        }
    }

    private func handleWakeWordDetected() {
        recordingMuted = false
        route = .recording
    }

    private func handleWakeStartRecording() {
        if viewModel.phase == .interrupted {
            continueInterruptedRecording()
        } else if viewModel.phase == .recording {
            route = .recording
        } else {
            showRecording()
        }
    }

    private func handleWakeStopRecording() {
        if viewModel.phase == .recording {
            stopRecordingAndStay()
        } else if viewModel.phase == .interrupted {
            finishInterruptedRecording()
        } else {
            route = .recording
        }
    }

    private var currentUserDisplayName: String {
        if let name = authStore.session?.user.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let email = authStore.session?.user.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email.components(separatedBy: "@").first ?? email
        }
        return settings.ownerDisplayName
    }
}

private struct ExactBrandBar: View {
    let status: String

    var body: some View {
        HStack(spacing: 10) {
            HerOrb(size: 22)
            Text("Her")
                .font(.system(size: 17, weight: .medium, design: .serif))
                .foregroundColor(AppTheme.fg)
            Spacer()
            Text(status.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(AppTheme.dim)
                .tracking(1.5)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

private struct ExactHomeScreen: View {
    @ObservedObject var viewModel: ConversationSessionViewModel
    @ObservedObject var bridge: WearablesBridge
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var liveContext: LiveContextStore
    let meetings: [StoredMeeting]
    let onSettings: () -> Void
    let onPair: () -> Void
    let onConversations: () -> Void
    let onRecord: () -> Void
    let onMemory: () -> Void
    let onHer: () -> Void
    let onSelectConversation: (StoredMeeting) -> Void
    let onGenerateSummary: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ExactHomeTopBar(
                bridge: bridge,
                status: isRecording ? "● LISTENING" : "IDLE",
                onDevice: onPair
            )

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    TimelineView(.periodic(from: Date(), by: 60)) { timeline in
                        MonoLabel(liveContext.homeContextLabel(for: timeline.date))
                    }
                    Text(isRecording ? "Listening, \(settings.ownerDisplayName)..." : "Good morning, \(settings.ownerDisplayName).")
                        .font(.system(size: 28, weight: .medium, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.fg)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .padding(.top, 6)

                    Text(homeDetailText)
                        .font(.system(size: 14, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.muted)
                        .lineSpacing(4)
                        .padding(.top, 8)

                    if let errorMessage = viewModel.errorMessage {
                        ErrorBanner(message: errorMessage)
                            .padding(.top, 18)
                    }

                    if shouldShowCurrentSession {
                        ExactCurrentSessionCard(viewModel: viewModel, onGenerateSummary: onGenerateSummary)
                            .padding(.top, 18)
                    }

                    ExactTodaySnapshot(meetings: meetings, activeElapsedSeconds: isRecording ? viewModel.elapsedSeconds : 0)
                        .padding(.top, 18)

                    ExactRecentList(items: Array(meetings.prefix(2)), onSelect: onSelectConversation, onSeeAll: onConversations)
                        .padding(.top, 20)
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 36)
            }

            ExactTabBar(activeIndex: 0, recording: isRecording, onHome: {}, onRecord: onRecord, onLog: onConversations, onMemory: onMemory, onHer: onHer)
        }
    }

    private var isRecording: Bool {
        viewModel.phase == .recording
    }

    private var shouldShowCurrentSession: Bool {
        viewModel.phase == .recording
            || viewModel.phase == .interrupted
            || viewModel.phase == .transcribing
            || viewModel.phase == .transcriptReady
            || viewModel.phase == .summarizing
            || viewModel.summary != nil
            || !viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var homeDetailText: String {
        if isRecording {
            return "Capturing audio. Stop when the conversation ends."
        }
        if viewModel.phase == .interrupted {
            return "Recording was paused by iOS. Continue or finish the captured audio."
        }
        if viewModel.phase == .transcriptReady {
            return "Transcript is ready. Generate a summary when you need it."
        }
        if meetings.isEmpty {
            return "No conversations saved yet."
        }
        return "\(meetings.count) saved conversation\(meetings.count == 1 ? "" : "s")."
    }
}

private struct ExactHomeTopBar: View {
    @ObservedObject var bridge: WearablesBridge
    let status: String
    let onDevice: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onDevice) {
                HStack(spacing: 8) {
                    RayBanPhoto()
                        .frame(width: 46, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ray-Ban")
                            .font(.system(size: 12, weight: .medium, design: .serif))
                            .foregroundColor(AppTheme.fg)
                        MonoLabel(deviceStatus, color: deviceStatusColor)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 42)
                .background(Capsule().fill(AppTheme.bgSoft))
                .overlay(Capsule().stroke(AppTheme.borderStrong, lineWidth: 1))
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()

            Text(status.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(AppTheme.dim)
                .tracking(1.5)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var deviceStatus: String {
        if let device = bridge.audioRoute.primaryDetectedDevice {
            if device.supportsInput && device.isActive {
                return "connected"
            }
            if device.supportsInput {
                return "mic ready"
            }
            return "audio only"
        }
        return "searching"
    }

    private var deviceStatusColor: Color {
        bridge.audioRoute.primaryDetectedDevice == nil ? AppTheme.dim : AppTheme.fg
    }
}

private struct ExactGlassesStatusCard: View {
    @ObservedObject var bridge: WearablesBridge
    let onPair: () -> Void

    var body: some View {
        WwCard {
            HStack(alignment: .center, spacing: 14) {
                SmallGlassesIcon()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ray-Ban Meta")
                        .font(.system(size: 13.5, weight: .medium, design: .serif))
                        .foregroundColor(AppTheme.fg)
                    Text(detailText)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundColor(AppTheme.dim)
                        .tracking(1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                Spacer()
                Button(action: onPair) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(linked ? AppTheme.fg : AppTheme.dim)
                            .frame(width: 5, height: 5)
                        Text(linked ? "linked" : "pair")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(1.5)
                    }
                    .foregroundColor(AppTheme.fg)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .overlay(Capsule().stroke(AppTheme.fg, lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private var linked: Bool {
        bridge.audioRoute.primaryDetectedDevice != nil
    }

    private var detailText: String {
        if let device = bridge.audioRoute.primaryDetectedDevice {
            return "\(device.name.uppercased()) · \(device.supportsInput ? "MIC READY" : "OUTPUT")"
        }
        return "NOT FOUND · TAP PAIR"
    }
}

private struct ExactCurrentSessionCard: View {
    @ObservedObject var viewModel: ConversationSessionViewModel
    let onGenerateSummary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel("current session")
            WwCard(background: AppTheme.bgSoft, showsBorder: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title)
                        .font(.system(size: 18, weight: .medium, design: .serif))
                        .foregroundColor(AppTheme.fg)
                    Text(detail)
                        .font(.system(size: 14, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.muted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)

                    if viewModel.canGenerateSummary || viewModel.phase == .summarizing {
                        WwPrimaryButton(viewModel.summaryButtonTitle, disabled: !viewModel.canGenerateSummary) {
                            onGenerateSummary()
                        }
                    }
                }
            }
        }
    }

    private var title: String {
        if let summary = viewModel.summary {
            return summary.title
        }
        switch viewModel.phase {
        case .recording:
            return "Recording in progress"
        case .interrupted:
            return "Recording paused"
        case .transcribing:
            return "Preparing transcript"
        case .transcriptReady:
            return "Transcript ready"
        case .summarizing:
            return "Generating summary"
        case .completed:
            return "Summary ready"
        case .failed:
            return "Session needs attention"
        case .idle:
            return "No active session"
        }
    }

    private var detail: String {
        if let summary = viewModel.summary {
            return summary.overview
        }
        let trimmedTranscript = viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTranscript.isEmpty {
            return trimmedTranscript
        }
        if viewModel.phase == .recording {
            return "Recording through \(viewModel.activeInputName)."
        }
        if viewModel.phase == .interrupted {
            return "Recording was paused by iOS. Continue or finish the captured audio."
        }
        return "Transcript will appear here after recording stops."
    }
}

private struct ExactTodaySnapshot: View {
    let meetings: [StoredMeeting]
    let activeElapsedSeconds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel("today, so far")
            WwCard(background: AppTheme.bgSoft, showsBorder: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(summaryText)
                        .font(.system(size: 16, weight: .regular, design: .serif))
                        .foregroundColor(AppTheme.fg)
                        .lineSpacing(5)
                    DividerLine()
                    HStack(spacing: 14) {
                        ExactMetric(value: durationText, label: "recorded")
                        ExactMetric(value: "\(todayMeetings.count)", label: "saved")
                        ExactMetric(value: "\(followUpCount)", label: "follow-up")
                    }
                }
            }
        }
    }

    private var todayMeetings: [StoredMeeting] {
        meetings.filter { Calendar.current.isDateInToday($0.createdAt) }
    }

    private var recordedSeconds: Int {
        todayMeetings.reduce(activeElapsedSeconds) { total, meeting in
            total + Int((meeting.durationSeconds ?? 0).rounded())
        }
    }

    private var followUpCount: Int {
        todayMeetings.reduce(0) { $0 + $1.summary.followUps.count }
    }

    private var durationText: String {
        guard recordedSeconds > 0 else {
            return "0m"
        }
        let minutes = recordedSeconds / 60
        return minutes > 0 ? "\(minutes)m" : "\(recordedSeconds)s"
    }

    private var summaryText: String {
        if todayMeetings.isEmpty && activeElapsedSeconds == 0 {
            return "No conversations recorded today."
        }
        return "\(todayMeetings.count) saved conversation\(todayMeetings.count == 1 ? "" : "s") today across \(durationText)."
    }
}

private struct ExactMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .medium, design: .serif))
                .foregroundColor(AppTheme.fg)
            MonoLabel(label)
        }
    }
}

private struct ExactRecentList: View {
    let items: [StoredMeeting]
    let onSelect: (StoredMeeting) -> Void
    let onSeeAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MonoLabel("recent")
                Spacer()
                Button(action: onSeeAll) {
                    Text("see all →")
                        .font(.system(size: 12, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.fg)
                }
                .buttonStyle(PlainButtonStyle())
            }

            WwCard(padding: 0) {
                VStack(spacing: 0) {
                    if items.isEmpty {
                        Text("No saved conversations yet.")
                            .font(.system(size: 14, weight: .regular, design: .serif))
                            .italic()
                            .foregroundColor(AppTheme.muted)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button(action: { onSelect(item) }) {
                                ConversationListRow(item: item)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(PlainButtonStyle())

                            if index < items.count - 1 {
                                DividerLine()
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ExactPairRayBanScreen: View {
    @ObservedObject var bridge: WearablesBridge
    let onBack: () -> Void
    let onFinish: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WwHeader(pre: "connect", title: "Searching for Ray-Ban.", italic: true, onBack: onBack)

            VStack(alignment: .leading, spacing: 0) {
                Text("Open the case near your phone. If they already appear in iOS Bluetooth, Her will show them here.")
                    .font(.system(size: 14, weight: .regular, design: .serif))
                    .foregroundColor(AppTheme.muted)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    ForEach([CGFloat(110), CGFloat(190), CGFloat(270)], id: \.self) { diameter in
                        Circle()
                            .stroke(AppTheme.border, lineWidth: 1)
                            .frame(width: diameter, height: diameter)
                    }
                    VStack(spacing: 18) {
                        LargeGlassesIcon()
                            .frame(width: 270, height: 110)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(AppTheme.fg)
                                .frame(width: 6, height: 6)
                            Text(deviceStatusText)
                                .font(.system(size: 13, weight: .regular, design: .serif))
                                .italic()
                                .foregroundColor(AppTheme.fg)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
                .frame(minHeight: 300)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(AppTheme.bgSoft))
                .padding(.vertical, 20)
                .layoutPriority(1)

                WwCard {
                    HStack(spacing: 14) {
                        SmallGlassesIcon()
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bridge.audioRoute.primaryDetectedDevice?.name ?? "Ray-Ban Wayfarer")
                                .font(.system(size: 13.5, weight: .medium, design: .serif))
                                .foregroundColor(AppTheme.fg)
                            Text("MATTE BLACK · LAST 4: 7C2A")
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .tracking(1)
                                .foregroundColor(AppTheme.dim)
                        }
                        Spacer()
                        Button(action: {
                            if bridge.performSetupPairAction() {
                                onFinish()
                            }
                        }) {
                            Text(bridge.setupPairActionTitle)
                                .font(.system(size: 13, weight: .medium, design: .serif))
                                .foregroundColor(AppTheme.bg)
                                .padding(.horizontal, 16)
                                .frame(height: 34)
                                .background(Capsule().fill(AppTheme.fg))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }

                WwGhostButton(title: "I'll do it later", action: onSkip)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deviceStatusText: String {
        bridge.audioRoute.primaryDetectedDevice == nil ? "searching..." : "device found"
    }
}

private struct ExactDeviceConnectedScreen: View {
    @ObservedObject var bridge: WearablesBridge
    let onBack: () -> Void
    let onConnect: () -> Void
    let onRecord: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WwHeader(pre: "device", title: "Ray-Ban connected.", italic: true, onBack: onBack)

            VStack(alignment: .leading, spacing: 0) {
                Text("Her can now use the active iOS audio route for recording. Keep the glasses selected as the microphone route when the meeting starts.")
                    .font(.system(size: 14, weight: .regular, design: .serif))
                    .foregroundColor(AppTheme.muted)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)

                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(AppTheme.bgSoft)
                    VStack(spacing: 20) {
                        RayBanPhoto()
                            .frame(width: 290, height: 130)
                        VStack(spacing: 6) {
                            Text(deviceName)
                                .font(.system(size: 22, weight: .medium, design: .serif))
                                .foregroundColor(AppTheme.fg)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            MonoLabel(deviceDetail, color: AppTheme.dim)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 330)
                .padding(.vertical, 20)

                WwCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            MonoLabel("status", color: AppTheme.dim)
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 6, height: 6)
                                MonoLabel(statusLabel, color: statusColor)
                            }
                        }
                        DividerLine()
                        RouteInfoRow(label: "ROUTE", value: bridge.audioRoute.routeSummary)
                        RouteInfoRow(label: "MIC", value: micLabel)
                    }
                }

                HStack(spacing: 10) {
                    WwGhostButton(title: "Refresh route") {
                        bridge.refreshAudioRoute()
                    }
                    Button(action: onConnect) {
                        Text("use glasses")
                            .font(.system(size: 14, weight: .medium, design: .serif))
                            .foregroundColor(AppTheme.bg)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.fg))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.top, 12)

                WwGhostButton(title: "Start recording", action: onRecord)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deviceName: String {
        bridge.audioRoute.primaryDetectedDevice?.name ?? "Ray-Ban Wayfarer"
    }

    private var deviceDetail: String {
        guard let device = bridge.audioRoute.primaryDetectedDevice else {
            return "waiting for bluetooth"
        }
        if device.supportsInput && device.isActive {
            return "connected · microphone active"
        }
        if device.supportsInput {
            return "connected · microphone ready"
        }
        return "connected · audio output"
    }

    private var micLabel: String {
        guard let device = bridge.audioRoute.primaryDetectedDevice else {
            return "not detected"
        }
        return device.supportsInput ? "available" : "output only"
    }

    private var statusLabel: String {
        bridge.audioRoute.primaryDetectedDevice == nil ? "searching" : "connected"
    }

    private var statusColor: Color {
        bridge.audioRoute.primaryDetectedDevice == nil ? AppTheme.dim : AppTheme.fg
    }
}

private struct ExactConversationsScreen: View {
    let meetings: [StoredMeeting]
    let onBackHome: () -> Void
    let onSelect: (StoredMeeting) -> Void
    let onRecord: () -> Void
    let onMemory: () -> Void
    let onHer: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("conversations")
                    .font(.system(size: 32, weight: .medium, design: .serif))
                    .italic()
                    .foregroundColor(AppTheme.fg)
                Spacer()
                Text("\(items.count) ITEMS")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(AppTheme.dim)
                    .tracking(1)
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                HerOrb(size: 16)
                Text(items.isEmpty ? "record a conversation to start the log." : "open a conversation to review transcript, summary, and chat.")
                    .font(.system(size: 13.5, weight: .regular, design: .serif))
                    .italic()
                    .foregroundColor(AppTheme.muted)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Capsule().fill(AppTheme.bgSoft).overlay(Capsule().stroke(AppTheme.borderStrong, lineWidth: 1)))
            .padding(.horizontal, 22)
            .padding(.bottom, 14)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if items.isEmpty {
                        ConversationEmptyState()
                            .padding(.top, 18)
                    } else {
                        ForEach(groupedItems.indices, id: \.self) { groupIndex in
                            let group = groupedItems[groupIndex]
                            Text(group.date)
                                .font(.system(size: 13, weight: .regular, design: .serif))
                                .italic()
                                .foregroundColor(AppTheme.dim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                                .overlay(alignment: .bottom) { DividerLine() }

                            ForEach(group.items) { item in
                                Button(action: { onSelect(item) }) {
                                    ConversationListRow(item: item)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                }
                .padding(.horizontal, 22)
            }

            ExactTabBar(activeIndex: 1, recording: false, onHome: onBackHome, onRecord: onRecord, onLog: {}, onMemory: onMemory, onHer: onHer)
        }
    }

    private var items: [StoredMeeting] {
        meetings
    }

    private var groupedItems: [(date: String, items: [StoredMeeting])] {
        var result: [(String, [StoredMeeting])] = []
        for item in items {
            let date = item.displayDate
            if result.last?.0 == date {
                result[result.count - 1].1.append(item)
            } else {
                result.append((date, [item]))
            }
        }
        return result
    }
}

private struct ConversationEmptyState: View {
    var body: some View {
        WwCard {
            VStack(alignment: .leading, spacing: 8) {
                MonoLabel("empty")
                Text("No backend conversations yet.")
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .foregroundColor(AppTheme.fg)
                Text("Saved meetings from the backend will appear here when the database is not empty.")
                    .font(.system(size: 14, weight: .regular, design: .serif))
                    .italic()
                    .foregroundColor(AppTheme.muted)
                    .lineSpacing(4)
            }
        }
    }
}

private struct ConversationListRow: View {
    let item: StoredMeeting

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTime)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(AppTheme.fg)
                Text(item.sourceLabel.uppercased())
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundColor(AppTheme.dim)
            }
            .frame(width: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundColor(AppTheme.fg)
                Text("\(item.displayLocation) · \(item.durationText)")
                    .font(.system(size: 12, weight: .regular, design: .serif))
                    .italic()
                    .foregroundColor(AppTheme.dim)
                if !item.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(item.tags, id: \.self) { tag in
                            Text(tag.uppercased())
                                .font(.system(size: 9, weight: .regular, design: .monospaced))
                                .foregroundColor(AppTheme.fg)
                                .padding(.horizontal, 9)
                                .frame(height: 20)
                                .overlay(Capsule().stroke(AppTheme.borderStrong, lineWidth: 1))
                        }
                    }
                }
            }
            Spacer()
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.fg)
                .padding(.top, 6)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { DividerLine() }
    }
}

private extension StoredMeeting {
    var displayTime: String {
        Self.timeFormatter.string(from: createdAt)
    }

    var displayDate: String {
        if Calendar.current.isDateInToday(createdAt) {
            return "today"
        }
        if Calendar.current.isDateInYesterday(createdAt) {
            return "yesterday"
        }
        return Self.dateFormatter.string(from: createdAt).lowercased()
    }

    var tags: [String] {
        [language, source]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)
            .map { String($0) }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

private struct ExactConversationDetailScreen: View {
    let meeting: StoredMeeting?
    let currentUserName: String
    let onBack: () -> Void
    let onGenerateSummary: (StoredMeeting) async -> Void
    let onUpdateTranscript: (StoredMeeting, String, [MeetingTranscriptSegment]) async throws -> StoredMeeting
    let onAssignSpeaker: (StoredMeeting, String, String?, String) async throws -> SpeakerAssignmentResult
    private let tabs = ["contents", "summary", "chat"]
    @State private var selectedTab = 0
    @State private var isGeneratingSummary = false

    var body: some View {
        VStack(spacing: 0) {
            detailHeader

            if let meeting {
                ExactSegmentedTabs(tabs: tabs, selectedIndex: $selectedTab)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 14)

                if selectedTab == 2 {
                    ConversationChatPanel(meeting: meeting)
                } else if selectedTab == 0 {
                    ScrollViewReader { scrollProxy in
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 16) {
                                ConversationContentsPanel(
                                    meeting: meeting,
                                    scrollProxy: scrollProxy,
                                    currentUserName: currentUserName,
                                    onUpdateTranscript: { transcript, segments in
                                        try await onUpdateTranscript(meeting, transcript, segments)
                                    },
                                    onAssignSpeaker: { speaker, profileId, name in
                                        try await onAssignSpeaker(meeting, speaker, profileId, name)
                                    }
                                )
                            }
                            .padding(.horizontal, 22)
                            .padding(.bottom, 14)
                        }
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 16) {
                            SummaryPanel(
                                summary: meeting.summary,
                                isGenerating: isGeneratingSummary,
                                onGenerateSummary: meeting.hasGeneratedSummary ? nil : {
                                    Task { @MainActor in
                                        isGeneratingSummary = true
                                        await onGenerateSummary(meeting)
                                        isGeneratingSummary = false
                                    }
                                }
                            )
                        }
                        .padding(.horizontal, 22)
                        .padding(.bottom, 14)
                    }
                }
            } else {
                ConversationEmptyState()
                    .padding(.horizontal, 22)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Text("←")
                        .font(.system(size: 22, weight: .regular, design: .serif))
                        .foregroundColor(AppTheme.fg)
                }
                .buttonStyle(PlainButtonStyle())
                MonoLabel(meeting?.sourceLabel ?? "conversation")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)

            Text(meeting?.title ?? "No conversation selected")
                .font(.system(size: 28, weight: .medium, design: .serif))
                .italic()
                .foregroundColor(AppTheme.fg)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let meeting {
                HStack(spacing: 14) {
                    Text(meeting.displayLocation)
                        .italic()
                    Text(meeting.durationText)
                        .italic()
                    Text(meeting.displayDate)
                        .italic()
                }
                .font(.system(size: 13, weight: .regular, design: .serif))
                .foregroundColor(AppTheme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }
}

private struct ExactSegmentedTabs: View {
    let tabs: [String]
    @Binding var selectedIndex: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                Button(action: { selectedIndex = index }) {
                    Text(tab)
                        .font(.system(size: 13, weight: .medium, design: .serif))
                        .italic()
                        .foregroundColor(index == selectedIndex ? AppTheme.bg : AppTheme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(Capsule().fill(index == selectedIndex ? AppTheme.fg : Color.clear))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(4)
        .background(Capsule().fill(AppTheme.bgSoft).overlay(Capsule().stroke(AppTheme.border, lineWidth: 1)))
    }
}

private struct ConversationChatPanel: View {
    let meeting: StoredMeeting
    @State private var draft = ""
    @State private var messages: [ConversationChatMessage] = []
    @State private var isSending = false
    private let chatService = MeetingChatServiceFactory.make()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty {
                        ChatEmptyState()
                    } else {
                        ForEach(messages) { message in
                            ConversationChatBubble(message: message)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            }

            HStack(spacing: 10) {
                TextField("", text: $draft, prompt: Text("Ask about this conversation").foregroundColor(AppTheme.dim))
                    .font(.system(size: 14, weight: .regular, design: .serif))
                    .foregroundColor(AppTheme.fg)
                    .foregroundStyle(AppTheme.fg)
                    .tint(AppTheme.fg)
                    .textFieldStyle(.plain)
                    .padding(.leading, 16)
                    .frame(height: 46)

                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.bg)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(canSend ? AppTheme.fg : AppTheme.dim))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!canSend)
                .padding(.trailing, 6)
            }
            .background(Capsule().fill(AppTheme.bgSoft).overlay(Capsule().stroke(AppTheme.borderStrong, lineWidth: 1)))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { DividerLine() }
        }
        .task(id: meeting.id) {
            await loadMessages()
        }
    }

    private var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            return
        }

        let assistantMessageId = UUID()
        messages.append(ConversationChatMessage(role: .user, text: question))
        messages.append(ConversationChatMessage(role: .assistant, text: "", id: assistantMessageId))
        draft = ""
        isSending = true

        Task { @MainActor in
            let answer: String
            if let chatService {
                do {
                    answer = try await chatService.ask(meetingId: meeting.id, question: question) { partial in
                        Task { @MainActor in
                            updateAssistantMessage(id: assistantMessageId, text: partial)
                        }
                    }
                } catch {
                    answer = localAnswer(for: question)
                }
            } else {
                answer = localAnswer(for: question)
            }
            updateAssistantMessage(id: assistantMessageId, text: answer)
            isSending = false
        }
    }

    private func loadMessages() async {
        guard let chatService else {
            messages = []
            return
        }
        do {
            let saved = try await chatService.messages(meetingId: meeting.id)
            messages = saved.compactMap { item in
                guard let role = ConversationChatMessage.Role(rawValue: item.role) else {
                    return nil
                }
                return ConversationChatMessage(role: role, text: item.content)
            }
        } catch {
            messages = []
        }
    }

    private func updateAssistantMessage(id: UUID, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[index].text = text
    }

    private func localAnswer(for question: String) -> String {
        let lowercased = question.lowercased()
        if lowercased.contains("action") || lowercased.contains("todo") || lowercased.contains("зада") {
            return meeting.summary.actionItems.isEmpty ? "No action items were found in this conversation." : meeting.summary.actionItems.joined(separator: "\n")
        }
        if lowercased.contains("decision") || lowercased.contains("реш") {
            return meeting.summary.decisions.isEmpty ? "No decisions were found in this conversation." : meeting.summary.decisions.joined(separator: "\n")
        }
        if lowercased.contains("follow") || lowercased.contains("напом") || lowercased.contains("след") {
            return meeting.summary.followUps.isEmpty ? "No follow-ups were found in this conversation." : meeting.summary.followUps.joined(separator: "\n")
        }
        if lowercased.contains("transcript") || lowercased.contains("транск") {
            return meeting.transcript
        }
        return meeting.summary.overview
    }
}

private struct ConversationChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: Role
    var text: String

    init(role: Role, text: String, id: UUID = UUID()) {
        self.id = id
        self.role = role
        self.text = text
    }

    enum Role: String, Equatable {
        case user
        case assistant
    }
}

private struct ConversationChatBubble: View {
    let message: ConversationChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 36)
            }
            bubbleContent
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(message.role == .user ? AppTheme.fg : AppTheme.bgSoft)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(message.role == .user ? Color.clear : AppTheme.borderStrong, lineWidth: 1)
                )
            if message.role == .assistant {
                Spacer(minLength: 36)
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.role == .assistant {
            FormattedChatMessage(text: displayText)
        } else {
            Text(displayText)
                .font(.system(size: 14, weight: .regular, design: .serif))
                .foregroundColor(AppTheme.bg)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var displayText: String {
        message.text.isEmpty ? "..." : message.text
    }
}

private struct FormattedChatMessage: View {
    let text: String

    private var blocks: [ChatDisplayBlock] {
        ChatMessageFormatter.blocks(from: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value):
                    ChatFormattedText(value)
                case .table(let table):
                    ChatTableBlock(table: table)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ChatFormattedText: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(ChatMessageFormatter.displayLines(from: value).enumerated()), id: \.offset) { _, line in
                if line.isEmpty {
                    Spacer(minLength: 3)
                } else if let attributed = ChatMessageFormatter.attributedString(from: line) {
                    Text(attributed)
                } else {
                    Text(ChatMessageFormatter.plainText(from: line))
                }
            }
        }
        .font(.system(size: 14, weight: .regular, design: .serif))
        .foregroundColor(AppTheme.fg)
        .lineSpacing(4)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ChatTableBlock: View {
    let table: ChatMarkdownTable

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                VStack(alignment: .leading, spacing: 7) {
                    if let rowLabel = table.rowLabel(for: row) {
                        MonoLabel(rowLabel, color: AppTheme.dim)
                    }

                    ForEach(row.indices, id: \.self) { columnIndex in
                        let cell = row[columnIndex]
                        if !cell.isEmpty && !table.shouldHideColumn(columnIndex, in: row) {
                            VStack(alignment: .leading, spacing: 2) {
                                if let header = table.header(at: columnIndex), table.rows.count > 1 {
                                    Text(header)
                                        .font(.system(size: 12, weight: .semibold, design: .serif))
                                        .foregroundColor(AppTheme.dim)
                                }
                                ChatFormattedText(cell)
                            }
                        }
                    }
                }

                if index < table.rows.count - 1 {
                    DividerLine()
                }
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(AppTheme.borderStrong)
                .frame(width: 2)
        }
    }
}

private enum ChatDisplayBlock {
    case text(String)
    case table(ChatMarkdownTable)
}

private struct ChatMarkdownTable {
    let headers: [String]
    let rows: [[String]]

    func header(at index: Int) -> String? {
        guard headers.indices.contains(index) else {
            return nil
        }
        let value = headers[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func rowLabel(for row: [String]) -> String? {
        guard shouldHideColumn(0, in: row), let value = row.first?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return "№ \(value)"
    }

    func shouldHideColumn(_ index: Int, in row: [String]) -> Bool {
        guard index == 0,
              row.indices.contains(index),
              let header = header(at: index) else {
            return false
        }
        let normalized = header.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == "#"
            || normalized == "№"
            || normalized == "no"
            || normalized == "n"
            || normalized.contains("номер")
    }
}

private enum ChatMessageFormatter {
    static func blocks(from text: String) -> [ChatDisplayBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [ChatDisplayBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let value = paragraph
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                blocks.append(.text(value))
            }
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if isTableLine(line) {
                flushParagraph()
                var tableLines: [String] = []
                while index < lines.count, isTableLine(lines[index]) {
                    tableLines.append(lines[index])
                    index += 1
                }

                if let table = table(from: tableLines) {
                    blocks.append(.table(table))
                } else {
                    paragraph.append(contentsOf: tableLines)
                }
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return blocks.isEmpty ? [.text(text)] : blocks
    }

    static func attributedString(from text: String) -> AttributedString? {
        let source = normalizedMarkdown(from: text)
        guard !source.isEmpty else {
            return nil
        }
        return try? AttributedString(markdown: source)
    }

    static func plainText(from text: String) -> String {
        normalizedMarkdown(from: text)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "### ", with: "")
            .replacingOccurrences(of: "## ", with: "")
            .replacingOccurrences(of: "# ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func displayLines(from text: String) -> [String] {
        let lines = normalizedMarkdown(from: text)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.isEmpty ? [""] : lines
    }

    private static func normalizedMarkdown(from text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(
                of: #"([.!?;:])(\*\*[^\n])"#,
                with: "$1\n$2",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"([.!?;:])(__[^\n])"#,
                with: "$1\n$2",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        return trimmed.filter { $0 == "|" }.count >= 2
    }

    private static func table(from lines: [String]) -> ChatMarkdownTable? {
        let rows = lines
            .map(splitTableRow)
            .filter { !$0.isEmpty && !isSeparatorRow($0) }
        guard rows.count >= 2 else {
            return nil
        }

        let headers = rows[0]
        let body = rows
            .dropFirst()
            .map { normalizeRow($0, count: headers.count) }
            .filter { row in row.contains { !$0.isEmpty } }

        guard !body.isEmpty else {
            return nil
        }
        return ChatMarkdownTable(headers: headers, rows: Array(body))
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("|") {
            trimmed.removeFirst()
        }
        if trimmed.hasSuffix("|") {
            trimmed.removeLast()
        }
        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { plainText(from: String($0)) }
    }

    private static func isSeparatorRow(_ row: [String]) -> Bool {
        guard !row.isEmpty else {
            return false
        }
        return row.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { character in
                character == "-" || character == ":" || character == " "
            }
        }
    }

    private static func normalizeRow(_ row: [String], count: Int) -> [String] {
        if row.count >= count {
            return Array(row.prefix(row.count))
        }
        return row + Array(repeating: "", count: count - row.count)
    }
}

private struct ChatEmptyState: View {
    var body: some View {
        WwCard {
            VStack(alignment: .leading, spacing: 8) {
                MonoLabel("chat")
                Text("Ask a question about the transcript or summary.")
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .italic()
                    .foregroundColor(AppTheme.muted)
            }
        }
    }
}

private struct ExactMemoryScreen: View {
    let recording: Bool
    let onHome: () -> Void
    let onConversations: () -> Void
    let onRecord: () -> Void
    let onHer: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ExactBrandBar(status: "MEMORY")

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    MonoLabel("your mind, indexed")
                    (Text("What I know\n")
                        + Text("about you.").italic())
                        .font(.system(size: 34, weight: .medium, design: .serif))
                        .foregroundColor(AppTheme.fg)
                        .lineSpacing(0)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)

                    Text("Memory will show backend facts, people, places, and preferences when the database has saved entries.")
                        .font(.system(size: 14, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.muted)
                        .lineSpacing(5)
                        .padding(.top, 10)

                    MemorySearchCapsule()
                        .padding(.top, 14)

                    WwCard {
                        VStack(alignment: .leading, spacing: 8) {
                            MonoLabel("empty")
                            Text("No memory entries loaded.")
                                .font(.system(size: 16, weight: .medium, design: .serif))
                                .foregroundColor(AppTheme.fg)
                            Text("When backend memory endpoints are connected, this screen will render real facts and controls here.")
                                .font(.system(size: 14, weight: .regular, design: .serif))
                                .italic()
                                .foregroundColor(AppTheme.muted)
                                .lineSpacing(4)
                        }
                        .padding(.top, 18)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }

            ExactTabBar(activeIndex: 2, recording: recording, onHome: onHome, onRecord: onRecord, onLog: onConversations, onMemory: {}, onHer: onHer)
        }
    }
}

private struct MemorySearchCapsule: View {
    var body: some View {
        HStack(spacing: 10) {
            HerOrb(size: 16)
            Text("ask — \"what do you know about anya?\"")
                .font(.system(size: 13.5, weight: .regular, design: .serif))
                .italic()
                .foregroundColor(AppTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Spacer()
            Text("⌘K")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(AppTheme.dim)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(AppTheme.bgDeep))
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Capsule().fill(AppTheme.bgSoft).overlay(Capsule().stroke(AppTheme.borderStrong, lineWidth: 1)))
    }
}

private struct MemoryPinRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(AppTheme.dim)
                .tracking(1.4)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.system(size: 13.5, weight: .regular, design: .serif))
                .foregroundColor(AppTheme.fg)
                .lineSpacing(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct MemoryTopicRow: View {
    let title: String
    let count: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: topicIcon)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(AppTheme.fg)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundColor(AppTheme.fg)
                Text(detail)
                    .font(.system(size: 12, weight: .regular, design: .serif))
                    .italic()
                    .foregroundColor(AppTheme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Spacer()
            Text(count)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(AppTheme.muted)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.dim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    private var topicIcon: String {
        switch title {
        case "work":
            return "briefcase"
        case "health":
            return "heart"
        case "relationships":
            return "person.2"
        case "places":
            return "mappin.and.ellipse"
        case "tastes":
            return "sparkles"
        default:
            return "clock"
        }
    }
}

private struct MemoryPersonRow: View {
    let initial: String
    let name: String
    let subtitle: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Text(initial)
                .font(.system(size: 14, weight: .medium, design: .serif))
                .foregroundColor(AppTheme.bg)
                .frame(width: 34, height: 34)
                .background(Circle().fill(AppTheme.fg))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundColor(AppTheme.fg)
                Text(subtitle)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(AppTheme.dim)
                    .tracking(0.5)
                Text(detail)
                    .font(.system(size: 12, weight: .regular, design: .serif))
                    .italic()
                    .foregroundColor(AppTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Spacer()
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.dim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct MemoryLearnedRow: View {
    let time: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(time.uppercased())
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(AppTheme.dim)
                .tracking(1.2)
                .frame(width: 68, alignment: .leading)
            Text(text)
                .font(.system(size: 13.5, weight: .regular, design: .serif))
                .foregroundColor(AppTheme.fg)
                .lineSpacing(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct ExactRecordingScreen: View {
    @ObservedObject var viewModel: ConversationSessionViewModel
    @ObservedObject var liveContext: LiveContextStore
    @Binding var muted: Bool
    let currentUserName: String
    let onStop: () -> Void
    let onContinue: () -> Void
    let onFinishInterrupted: () -> Void
    let onGenerateSummary: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            recordingHeader

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .lastTextBaseline) {
                    Text(viewModel.elapsedText)
                        .font(.system(size: 52, weight: .medium, design: .monospaced))
                        .foregroundColor(AppTheme.fg)
                        .monospacedDigit()
                    Spacer()
                    Text(recordingStatusText)
                        .font(.system(size: 13, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.dim)
                }

                SpeechActivityMeter(level: muted ? 0 : viewModel.audioLevel, active: viewModel.phase == .recording && !muted)
                    .frame(height: 58)

                HStack {
                    MonoLabel(viewModel.activeInputName)
                    Spacer()
                    if viewModel.phase == .recording {
                        MonoLabel("speech input", color: AppTheme.dim)
                    } else if viewModel.phase == .interrupted {
                        MonoLabel("saved partial", color: AppTheme.dim)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)

            RecordingInsightChip(message: insightText)
                .padding(.horizontal, 22)
                .padding(.bottom, 14)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if viewModel.phase == .transcribing {
                        TranscriptionProgressCard()
                    }

                    MonoLabel(transcriptTitle)
                        .padding(.horizontal, 4)
                    if transcriptEntries.isEmpty {
                        RecordingTranscriptEmptyState(message: transcriptPlaceholder)
                    }
                    ForEach(transcriptEntries) { entry in
                        RecordingTranscriptRow(entry: entry, muted: muted)
                    }

                    if let summary = viewModel.summary {
                        SummaryPanel(summary: summary, isGenerating: false, onGenerateSummary: nil)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
            }

            if viewModel.phase == .recording {
                RecordingControlDock(muted: $muted, onStop: onStop)
            } else if viewModel.phase == .interrupted {
                RecordingInterruptedDock(onContinue: onContinue, onFinish: onFinishInterrupted)
            } else {
                RecordingPostProcessDock(viewModel: viewModel, onGenerateSummary: onGenerateSummary)
            }
        }
    }

    private var recordingHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            RecordingStatusPill(title: statusPillTitle, active: viewModel.phase == .recording && !muted)
                .frame(width: 104, alignment: .leading)

            VStack(spacing: 2) {
                Text(headerTitle)
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundColor(AppTheme.fg)
                Text(liveContext.recordingLocationLabel)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(AppTheme.dim)
                    .tracking(0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)

            Button(action: onDismiss) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppTheme.fg)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(AppTheme.bgSoft))
                    .overlay(Circle().stroke(AppTheme.borderStrong, lineWidth: 1))
            }
            .buttonStyle(PlainButtonStyle())
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var transcriptEntries: [RecordingTranscriptEntry] {
        RecordingTranscriptEntry.fromSegments(
            viewModel.transcriptSegments,
            transcript: viewModel.transcript,
            currentUserName: currentUserName
        )
    }

    private var recordingStatusText: String {
        if viewModel.phase == .interrupted {
            return "interrupted"
        }
        if muted {
            return "muted"
        }
        switch viewModel.phase {
        case .recording:
            return "listening"
        case .interrupted:
            return "paused"
        case .transcribing:
            return "transcribing"
        case .transcriptReady:
            return "transcript ready"
        case .summarizing:
            return "summarizing"
        case .completed:
            return "saved"
        case .failed:
            return "failed"
        case .idle:
            return "ready"
        }
    }

    private var headerTitle: String {
        switch viewModel.phase {
        case .recording:
            return "Recording"
        case .interrupted:
            return "Recording paused"
        case .transcribing:
            return "Transcribing"
        case .transcriptReady:
            return "Transcript ready"
        case .summarizing:
            return "Summarizing"
        case .completed:
            return viewModel.summary?.title ?? "Summary ready"
        case .failed:
            return "Recording failed"
        case .idle:
            return "Ready"
        }
    }

    private var statusPillTitle: String {
        switch viewModel.phase {
        case .recording:
            return muted ? "paused" : "recording"
        case .interrupted:
            return "paused"
        default:
            return viewModel.phase.label
        }
    }

    private var insightText: String {
        if let errorMessage = viewModel.errorMessage {
            return errorMessage
        }
        if muted {
            return "Capture is paused. Unmute before continuing the recording."
        }
        switch viewModel.phase {
        case .recording:
            return "Recording through \(viewModel.activeInputName). Transcript will appear after stop."
        case .interrupted:
            return "Recording was paused by iOS. Continue into the same meeting or finish and transcribe the audio captured so far."
        case .transcribing:
            return "The saved audio is being converted into transcript text."
        case .transcriptReady:
            return "Transcript is ready. Generate summary when you need it."
        case .summarizing:
            return "The transcript is being summarized with the configured backend model."
        case .completed:
            return viewModel.summary?.overview ?? "Transcript and summary are ready."
        case .failed:
            return "Check microphone permission and backend health."
        case .idle:
            return "Start a recording to capture a real transcript."
        }
    }

    private var transcriptTitle: String {
        viewModel.transcript.isEmpty ? "transcript" : "saved transcript"
    }

    private var transcriptPlaceholder: String {
        switch viewModel.phase {
        case .recording:
            return "No live transcript yet. This build records audio first, then transcribes it through the backend when you stop."
        case .interrupted:
            return "Recording paused. The captured audio is safe; continue recording or finish to transcribe it."
        case .transcribing:
            return "Waiting for backend transcription."
        case .transcriptReady:
            return "Transcript is ready."
        case .summarizing:
            return "Generating summary from the transcript."
        case .failed:
            return viewModel.errorMessage ?? "Recording failed before transcript was created."
        default:
            return "No transcript has been created yet."
        }
    }
}

private struct RecordingStatusPill: View {
    let title: String
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? AppTheme.danger : AppTheme.dim)
                .frame(width: 7, height: 7)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(AppTheme.fg)
                .tracking(1.2)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Capsule().fill(AppTheme.bgSoft).overlay(Capsule().stroke(AppTheme.borderStrong, lineWidth: 1)))
    }
}

private struct SpeechActivityMeter: View {
    let level: Double
    let active: Bool
    private let barCount = 32

    var body: some View {
        TimelineView(.animation) { timeline in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(active ? AppTheme.fg : AppTheme.dim.opacity(0.35))
                        .frame(width: 3, height: height(for: index, at: timeline.date))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.bgSoft))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.borderStrong, lineWidth: 1))
        }
    }

    private func height(for index: Int, at date: Date) -> CGFloat {
        guard active else {
            return 5
        }

        let clampedLevel = min(max(level, 0), 1)
        let time = date.timeIntervalSinceReferenceDate
        let wave = abs(sin(time * 7.0 + Double(index) * 0.72))
        let accent = index % 7 == 0 ? 0.22 : 0
        let amplitude = max(clampedLevel, 0.08)
        return CGFloat(5 + (amplitude + accent) * (13 + wave * 34))
    }
}

private struct TranscriptionProgressCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(AppTheme.fg)
                Text("Transcribing audio")
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundColor(AppTheme.fg)
                Spacer()
            }

            TranscriptionLoadingBar()
                .frame(height: 5)

            Text("The backend is turning the recording into transcript text.")
                .font(.system(size: 13, weight: .regular, design: .serif))
                .italic()
                .foregroundColor(AppTheme.muted)
                .lineSpacing(4)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppTheme.bgSoft))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.borderStrong, lineWidth: 1))
    }
}

private struct TranscriptionLoadingBar: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            GeometryReader { geometry in
                let width = geometry.size.width
                let progress = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                let segmentWidth = max(width * 0.34, 44)
                let xOffset = CGFloat(progress) * (width + segmentWidth) - segmentWidth

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.bgDeep)
                    Capsule()
                        .fill(AppTheme.fg)
                        .frame(width: segmentWidth)
                        .offset(x: xOffset)
                }
                .clipShape(Capsule())
            }
        }
    }
}

private struct RecordingInsightChip: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HerOrb(size: 18)
            Text(message)
                .font(.system(size: 13.5, weight: .regular, design: .serif))
                .italic()
                .foregroundColor(AppTheme.muted)
                .lineSpacing(4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.bgSoft))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.borderStrong, lineWidth: 1))
    }
}

private struct RecordingTranscriptEntry: Identifiable {
    let id = UUID()
    let time: String
    let speaker: String
    let initial: String
    let text: String
    let active: Bool
    let unknown: Bool

    static func fromSegments(
        _ segments: [MeetingTranscriptSegment],
        transcript: String,
        currentUserName: String
    ) -> [RecordingTranscriptEntry] {
        let usableSegments = segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !usableSegments.isEmpty {
            return usableSegments.map { segment in
                let rawSpeaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let fallbackSpeaker = rawSpeaker.isEmpty ? "Speaker" : rawSpeaker
                let speaker = SpeakerDisplayNames.decorated(fallbackSpeaker, currentUserName: currentUserName)
                return RecordingTranscriptEntry(
                    time: MeetingTimeFormatter.timestamp(segment.start),
                    speaker: speaker,
                    initial: String(speaker.prefix(1)).uppercased(),
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    active: false,
                    unknown: fallbackSpeaker.localizedCaseInsensitiveContains("speaker")
                )
            }
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        return [
            RecordingTranscriptEntry(
                time: "saved",
                speaker: "Transcript",
                initial: "T",
                text: SpeakerDisplayNames.decoratedSpeakerLabels(in: trimmed, currentUserName: currentUserName),
                active: false,
                unknown: false
            )
        ]
    }
}

private struct RecordingTranscriptEmptyState: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .regular, design: .serif))
            .foregroundColor(AppTheme.muted)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppTheme.bgSoft))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.borderStrong, lineWidth: 1))
    }
}

private struct RecordingTranscriptRow: View {
    let entry: RecordingTranscriptEntry
    let muted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.initial)
                .font(.system(size: 13, weight: .medium, design: .serif))
                .foregroundColor(entry.unknown ? AppTheme.fg : AppTheme.bg)
                .frame(width: 32, height: 32)
                .background(Circle().fill(entry.unknown ? AppTheme.bgDeep : AppTheme.fg))
                .overlay(Circle().stroke(AppTheme.borderStrong, lineWidth: entry.unknown ? 1 : 0))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    MonoLabel("\(entry.time) \(entry.speaker.lowercased())")
                    if entry.unknown {
                        Text("tap to name")
                            .font(.system(size: 11, weight: .regular, design: .serif))
                            .italic()
                            .foregroundColor(AppTheme.fg)
                    }
                    if entry.active && !muted {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(AppTheme.danger)
                                .frame(width: 5, height: 5)
                            Text("now")
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundColor(AppTheme.danger)
                        }
                    }
                    Spacer(minLength: 0)
                }

                Text(entry.text)
                    .font(.system(size: 14.5, weight: .regular, design: .serif))
                    .foregroundColor(AppTheme.fg)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(entry.active ? AppTheme.bgSoft : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(entry.active ? AppTheme.borderStrong : Color.clear, lineWidth: 1))
        .opacity(muted && entry.active ? 0.62 : 1)
    }
}

private struct RecordingControlDock: View {
    @Binding var muted: Bool
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 42) {
            Button(action: { muted.toggle() }) {
                VStack(spacing: 6) {
                    Image(systemName: muted ? "mic" : "mic.slash")
                        .font(.system(size: 18, weight: .medium))
                    Text(muted ? "unmute" : "mute")
                        .font(.system(size: 11, weight: .regular, design: .serif))
                        .italic()
                }
                .foregroundColor(AppTheme.fg)
                .frame(width: 70, height: 58)
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: onStop) {
                Circle()
                    .fill(AppTheme.danger)
                    .frame(width: 72, height: 72)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white)
                            .frame(width: 22, height: 22)
                    )
                    .shadow(color: AppTheme.danger.opacity(0.24), radius: 12, x: 0, y: 6)
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()
                .frame(width: 70, height: 58)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(AppTheme.bg)
        .overlay(alignment: .top) { DividerLine() }
    }
}

private struct RecordingInterruptedDock: View {
    let onContinue: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Button(action: onContinue) {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Continue recording")
                        .font(.system(size: 16, weight: .medium, design: .serif))
                }
                .foregroundColor(AppTheme.bg)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.fg))
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: onFinish) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Finish and transcribe")
                        .font(.system(size: 14.5, weight: .medium, design: .serif))
                }
                .foregroundColor(AppTheme.fg)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.bg))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.borderStrong, lineWidth: 1))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(AppTheme.bg)
        .overlay(alignment: .top) { DividerLine() }
    }
}

private struct RecordingPostProcessDock: View {
    @ObservedObject var viewModel: ConversationSessionViewModel
    let onGenerateSummary: () -> Void

    var body: some View {
        Group {
            if viewModel.phase == .transcribing {
                EmptyView()
            } else {
                VStack(spacing: 10) {
                    if viewModel.phase == .summarizing {
                        HStack(spacing: 9) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(AppTheme.fg)
                            Text("Generating summary...")
                                .font(.system(size: 14, weight: .medium, design: .serif))
                                .foregroundColor(AppTheme.fg)
                            Spacer()
                        }
                        .padding(.horizontal, 22)
                    } else if viewModel.canGenerateSummary || viewModel.summary != nil {
                        Button(action: onGenerateSummary) {
                            HStack(spacing: 8) {
                                Image(systemName: viewModel.summary == nil ? "sparkles" : "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                Text(viewModel.summaryButtonTitle)
                                    .font(.system(size: 16, weight: .medium, design: .serif))
                            }
                            .foregroundColor(AppTheme.bg)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.fg))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(!viewModel.canGenerateSummary)
                        .opacity(viewModel.canGenerateSummary ? 1 : 0.55)
                        .padding(.horizontal, 22)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 24)
                .background(AppTheme.bg)
                .overlay(alignment: .top) { DividerLine() }
            }
        }
    }
}

private struct ExactSettingsHerScreen: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var bridge: WearablesBridge
    @ObservedObject var viewModel: ConversationSessionViewModel
    @ObservedObject var wakeCommands: WakeCommandController
    @ObservedObject var authStore: AuthStore

    let onHome: () -> Void
    let onConversations: () -> Void
    let onRecord: () -> Void
    let onMemory: () -> Void
    let onPair: () -> Void

    @State private var editingProfile = false
    @State private var aiName: String
    @State private var ownerName: String
    @State private var voiceProfiles: [VoiceProfile] = []
    @State private var voiceProfilesLoading = false
    @State private var presentingVoiceEnrollment = false
    @State private var presentingLegal: LegalDocument?
    @State private var processOnDevice = true
    @State private var redactPII = true
    @State private var glassesIndicator = true
    @State private var requireFaceID = false
    @State private var silenceTrim = true
    @State private var dailySummary = true
    @State private var followUps = true
    @State private var wifiOnly = false

    init(
        settings: AppSettingsStore,
        bridge: WearablesBridge,
        viewModel: ConversationSessionViewModel,
        wakeCommands: WakeCommandController,
        authStore: AuthStore,
        onHome: @escaping () -> Void,
        onConversations: @escaping () -> Void,
        onRecord: @escaping () -> Void,
        onMemory: @escaping () -> Void,
        onPair: @escaping () -> Void
    ) {
        self.settings = settings
        self.bridge = bridge
        self.viewModel = viewModel
        self.wakeCommands = wakeCommands
        self.authStore = authStore
        self.onHome = onHome
        self.onConversations = onConversations
        self.onRecord = onRecord
        self.onMemory = onMemory
        self.onPair = onPair
        _aiName = State(initialValue: settings.aiDisplayName)
        _ownerName = State(initialValue: settings.ownerDisplayName == "Owner" ? "" : settings.ownerDisplayName)
    }

    var body: some View {
        VStack(spacing: 0) {
            ExactBrandBar(status: "SETTINGS")

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    MonoLabel("your account")
                    Text("Settings.")
                        .font(.system(size: 28, weight: .medium, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.fg)
                        .padding(.top, 6)

                    SettingsProfileCard(
                        settings: settings,
                        editingProfile: $editingProfile,
                        aiName: $aiName,
                        ownerName: $ownerName
                    )
                    .padding(.top, 18)

                    SettingsSectionHeader(title: "people", hint: voiceProfiles.isEmpty ? "empty" : "\(voiceProfiles.count) known")
                    WwCard(padding: 0) {
                        VStack(spacing: 0) {
                            if voiceProfiles.isEmpty {
                                SettingsValueRow(
                                    icon: "person.2",
                                    label: "Known people",
                                    subtitle: "Saved voices and speaker names will appear here",
                                    value: "empty"
                                )
                                DividerLine()
                            } else {
                                ForEach(voiceProfiles) { profile in
                                    VoiceProfileRow(profile: profile) {
                                        Task { await deleteVoiceProfile(profile) }
                                    }
                                    DividerLine()
                                }
                            }
                            Button(action: { presentingVoiceEnrollment = true }) {
                                HStack(spacing: 14) {
                                    Image(systemName: "waveform.badge.plus")
                                        .font(.system(size: 16))
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Add your voice")
                                            .font(.system(size: 14.5, weight: .medium, design: .serif))
                                        Text("60-second sample so Her can label you in transcripts")
                                            .font(.system(size: 12, design: .serif))
                                            .italic()
                                            .foregroundColor(AppTheme.dim)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(AppTheme.dim)
                                }
                                .foregroundColor(AppTheme.fg)
                                .padding(16)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .onAppear { Task { await loadVoiceProfiles() } }
                    .sheet(isPresented: $presentingVoiceEnrollment) {
                        VoiceEnrollmentView(isPresented: $presentingVoiceEnrollment) { newProfile in
                            voiceProfiles.insert(newProfile, at: 0)
                        }
                    }
                    .sheet(item: $presentingLegal) { doc in
                        LegalDocumentView(document: doc, current: $presentingLegal)
                    }

                    SettingsSectionHeader(title: "memory & data")
                    WwCard(padding: 0) {
                        VStack(spacing: 0) {
                            SettingsValueRow(icon: "brain.head.profile", label: "What Her knows", subtitle: "connect backend memory to populate", value: "empty")
                            DividerLine()
                            SettingsValueRow(icon: "square.stack.3d.up", label: "Conversations", subtitle: "loaded from backend meetings", value: "sync")
                            DividerLine()
                            SettingsValueRow(icon: "clock", label: "Auto-delete after", value: "90 days")
                            DividerLine()
                            SettingsActionRow(icon: "square.and.arrow.up", label: "Export everything", subtitle: "json + audio archive")
                            DividerLine()
                            SettingsActionRow(icon: "xmark", label: "Clear by topic", subtitle: "forget a person, place, or event", danger: true)
                        }
                    }

                    SettingsSectionHeader(title: "privacy", hint: "on-device first")
                    WwCard(padding: 0) {
                        VStack(spacing: 0) {
                            SettingsToggleRow(icon: "lock", label: "Process on-device", subtitle: "ship to cloud only when you ask", isOn: $processOnDevice)
                            DividerLine()
                            SettingsToggleRow(icon: "shield", label: "Redact PII in cloud", subtitle: "phone numbers, addresses, names", isOn: $redactPII)
                            DividerLine()
                            SettingsToggleRow(icon: "eyeglasses", label: "Glasses indicator LED", subtitle: "recording light always visible", isOn: $glassesIndicator)
                            DividerLine()
                            SettingsToggleRow(icon: "faceid", label: "Require Face ID", subtitle: "to open conversations", isOn: $requireFaceID)
                        }
                    }

                    SettingsSectionHeader(title: "voice & capture")
                    WwCard(padding: 0) {
                        VStack(spacing: 0) {
                            SettingsValueRow(icon: "globe", label: "Language", value: "auto")
                            DividerLine()
                            SettingsValueRow(icon: "mic", label: "Wake word", subtitle: "assistant name, Hey optional", value: settings.aiDisplayName.lowercased())
                            DividerLine()
                            SettingsToggleRow(icon: "waveform", label: "Listen for \(settings.aiDisplayName)", subtitle: wakeCommandSubtitle, isOn: wakeCommandBinding)
                            DividerLine()
                            SettingsValueRow(icon: "sparkles", label: "Command status", subtitle: wakeCommands.statusText, value: wakeCommands.shortStatus)
                            DividerLine()
                            SettingsToggleRow(icon: "waveform", label: "Silence trim", isOn: $silenceTrim)
                        }
                    }

                    SettingsSectionHeader(title: "notifications")
                    WwCard(padding: 0) {
                        VStack(spacing: 0) {
                            SettingsToggleRow(icon: "sparkles", label: "Daily summary", subtitle: "disabled until backend schedule is connected", isOn: $dailySummary)
                            DividerLine()
                            SettingsToggleRow(icon: "pin", label: "Follow-ups", subtitle: "when Her finds an action item", isOn: $followUps)
                            DividerLine()
                            SettingsToggleRow(icon: "wifi", label: "Sync over Wi-Fi only", isOn: $wifiOnly)
                        }
                    }

                    SettingsSectionHeader(title: "about")
                    WwCard(padding: 0) {
                        VStack(spacing: 0) {
                            SettingsValueRow(icon: "gearshape", label: "Version", value: appVersion)
                            DividerLine()
                            SettingsActionRow(icon: "shield", label: "Privacy policy") {
                                presentingLegal = .privacy
                            }
                            DividerLine()
                            SettingsActionRow(icon: "doc.text", label: "Terms of service") {
                                presentingLegal = .terms
                            }
                            DividerLine()
                            SettingsActionRow(icon: "bubble.left.and.bubble.right", label: "Help & feedback")
                            DividerLine()
                            SettingsActionRow(icon: "curlybraces", label: "Open source licenses")
                        }
                    }

                    SettingsDangerFooter(
                        signOut: {
                            authStore.clear()
                            settings.resetOnboarding()
                        },
                        restartSetup: {
                            settings.resetOnboarding()
                        }
                    )
                    .padding(.top, 26)

                    Text("made carefully · almaty · 2026")
                        .font(.system(size: 12, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.dim)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }

            ExactTabBar(
                activeIndex: 3,
                recording: viewModel.phase == .recording,
                onHome: onHome,
                onRecord: onRecord,
                onLog: onConversations,
                onMemory: onMemory,
                onHer: {}
            )
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var wakeCommandBinding: Binding<Bool> {
        Binding(
            get: { wakeCommands.isEnabled },
            set: { wakeCommands.setEnabled($0) }
        )
    }

    private var wakeCommandSubtitle: String {
        "Say \"Hey \(settings.aiDisplayName)\" or \"\(settings.aiDisplayName)\", then \"start recording\" or \"stop recording\"."
    }

    @MainActor
    private func loadVoiceProfiles() async {
        guard !voiceProfilesLoading, let service = VoiceProfilesService() else { return }
        voiceProfilesLoading = true
        defer { voiceProfilesLoading = false }
        do {
            voiceProfiles = try await service.list()
        } catch {
            // Soft fail; show empty list.
        }
    }

    @MainActor
    private func deleteVoiceProfile(_ profile: VoiceProfile) async {
        guard let service = VoiceProfilesService() else { return }
        do {
            try await service.delete(id: profile.id)
            voiceProfiles.removeAll { $0.id == profile.id }
        } catch {
            // Stay quiet; could surface error if needed.
        }
    }
}

private struct VoiceProfileRow: View {
    let profile: VoiceProfile
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.wave.2")
                .font(.system(size: 16))
                .foregroundColor(AppTheme.fg)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.system(size: 14.5, weight: .medium, design: .serif))
                    .foregroundColor(AppTheme.fg)
                if let duration = profile.durationSeconds {
                    Text(String(format: "%.0fs sample", duration))
                        .font(.system(size: 12, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.dim)
                }
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(AppTheme.danger)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(16)
    }
}

private struct SettingsProfileCard: View {
    @ObservedObject var settings: AppSettingsStore
    @Binding var editingProfile: Bool
    @Binding var aiName: String
    @Binding var ownerName: String

    var body: some View {
        WwCard(padding: 0) {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    Text(ownerInitial)
                        .font(.system(size: 24, weight: .medium, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.bg)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(AppTheme.fg))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.ownerDisplayName)
                            .font(.system(size: 16, weight: .medium, design: .serif))
                            .foregroundColor(AppTheme.fg)
                        Text(settings.signInProvider?.title.lowercased() ?? "local account")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundColor(AppTheme.dim)
                            .tracking(0.5)
                    }

                    Spacer()

                    Button(action: { editingProfile.toggle() }) {
                        Text(editingProfile ? "done" : "edit")
                            .font(.system(size: 13, weight: .regular, design: .serif))
                            .italic()
                            .foregroundColor(AppTheme.fg)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .overlay(Capsule().stroke(AppTheme.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(16)

                DividerLine()

                HStack(spacing: 12) {
                    SettingsProfileMetric(label: "plan", value: "mvp")
                    SettingsProfileMetric(label: "storage", value: "local")
                    SettingsProfileMetric(label: "agent", value: settings.aiDisplayName.lowercased())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                DividerLine()

                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(AppTheme.bgDeep)
                            Capsule()
                                .fill(AppTheme.fg)
                                .frame(width: geometry.size.width * 0.24)
                        }
                    }
                    .frame(height: 4)

                    HStack {
                        MonoLabel("local backend")
                        Spacer()
                        Text("active")
                            .font(.system(size: 11, weight: .regular, design: .serif))
                            .italic()
                            .foregroundColor(AppTheme.fg)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if editingProfile {
                    DividerLine()
                    VStack(alignment: .leading, spacing: 14) {
                        ProfileTextField(label: "AI NAME", placeholder: "Her", text: $aiName)
                        ProfileTextField(label: "OWNER", placeholder: "Your name", text: $ownerName)
                        WwPrimaryButton("save profile") {
                            settings.saveProfile(aiName: aiName, ownerName: ownerName)
                            editingProfile = false
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var ownerInitial: String {
        String(settings.ownerDisplayName.prefix(1)).uppercased()
    }
}

private struct SettingsProfileMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MonoLabel(label)
            Text(value)
                .font(.system(size: 14, weight: .regular, design: .serif))
                .italic()
                .foregroundColor(AppTheme.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsGlassesCard: View {
    @ObservedObject var bridge: WearablesBridge
    let onPair: () -> Void

    var body: some View {
        WwCard(padding: 0) {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    SmallGlassesIcon()
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(glassesTitle)
                            .font(.system(size: 15, weight: .medium, design: .serif))
                            .foregroundColor(AppTheme.fg)
                        Text(glassesSubtitle)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundColor(AppTheme.dim)
                            .tracking(0.5)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                    }

                    Spacer()

                    HStack(spacing: 5) {
                        Circle()
                            .fill(isLinked ? AppTheme.fg : AppTheme.dim)
                            .frame(width: 5, height: 5)
                        Text(isLinked ? "linked" : "offline")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(1.5)
                    }
                    .foregroundColor(AppTheme.fg)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .overlay(Capsule().stroke(isLinked ? AppTheme.fg : AppTheme.borderStrong, lineWidth: 1))
                }
                .padding(16)

                DividerLine()
                SettingsActionRow(icon: "plus", label: "Pair another device", action: onPair)
                DividerLine()
                SettingsActionRow(icon: "arrow.clockwise", label: "Refresh audio route", subtitle: bridge.audioRoute.routeSummary) {
                    bridge.refreshAudioRoute()
                }
                DividerLine()
                SettingsActionRow(icon: "xmark", label: "Forget this device", subtitle: "will erase pairing key from phone", danger: true)
            }
        }
    }

    private var isLinked: Bool {
        bridge.audioRoute.primaryDetectedDevice != nil
    }

    private var glassesTitle: String {
        bridge.audioRoute.primaryDetectedDevice?.name ?? "Ray-Ban Meta · Wayfarer"
    }

    private var glassesSubtitle: String {
        guard let device = bridge.audioRoute.primaryDetectedDevice else {
            return "Pair from iOS Bluetooth, then refresh here."
        }

        let input = device.supportsInput ? "MIC READY" : "OUTPUT ONLY"
        return "\(input) · \(bridge.state.detail.uppercased())"
    }
}

private struct SettingsSectionHeader: View {
    let title: String
    let hint: String?

    init(title: String, hint: String? = nil) {
        self.title = title
        self.hint = hint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            MonoLabel(title)
            Spacer()
            if let hint {
                Text(hint)
                    .font(.system(size: 12, weight: .regular, design: .serif))
                    .italic()
                    .foregroundColor(AppTheme.dim)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }
}

private struct SettingsActionRow: View {
    let icon: String
    let label: String
    let subtitle: String?
    let danger: Bool
    let action: (() -> Void)?

    init(icon: String, label: String, subtitle: String? = nil, danger: Bool = false, action: (() -> Void)? = nil) {
        self.icon = icon
        self.label = label
        self.subtitle = subtitle
        self.danger = danger
        self.action = action
    }

    var body: some View {
        Button(action: { action?() }) {
            settingsRowContent(trailing: AnyView(
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.dim)
            ))
        }
        .buttonStyle(PlainButtonStyle())
    }

    fileprivate func settingsRowContent(trailing: AnyView) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(danger ? AppTheme.danger : AppTheme.fg)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundColor(danger ? AppTheme.danger : AppTheme.fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.dim)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                }
            }

            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct SettingsValueRow: View {
    let icon: String
    let label: String
    let subtitle: String?
    let value: String

    init(icon: String, label: String, subtitle: String? = nil, value: String) {
        self.icon = icon
        self.label = label
        self.subtitle = subtitle
        self.value = value
    }

    var body: some View {
        SettingsActionRow(icon: icon, label: label, subtitle: subtitle).settingsRowContent(trailing: AnyView(
            HStack(spacing: 6) {
                Text(value)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(AppTheme.muted)
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.dim)
            }
        ))
    }
}

private struct SettingsToggleRow: View {
    let icon: String
    let label: String
    let subtitle: String?
    @Binding var isOn: Bool

    init(icon: String, label: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.icon = icon
        self.label = label
        self.subtitle = subtitle
        _isOn = isOn
    }

    var body: some View {
        Button(action: { isOn.toggle() }) {
            SettingsActionRow(icon: icon, label: label, subtitle: subtitle).settingsRowContent(trailing: AnyView(
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? AppTheme.fg : AppTheme.bgDeep)
                        .frame(width: 38, height: 22)
                    Circle()
                        .fill(AppTheme.bg)
                        .frame(width: 18, height: 18)
                        .padding(2)
                }
                .animation(.easeInOut(duration: 0.18), value: isOn)
            ))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct SettingsDangerFooter: View {
    let signOut: () -> Void
    let restartSetup: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Button(action: signOut) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 14, weight: .medium))
                    Text("sign out")
                        .font(.system(size: 16, weight: .medium, design: .serif))
                }
                .foregroundColor(AppTheme.fg)
                .frame(maxWidth: .infinity, minHeight: 52)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.borderStrong, lineWidth: 1))
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: restartSetup) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .medium))
                    Text("restart setup")
                        .font(.system(size: 16, weight: .medium, design: .serif))
                }
                .foregroundColor(AppTheme.fg)
                .frame(maxWidth: .infinity, minHeight: 52)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.borderStrong, lineWidth: 1))
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: {}) {
                Text("delete my account")
                    .font(.system(size: 13.5, weight: .regular, design: .serif))
                    .italic()
                    .foregroundColor(AppTheme.danger)
                    .padding(.vertical, 8)
            }
            .buttonStyle(PlainButtonStyle())

            Text("erases everything — conversations, memory, glasses pairing — in 30 days. you can cancel anytime.")
                .font(.system(size: 11.5, weight: .regular, design: .serif))
                .italic()
                .foregroundColor(AppTheme.dim)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ExactTabBar: View {
    let activeIndex: Int
    let recording: Bool
    let onHome: () -> Void
    let onRecord: () -> Void
    let onLog: () -> Void
    let onMemory: () -> Void
    let onHer: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                tab(icon: "house", title: "home", index: 0, action: onHome)
                tab(icon: "square.stack.3d.up", title: "log", index: 1, action: onLog)
                Color.clear
                    .frame(width: 76, height: 1)
                tab(icon: "brain.head.profile", title: "memory", index: 2, action: onMemory)
                tab(icon: "gearshape", title: "Her", index: 3, action: onHer)
            }

            Button(action: onRecord) {
                ZStack {
                    Circle()
                        .fill(AppTheme.fg)
                        .frame(width: 60, height: 60)
                        .shadow(color: Color.black.opacity(0.18), radius: 9, x: 0, y: 6)
                        .overlay(Circle().stroke(AppTheme.bg, lineWidth: 4))
                    if recording {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(AppTheme.bg)
                            .frame(width: 16, height: 16)
                        Circle()
                            .stroke(AppTheme.fg.opacity(0.35), lineWidth: 1.5)
                            .frame(width: 76, height: 76)
                    } else {
                        Image(systemName: "mic")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(AppTheme.bg)
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            .offset(y: -22)
        }
        .frame(height: 72, alignment: .top)
        .background(AppTheme.bg)
        .overlay(alignment: .top) { DividerLine() }
    }

    private func tab(icon: String, title: String, index: Int, action: @escaping () -> Void) -> some View {
        let active = index == activeIndex
        return Button(action: action) {
            VStack(spacing: 4) {
                Rectangle()
                    .fill(active ? AppTheme.fg : Color.clear)
                    .frame(width: 34, height: 2)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                if active {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .serif))
                        .italic()
                } else {
                    Text(title)
                        .font(.system(size: 11, weight: .regular, design: .serif))
                }
            }
            .foregroundColor(active ? AppTheme.fg : AppTheme.dim)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct SmallGlassesIcon: View {
    var body: some View {
        RayBanPhoto()
            .frame(width: 34, height: 18)
    }
}

private struct LargeGlassesIcon: View {
    var body: some View {
        RayBanPhoto()
    }
}

private struct RayBanPhoto: View {
    var body: some View {
        Image("RayBanMetaWayfarer")
            .resizable()
            .scaledToFit()
            .accessibilityLabel("Ray-Ban Meta Wayfarer")
    }
}

private struct WwCard<Content: View>: View {
    let padding: CGFloat
    let background: Color
    let showsBorder: Bool
    let content: Content

    init(padding: CGFloat = 14, background: Color = AppTheme.bg, showsBorder: Bool = true, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.background = background
        self.showsBorder = showsBorder
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.borderStrong, lineWidth: showsBorder ? 1 : 0))
    }
}

private struct WwPrimaryButton: View {
    let title: String
    let disabled: Bool
    let action: () -> Void

    init(_ title: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .medium, design: .serif))
                .foregroundColor(AppTheme.bg)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.fg))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

private struct WwGhostButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .regular, design: .serif))
                .foregroundColor(AppTheme.muted)
                .frame(maxWidth: .infinity, minHeight: 54)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.borderStrong, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct WwHeader: View {
    let pre: String
    let title: String
    let italic: Bool
    let onBack: (() -> Void)?

    init(pre: String, title: String, italic: Bool = false, onBack: (() -> Void)? = nil) {
        self.pre = pre
        self.title = title
        self.italic = italic
        self.onBack = onBack
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onBack {
                Button(action: onBack) {
                    Text("←")
                        .font(.system(size: 22, weight: .regular, design: .serif))
                        .foregroundColor(AppTheme.muted)
                        .padding(.bottom, 10)
                }
                .buttonStyle(PlainButtonStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !pre.isEmpty {
                MonoLabel(pre)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(title)
                .font(.system(size: 32, weight: .medium, design: .serif))
                .italic()
                .foregroundColor(AppTheme.fg)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WwSteps: View {
    let step: Int
    let total: Int
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%02d / %02d", step, total))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .tracking(1.5)
                .foregroundColor(AppTheme.dim)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.bgDeep)
                    Capsule()
                        .fill(AppTheme.fg)
                        .frame(width: proxy.size.width * CGFloat(step) / CGFloat(total))
                }
            }
            .frame(height: 2)
            Text(label)
                .font(.system(size: 12, weight: .regular, design: .serif))
                .italic()
                .foregroundColor(AppTheme.muted)
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }
}

private struct FlowWrap<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let items: Data
    let content: (Data.Element) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(Array(items), id: \.self) { item in
                content(item)
            }
        }
    }
}

private struct WarmHomeHeader: View {
    @ObservedObject var viewModel: ConversationSessionViewModel
    @ObservedObject var settings: AppSettingsStore
    let onSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HerOrb(size: 28)

            Text(settings.aiDisplayName.lowercased())
                .font(.system(size: 20, weight: .medium, design: .serif))
                .foregroundColor(AppTheme.fg)
                .lineLimit(1)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                MonoLabel(statusTitle, color: AppTheme.muted)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppTheme.bgSoft))

            Button(action: onSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.fg)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.bg))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppTheme.borderStrong, lineWidth: 1)
                    )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var statusTitle: String {
        switch viewModel.phase {
        case .recording:
            return "REC"
        case .interrupted:
            return "PAUSED"
        case .transcribing:
            return "TRANSCRIBING"
        case .transcriptReady:
            return "TRANSCRIPT"
        case .summarizing:
            return "SUMMARIZING"
        case .completed:
            return "READY"
        case .failed:
            return "ATTENTION"
        case .idle:
            return "IDLE"
        }
    }

    private var statusColor: Color {
        switch viewModel.phase {
        case .recording, .transcribing, .summarizing:
            return AppTheme.fg
        case .interrupted:
            return AppTheme.danger
        case .transcriptReady, .completed:
            return AppTheme.success
        case .failed:
            return AppTheme.danger
        case .idle:
            return AppTheme.dim
        }
    }
}

private struct WarmGreeting: View {
    @ObservedObject var viewModel: ConversationSessionViewModel
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel(kicker)
            Text(title)
                .font(.system(size: 28, weight: .medium, design: .serif))
                .foregroundColor(AppTheme.fg)
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            Text(detail)
                .font(.system(size: 14, weight: .regular, design: .serif))
                .foregroundColor(AppTheme.muted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 18)
    }

    private var kicker: String {
        if viewModel.phase == .recording {
            return "now · recording"
        }
        if viewModel.phase == .interrupted {
            return "now · paused"
        }
        return "today · local"
    }

    private var title: String {
        switch viewModel.phase {
        case .recording:
            return "Listening, \(settings.ownerDisplayName)..."
        case .interrupted:
            return "Recording paused."
        case .transcribing:
            return "Preparing transcript."
        case .transcriptReady:
            return "Transcript is ready."
        case .summarizing:
            return "Writing summary."
        case .completed:
            return "Summary is ready."
        case .failed:
            return "Needs attention."
        case .idle:
            return "Good morning, \(settings.ownerDisplayName)."
        }
    }

    private var detail: String {
        switch viewModel.phase {
        case .recording:
            return "Recording through \(viewModel.activeInputName). Stop when the meeting ends to create a transcript."
        case .interrupted:
            return "iOS paused microphone capture. Continue into the same meeting or finish with the audio captured so far."
        case .transcribing:
            return "The audio is being turned into a clean transcript."
        case .transcriptReady:
            return "Review the transcript or generate a summary when needed."
        case .summarizing:
            return "Decisions, action items, follow-ups, and memory are being extracted."
        case .completed:
            return "Review the notes below or ask \(settings.aiDisplayName) about the conversation."
        case .failed:
            return "Check microphone permission or the backend endpoint before trying again."
        case .idle:
            return "Tap to record a real meeting."
        }
    }
}

private struct WarmGlassesStatusCard: View {
    @ObservedObject var bridge: WearablesBridge

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: bridge.audioRoute.primaryDetectedDevice == nil ? "antenna.radiowaves.left.and.right" : "eyeglasses")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(AppTheme.bg)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(AppTheme.fg))

                    VStack(alignment: .leading, spacing: 5) {
                        MonoLabel("Ray-Ban Meta")
                        Text(bridge.audioRoute.primaryDetectedDevice?.name ?? "Glasses not detected")
                            .font(.system(size: 17, weight: .medium, design: .serif))
                            .foregroundColor(AppTheme.fg)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                        MonoLabel(routeStatusTitle, color: routeStatusColor)
                    }

                    Spacer(minLength: 10)

                    Button(action: bridge.refreshAudioRoute) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppTheme.fg)
                            .frame(width: 38, height: 38)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.bgSoft))
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                Text(bridge.state.detail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(AppTheme.muted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    WarmMiniButton(title: "Scan", icon: "dot.radiowaves.left.and.right", filled: true) {
                        bridge.connectDetectedAudioRoute()
                    }

                    WarmMiniButton(title: "DAT", icon: "play.circle", filled: false) {
                        bridge.startGlassesSession()
                    }
                }
            }
        }
    }

    private var routeStatusTitle: String {
        guard let device = bridge.audioRoute.primaryDetectedDevice else {
            return "not found"
        }
        if device.supportsInput && device.isActive {
            return "linked"
        }
        if device.supportsInput {
            return "mic ready"
        }
        return "output only"
    }

    private var routeStatusColor: Color {
        switch bridge.state {
        case .failed:
            return AppTheme.danger
        case .sessionStarted:
            return AppTheme.success
        case .configurationMissing:
            return AppTheme.warn
        case .detected, .ready:
            return bridge.audioRoute.primaryDetectedDevice == nil ? AppTheme.dim : AppTheme.fg
        case .registrationAvailable, .registrationStarted:
            return AppTheme.warn
        case .notDetected:
            return AppTheme.dim
        }
    }
}

private struct WarmMiniButton: View {
    let title: String
    let icon: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(filled ? AppTheme.bg : AppTheme.fg)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(filled ? AppTheme.fg : AppTheme.bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(filled ? Color.clear : AppTheme.borderStrong, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct WarmRecordControl: View {
    @ObservedObject var viewModel: ConversationSessionViewModel

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            Button(action: viewModel.primaryAction) {
                ZStack {
                    Circle()
                        .fill(AppTheme.bgSoft)
                        .frame(width: 180, height: 180)
                    Circle()
                        .stroke(AppTheme.borderStrong, lineWidth: 1)
                        .frame(width: 180, height: 180)
                    Circle()
                        .stroke(AppTheme.border, lineWidth: 1)
                        .frame(width: 136, height: 136)
                    Circle()
                        .fill(viewModel.phase == .recording ? AppTheme.fg : AppTheme.bg)
                        .frame(width: 96, height: 96)
                        .overlay(
                            Circle()
                                .stroke(AppTheme.borderStrong, lineWidth: 1)
                        )

                    Image(systemName: viewModel.phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(viewModel.phase == .recording ? AppTheme.bg : AppTheme.fg)
                }
                .opacity(viewModel.canTapPrimaryButton ? 1 : 0.45)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!viewModel.canTapPrimaryButton)

            VStack(spacing: 8) {
                Text(viewModel.elapsedText)
                    .font(.system(size: 34, weight: .medium, design: .monospaced))
                    .foregroundColor(AppTheme.fg)
                    .lineLimit(1)

                MonoLabel(viewModel.phase == .recording ? viewModel.activeInputName : viewModel.primaryButtonTitle)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

private struct WarmRecentConversationCard: View {
    @ObservedObject var viewModel: ConversationSessionViewModel

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    MonoLabel("recent")
                    Spacer()
                    Text("today")
                        .font(.system(size: 12, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.dim)
                }

                Text(title)
                    .font(.system(size: 22, weight: .medium, design: .serif))
                    .foregroundColor(AppTheme.fg)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                Text(detail)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(AppTheme.muted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        if let summary = viewModel.summary {
            return summary.title
        }
        switch viewModel.phase {
        case .recording:
            return "Recording in progress"
        case .interrupted:
            return "Recording paused"
        case .transcribing:
            return "Transcript is being prepared"
        case .transcriptReady:
            return "Transcript is ready"
        case .summarizing:
            return "Summary is being prepared"
        case .failed:
            return "No saved summary"
        case .idle, .completed:
            return "No conversations yet"
        }
    }

    private var detail: String {
        if let summary = viewModel.summary {
            return summary.overview
        }
        if !viewModel.transcript.isEmpty {
            return viewModel.transcript
        }
        return "Start a meeting from the phone or connected glasses. When it ends, the transcript and summary will appear here."
    }
}

private struct WarmTabBar: View {
    let activeIndex: Int
    private let tabs = [
        ("mic", "record"),
        ("square.stack.3d.up", "log"),
        ("brain.head.profile", "memory"),
        ("gearshape", "Her")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                VStack(spacing: 6) {
                    Rectangle()
                        .fill(index == activeIndex ? AppTheme.fg : Color.clear)
                        .frame(width: 34, height: 2)
                    Image(systemName: tab.0)
                        .font(.system(size: 17, weight: .medium))
                    Text(tab.1)
                        .font(.system(size: 12, weight: index == activeIndex ? .semibold : .regular, design: .serif))
                }
                .foregroundColor(index == activeIndex ? AppTheme.fg : AppTheme.dim)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 14)
            }
        }
        .padding(.top, 0)
        .background(AppTheme.bg)
        .overlay(alignment: .top) {
            DividerLine()
        }
    }
}

private struct AppHeader: View {
    @ObservedObject var viewModel: ConversationSessionViewModel
    @ObservedObject var settings: AppSettingsStore
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 9) {
                    MonoLabel("CONVERSATION AGENT")
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(settings.aiDisplayName)
                            .font(.system(size: 48, weight: .light, design: .serif))
                            .foregroundColor(AppTheme.fg)
                        Text(" live")
                            .font(.system(size: 48, weight: .regular, design: .serif))
                            .italic()
                            .foregroundColor(AppTheme.accent)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                    Text(headerDetail)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(AppTheme.muted)
                        .lineLimit(2)
                }

                Spacer(minLength: 16)

                HStack(spacing: 10) {
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(AppTheme.fg)
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(AppTheme.bgSoft))
                            .overlay(Circle().stroke(AppTheme.border, lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())

                    Text(settings.logoText)
                        .font(.system(size: 20, weight: .medium, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.bg)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(AppTheme.fg))
                }
            }

            DividerLine()
        }
    }

    private var headerDetail: String {
        switch viewModel.phase {
        case .recording:
            return "Recording meeting audio from \(viewModel.activeInputName)."
        case .interrupted:
            return "Recording paused. Continue or finish the captured audio."
        case .transcribing:
            return "Turning the recording into a clean transcript."
        case .transcriptReady:
            return "Transcript is ready for review."
        case .summarizing:
            return "Extracting decisions, actions, and follow-ups."
        case .completed:
            return "Summary is ready for review."
        case .failed:
            return "The session needs attention."
        case .idle:
            return "Ready for \(settings.ownerDisplayName)'s meetings."
        }
    }
}

private struct RecordingStatusView: View {
    @ObservedObject var viewModel: ConversationSessionViewModel

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    StatusGlyph(icon: statusIcon, color: statusColor)

                    VStack(alignment: .leading, spacing: 5) {
                        MonoLabel("SESSION")
                        Text(viewModel.phase.label)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(AppTheme.fg)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }

                    Spacer(minLength: 12)

                    Text(viewModel.elapsedText)
                        .font(.system(size: 26, weight: .medium, design: .monospaced))
                        .foregroundColor(statusColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                DividerLine()

                HStack(spacing: 8) {
                    StateChip(
                        title: stateChipTitle,
                        icon: "record.circle",
                        color: statusColor,
                        accented: viewModel.phase == .recording || viewModel.phase == .interrupted
                    )
                    StateChip(title: viewModel.activeInputName, icon: "mic", color: AppTheme.fg)
                }
            }
        }
    }

    private var stateChipTitle: String {
        switch viewModel.phase {
        case .recording:
            return "live"
        case .interrupted:
            return "paused"
        default:
            return "standby"
        }
    }

    private var statusIcon: String {
        switch viewModel.phase {
        case .recording:
            return "record.circle"
        case .interrupted:
            return "pause.circle"
        case .transcribing:
            return "waveform"
        case .transcriptReady:
            return "text.quote"
        case .summarizing:
            return "sparkles"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        case .idle:
            return "mic.circle"
        }
    }

    private var statusColor: Color {
        switch viewModel.phase {
        case .recording, .transcribing, .summarizing:
            return AppTheme.accent
        case .interrupted:
            return AppTheme.danger
        case .transcriptReady, .completed:
            return AppTheme.success
        case .failed:
            return AppTheme.danger
        case .idle:
            return AppTheme.dim
        }
    }
}

private struct PrimaryRecordingButton: View {
    @ObservedObject var viewModel: ConversationSessionViewModel

    var body: some View {
        Button(action: viewModel.primaryAction) {
            HStack(spacing: 10) {
                Image(systemName: viewModel.phase == .recording ? "stop.fill" : "record.circle")
                    .font(.system(size: 17, weight: .semibold))
                Text(viewModel.primaryButtonTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundColor(AppTheme.bg)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Capsule().fill(AppTheme.fg))
            .opacity(viewModel.canTapPrimaryButton ? 1 : 0.48)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!viewModel.canTapPrimaryButton)
    }
}

private struct WearablesPanel: View {
    @ObservedObject var bridge: WearablesBridge

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(systemName: bridge.audioRoute.primaryDetectedDevice == nil ? "antenna.radiowaves.left.and.right" : "eyeglasses")

                    VStack(alignment: .leading, spacing: 6) {
                        MonoLabel("META WEARABLES")
                        Text(bridge.state.title)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(AppTheme.fg)
                        Text(bridge.state.detail)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(AppTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    StateChip(title: routeStatusTitle, icon: routeStatusIcon, color: routeStatusColor, accented: bridge.audioRoute.primaryDetectedDevice != nil)
                    StateChip(title: datStatusTitle, icon: "shippingbox", color: datStatusColor)
                }

                VStack(alignment: .leading, spacing: 9) {
                    RouteInfoRow(label: "ROUTE", value: bridge.audioRoute.routeSummary)
                    if let device = bridge.audioRoute.primaryDetectedDevice {
                        RouteInfoRow(label: "DEVICE", value: device.name)
                        RouteInfoRow(label: "MIC", value: device.supportsInput ? "available" : "output only")
                    } else {
                        RouteInfoRow(label: "INPUTS", value: bridge.audioRoute.availableInputNames.isEmpty ? "none" : bridge.audioRoute.availableInputNames.joined(separator: ", "))
                    }
                }

                HStack(spacing: 10) {
                    OutlineButton(title: "Refresh", icon: "arrow.clockwise") {
                        bridge.refreshAudioRoute()
                    }
                    OutlineButton(title: "Scan", icon: "dot.radiowaves.left.and.right") {
                        bridge.connectDetectedAudioRoute()
                    }
                }

                HStack(spacing: 10) {
                    OutlineButton(title: "Register", icon: "link") {
                        bridge.startRegistration()
                    }
                    OutlineButton(title: "DAT Session", icon: "play.circle") {
                        bridge.startGlassesSession()
                    }
                }
            }
        }
    }

    private var routeStatusTitle: String {
        guard let device = bridge.audioRoute.primaryDetectedDevice else {
            return "not found"
        }
        if device.supportsInput && device.isActive {
            return "mic active"
        }
        if device.supportsInput {
            return "mic ready"
        }
        return "output only"
    }

    private var routeStatusIcon: String {
        guard let device = bridge.audioRoute.primaryDetectedDevice else {
            return "slash.circle"
        }
        return device.supportsInput ? "mic.circle" : "speaker.wave.2"
    }

    private var datStatusTitle: String {
        if !bridge.isDATLinked {
            return "DAT missing"
        }
        return bridge.hasDATCredentials ? "DAT ready" : "DAT setup"
    }

    private var datStatusColor: Color {
        if !bridge.isDATLinked {
            return AppTheme.dim
        }
        return bridge.hasDATCredentials ? AppTheme.success : AppTheme.warn
    }

    private var routeStatusColor: Color {
        switch bridge.state {
        case .failed:
            return AppTheme.danger
        case .sessionStarted:
            return AppTheme.success
        case .configurationMissing:
            return AppTheme.warn
        case .detected, .ready:
            return bridge.audioRoute.primaryDetectedDevice == nil ? AppTheme.dim : AppTheme.accent
        case .registrationAvailable, .registrationStarted:
            return AppTheme.accent
        case .notDetected:
            return AppTheme.dim
        }
    }
}

private struct SummaryPanel: View {
    let summary: MeetingSummary
    let isGenerating: Bool
    let onGenerateSummary: (() -> Void)?

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(label: summary.summaryMode.title.uppercased(), title: summary.title, icon: summary.summaryMode.icon)

                if let onGenerateSummary {
                    WwPrimaryButton(isGenerating ? "Generating summary..." : "Generate summary", disabled: isGenerating) {
                        onGenerateSummary()
                    }
                }

                MonoLabel("overview")
                Text(summary.overview)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(AppTheme.fg)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                DividerLine()

                SummaryList(title: "Key Topics", items: keyTopics, icon: "number")
                SummaryList(title: "Decisions", items: summary.decisions, icon: "checkmark.seal")
                SummaryList(title: "Action Items", items: summary.actionItems, icon: "checklist")
                SummaryList(title: "Follow-ups", items: summary.followUps, icon: "arrow.clockwise")
            }
        }
    }

    private var keyTopics: [String] {
        if !summary.keyTopics.isEmpty {
            return summary.keyTopics
        }

        let candidates = [summary.title] + summary.decisions + summary.actionItems + summary.followUps
        return Array(candidates.prefix(4)).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

private struct ConversationContentsPanel: View {
    let meeting: StoredMeeting
    let scrollProxy: ScrollViewProxy
    let currentUserName: String
    let onUpdateTranscript: (String, [MeetingTranscriptSegment]) async throws -> StoredMeeting
    let onAssignSpeaker: (String, String?, String) async throws -> SpeakerAssignmentResult
    @Environment(\.scenePhase) private var scenePhase
    @State private var speakerNames: [String: String] = [:]
    @State private var voiceProfiles: [VoiceProfile] = []
    @State private var voiceProfilesLoading = false
    @State private var lastScrolledChunkID: String?
    @StateObject private var playback = MeetingAudioPlaybackController()

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            ConversationAudioRow(meeting: meeting, playback: playback)

            ConversationOutlineSection(items: outlineItems)

            VStack(alignment: .leading, spacing: 18) {
                ContentsSectionTitle(title: "Transcript")

                if displaySegments.isEmpty {
                    Text(SpeakerDisplayNames.decoratedSpeakerLabels(in: meeting.transcript, currentUserName: currentUserName))
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(AppTheme.fg)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(displayChunks) { chunk in
                        ConversationTranscriptSegmentRow(
                            chunk: chunk,
                            speakerName: displayName(for: chunk),
                            isActive: activeChunkID == chunk.id,
                            isPlaying: playback.isPlaying && activeChunkID == chunk.id,
                            playbackTime: playback.currentTime,
                            voiceProfiles: voiceProfiles,
                            currentUserName: currentUserName,
                            onTogglePlay: {
                                toggleChunkPlayback(chunk)
                            },
                            onPlayFromText: {
                                toggleChunkPlayback(chunk)
                            },
                            onStopPlaybackForEditing: {
                                playback.pausePlayback()
                            },
                            onSaveSpeakerName: { selection, scope in
                                try await saveSpeakerName(selection, for: chunk, scope: scope)
                            },
                            onSaveText: { text in
                                try await saveTranscriptEdit(chunk, text: text)
                            }
                        )
                        .id(chunk.id)
                    }
                }
            }
        }
        .padding(.top, 4)
        .onAppear {
            speakerNames = SpeakerNamePreferences.load(meetingId: meeting.id)
            Task { await loadVoiceProfiles() }
        }
        .onChange(of: playback.currentTime) { _ in
            scrollToActiveChunkIfNeeded()
        }
        .onChange(of: activeChunkID) { _ in
            scrollToActiveChunkIfNeeded(force: true)
        }
        .onChange(of: playback.isPlaying) { isPlaying in
            if isPlaying {
                scrollToActiveChunkIfNeeded(force: true)
            } else {
                lastScrolledChunkID = nil
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase != .active else {
                return
            }
            playback.stopForAppLifecycle()
        }
        .onDisappear {
            playback.stop()
        }
    }

    private var displaySegments: [MeetingTranscriptSegment] {
        if !meeting.segments.isEmpty {
            return meeting.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        let trimmed = meeting.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }
        return [
            MeetingTranscriptSegment(
                start: 0,
                end: meeting.durationSeconds ?? 0,
                text: trimmed,
                speaker: "Speaker"
            )
        ]
    }

    private var outlineItems: [MeetingOutlineItem] {
        if !meeting.summary.outline.isEmpty {
            return meeting.summary.outline
        }
        return MeetingContentsBuilder.outline(from: displaySegments, transcript: meeting.transcript)
    }

    private var displayChunks: [TranscriptDisplayChunk] {
        TranscriptDisplayChunk.group(segments: displaySegments, speakerKey: speakerKey(for:))
    }

    private var activeChunkID: String? {
        guard playback.isPlaying || playback.hasPlaybackPosition else {
            return nil
        }
        return displayChunks.first { chunk in
            playback.currentTime + 0.05 >= chunk.start && playback.currentTime <= chunk.end + 0.25
        }?.id
    }

    private func speakerKey(for segment: MeetingTranscriptSegment) -> String {
        let trimmed = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Speaker" : trimmed
    }

    private func displayName(for chunk: TranscriptDisplayChunk) -> String {
        let segmentKey = SpeakerNamePreferences.segmentKey(chunk.id)
        if let renamed = speakerNames[segmentKey], !renamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SpeakerDisplayNames.decorated(renamed, currentUserName: currentUserName)
        }
        return displayName(for: chunk.speakerKey)
    }

    private func displayName(for speakerKey: String) -> String {
        if let renamed = speakerNames[speakerKey], !renamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SpeakerDisplayNames.decorated(renamed, currentUserName: currentUserName)
        }

        if !speakerKey.localizedCaseInsensitiveContains("speaker") {
            return SpeakerDisplayNames.decorated(speakerKey, currentUserName: currentUserName)
        }

        let orderedKeys = speakerOrder
        if let index = orderedKeys.firstIndex(of: speakerKey) {
            return "Speaker \(index + 1)"
        }
        return "Speaker"
    }

    private var speakerOrder: [String] {
        var keys: [String] = []
        for chunk in displayChunks {
            let key = chunk.speakerKey
            if !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    private func saveSpeakerName(
        _ selection: SpeakerRenameSelection,
        for chunk: TranscriptDisplayChunk,
        scope: SpeakerRenameScope
    ) async throws {
        let trimmed = selection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = scope == .speaker ? chunk.speakerKey : SpeakerNamePreferences.segmentKey(chunk.id)
        if trimmed.isEmpty {
            speakerNames.removeValue(forKey: key)
        } else {
            speakerNames[key] = trimmed
            SpeakerNamePreferences.rememberRecentName(trimmed)
        }
        SpeakerNamePreferences.save(speakerNames, meetingId: meeting.id)

        guard scope == .speaker, !trimmed.isEmpty else {
            return
        }

        let result = try await onAssignSpeaker(chunk.speakerKey, selection.profileId, trimmed)
        upsertVoiceProfile(result.profile)
    }

    private func saveTranscriptEdit(_ chunk: TranscriptDisplayChunk, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptInlineEditError.emptyText
        }
        let updatedSegments = segments(replacing: chunk, with: trimmed)
        let updatedTranscript = MeetingTranscriptTextBuilder.text(from: updatedSegments)
        _ = try await onUpdateTranscript(updatedTranscript, updatedSegments)
    }

    private func toggleChunkPlayback(_ chunk: TranscriptDisplayChunk) {
        if activeChunkID == chunk.id {
            if playback.isPlaying {
                playback.pausePlayback()
            } else {
                scrollToChunk(chunk.id, force: true)
                playback.resumePlayback(for: meeting)
            }
        } else {
            scrollToChunk(chunk.id, force: true)
            playback.playFrom(chunk.start, meeting: meeting)
        }
    }

    private func segments(
        replacing chunk: TranscriptDisplayChunk,
        with text: String
    ) -> [MeetingTranscriptSegment] {
        let currentSegments = displaySegments
        let indexes = chunk.segmentIndexes.sorted()
        guard let firstIndex = indexes.first, firstIndex < currentSegments.count else {
            return [
                MeetingTranscriptSegment(
                    start: chunk.start,
                    end: chunk.end,
                    text: text,
                    speaker: chunk.speakerKey
                )
            ]
        }

        let skipIndexes = Set(indexes)
        let lastIndex = min(indexes.last ?? firstIndex, currentSegments.count - 1)
        var updated: [MeetingTranscriptSegment] = []

        for (index, segment) in currentSegments.enumerated() {
            if index == firstIndex {
                let lastSegment = currentSegments[lastIndex]
                updated.append(
                    MeetingTranscriptSegment(
                        start: segment.start,
                        end: max(segment.end, lastSegment.end),
                        text: text,
                        speaker: segment.speaker
                    )
                )
            } else if skipIndexes.contains(index) {
                continue
            } else {
                updated.append(segment)
            }
        }

        return updated
    }

    private func scrollToActiveChunkIfNeeded(force: Bool = false) {
        guard let activeChunkID else {
            return
        }
        scrollToChunk(activeChunkID, force: force)
    }

    private func scrollToChunk(_ chunkID: String, force: Bool = false) {
        guard force || chunkID != lastScrolledChunkID else {
            return
        }
        lastScrolledChunkID = chunkID
        withAnimation(.easeInOut(duration: 0.25)) {
            scrollProxy.scrollTo(chunkID, anchor: .center)
        }
    }

    private func loadVoiceProfiles() async {
        guard !voiceProfilesLoading, let service = VoiceProfilesService() else {
            return
        }
        voiceProfilesLoading = true
        defer { voiceProfilesLoading = false }
        do {
            voiceProfiles = try await service.list()
        } catch {
            voiceProfiles = []
        }
    }

    private func upsertVoiceProfile(_ profile: VoiceProfile) {
        if let index = voiceProfiles.firstIndex(where: { $0.id == profile.id }) {
            voiceProfiles[index] = profile
        } else {
            voiceProfiles.insert(profile, at: 0)
        }
    }
}

private struct ConversationAudioRow: View {
    let meeting: StoredMeeting
    @ObservedObject var playback: MeetingAudioPlaybackController
    @State private var scrubberValue: Double = 0
    @State private var isScrubbing = false
    @State private var wasPlayingBeforeScrub = false
    @State private var controlsExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            DividerLine()
            VStack(spacing: controlsExpanded ? 14 : 0) {
                HStack(alignment: .center, spacing: 12) {
                    Text("\(MeetingTimeFormatter.fullTimestamp(isScrubbing ? scrubberValue : playback.currentTime)) / \(MeetingTimeFormatter.fullTimestamp(playbackDuration))")
                        .font(.system(size: 16, weight: .regular, design: .monospaced))
                        .foregroundColor(AppTheme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Spacer(minLength: 0)

                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { controlsExpanded.toggle() } }) {
                        Image(systemName: controlsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppTheme.fg)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(AppTheme.bgSoft))
                            .overlay(Circle().stroke(AppTheme.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                if controlsExpanded {
                    VStack(spacing: 12) {
                        AudioWaveformScrubber(
                            value: isScrubbing ? scrubberValue : playback.currentTime,
                            duration: sliderUpperBound,
                            samples: playback.waveformSamples,
                            isEnabled: canPlay && !playback.isLoading,
                            onScrubStart: {
                                isScrubbing = true
                                wasPlayingBeforeScrub = playback.isPlaying
                            },
                            onScrubChanged: { value in
                                scrubberValue = value
                                playback.previewSeek(to: value)
                            },
                            onScrubEnded: { value in
                                scrubberValue = value
                                isScrubbing = false
                                playback.seek(
                                    to: value,
                                    meeting: meeting,
                                    resumePlayback: wasPlayingBeforeScrub
                                )
                            }
                        )

                        HStack(spacing: 16) {
                            AudioTransportButton(
                                systemName: playbackIcon,
                                size: .large,
                                disabled: !canPlay || playback.isLoading
                            ) {
                                playback.toggleFullPlayback(for: meeting)
                            }

                            AudioTransportButton(
                                systemName: "gobackward.15",
                                disabled: !canPlay || playback.isLoading
                            ) {
                                playback.skip(by: -15, meeting: meeting)
                            }

                            AudioTransportButton(
                                systemName: "goforward.15",
                                disabled: !canPlay || playback.isLoading
                            ) {
                                playback.skip(by: 15, meeting: meeting)
                            }

                            Button(action: { playback.cyclePlaybackRate() }) {
                                VStack(spacing: 1) {
                                    Image(systemName: "speedometer")
                                        .font(.system(size: 15, weight: .medium))
                                    Text(playback.playbackRateLabel)
                                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                                }
                                .foregroundColor(canPlay ? AppTheme.fg : AppTheme.dim)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(AppTheme.bgSoft))
                                .overlay(Circle().stroke(AppTheme.borderStrong.opacity(0.75), lineWidth: 1))
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(!canPlay)

                            Spacer(minLength: 0)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.vertical, controlsExpanded ? 18 : 14)
            DividerLine()
        }
        .onAppear {
            scrubberValue = playback.currentTime
            playback.preloadLocalAudioIfAvailable(for: meeting)
            playback.loadLocalWaveformIfAvailable(for: meeting)
        }
        .onChange(of: playback.currentTime) { newValue in
            if !isScrubbing {
                scrubberValue = newValue
            }
        }
    }

    private var canPlay: Bool {
        playback.canPlay(meeting)
    }

    private var playbackDuration: Double {
        playback.durationSeconds(for: meeting)
    }

    private var sliderUpperBound: Double {
        max(1, playbackDuration)
    }

    private var playbackIcon: String {
        guard canPlay else {
            return "play.slash.fill"
        }
        return playback.isPlaying ? "pause.fill" : "play.fill"
    }
}

private struct AudioWaveformScrubber: View {
    let value: Double
    let duration: Double
    let samples: [CGFloat]
    let isEnabled: Bool
    let onScrubStart: () -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnded: (Double) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let progress = progressRatio
            ZStack(alignment: .leading) {
                waveformCanvas(
                    samples: displaySamples,
                    progress: progress
                )
                .padding(.vertical, 6)

                Capsule()
                    .fill(AppTheme.fg)
                    .frame(width: 2, height: 52)
                    .offset(x: min(max(0, width * progress), max(0, width - 2)))
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else {
                            return
                        }
                        if !isDragging {
                            isDragging = true
                            onScrubStart()
                        }
                        onScrubChanged(time(at: gesture.location.x, width: width))
                    }
                    .onEnded { gesture in
                        guard isEnabled else {
                            isDragging = false
                            return
                        }
                        isDragging = false
                        onScrubEnded(time(at: gesture.location.x, width: width))
                    }
            )
        }
        .frame(height: 62)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio position")
        .accessibilityValue(MeetingTimeFormatter.timestamp(value))
    }

    private var progressRatio: CGFloat {
        guard duration > 0, value.isFinite else {
            return 0
        }
        return CGFloat(min(max(value / duration, 0), 1))
    }

    private var displaySamples: [CGFloat] {
        if !samples.isEmpty {
            return samples
        }
        return Self.placeholderSamples
    }

    private func time(at xPosition: CGFloat, width: CGFloat) -> Double {
        let ratio = min(max(xPosition / max(1, width), 0), 1)
        return Double(ratio) * max(0, duration)
    }

    private func waveformCanvas(
        samples: [CGFloat],
        progress: CGFloat
    ) -> some View {
        Canvas { context, canvasSize in
            drawWaveform(
                in: context,
                size: canvasSize,
                samples: samples,
                color: AppTheme.dim.opacity(0.24),
                clipProgress: 1
            )
            drawWaveform(
                in: context,
                size: canvasSize,
                samples: samples,
                color: AppTheme.fg,
                clipProgress: progress
            )
        }
    }

    private func drawWaveform(
        in context: GraphicsContext,
        size: CGSize,
        samples: [CGFloat],
        color: Color,
        clipProgress: CGFloat
    ) {
        guard !samples.isEmpty, size.width > 0, size.height > 0 else {
            return
        }

        var drawingContext = context
        drawingContext.clip(
            to: Path(
                CGRect(
                    x: 0,
                    y: 0,
                    width: size.width * min(max(clipProgress, 0), 1),
                    height: size.height
                )
            )
        )

        let spacing: CGFloat = 2
        let barWidth = max(2, (size.width - spacing * CGFloat(samples.count - 1)) / CGFloat(samples.count))
        for index in samples.indices {
            let amplitude = min(max(samples[index], 0.06), 1)
            let height = max(4, size.height * amplitude)
            let rect = CGRect(
                x: CGFloat(index) * (barWidth + spacing),
                y: (size.height - height) / 2,
                width: barWidth,
                height: height
            )
            drawingContext.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                with: .color(color)
            )
        }
    }

    private static let placeholderSamples: [CGFloat] = (0..<72).map { index in
        let primary = abs(sin(Double(index) * 0.41))
        let secondary = abs(cos(Double(index) * 0.17 + 0.8))
        return CGFloat(0.12 + min(0.86, primary * 0.58 + secondary * 0.24))
    }
}

private struct AudioTransportButton: View {
    enum Size {
        case standard
        case large
    }

    let systemName: String
    var size: Size = .standard
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if size == .large {
                    Circle()
                        .fill(AppTheme.bgSoft)
                }
                Image(systemName: systemName)
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundColor(disabled ? AppTheme.dim : AppTheme.fg)
            }
            .frame(width: buttonSize, height: buttonSize)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
        .accessibilityHidden(disabled)
    }

    private var buttonSize: CGFloat {
        size == .large ? 44 : 38
    }

    private var iconSize: CGFloat {
        size == .large ? 18 : 17
    }
}

private struct TranscriptDisplayChunk: Identifiable, Equatable {
    let id: String
    let start: Double
    let end: Double
    let speakerKey: String
    let text: String
    let segmentIndexes: [Int]
    let timeline: [TranscriptDisplayChunkTimelineItem]

    static func group(
        segments: [MeetingTranscriptSegment],
        speakerKey: (MeetingTranscriptSegment) -> String
    ) -> [TranscriptDisplayChunk] {
        let usableSegments = segments.enumerated().filter { _, segment in
            !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var groups: [[(offset: Int, element: MeetingTranscriptSegment)]] = []
        var current: [(offset: Int, element: MeetingTranscriptSegment)] = []

        for indexedSegment in usableSegments {
            guard let previous = current.last else {
                current = [indexedSegment]
                continue
            }

            if shouldStartNewGroup(
                next: indexedSegment.element,
                after: previous.element,
                current: current.map { $0.element },
                speakerKey: speakerKey
            ) {
                groups.append(current)
                current = [indexedSegment]
            } else {
                current.append(indexedSegment)
            }
        }

        if !current.isEmpty {
            groups.append(current)
        }

        return groups.compactMap { group in
            guard let first = group.first?.element, let last = group.last?.element else {
                return nil
            }
            let key = speakerKey(first)
            let startBucket = Int((first.start * 100).rounded())
            let endBucket = Int((last.end * 100).rounded())
            return TranscriptDisplayChunk(
                id: "\(startBucket)-\(endBucket)-\(key)",
                start: first.start,
                end: max(first.end, last.end),
                speakerKey: key,
                text: group.map { $0.element.text }.joined(separator: " "),
                segmentIndexes: group.map { $0.offset },
                timeline: group.map { item in
                    TranscriptDisplayChunkTimelineItem(
                        start: item.element.start,
                        end: max(item.element.start + 0.1, item.element.end),
                        text: item.element.text
                    )
                }
            )
        }
    }

    private static func shouldStartNewGroup(
        next: MeetingTranscriptSegment,
        after previous: MeetingTranscriptSegment,
        current: [MeetingTranscriptSegment],
        speakerKey: (MeetingTranscriptSegment) -> String
    ) -> Bool {
        if speakerKey(next) != speakerKey(previous) {
            return true
        }
        if next.start - previous.end >= 4 {
            return true
        }
        let sentenceCount = current.reduce(0) { total, segment in
            total + max(1, segment.text.filter { ".!?".contains($0) }.count)
        }
        if sentenceCount >= 3 {
            return true
        }
        let duration = max(previous.end, next.end) - (current.first?.start ?? next.start)
        return duration >= 24
    }
}

private struct TranscriptDisplayChunkTimelineItem: Equatable {
    let start: Double
    let end: Double
    let text: String

    var wordCount: Int {
        TranscriptPlaybackTextToken.wordCount(in: text)
    }
}

@MainActor
private final class MeetingAudioPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var waveformSamples: [CGFloat] = []
    @Published private(set) var playbackRate: Double = 1
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasPlaybackPosition = false

    private var player: AVAudioPlayer?
    private var loadedMeetingID: String?
    private var waveformMeetingID: String?
    private var waveformTask: Task<Void, Never>?
    private var stopAt: Double?
    private var timer: Timer?
    private var playbackRequestSerial = 0
    private let downloader: MeetingAudioDownloadService?

    init(downloader: MeetingAudioDownloadService? = MeetingAudioDownloadServiceFactory.make()) {
        self.downloader = downloader
    }

    func canPlay(_ meeting: StoredMeeting) -> Bool {
        MeetingAudioFileStore.load(meetingId: meeting.id) != nil || (meeting.hasAudio && downloader != nil)
    }

    func durationSeconds(for meeting: StoredMeeting) -> Double {
        if duration.isFinite, duration > 0 {
            return duration
        }
        return max(0, meeting.durationSeconds ?? 0)
    }

    var playbackRateLabel: String {
        switch playbackRate {
        case 1.25:
            return "1.25x"
        case 1.5:
            return "1.5x"
        case 2:
            return "2x"
        default:
            return "1x"
        }
    }

    func cyclePlaybackRate() {
        let rates = [1.0, 1.25, 1.5, 2.0]
        let currentIndex = rates.firstIndex { abs($0 - playbackRate) < 0.01 } ?? 0
        playbackRate = rates[(currentIndex + 1) % rates.count]
        if let player {
            applyPlaybackRate(to: player)
        }
    }

    func loadLocalWaveformIfAvailable(for meeting: StoredMeeting) {
        guard waveformMeetingID != meeting.id,
              let localURL = MeetingAudioFileStore.load(meetingId: meeting.id) else {
            return
        }
        loadWaveform(from: localURL, meetingID: meeting.id)
    }

    func preloadLocalAudioIfAvailable(for meeting: StoredMeeting) {
        guard loadedMeetingID != meeting.id,
              player == nil,
              let localURL = MeetingAudioFileStore.load(meetingId: meeting.id) else {
            return
        }

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: localURL)
            newPlayer.delegate = self
            applyPlaybackRate(to: newPlayer)
            newPlayer.prepareToPlay()
            player = newPlayer
            loadedMeetingID = meeting.id
            duration = newPlayer.duration
            if !hasPlaybackPosition {
                currentTime = newPlayer.currentTime
            }
            loadWaveform(from: localURL, meetingID: meeting.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func previewSeek(to seconds: Double) {
        currentTime = clampedTime(seconds)
    }

    func toggleFullPlayback(for meeting: StoredMeeting) {
        Task { @MainActor in
            guard canPlay(meeting) else {
                return
            }
            let requestSerial = beginPlaybackRequest()
            if isPlaying && stopAt == nil {
                pause()
                return
            }
            do {
                guard let player = try await preparePlayer(for: meeting, requestSerial: requestSerial) else {
                    return
                }
                stopAt = nil
                hasPlaybackPosition = true
                play(player)
                isPlaying = true
                startTimer()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func playChunk(_ chunk: TranscriptDisplayChunk, meeting: StoredMeeting) {
        Task { @MainActor in
            guard canPlay(meeting) else {
                return
            }
            let requestSerial = beginPlaybackRequest()
            do {
                guard let player = try await preparePlayer(for: meeting, requestSerial: requestSerial) else {
                    return
                }
                player.currentTime = max(0, chunk.start)
                currentTime = player.currentTime
                hasPlaybackPosition = true
                stopAt = max(chunk.start, chunk.end)
                play(player)
                isPlaying = true
                startTimer()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func playFrom(_ seconds: Double, meeting: StoredMeeting) {
        Task { @MainActor in
            guard canPlay(meeting) else {
                return
            }
            let requestSerial = beginPlaybackRequest()
            do {
                guard let player = try await preparePlayer(for: meeting, requestSerial: requestSerial) else {
                    return
                }
                stopAt = nil
                player.currentTime = clampedTime(seconds)
                currentTime = player.currentTime
                hasPlaybackPosition = true
                play(player)
                isPlaying = true
                startTimer()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func resumePlayback(for meeting: StoredMeeting) {
        Task { @MainActor in
            guard canPlay(meeting), hasPlaybackPosition else {
                return
            }
            let requestSerial = beginPlaybackRequest()
            let resumeTime = currentTime
            do {
                guard let player = try await preparePlayer(for: meeting, requestSerial: requestSerial) else {
                    return
                }
                stopAt = nil
                player.currentTime = clampedTime(resumeTime)
                currentTime = player.currentTime
                hasPlaybackPosition = true
                play(player)
                isPlaying = true
                startTimer()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func seek(to seconds: Double, meeting: StoredMeeting, resumePlayback: Bool) {
        Task { @MainActor in
            guard canPlay(meeting) else {
                return
            }
            let requestSerial = beginPlaybackRequest()
            do {
                guard let player = try await preparePlayer(for: meeting, requestSerial: requestSerial) else {
                    return
                }
                player.currentTime = clampedTime(seconds)
                currentTime = player.currentTime
                hasPlaybackPosition = true
                if resumePlayback {
                    play(player)
                    isPlaying = true
                    startTimer()
                } else {
                    isPlaying = player.isPlaying
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func skip(by seconds: Double, meeting: StoredMeeting) {
        Task { @MainActor in
            guard canPlay(meeting) else {
                return
            }
            let requestSerial = beginPlaybackRequest()
            do {
                guard let player = try await preparePlayer(for: meeting, requestSerial: requestSerial) else {
                    return
                }
                stopAt = nil
                player.currentTime = clampedTime(player.currentTime + seconds)
                currentTime = player.currentTime
                hasPlaybackPosition = true
                if isPlaying {
                    play(player)
                    startTimer()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func pausePlayback() {
        pause()
    }

    func stop() {
        stop(invalidateRequest: true)
    }

    private func stop(invalidateRequest: Bool) {
        if invalidateRequest {
            invalidatePlaybackRequests()
        }
        timer?.invalidate()
        timer = nil
        player?.stop()
        try? Self.deactivatePlaybackAudioSession()
        player = nil
        loadedMeetingID = nil
        waveformMeetingID = nil
        waveformTask?.cancel()
        waveformTask = nil
        waveformSamples = []
        stopAt = nil
        isLoading = false
        hasPlaybackPosition = false
        currentTime = 0
        duration = 0
        isPlaying = false
    }

    func stopForAppLifecycle() {
        guard player != nil || isPlaying || isLoading else {
            return
        }
        stop()
    }

    private func preparePlayer(for meeting: StoredMeeting, requestSerial: Int) async throws -> AVAudioPlayer? {
        if loadedMeetingID == meeting.id, let player {
            return player
        }

        stop(invalidateRequest: false)
        isLoading = true
        defer { isLoading = false }

        let audioURL: URL
        if let localURL = MeetingAudioFileStore.load(meetingId: meeting.id) {
            audioURL = localURL
        } else if meeting.hasAudio, let downloader {
            audioURL = try await downloader.downloadAudio(meetingId: meeting.id, locationName: meeting.locationName)
        } else {
            throw MeetingsServiceError.backendFailed
        }

        guard isCurrentPlaybackRequest(requestSerial) else {
            return nil
        }
        let newPlayer = try AVAudioPlayer(contentsOf: audioURL)
        newPlayer.delegate = self
        applyPlaybackRate(to: newPlayer)
        newPlayer.prepareToPlay()
        player = newPlayer
        loadedMeetingID = meeting.id
        duration = newPlayer.duration
        currentTime = newPlayer.currentTime
        loadWaveform(from: audioURL, meetingID: meeting.id)
        return newPlayer
    }

    private func beginPlaybackRequest() -> Int {
        playbackRequestSerial += 1
        return playbackRequestSerial
    }

    private func invalidatePlaybackRequests() {
        playbackRequestSerial += 1
    }

    private func isCurrentPlaybackRequest(_ serial: Int) -> Bool {
        playbackRequestSerial == serial
    }

    private func loadWaveform(from audioURL: URL, meetingID: String) {
        waveformTask?.cancel()
        waveformMeetingID = meetingID
        waveformTask = Task { [weak self] in
            let samples = await AudioWaveformAnalyzer.samples(for: audioURL, targetSampleCount: 96)
            await MainActor.run {
                guard let self,
                      !Task.isCancelled,
                      self.waveformMeetingID == meetingID else {
                    return
                }
                self.waveformSamples = samples
            }
        }
    }

    private func applyPlaybackRate(to player: AVAudioPlayer) {
        player.enableRate = true
        player.rate = Float(playbackRate)
    }

    private func play(_ player: AVAudioPlayer) {
        try? Self.configurePlaybackAudioSession()
        applyPlaybackRate(to: player)
        player.play()
        player.rate = Float(playbackRate)
    }

    private static func configurePlaybackAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }

    private static func deactivatePlaybackAudioSession() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func pause() {
        player?.pause()
        if let player {
            currentTime = player.currentTime
            hasPlaybackPosition = true
        }
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let player else {
            stop()
            return
        }
        currentTime = player.currentTime
        hasPlaybackPosition = true
        if let stopAt, player.currentTime >= stopAt {
            player.pause()
            player.currentTime = stopAt
            currentTime = stopAt
            hasPlaybackPosition = true
            self.stopAt = nil
            timer?.invalidate()
            timer = nil
            isPlaying = false
            try? Self.deactivatePlaybackAudioSession()
        } else {
            isPlaying = player.isPlaying
        }
    }

    private func clampedTime(_ seconds: Double) -> Double {
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        return min(max(0, seconds), upperBound)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.timer?.invalidate()
            self.timer = nil
            self.stopAt = nil
            self.isPlaying = false
            self.currentTime = player.currentTime
            self.hasPlaybackPosition = false
            try? Self.deactivatePlaybackAudioSession()
        }
    }
}

private enum AudioWaveformAnalyzer {
    static func samples(for audioURL: URL, targetSampleCount: Int) async -> [CGFloat] {
        await Task.detached(priority: .utility) {
            readSamples(for: audioURL, targetSampleCount: targetSampleCount)
        }.value
    }

    private static func readSamples(for audioURL: URL, targetSampleCount: Int) -> [CGFloat] {
        let bucketCount = max(24, targetSampleCount)
        do {
            let audioFile = try AVAudioFile(forReading: audioURL)
            let totalFrames = max(1, Int(audioFile.length))
            let processingFormat = audioFile.processingFormat
            let readCapacity: AVAudioFrameCount = 8_192
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: processingFormat,
                frameCapacity: readCapacity
            ) else {
                return []
            }

            var peaks = Array(repeating: Float(0), count: bucketCount)
            var absoluteFrameIndex = 0
            while audioFile.framePosition < audioFile.length {
                if Task.isCancelled {
                    return []
                }
                try audioFile.read(into: buffer, frameCount: readCapacity)
                let frameLength = Int(buffer.frameLength)
                guard frameLength > 0, let channelData = buffer.floatChannelData else {
                    break
                }

                let channelCount = max(1, Int(processingFormat.channelCount))
                for frameIndex in 0..<frameLength {
                    var amplitude: Float = 0
                    for channelIndex in 0..<channelCount {
                        amplitude = max(amplitude, abs(channelData[channelIndex][frameIndex]))
                    }
                    let bucketIndex = min(
                        bucketCount - 1,
                        (absoluteFrameIndex + frameIndex) * bucketCount / totalFrames
                    )
                    peaks[bucketIndex] = max(peaks[bucketIndex], amplitude)
                }
                absoluteFrameIndex += frameLength
            }

            guard let maxPeak = peaks.max(), maxPeak > 0 else {
                return []
            }
            return peaks.map { peak in
                let normalized = sqrt(Double(peak / maxPeak))
                return CGFloat(min(max(normalized, 0.08), 1))
            }
        } catch {
            return []
        }
    }
}

private struct ConversationOutlineSection: View {
    let items: [MeetingOutlineItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ContentsSectionTitle(title: "Outline")

            if items.isEmpty {
                Text("No outline was generated for this conversation.")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(AppTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 24) {
                            Text(MeetingTimeFormatter.timestamp(item.start))
                                .font(.system(size: 16, weight: .regular, design: .monospaced))
                                .underline()
                                .foregroundColor(AppTheme.fg)
                                .frame(width: 86, alignment: .leading)

                            Text(item.title)
                                .font(.system(size: 16, weight: .regular))
                                .foregroundColor(AppTheme.muted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            DividerLine()
        }
    }
}

private struct ConversationTranscriptSegmentRow: View {
    let chunk: TranscriptDisplayChunk
    let speakerName: String
    let isActive: Bool
    let isPlaying: Bool
    let playbackTime: Double
    let voiceProfiles: [VoiceProfile]
    let currentUserName: String
    let onTogglePlay: () -> Void
    let onPlayFromText: () -> Void
    let onStopPlaybackForEditing: () -> Void
    let onSaveSpeakerName: (SpeakerRenameSelection, SpeakerRenameScope) async throws -> Void
    let onSaveText: (String) async throws -> Void

    @State private var textDraft: String
    @State private var speakerDraft: String
    @State private var isEditingText = false
    @State private var isRenamingSpeaker = false
    @State private var isSavingSpeaker = false
    @State private var isSavingText = false
    @State private var speakerErrorMessage: String?
    @State private var textErrorMessage: String?
    @FocusState private var focusedField: FocusedField?

    init(
        chunk: TranscriptDisplayChunk,
        speakerName: String,
        isActive: Bool,
        isPlaying: Bool,
        playbackTime: Double,
        voiceProfiles: [VoiceProfile],
        currentUserName: String,
        onTogglePlay: @escaping () -> Void,
        onPlayFromText: @escaping () -> Void,
        onStopPlaybackForEditing: @escaping () -> Void,
        onSaveSpeakerName: @escaping (SpeakerRenameSelection, SpeakerRenameScope) async throws -> Void,
        onSaveText: @escaping (String) async throws -> Void
    ) {
        self.chunk = chunk
        self.speakerName = speakerName
        self.isActive = isActive
        self.isPlaying = isPlaying
        self.playbackTime = playbackTime
        self.voiceProfiles = voiceProfiles
        self.currentUserName = currentUserName
        self.onTogglePlay = onTogglePlay
        self.onPlayFromText = onPlayFromText
        self.onStopPlaybackForEditing = onStopPlaybackForEditing
        self.onSaveSpeakerName = onSaveSpeakerName
        self.onSaveText = onSaveText
        _textDraft = State(initialValue: chunk.text)
        _speakerDraft = State(initialValue: speakerName)
    }

    private enum FocusedField: Hashable {
        case text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Button(action: onTogglePlay) {
                    HStack(spacing: 6) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(MeetingTimeFormatter.timestamp(chunk.start))
                            .font(.system(size: 15, weight: .regular, design: .monospaced))
                    }
                    .foregroundColor(isPlaying ? AppTheme.fg : AppTheme.dim)
                    .frame(width: 86, alignment: .leading)
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: beginSpeakerRenaming) {
                    Text(speakerName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppTheme.fg)
                }
                .buttonStyle(PlainButtonStyle())

                Spacer(minLength: 0)
            }

            if isEditingText {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $textDraft)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(AppTheme.fg)
                        .focused($focusedField, equals: .text)
                        .frame(minHeight: textEditorHeight)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppTheme.bg))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.borderStrong, lineWidth: 1))

                    HStack(spacing: 8) {
                        InlineEditActionButton(
                            systemName: isSavingText ? "hourglass" : "checkmark",
                            disabled: isSavingText,
                            action: commitTextEdit
                        )
                        InlineEditActionButton(
                            systemName: "xmark",
                            disabled: isSavingText,
                            action: cancelTextEdit
                        )

                        if let textErrorMessage {
                            Text(textErrorMessage)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(AppTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                }
            } else {
                playbackHighlightedText
                    .font(.system(size: 18, weight: .regular))
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onPlayFromText)
                    .simultaneousGesture(
                        TapGesture(count: 2)
                            .onEnded { beginTextEditing() }
                    )
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? AppTheme.bgSoft : Color.clear)
        )
        .onChange(of: chunk.text) { newValue in
            if !isEditingText {
                textDraft = newValue
            }
        }
        .onChange(of: speakerName) { newValue in
            if !isRenamingSpeaker {
                speakerDraft = newValue
            }
        }
        .sheet(isPresented: $isRenamingSpeaker) {
            SpeakerRenamePopup(
                initialName: speakerName,
                voiceProfiles: voiceProfiles,
                currentUserName: currentUserName,
                isSaving: isSavingSpeaker,
                errorMessage: speakerErrorMessage,
                onCancel: cancelSpeakerRename,
                onSave: commitSpeakerRename
            )
            .speakerRenameSheetStyle()
        }
    }

    private var textEditorHeight: CGFloat {
        let lineCount = max(3, textDraft.components(separatedBy: .newlines).count + textDraft.count / 42)
        return min(220, CGFloat(lineCount * 25 + 24))
    }

    private var playbackHighlightedText: Text {
        guard isActive else {
            return Text(chunk.text).foregroundColor(AppTheme.fg)
        }

        let highlightedCount = highlightedPlaybackWordCount
        var rendered = Text("")
        var wordIndex = 0

        for token in TranscriptPlaybackTextToken.tokenize(chunk.text) {
            if token.isWord {
                let color = wordIndex < highlightedCount ? AppTheme.playbackBlue : AppTheme.fg
                rendered = rendered + Text(token.value).foregroundColor(color)
                wordIndex += 1
            } else {
                rendered = rendered + Text(token.value).foregroundColor(AppTheme.fg)
            }
        }

        return rendered
    }

    private var highlightedPlaybackWordCount: Int {
        guard isActive else {
            return 0
        }

        let wordCount = TranscriptPlaybackTextToken.wordCount(in: chunk.text)
        guard wordCount > 0 else {
            return 0
        }

        let readableLeadSeconds = isPlaying ? 0.7 : 0
        let targetTime = playbackTime + readableLeadSeconds
        var completedWords = 0

        for item in chunk.timeline {
            let itemWordCount = item.wordCount
            guard itemWordCount > 0 else {
                continue
            }
            if targetTime >= item.end {
                completedWords += itemWordCount
                continue
            }
            if targetTime <= item.start {
                break
            }

            let duration = max(0.1, item.end - item.start)
            let progress = min(max((targetTime - item.start) / duration, 0), 1)
            completedWords += min(itemWordCount, max(1, Int(ceil(progress * Double(itemWordCount)))))
            break
        }

        return min(wordCount, completedWords)
    }

    private func beginSpeakerRenaming() {
        speakerDraft = speakerName
        speakerErrorMessage = nil
        isRenamingSpeaker = true
    }

    private func commitSpeakerRename(_ selection: SpeakerRenameSelection, scope: SpeakerRenameScope) {
        guard !isSavingSpeaker else {
            return
        }
        speakerDraft = selection.name
        speakerErrorMessage = nil
        isSavingSpeaker = true
        Task { @MainActor in
            do {
                try await onSaveSpeakerName(selection, scope)
                isRenamingSpeaker = false
            } catch {
                speakerErrorMessage = error.localizedDescription
            }
            isSavingSpeaker = false
        }
    }

    private func cancelSpeakerRename() {
        guard !isSavingSpeaker else {
            return
        }
        speakerDraft = speakerName
        speakerErrorMessage = nil
        isRenamingSpeaker = false
    }

    private func beginTextEditing() {
        onStopPlaybackForEditing()
        textDraft = chunk.text
        textErrorMessage = nil
        isEditingText = true
        DispatchQueue.main.async {
            focusedField = .text
        }
    }

    private func commitTextEdit() {
        guard !isSavingText else {
            return
        }
        let trimmed = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            textErrorMessage = TranscriptInlineEditError.emptyText.localizedDescription
            return
        }

        isSavingText = true
        textErrorMessage = nil
        Task { @MainActor in
            do {
                try await onSaveText(trimmed)
                isEditingText = false
                focusedField = nil
            } catch {
                textErrorMessage = error.localizedDescription
            }
            isSavingText = false
        }
    }

    private func cancelTextEdit() {
        textDraft = chunk.text
        textErrorMessage = nil
        isEditingText = false
        focusedField = nil
    }
}

private struct TranscriptPlaybackTextToken {
    let value: String
    let isWord: Bool

    static func tokenize(_ text: String) -> [TranscriptPlaybackTextToken] {
        var tokens: [TranscriptPlaybackTextToken] = []
        var buffer = ""
        var currentIsWord: Bool?

        for character in text {
            let isWord = !character.isTranscriptWhitespace
            if currentIsWord == isWord {
                buffer.append(character)
            } else {
                append(buffer, isWord: currentIsWord, to: &tokens)
                buffer = String(character)
                currentIsWord = isWord
            }
        }

        append(buffer, isWord: currentIsWord, to: &tokens)
        return tokens
    }

    static func wordCount(in text: String) -> Int {
        tokenize(text).filter(\.isWord).count
    }

    private static func append(
        _ value: String,
        isWord: Bool?,
        to tokens: inout [TranscriptPlaybackTextToken]
    ) {
        guard let isWord, !value.isEmpty else {
            return
        }
        tokens.append(TranscriptPlaybackTextToken(value: value, isWord: isWord))
    }
}

private extension Character {
    var isTranscriptWhitespace: Bool {
        unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }
}

private struct InlineEditActionButton: View {
    let systemName: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(disabled ? AppTheme.dim : AppTheme.fg)
                .frame(width: 28, height: 28)
                .background(Circle().fill(AppTheme.bgSoft))
                .overlay(Circle().stroke(AppTheme.borderStrong, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
    }
}

private enum SpeakerRenameScope {
    case segment
    case speaker
}

private struct SpeakerRenameSelection {
    let name: String
    let profileId: String?
}

private struct SpeakerRenamePopup: View {
    let initialName: String
    let voiceProfiles: [VoiceProfile]
    let currentUserName: String
    let isSaving: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onSave: (SpeakerRenameSelection, SpeakerRenameScope) -> Void

    @State private var draft: String
    @State private var selectedProfileId: String?
    @State private var scope: SpeakerRenameScope = .speaker
    @FocusState private var isNameFocused: Bool

    init(
        initialName: String,
        voiceProfiles: [VoiceProfile],
        currentUserName: String,
        isSaving: Bool,
        errorMessage: String?,
        onCancel: @escaping () -> Void,
        onSave: @escaping (SpeakerRenameSelection, SpeakerRenameScope) -> Void
    ) {
        self.initialName = initialName
        self.voiceProfiles = voiceProfiles
        self.currentUserName = currentUserName
        self.isSaving = isSaving
        self.errorMessage = errorMessage
        self.onCancel = onCancel
        self.onSave = onSave
        _draft = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                Text("Name this speaker")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundColor(AppTheme.fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 12)

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppTheme.fg)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(PlainButtonStyle())
            }

            DividerLine()

            TextField(initialName, text: $draft)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(AppTheme.fg)
                .focused($isNameFocused)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .onSubmit {
                    isNameFocused = false
                }
                .padding(.horizontal, 11)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppTheme.bg))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.borderStrong, lineWidth: 1))
                .onChange(of: draft) { newValue in
                    if selectedProfile?.name != newValue {
                        selectedProfileId = nil
                    }
                }

            if let userName = selfName {
                Button(action: {
                    draft = userName
                    selectedProfileId = matchingProfile(named: userName)?.id
                }) {
                    Text("\(userName)(you)")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(AppTheme.muted)
                        .padding(.horizontal, 9)
                        .frame(height: 32)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .foregroundColor(AppTheme.borderStrong)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("Saved voice profiles")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(AppTheme.muted)
                    .padding(.bottom, 8)

                if voiceProfiles.isEmpty {
                    Text("No saved voices yet")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(AppTheme.dim)
                        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                } else {
                    ForEach(voiceProfiles.prefix(6)) { profile in
                        Button(action: { select(profile) }) {
                            HStack(spacing: 8) {
                                Text(profile.name)
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(AppTheme.fg)
                                if let sampleCount = profile.sampleCount, sampleCount > 1 {
                                    Text("\(sampleCount) samples")
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundColor(AppTheme.dim)
                                }
                                Spacer(minLength: 0)
                                if selectedProfileId == profile.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(AppTheme.fg)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .overlay(alignment: .bottom) {
                            DividerLine()
                        }
                    }
                }
            }

            VStack(spacing: 0) {
                SpeakerRenameScopeRow(
                    title: "Apply to this segment",
                    subtitle: nil,
                    isSelected: scope == .segment,
                    action: { scope = .segment }
                )

                SpeakerRenameScopeRow(
                    title: "Apply to all segments from this speaker",
                    subtitle: "This saves or extends the voice profile for future meetings.",
                    isSelected: scope == .speaker,
                    action: { scope = .speaker }
                )
            }

            Button(action: save) {
                Text(isSaving ? "Saving..." : "Save")
                    .font(.system(size: 17, weight: .medium, design: .serif))
                    .foregroundColor(AppTheme.bg)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.fg))
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isSaving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(isSaving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            .padding(.top, 4)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(AppTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.bg.ignoresSafeArea())
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isNameFocused = true
            }
        }
    }

    private var selfName: String? {
        let trimmed = currentUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && trimmed != "Owner" else {
            return nil
        }
        return trimmed
    }

    private var selectedProfile: VoiceProfile? {
        guard let selectedProfileId else {
            return nil
        }
        return voiceProfiles.first { $0.id == selectedProfileId }
    }

    private func select(_ profile: VoiceProfile) {
        draft = profile.name
        selectedProfileId = profile.id
    }

    private func matchingProfile(named name: String) -> VoiceProfile? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return voiceProfiles.first { profile in
            profile.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        let profileId = selectedProfileId ?? matchingProfile(named: trimmed)?.id
        onSave(SpeakerRenameSelection(name: trimmed, profileId: profileId), scope)
    }
}

private extension View {
    @ViewBuilder
    func speakerRenameSheetStyle() -> some View {
        if #available(iOS 16.0, *) {
            self
                .presentationDetents([.fraction(0.75)])
                .presentationDragIndicator(.visible)
        } else {
            self
        }
    }
}

private struct SpeakerRenameScopeRow: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(AppTheme.fg)
                        .fixedSize(horizontal: false, vertical: true)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(AppTheme.dim)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 12)

                ZStack {
                    Circle()
                        .stroke(isSelected ? AppTheme.fg : AppTheme.borderStrong, lineWidth: isSelected ? 2 : 1.5)
                        .frame(width: 19, height: 19)
                    if isSelected {
                        Circle()
                            .fill(AppTheme.fg)
                            .frame(width: 10, height: 10)
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct ContentsSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(AppTheme.fg)
            .overlay(alignment: .bottomLeading) {
                Rectangle()
                    .fill(AppTheme.fg)
                    .frame(height: 1)
                    .offset(y: 4)
            }
    }
}

private enum TranscriptInlineEditError: LocalizedError {
    case emptyText

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Transcript text cannot be empty."
        }
    }
}

private enum SpeakerDisplayNames {
    static func decorated(_ name: String, currentUserName: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return name
        }
        guard !trimmed.localizedCaseInsensitiveContains("(you)") else {
            return trimmed
        }
        return isCurrentUserName(trimmed, currentUserName: currentUserName) ? "\(trimmed) (you)" : trimmed
    }

    static func decoratedSpeakerLabels(in transcript: String, currentUserName: String) -> String {
        transcript
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let colonIndex = line.firstIndex(of: ":") else {
                    return String(line)
                }
                let speaker = String(line[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard isCurrentUserName(speaker, currentUserName: currentUserName) else {
                    return String(line)
                }
                return "\(decorated(speaker, currentUserName: currentUserName))\(line[colonIndex...])"
            }
            .joined(separator: "\n")
    }

    private static func isCurrentUserName(_ name: String, currentUserName: String) -> Bool {
        let normalizedName = normalized(name)
        guard !normalizedName.isEmpty else {
            return false
        }
        let normalizedCurrentUser = normalized(currentUserName)
        return normalizedName == normalizedCurrentUser || normalizedName == "yerasyl"
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

private enum MeetingTranscriptTextBuilder {
    static func text(from segments: [MeetingTranscriptSegment]) -> String {
        let nonEmptySegments = segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !nonEmptySegments.isEmpty else {
            return ""
        }

        let speakerKeys = uniqueSpeakerKeys(in: nonEmptySegments)
        let shouldPrefixSpeaker = speakerKeys.count > 1 || speakerKeys.contains { key in
            !key.localizedCaseInsensitiveContains("speaker")
        }

        return nonEmptySegments.map { segment in
            let cleanText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard shouldPrefixSpeaker else {
                return cleanText
            }
            let speaker = speakerKey(for: segment)
            return "\(speaker): \(cleanText)"
        }
        .joined(separator: "\n")
    }

    private static func uniqueSpeakerKeys(in segments: [MeetingTranscriptSegment]) -> [String] {
        var keys: [String] = []
        for segment in segments {
            let key = speakerKey(for: segment)
            if !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    private static func speakerKey(for segment: MeetingTranscriptSegment) -> String {
        let trimmed = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Speaker" : trimmed
    }
}

private enum MeetingTimeFormatter {
    static func audioDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else {
            return "00:00:00"
        }
        return clock(seconds)
    }

    static func timestamp(_ seconds: Double) -> String {
        clock(seconds)
    }

    static func fullTimestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "0:%02d:%02d", minutes, secs)
    }
}

private enum MeetingContentsBuilder {
    static func outline(from segments: [MeetingTranscriptSegment], transcript: String) -> [MeetingOutlineItem] {
        let usableSegments = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usableSegments.isEmpty else {
            let title = outlineTitle(from: transcript)
            return title.isEmpty ? [] : [MeetingOutlineItem(start: 0, title: title)]
        }

        var groups: [[MeetingTranscriptSegment]] = []
        var current: [MeetingTranscriptSegment] = []
        for segment in usableSegments {
            guard let previous = current.last else {
                current = [segment]
                continue
            }

            let gap = segment.start - previous.end
            let duration = max(previous.end, segment.end) - (current.first?.start ?? segment.start)
            let previousEndedSentence = previous.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".")
                || previous.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
                || previous.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("!")

            if gap >= 12 || duration >= 140 || (duration >= 75 && previousEndedSentence) {
                groups.append(current)
                current = [segment]
            } else {
                current.append(segment)
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }

        return groups.prefix(8).compactMap { group in
            guard let first = group.first else {
                return nil
            }
            let title = outlineTitle(from: group.map(\.text).joined(separator: " "))
            return title.isEmpty ? nil : MeetingOutlineItem(start: first.start, title: title)
        }
    }

    private static func outlineTitle(from text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return ""
        }

        let sentence = cleaned
            .split(whereSeparator: { ".!?".contains($0) })
            .first
            .map(String.init) ?? cleaned
        return sentence
            .split(separator: " ")
            .prefix(12)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-"))
    }
}

private enum SpeakerNamePreferences {
    private static let recentNamesKey = "her.meeting.recentSpeakerNames"

    static func load(meetingId: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key(meetingId)) as? [String: String] ?? [:]
    }

    static func save(_ names: [String: String], meetingId: String) {
        UserDefaults.standard.set(names, forKey: key(meetingId))
    }

    static func segmentKey(_ chunkID: String) -> String {
        "segment.\(chunkID)"
    }

    static func recentNames() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentNamesKey) ?? []
    }

    static func rememberRecentName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        var names = recentNames().filter { $0 != trimmed }
        names.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(names.prefix(12)), forKey: recentNamesKey)
    }

    private static func key(_ meetingId: String) -> String {
        "her.meeting.speakerNames.\(meetingId)"
    }
}

private struct SummaryList: View {
    let title: String
    let items: [String]
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(AppTheme.fg)
                    .textCase(.uppercase)
            }

            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 9) {
                    Circle()
                        .fill(AppTheme.accent)
                        .frame(width: 5, height: 5)
                        .padding(.top, 7)

                    Text(item)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(AppTheme.danger)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.danger.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.danger.opacity(0.22), lineWidth: 1)
        )
    }
}

private enum OnboardingStep: Int, CaseIterable, Hashable {
    case account
    case ownerName
    case aiName
    case voiceProfile
    case permissions
    case glasses

    var label: String {
        switch self {
        case .account:
            return "ACCOUNT"
        case .ownerName:
            return "YOU"
        case .voiceProfile:
            return "VOICE"
        case .aiName:
            return "AI"
        case .permissions:
            return "ACCESS"
        case .glasses:
            return "GLASSES"
        }
    }

    var title: String {
        switch self {
        case .account:
            return "One mind"
        case .ownerName:
            return "Your name"
        case .voiceProfile:
            return "Teach Her your voice"
        case .aiName:
            return "Assistant name"
        case .permissions:
            return "Permissions"
        case .glasses:
            return "Pair Ray-Ban"
        }
    }

    var detail: String {
        switch self {
        case .account:
            return "Sign in to keep conversations, settings, and summaries in one workspace."
        case .ownerName:
            return "This is how the app addresses the main owner."
        case .voiceProfile:
            return "Optional. Speak for ~60 seconds so Her can label you in transcripts automatically."
        case .aiName:
            return "This is the assistant name you will see across recordings and summaries."
        case .permissions:
            return "Enable the access needed for recording, transcripts, pairing, and reminders."
        case .glasses:
            return "Pair now or skip and connect from settings later."
        }
    }

    var icon: String {
        switch self {
        case .account:
            return "person.crop.circle"
        case .ownerName, .aiName:
            return "text.cursor"
        case .voiceProfile:
            return "waveform.badge.plus"
        case .permissions:
            return "checkmark.seal"
        case .glasses:
            return "eyeglasses"
        }
    }
}

private final class LocationPermissionController: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var state: PermissionState = .unknown

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        refresh()
    }

    func refresh() {
        state = Self.permissionState(for: manager.authorizationStatus)
    }

    func request() {
        manager.requestWhenInUseAuthorization()
        refresh()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        state = Self.permissionState(for: manager.authorizationStatus)
    }

    private static func permissionState(for status: CLAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }
}

private struct OnboardingView: View {
    @ObservedObject var wearablesBridge: WearablesBridge
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var authStore: AuthStore

    @StateObject private var locationPermission = LocationPermissionController()
    @State private var step: OnboardingStep
    @State private var selectedProvider: SignInProvider?
    @State private var aiName: String
    @State private var ownerName: String
    @State private var microphonePermission: PermissionState = .unknown
    @State private var notificationPermission: PermissionState = .unknown

    init(wearablesBridge: WearablesBridge, settings: AppSettingsStore, authStore: AuthStore) {
        self.wearablesBridge = wearablesBridge
        self.settings = settings
        self.authStore = authStore
        _step = State(initialValue: authStore.isAuthenticated ? .ownerName : .account)
        _selectedProvider = State(initialValue: settings.signInProvider)
        _aiName = State(initialValue: settings.aiDisplayName)
        let prefilledName: String
        if !settings.ownerName.isEmpty {
            prefilledName = settings.ownerName
        } else {
            prefilledName = authStore.session?.user.name ?? ""
        }
        _ownerName = State(initialValue: prefilledName)
    }

    var body: some View {
        NavigationView {
            ZStack {
                AppTheme.bg.ignoresSafeArea()

                if step == .account {
                    SetupAccountPage(
                        authStore: authStore,
                        selectedProvider: $selectedProvider
                    ) { provider, session in
                        selectedProvider = provider
                        if session.isExistingAccount {
                            settings.completeOnboardingForExistingAccount(session: session, provider: provider)
                            return
                        }
                        if ownerName.isEmpty, let name = authStore.session?.user.name {
                            ownerName = name
                        }
                        go(to: .ownerName)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    currentPage
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear(perform: completeSetupIfRestoredExistingAccount)
        .onAppear(perform: refreshPermissionStates)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStates()
        }
    }

    private var currentProvider: SignInProvider? {
        switch authStore.session?.user.provider {
        case "google": return .google
        case "apple": return .apple
        default: return selectedProvider
        }
    }

    private func completeSetupIfRestoredExistingAccount() {
        guard let session = authStore.session,
              session.isExistingAccount,
              let provider = provider(for: session) else {
            return
        }
        settings.completeOnboardingForExistingAccount(session: session, provider: provider)
    }

    private func provider(for session: AuthSession) -> SignInProvider? {
        switch session.user.provider {
        case "google": return .google
        case "apple": return .apple
        default: return selectedProvider
        }
    }

    @ViewBuilder
    private var currentPage: some View {
        switch step {
        case .account:
            EmptyView()
        case .ownerName:
            SetupOwnerNamePage(
                ownerName: $ownerName,
                provider: currentProvider,
                onBack: authStore.isAuthenticated ? nil : goBack
            ) {
                go(to: .aiName)
            }
        case .aiName:
            SetupAgentNamePage(
                aiName: $aiName,
                onBack: goBack
            ) {
                go(to: .voiceProfile)
            }
        case .voiceProfile:
            SetupVoiceProfilePage(
                ownerName: ownerName,
                onBack: goBack,
                onContinue: { go(to: .permissions) }
            )
        case .permissions:
            SetupPermissionsPage(
                microphonePermission: microphonePermission,
                locationPermission: locationPermission.state,
                notificationPermission: notificationPermission,
                bluetoothPermission: bluetoothPermission,
                onMicrophone: requestMicrophonePermission,
                onLocation: requestLocationPermission,
                onNotifications: requestNotificationPermission,
                onBluetooth: wearablesBridge.refreshAudioRoute,
                onBack: goBack
            ) {
                go(to: .glasses)
            }
        case .glasses:
            ExactPairRayBanScreen(
                bridge: wearablesBridge,
                onBack: goBack,
                onFinish: {
                    finish(glassesSkipped: false)
                },
                onSkip: {
                    finish(glassesSkipped: true)
                }
            )
        }
    }

    private func go(to nextStep: OnboardingStep) {
        withAnimation(.easeInOut(duration: 0.22)) {
            step = nextStep
        }
    }

    private func goBack() {
        guard let previousStep = OnboardingStep(rawValue: step.rawValue - 1) else {
            return
        }
        go(to: previousStep)
    }

    private func finish(glassesSkipped: Bool) {
        let provider: SignInProvider = (authStore.session?.user.provider == "google") ? .google : .apple

        settings.completeOnboarding(
            aiName: aiName,
            ownerName: ownerName,
            signInProvider: provider,
            glassesSetupSkipped: glassesSkipped
        )
    }

    private func refreshPermissionStates() {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            microphonePermission = .granted
        case .denied:
            microphonePermission = .denied
        case .undetermined:
            microphonePermission = .unknown
        @unknown default:
            microphonePermission = .unknown
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    notificationPermission = .granted
                case .denied:
                    notificationPermission = .denied
                case .notDetermined:
                    notificationPermission = .unknown
                @unknown default:
                    notificationPermission = .unknown
                }
            }
        }

        locationPermission.refresh()
    }

    private func requestMicrophonePermission() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                microphonePermission = granted ? .granted : .denied
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                notificationPermission = granted ? .granted : .denied
            }
        }
    }

    private func requestLocationPermission() {
        locationPermission.request()
    }

    private var bluetoothPermission: PermissionState {
        wearablesBridge.audioRoute.primaryDetectedDevice == nil ? .unknown : .granted
    }
}

private struct SetupFlowHeader: View {
    let step: OnboardingStep
    let aiName: String
    let onBack: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppTheme.fg)
                            .frame(width: 40, height: 40)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.bgSoft))
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    HerOrb(size: 28)
                }

                Text(displayName.lowercased())
                    .font(.system(size: 20, weight: .medium, design: .serif))
                    .foregroundColor(AppTheme.fg)
                    .lineLimit(1)

                Spacer(minLength: 12)

                MonoLabel("v 0.1 · ios")
            }

            DividerLine()
        }
    }

    private var displayName: String {
        let trimmed = aiName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Her" : trimmed
    }
}

private struct SetupFlowProgress: View {
    let step: OnboardingStep

    private var progress: CGFloat {
        CGFloat(step.rawValue + 1) / CGFloat(OnboardingStep.allCases.count)
    }

    var body: some View {
        HStack(spacing: 10) {
            MonoLabel(String(format: "%02d / %02d", step.rawValue + 1, OnboardingStep.allCases.count))

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.bgDeep)
                    Capsule()
                        .fill(AppTheme.fg)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 2)

            Text(step.label.lowercased())
                .font(.system(size: 12, weight: .regular, design: .serif))
                .italic()
                .foregroundColor(AppTheme.muted)
        }
        .frame(height: 28)
    }
}

private struct SetupPageShell<Content: View>: View {
    let label: String
    let title: String
    let icon: String
    let content: Content

    init(label: String, title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                MonoLabel(label)
                Text(title)
                    .font(.system(size: 36, weight: .medium, design: .serif))
                    .foregroundColor(AppTheme.fg)
                    .lineSpacing(0)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
    }
}

private struct SetupAccountPage: View {
    @ObservedObject var authStore: AuthStore
    @Binding var selectedProvider: SignInProvider?
    let onSelect: (SignInProvider, AuthSession) -> Void

    @State private var isWorking = false
    @State private var errorMessage: String?
    private let appleService = AppleSignInService()
    private let googleService = GoogleSignInService()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                HerOrb(size: 26)
                Text("Her")
                    .font(.system(size: 18, weight: .medium, design: .serif))
                    .foregroundColor(AppTheme.fg)
                Spacer(minLength: 12)
            }

            Color.clear
                .frame(height: 112)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("One mind.")
                        .font(.system(size: 48, weight: .regular, design: .serif))
                        .foregroundColor(AppTheme.fg)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                    Text("Every conversation.")
                        .font(.system(size: 48, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.fg)
                        .lineLimit(1)
                        .minimumScaleFactor(0.64)
                }

                Text("Records voice. Listens through your Ray-Ban. Summarizes everything — only when you ask.")
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .foregroundColor(AppTheme.muted)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    FeatureCheck(title: "voice capture", icon: "mic")
                    FeatureCheck(title: "glasses pair", icon: "eyeglasses")
                    FeatureCheck(title: "on-device first", icon: "lock")
                    FeatureCheck(title: "ask anything later", icon: "sparkles")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.bgSoft))
            .padding(.top, 24)

            Spacer(minLength: 28)

            VStack(spacing: 10) {
                SetupProviderButton(
                    provider: .apple,
                    selected: selectedProvider == .apple,
                    primary: true
                ) {
                    Task { await runApple() }
                }
                SetupProviderButton(
                    provider: .google,
                    selected: selectedProvider == .google,
                    primary: false
                ) {
                    Task { await runGoogle() }
                }
            }
            .disabled(isWorking)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12.5, weight: .regular, design: .serif))
                    .foregroundColor(.red)
                    .padding(.top, 12)
                    .multilineTextAlignment(.leading)
            }

            WarmAuthTerms()
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @MainActor
    private func runApple() async {
        guard let client = AuthClient() else {
            errorMessage = "Backend is not configured. Set BackendAPIURL in Info.plist."
            return
        }

        errorMessage = nil
        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await appleService.signIn()
            let session = try await client.signInWithApple(
                identityToken: result.identityToken,
                fullName: result.fullName,
                email: result.email
            )
            authStore.setSession(session)
            selectedProvider = .apple
            onSelect(.apple, session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func runGoogle() async {
        guard let client = AuthClient() else {
            errorMessage = "Backend is not configured. Set BackendAPIURL in Info.plist."
            return
        }

        errorMessage = nil
        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await googleService.signIn()
            let session = try await client.signInWithGoogle(idToken: result.idToken)
            authStore.setSession(session)
            selectedProvider = .google
            onSelect(.google, session)
        } catch GoogleSignInError.authorizationCancelled {
            // User cancelled the picker; stay silent.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SetupOwnerNamePage: View {
    @Binding var ownerName: String
    let provider: SignInProvider?
    let onBack: (() -> Void)?
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OnboardingBackBar(onBack: onBack)
            WwSteps(step: 1, total: 5, label: "you")
            WwHeader(pre: prefixText, title: "What should I call you?", italic: true)

            VStack(alignment: .leading, spacing: 16) {
                WwCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 0) {
                        MonoLabel("your name")
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            TextField("Ersultan", text: $ownerName)
                                .font(.system(size: 36, weight: .medium, design: .serif))
                                .foregroundColor(AppTheme.fg)
                                .disableAutocorrection(true)
                                .textInputAutocapitalization(.words)
                                .frame(minHeight: 54)
                        }
                        .padding(.top, 10)

                        DividerLine()
                            .padding(.top, 14)

                        Text("\"Hi, \(displayName).\" — so I can greet you.")
                            .font(.system(size: 13, weight: .regular, design: .serif))
                            .italic()
                            .foregroundColor(AppTheme.muted)
                            .padding(.top, 12)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: captionIcon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.muted)
                        .padding(.top, 2)
                    Text(captionText)
                        .font(.system(size: 12.5, weight: .regular, design: .serif))
                        .foregroundColor(AppTheme.muted)
                        .lineSpacing(4)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.bgSoft))

                Spacer()

                WwPrimaryButton("continue →", disabled: ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: onContinue)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 22)
        }
    }

    private var displayName: String {
        ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Ersultan" : ownerName
    }

    private var prefixText: String {
        switch provider {
        case .google: return "from your google account"
        case .apple, nil: return "from your apple id"
        }
    }

    private var captionText: String {
        switch provider {
        case .google:
            return "Pulled from your Google account. Editable anytime in Settings › Profile."
        case .apple, nil:
            return "Pulled from Apple ID. Editable anytime in Settings › Profile."
        }
    }

    private var captionIcon: String {
        switch provider {
        case .google: return "g.circle"
        case .apple, nil: return "apple.logo"
        }
    }
}

private struct SetupVoiceProfilePage: View {
    let ownerName: String
    let onBack: () -> Void
    let onContinue: () -> Void

    @StateObject private var recorder = VoiceEnrollmentRecorder()
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingBackBar(onBack: onBack)
            WwSteps(step: 3, total: 5, label: "voice")
            WwHeader(pre: "your voice", title: "Teach Her your voice.", italic: true)

            VStack(alignment: .leading, spacing: 16) {
                WwCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        MonoLabel(saved ? "voice profile saved" : "tap record · ~60 seconds")
                        Text(prompt)
                            .font(.system(size: 14, weight: .regular, design: .serif))
                            .foregroundColor(AppTheme.muted)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)

                        statusRow
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12.5, weight: .regular, design: .serif))
                        .foregroundColor(.red)
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "shield")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.muted)
                        .padding(.top, 2)
                    Text("Stored privately. You can re-record or delete this anytime in Settings › People.")
                        .font(.system(size: 12.5, weight: .regular, design: .serif))
                        .foregroundColor(AppTheme.muted)
                        .lineSpacing(4)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.bgSoft))

                Spacer()

                primaryButton
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 22)
        }
    }

    private var prompt: String {
        "Speak naturally for about a minute — describe your day, read something out loud, anything works. We'll use this to label you as \(ownerName.isEmpty ? "you" : ownerName) in future transcripts."
    }

    @ViewBuilder
    private var statusRow: some View {
        switch recorder.phase {
        case .idle:
            Button(action: { Task { await recorder.start() } }) {
                HStack(spacing: 10) {
                    Image(systemName: "record.circle")
                        .foregroundColor(.red)
                    Text("Record")
                        .font(.system(size: 16, weight: .medium, design: .serif))
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.borderStrong, lineWidth: 1))
                .foregroundColor(AppTheme.fg)
            }
            .buttonStyle(PlainButtonStyle())
        case let .recording(elapsed):
            VStack(alignment: .leading, spacing: 8) {
                Text("Recording… \(elapsed)s / 60s")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                ProgressView(value: Double(elapsed), total: 60)
                    .tint(.red)
                Button(action: { recorder.stop() }) {
                    Text(recorder.canStop ? "Stop" : "Hold (≥ 5s)")
                        .font(.system(size: 14, weight: .medium, design: .serif))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.borderStrong, lineWidth: 1))
                        .foregroundColor(AppTheme.fg)
                }
                .disabled(!recorder.canStop)
                .buttonStyle(PlainButtonStyle())
            }
        case .ready(let url):
            VStack(spacing: 8) {
                Label("Sample captured", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                HStack(spacing: 10) {
                    Button("Re-record") { recorder.reset() }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.borderStrong, lineWidth: 1))
                    Button(action: { Task { await save(url: url) } }) {
                        Text("Save")
                            .font(.system(size: 14, weight: .semibold, design: .serif))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(saving ? Color.gray : Color.black)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(saving)
                }
                .buttonStyle(PlainButtonStyle())
            }
        case .uploading:
            ProgressView("Saving…")
                .frame(maxWidth: .infinity, minHeight: 50)
        case .failed(let detail):
            Label(detail, systemImage: "exclamationmark.triangle")
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if saved {
            WwPrimaryButton("continue →", action: onContinue)
        } else {
            VStack(spacing: 8) {
                WwPrimaryButton("continue →", disabled: !canContinueWithoutSaving, action: onContinue)
                Button("Skip for now", action: onContinue)
                    .font(.system(size: 13, weight: .regular, design: .serif).italic())
                    .foregroundColor(AppTheme.muted)
            }
        }
    }

    private var canContinueWithoutSaving: Bool {
        if case .uploading = recorder.phase { return false }
        if case .recording = recorder.phase { return false }
        return true
    }

    @MainActor
    private func save(url: URL) async {
        guard let service = VoiceProfilesService() else {
            errorMessage = "Backend not configured."
            return
        }
        let trimmedName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Please go back and set your name first."
            return
        }
        errorMessage = nil
        saving = true
        recorder.setUploading()
        defer { saving = false }
        do {
            _ = try await service.enroll(name: trimmedName, audioURL: url)
            try? FileManager.default.removeItem(at: url)
            saved = true
            recorder.reset()
        } catch {
            errorMessage = error.localizedDescription
            recorder.setFailed(error.localizedDescription)
        }
    }
}

private struct OnboardingBackBar: View {
    let onBack: (() -> Void)?

    var body: some View {
        HStack {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppTheme.fg)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.bgSoft))
                }
                .buttonStyle(PlainButtonStyle())
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .frame(height: onBack == nil ? 0 : 48)
        .opacity(onBack == nil ? 0 : 1)
    }
}

private struct SetupAgentNamePage: View {
    @Binding var aiName: String
    let onBack: () -> Void
    let onContinue: () -> Void

    private let suggestions = ["Alfred", "Friday", "Jarvis", "Samantha", "iris", "atlas", "mira"]

    var body: some View {
        VStack(spacing: 0) {
            OnboardingBackBar(onBack: onBack)
            WwSteps(step: 2, total: 5, label: "agent")
            WwHeader(pre: "wake word", title: "What should wake me?", italic: true)

            VStack(alignment: .leading, spacing: 16) {
                WwCard(padding: 28) {
                    VStack(alignment: .center, spacing: 0) {
                        HerOrb(size: 38)
                        HStack(alignment: .center, spacing: 4) {
                            TextField("Her", text: $aiName)
                                .font(.system(size: 60, weight: .medium, design: .serif))
                                .foregroundColor(AppTheme.fg)
                                .multilineTextAlignment(.center)
                                .disableAutocorrection(true)
                                .textInputAutocapitalization(.never)
                                .frame(height: 66)
                        }
                        .padding(.top, 14)
                        MonoLabel("tap to rename")
                            .padding(.top, 14)
                    }
                    .frame(maxWidth: .infinity)
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.muted)
                        .padding(.top, 2)
                    Text("This name is the wake word. Say \"Hey \(displayName)\" or \"\(displayName)\", then \"start recording\" or \"stop recording\". Use at least four letters so it does not wake accidentally.")
                        .font(.system(size: 12.5, weight: .regular, design: .serif))
                        .foregroundColor(AppTheme.muted)
                        .lineSpacing(4)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.bgSoft))

                VStack(alignment: .leading, spacing: 10) {
                    MonoLabel("or pick one")
                    FlowWrap(items: suggestions) { suggestion in
                        AgentSuggestionChip(
                            suggestion: suggestion,
                            selected: aiName.caseInsensitiveCompare(suggestion) == .orderedSame
                        ) {
                            aiName = suggestion
                        }
                    }
                }

                Spacer()

                Text("\"Hey \(displayName), start recording.\"")
                    .font(.system(size: 14, weight: .regular, design: .serif))
                    .italic()
                    .foregroundColor(AppTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .center)

                WwPrimaryButton("nice to meet you →", disabled: !wakeWordIsUsable, action: onContinue)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 22)
        }
    }

    private var displayName: String {
        aiName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Her" : aiName
    }

    private var wakeWordIsUsable: Bool {
        displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0.isNumber }
            .count >= 4
    }
}

private struct AgentSuggestionChip: View {
    let suggestion: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
                .foregroundColor(selected ? AppTheme.bg : AppTheme.fg)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(Capsule().fill(selected ? AppTheme.fg : AppTheme.bg))
                .overlay(Capsule().stroke(selected ? AppTheme.fg : AppTheme.borderStrong, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var label: some View {
        Group {
            if selected {
                Text(suggestion)
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .italic()
            } else {
                Text(suggestion)
                    .font(.system(size: 14, weight: .regular, design: .serif))
            }
        }
    }
}

private struct SetupPrivacyPage: View {
    let onContinue: () -> Void

    var body: some View {
        SetupPageShell(label: "TRUST", title: "Data & privacy", icon: "lock.shield") {
            Text("Conversations, recordings, transcripts, and personal information are used to create summaries, action items, and searchable meeting notes.")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(AppTheme.fg)
                .fixedSize(horizontal: false, vertical: true)

            Text("Recordings and transcripts stay tied to your account so summaries can be saved and found later.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            PrivacyPolicyText()

            PrimaryActionButton(title: "Agree & Continue", icon: "arrow.right") {
                onContinue()
            }
        }
    }
}

private struct SetupTextInputPage: View {
    let label: String
    let title: String
    let icon: String
    let placeholder: String
    @Binding var text: String
    let continueDisabled: Bool
    let onContinue: () -> Void

    var body: some View {
        SetupPageShell(label: label, title: title, icon: icon) {
            ProfileTextField(label: label, placeholder: placeholder, text: $text)

            SetupPreviewRow(label: "PREVIEW", value: previewText)

            PrimaryActionButton(
                title: "Continue",
                icon: "arrow.right",
                disabled: continueDisabled
            ) {
                onContinue()
            }
        }
    }

    private var previewText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? placeholder : trimmed
    }
}

private struct SetupLanguagePage: View {
    @Binding var language: String
    let languages: [String]
    let onContinue: () -> Void

    var body: some View {
        SetupPageShell(label: "TRANSCRIPTION", title: "Primary language", icon: "globe") {
            Menu {
                ForEach(languages, id: \.self) { option in
                    Button(option) {
                        language = option
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Text(language)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppTheme.fg)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.dim)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.bg))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppTheme.borderStrong, lineWidth: 1)
                )
            }

            SetupPreviewRow(label: "DEFAULT", value: "\(language) transcripts and summaries")

            PrimaryActionButton(title: "Continue", icon: "arrow.right") {
                onContinue()
            }
        }
    }
}

private struct SetupPermissionsPage: View {
    let microphonePermission: PermissionState
    let locationPermission: PermissionState
    let notificationPermission: PermissionState
    let bluetoothPermission: PermissionState
    let onMicrophone: () -> Void
    let onLocation: () -> Void
    let onNotifications: () -> Void
    let onBluetooth: () -> Void
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OnboardingBackBar(onBack: onBack)
            WwSteps(step: 4, total: 5, label: "access")
            WwHeader(pre: "permissions", title: "Let me help.", italic: true)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("iOS will ask one prompt per item. Skip any — you can flip them later.")
                        .font(.system(size: 13.5, weight: .regular, design: .serif))
                        .foregroundColor(AppTheme.muted)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)

                    WwCard(padding: 0) {
                        VStack(spacing: 0) {
                            ExactPermissionRow(
                                icon: "mic",
                                title: "Microphone",
                                subtitle: "so I can listen and record",
                                state: microphonePermission,
                                defaultOn: true,
                                action: onMicrophone
                            )
                            DividerLine()
                            ExactPermissionRow(
                                icon: "globe",
                                title: "Location",
                                subtitle: "tag conversations with where",
                                state: locationPermission,
                                defaultOn: true,
                                action: onLocation
                            )
                            DividerLine()
                            ExactPermissionRow(
                                icon: "sparkles",
                                title: "Notifications",
                                subtitle: "whisper only when it matters",
                                state: notificationPermission,
                                defaultOn: true,
                                action: onNotifications
                            )
                            DividerLine()
                            ExactPermissionRow(
                                icon: "eyeglasses",
                                title: "Bluetooth",
                                subtitle: "pair Ray-Ban Meta",
                                state: bluetoothPermission,
                                defaultOn: true,
                                action: onBluetooth
                            )
                        }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "shield")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(AppTheme.fg)
                            .padding(.top, 2)
                        (Text("Audio stays on this device.").italic()
                            + Text(" Never uploaded unless you ask Her to summarize."))
                            .font(.system(size: 12.5, weight: .regular, design: .serif))
                            .foregroundColor(AppTheme.muted)
                            .lineSpacing(4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.bgSoft))

                    Spacer(minLength: 24)
                    WwPrimaryButton("continue →", action: onContinue)
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 22)
            }
        }
    }
}

private struct ExactPermissionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let state: PermissionState
    let defaultOn: Bool
    let action: () -> Void

    private var isOn: Bool {
        defaultOn && state != .denied
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(AppTheme.fg)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14.5, weight: .medium, design: .serif))
                        .foregroundColor(AppTheme.fg)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.dim)
                }

                Spacer(minLength: 8)

                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? AppTheme.fg : AppTheme.bgDeep)
                    Circle()
                        .fill(AppTheme.bg)
                        .frame(width: 18, height: 18)
                        .shadow(color: Color.black.opacity(0.15), radius: 1, x: 0, y: 1)
                        .padding(2)
                }
                .frame(width: 38, height: 22)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct SetupGlassesPage: View {
    @ObservedObject var bridge: WearablesBridge
    let onFinish: () -> Void
    let onSkip: () -> Void

    var body: some View {
        SetupPageShell(label: "device", title: "Pair your Ray-Ban.", icon: "eyeglasses") {
            VStack(spacing: 18) {
                GlassesLineArt()
                    .frame(maxWidth: .infinity)
                    .frame(height: 168)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.bgSoft))

                Text("We will use the iOS audio route first. If Ray-Ban Meta is already paired in Bluetooth, Her can detect it here.")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(AppTheme.muted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            OnboardingGlassesCard(bridge: bridge)

            HStack(spacing: 10) {
                OutlineButton(title: "Later", icon: "forward") {
                    onSkip()
                }
                PrimaryActionButton(title: bridge.audioRoute.primaryDetectedDevice == nil ? "Finish" : "Pair", icon: "checkmark") {
                    onFinish()
                }
            }
        }
    }
}

private struct SetupProviderButton: View {
    let provider: SignInProvider
    let selected: Bool
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ProviderIcon(provider: provider, inverted: primary)

                Text(provider == .apple ? "Continue with Apple" : "Continue with Google")
                    .font(.system(size: 17, weight: .medium, design: .serif))
                    .foregroundColor(primary ? AppTheme.bg : AppTheme.fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(primary ? AppTheme.fg : AppTheme.bg))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? AppTheme.fg : AppTheme.borderStrong, lineWidth: primary ? 0 : 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct ProviderIcon: View {
    let provider: SignInProvider
    let inverted: Bool

    var body: some View {
        if provider == .google {
            Text("G")
                .font(.system(size: 16, weight: .bold, design: .serif))
                .foregroundColor(Color(hex: 0x4285F4))
        } else {
            Image(systemName: provider.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(inverted ? AppTheme.bg : AppTheme.fg)
        }
    }
}

private struct WarmAuthTerms: View {
    var body: some View {
        LegalLinksRow(style: .warmSerif)
    }
}

private struct SetupPreviewRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            MonoLabel(label)
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.bg))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }
}

private struct PermissionSetupRow: View {
    let title: String
    let subtitle: String
    let state: PermissionState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                StatusGlyph(icon: state.icon, color: state.color)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppTheme.fg)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text(state.title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(state.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.bg))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct OnboardingGlassesCard: View {
    @ObservedObject var bridge: WearablesBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(systemName: bridge.audioRoute.primaryDetectedDevice == nil ? "antenna.radiowaves.left.and.right" : "eyeglasses")

                VStack(alignment: .leading, spacing: 6) {
                    MonoLabel("META WEARABLES")
                    Text(bridge.audioRoute.primaryDetectedDevice == nil ? "No glasses detected" : "Glasses detected")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(AppTheme.fg)
                    Text(bridge.state.detail)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                StateChip(title: bridge.audioRoute.primaryDetectedDevice == nil ? "not found" : "detected", icon: "dot.radiowaves.left.and.right", color: bridge.audioRoute.primaryDetectedDevice == nil ? AppTheme.dim : AppTheme.accent, accented: bridge.audioRoute.primaryDetectedDevice != nil)
                StateChip(title: datStatusTitle, icon: "shippingbox", color: datStatusColor)
            }

            HStack(spacing: 10) {
                OutlineButton(title: "Refresh", icon: "arrow.clockwise") {
                    bridge.refreshAudioRoute()
                }
                OutlineButton(title: "Scan", icon: "dot.radiowaves.left.and.right") {
                    bridge.connectDetectedAudioRoute()
                }
            }

            OutlineButton(title: "Start DAT session", icon: "play.circle") {
                bridge.startGlassesSession()
            }
        }
    }

    private var datStatusTitle: String {
        if !bridge.isDATLinked {
            return "DAT missing"
        }
        return bridge.hasDATCredentials ? "DAT ready" : "DAT setup"
    }

    private var datStatusColor: Color {
        if !bridge.isDATLinked {
            return AppTheme.dim
        }
        return bridge.hasDATCredentials ? AppTheme.success : AppTheme.warn
    }
}

private struct PrivacyLinkText: View {
    var body: some View {
        LegalLinksRow(style: .plain)
    }
}

private struct PrivacyPolicyText: View {
    var body: some View {
        LegalLinksRow(style: .settingsBlurb)
    }
}

private struct ProfileTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            MonoLabel(label)

            TextField(placeholder, text: $text)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(AppTheme.fg)
                .disableAutocorrection(true)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.bg))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppTheme.borderStrong, lineWidth: 1)
                )
        }
    }
}

private enum PermissionState {
    case unknown
    case granted
    case denied

    var title: String {
        switch self {
        case .unknown:
            return "ASK"
        case .granted:
            return "ON"
        case .denied:
            return "OFF"
        }
    }

    var icon: String {
        switch self {
        case .granted:
            return "checkmark"
        case .unknown:
            return "arrow.right"
        case .denied:
            return "exclamationmark"
        }
    }

    var color: Color {
        switch self {
        case .unknown:
            return AppTheme.dim
        case .granted:
            return AppTheme.success
        case .denied:
            return AppTheme.danger
        }
    }
}

private struct SettingsSheet: View {
    @ObservedObject var settings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var aiName: String
    @State private var ownerName: String

    init(settings: AppSettingsStore) {
        self.settings = settings
        _aiName = State(initialValue: settings.aiDisplayName)
        _ownerName = State(initialValue: settings.ownerName)
    }

    var body: some View {
        NavigationView {
            ZStack {
                AppTheme.bg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 9) {
                            MonoLabel("SETTINGS")
                            Text("Profile")
                                .font(.system(size: 42, weight: .light, design: .serif))
                                .foregroundColor(AppTheme.fg)
                            Text(settings.signInProvider?.title ?? "Account")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundColor(AppTheme.muted)
                        }

                        DividerLine()

                        AppCard {
                            VStack(alignment: .leading, spacing: 16) {
                                ProfileTextField(label: "AI NAME", placeholder: "Her", text: $aiName)
                                ProfileTextField(label: "OWNER", placeholder: "Your name", text: $ownerName)

                                PrimaryActionButton(title: "Save", icon: "checkmark") {
                                    settings.saveProfile(aiName: aiName, ownerName: ownerName)
                                    dismiss()
                                }

                                OutlineButton(title: "Restart setup", icon: "arrow.counterclockwise") {
                                    settings.resetOnboarding()
                                    dismiss()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
    }
}

private struct HerOrb: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppTheme.fg, lineWidth: 1)
            Circle()
                .stroke(AppTheme.fg, lineWidth: 0.75)
                .padding(size * 0.18)
            Circle()
                .fill(AppTheme.fg)
                .padding(size * 0.39)
        }
        .frame(width: size, height: size)
    }
}

private struct FeatureCheck: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppTheme.fg)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13, weight: .regular, design: .serif))
                .foregroundColor(AppTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }
}

private struct GlassesLineArt: View {
    var body: some View {
        ZStack {
            ForEach([CGFloat(92), CGFloat(124), CGFloat(156)], id: \.self) { diameter in
                Circle()
                    .stroke(AppTheme.border, lineWidth: 1)
                    .frame(width: diameter, height: diameter)
            }

            HStack(spacing: -4) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.fg, lineWidth: 2)
                    .frame(width: 86, height: 52)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.fg, lineWidth: 2)
                    .frame(width: 86, height: 52)
            }
            .overlay(
                Capsule()
                    .fill(AppTheme.fg)
                    .frame(width: 20, height: 3),
                alignment: .center
            )

            HStack {
                Rectangle()
                    .fill(AppTheme.fg)
                    .frame(width: 42, height: 2)
                    .rotationEffect(.degrees(-16))
                Spacer()
                Rectangle()
                    .fill(AppTheme.fg)
                    .frame(width: 42, height: 2)
                    .rotationEffect(.degrees(16))
            }
            .padding(.horizontal, 48)
        }
    }
}

private struct AppCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.borderStrong, lineWidth: 1)
            )
    }
}

private struct MonoLabel: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color = AppTheme.dim) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(1.5)
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

private struct SectionTitle: View {
    let label: String
    let title: String
    let icon: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppTheme.accent)

            VStack(alignment: .leading, spacing: 4) {
                MonoLabel(label)
                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(AppTheme.fg)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }
        }
    }
}

private struct StatusGlyph: View {
    let icon: String
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.bg)
                .frame(width: 46, height: 46)
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(color)
        }
    }
}

private struct IconTile: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(AppTheme.bg)
            .frame(width: 44, height: 44)
            .background(Circle().fill(AppTheme.fg))
    }
}

private struct StateChip: View {
    let title: String
    let icon: String
    let color: Color
    let accented: Bool

    init(title: String, icon: String, color: Color, accented: Bool = false) {
        self.title = title
        self.icon = icon
        self.color = color
        self.accented = accented
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundColor(color)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Capsule().fill(accented ? AppTheme.accentSoft : AppTheme.bg))
        .overlay(Capsule().stroke(color.opacity(0.22), lineWidth: 1))
    }
}

private struct OutlineButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    let disabled: Bool

    init(title: String, icon: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundColor(AppTheme.fg)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.borderStrong, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.48 : 1)
    }
}

private struct PrimaryActionButton: View {
    let title: String
    let icon: String
    let disabled: Bool
    let action: () -> Void

    init(title: String, icon: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundColor(AppTheme.bg)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.fg))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.48 : 1)
    }
}

private struct RouteInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            MonoLabel(label)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppTheme.muted)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
    }
}

private struct DividerLine: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.border)
            .frame(height: 1)
    }
}

private enum AppTheme {
    static let bg = Color(hex: 0xffffff)
    static let bgSoft = Color(hex: 0xfafaf8)
    static let bgDeep = Color(hex: 0xf3f2ee)
    static let fg = Color(hex: 0x0f0f0f)
    static let muted = Color(hex: 0x3a3a3a)
    static let dim = Color(hex: 0x7a7a7a)
    static let accent = Color(hex: 0x0f0f0f)
    static let accentSoft = Color(hex: 0xf3f2ee)
    static let playbackBlue = Color(hex: 0x1c5cff)
    static let danger = Color(hex: 0xa00000)
    static let success = Color(hex: 0x2f6b2f)
    static let warn = Color(hex: 0xa06a00)
    static let border = Color.black.opacity(0.08)
    static let borderStrong = Color.black.opacity(0.18)
}

private extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

enum LegalDocument: Identifiable {
    case privacy
    case terms

    var id: String {
        switch self {
        case .privacy: return "privacy"
        case .terms: return "terms"
        }
    }

    var title: String {
        switch self {
        case .privacy: return "Privacy"
        case .terms: return "Terms of use"
        }
    }

    var label: String {
        switch self {
        case .privacy: return "privacy · draft"
        case .terms: return "terms · draft"
        }
    }

    var updated: String { "updated · May 7, 2026" }

    var intro: String {
        switch self {
        case .privacy:
            return "A working draft of Her's data policy: what may be stored, how browser permissions are used for tasks, and where the user keeps control."
        case .terms:
            return "A short working document on how to use Her carefully: which actions stay on your side, where confirmations are required, and what is still considered an early version of the product."
        }
    }

    var sections: [(title: String, body: [String])] {
        switch self {
        case .privacy:
            return [
                ("What data Her needs", [
                    "Her may store account data, agent settings, conversation history, permissions, connected sites, and technical events required for the product to work.",
                    "We try not to collect anything unnecessary. If data does not help complete a task, ensure security, or improve reliability, it should not be in the product."
                ]),
                ("Browser and connected services", [
                    "When you enable browser capabilities, Her may see the pages, UI elements, and action results needed to complete your task.",
                    "Sessions for third-party services stay in your browser. Her uses them only within the permissions you grant and should not perform irreversible actions without separate confirmation."
                ]),
                ("Credentials", [
                    "Passkeys are used for password-less sign-in. The passkey secret stays on your device or in the system credential manager.",
                    "If Her receives temporary access to a login, password, token, or session, that access must be limited by task, time, and permission level."
                ]),
                ("How we use data", [
                    "Data is used to fulfill your requests, preserve context, configure agents, diagnose errors, ensure security, and improve product quality.",
                    "We don't want to build a product on selling personal data. Any future change to this approach must be explicitly described in the final policy."
                ]),
                ("Storage and deletion", [
                    "Some data may be stored locally or on the server, depending on the feature. Histories, settings, and permissions should be deletable wherever technically possible.",
                    "Storage rules may change before the final release. For sensitive workflows, treat the current version as a test and don't share data you can't safely use in an early product."
                ]),
                ("User control", [
                    "You can disable permissions, change agent settings, and stop tasks. The final version will need a more precise control panel for data, export, and deletion."
                ])
            ]
        case .terms:
            return [
                ("What Her is", [
                    "Her helps you build personal agents that work with your browser, connected services, and tasks. The agent acts only within the permissions you explicitly enable.",
                    "This text is a working draft. It exists so the product has clear rules even before the final legal review."
                ]),
                ("Your responsibilities", [
                    "Use Her only for lawful tasks and don't instruct the agent to do anything that violates other people's rights, third-party service rules, or applicable law.",
                    "You are responsible for the decisions you confirm: sending messages, placing orders, changing data, connecting accounts, and any action taken in third-party services."
                ]),
                ("Permissions and confirmations", [
                    "Some features require access to the browser, accounts, contacts, calendar, files, or stored credentials. These permissions can be limited or turned off.",
                    "Payments, financial operations, and other sensitive actions must require separate confirmation. If something looks wrong, stop the task and verify the result manually."
                ]),
                ("Third-party services", [
                    "Her may work on top of sites and APIs we don't own. The availability, limits, pricing, blocks, and errors of those services are beyond our control.",
                    "When you use a third-party service through Her, its own rules continue to apply."
                ]),
                ("Product availability", [
                    "The service is in an early stage. Bugs, feature changes, temporary outages, and gaps between expected and actual agent behavior are possible.",
                    "We will try to fix important issues quickly, but we do not yet promise constant availability or fitness of Her for mission-critical workflows."
                ]),
                ("Feedback", [
                    "If you notice a risk, bug, or questionable agent behavior, let us know. That feedback helps align the product and final documents with real usage."
                ])
            ]
        }
    }
}

struct LegalDocumentView: View {
    let document: LegalDocument
    @Binding var current: LegalDocument?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(document.label.uppercased())
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1.5)
                        .foregroundColor(AppTheme.dim)

                    Text(document.title)
                        .font(.system(size: 32, weight: .medium, design: .serif))

                    Text(document.intro)
                        .font(.system(size: 15, design: .serif))
                        .foregroundColor(AppTheme.muted)
                        .lineSpacing(4)

                    Text(document.updated)
                        .font(.system(size: 12, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.dim)

                    Divider().padding(.vertical, 4)

                    ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title)
                                .font(.system(size: 18, weight: .semibold, design: .serif))
                            ForEach(Array(section.body.enumerated()), id: \.offset) { _, paragraph in
                                Text(paragraph)
                                    .font(.system(size: 14, design: .serif))
                                    .foregroundColor(AppTheme.muted)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.bottom, 8)
                    }

                    HStack(spacing: 10) {
                        Button(document == .privacy ? "Read terms" : "Read privacy") {
                            current = document == .privacy ? .terms : .privacy
                        }
                        .font(.system(size: 13, weight: .medium, design: .serif))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.black)
                        .cornerRadius(10)

                        Spacer()
                    }
                    .padding(.top, 10)
                }
                .padding(20)
            }
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { current = nil }
                }
            }
        }
    }
}

struct LegalLinksRow: View {
    enum Style {
        case warmSerif
        case plain
        case settingsBlurb
    }

    let style: Style
    @State private var sheet: LegalDocument?

    var body: some View {
        Group {
            switch style {
            case .warmSerif:
                HStack(spacing: 4) {
                    Text("by continuing —")
                    legalButton(.terms, "terms")
                    Text("·")
                    legalButton(.privacy, "privacy")
                }
                .font(.system(size: 12, weight: .regular, design: .serif).italic())
                .foregroundColor(AppTheme.dim)
                .frame(maxWidth: .infinity, alignment: .center)

            case .plain:
                HStack(spacing: 4) {
                    Text("By continuing, you agree to our")
                    legalButton(.privacy, "Privacy Policy")
                    Text("&")
                    legalButton(.terms, "Terms of Use")
                    Text(".")
                }
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(AppTheme.dim)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            case .settingsBlurb:
                HStack(spacing: 4) {
                    Text("Governed by our")
                    legalButton(.privacy, "Privacy Policy")
                    Text("and")
                    legalButton(.terms, "Terms of Service")
                    Text(".")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $sheet) { doc in
            LegalDocumentView(document: doc, current: $sheet)
        }
    }

    @ViewBuilder
    private func legalButton(_ doc: LegalDocument, _ title: String) -> some View {
        Button(action: { sheet = doc }) {
            Text(title).underline()
        }
        .buttonStyle(.plain)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        RootView(wearablesBridge: WearablesBridge())
    }
}
