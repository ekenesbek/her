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
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 1_000
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

    func homeContextLabel(for date: Date) -> String {
        var parts = [Self.dayFormatter.string(from: date).lowercased()]
        if let locationName {
            parts.append(locationName.lowercased())
        }
        return parts.joined(separator: " · ")
    }

    var recordingLocationLabel: String {
        locationName ?? "location unavailable"
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

            let place = placemarks?.first
            let name = place?.locality
                ?? place?.subAdministrativeArea
                ?? place?.administrativeArea
                ?? place?.country

            DispatchQueue.main.async {
                let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.locationName = cleanName?.isEmpty == false ? cleanName : nil
            }
        }
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
    @ObservedObject var wearablesBridge: WearablesBridge
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var authStore: AuthStore
    @StateObject private var viewModel: ConversationSessionViewModel
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
                        onBack: { route = .conversations }
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
                        onStop: stopRecordingAndStay,
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
            Task { @MainActor in
                await meetingsStore.refresh()
                await viewModel.recoverIfNeeded()
            }
        }
        .onChange(of: viewModel.phase) { newPhase in
            if newPhase == .completed {
                Task { @MainActor in
                    await meetingsStore.refresh()
                }
            }
        }
    }

    private func showRecording() {
        if viewModel.phase == .recording {
            recordingMuted = false
            route = .recording
            return
        }

        guard viewModel.canTapPrimaryButton else {
            return
        }

        Task { @MainActor in
            wearablesBridge.refreshAudioRoute()
            let didStart = await viewModel.startRecording()
            guard didStart else {
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
            await viewModel.stopAndTranscribe()
        }
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
    let onBack: () -> Void
    private let tabs = ["summary", "transcript", "chat"]
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            detailHeader

            if let meeting {
                ExactSegmentedTabs(tabs: tabs, selectedIndex: $selectedTab)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 14)

                if selectedTab == 2 {
                    ConversationChatPanel(meeting: meeting)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 16) {
                            if selectedTab == 0 {
                                SummaryPanel(summary: meeting.summary)
                            } else {
                                TranscriptPanel(transcript: meeting.transcript)
                            }
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
                TextField("Ask about this conversation", text: $draft)
                    .font(.system(size: 14, weight: .regular, design: .serif))
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
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            return
        }

        messages.append(ConversationChatMessage(role: .user, text: question))
        messages.append(ConversationChatMessage(role: .assistant, text: answer(for: question)))
        draft = ""
    }

    private func answer(for question: String) -> String {
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
    let id = UUID()
    let role: Role
    let text: String

    enum Role: Equatable {
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
            Text(message.text)
                .font(.system(size: 14, weight: .regular, design: .serif))
                .foregroundColor(message.role == .user ? AppTheme.bg : AppTheme.fg)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
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
    let onStop: () -> Void
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
                        SummaryPanel(summary: summary)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
            }

            if viewModel.phase == .recording {
                RecordingControlDock(muted: $muted, onStop: onStop)
            } else {
                RecordingPostProcessDock(viewModel: viewModel, onGenerateSummary: onGenerateSummary)
            }
        }
    }

    private var recordingHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            RecordingStatusPill(title: muted ? "paused" : "recording", active: !muted)
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
        RecordingTranscriptEntry.fromTranscript(viewModel.transcript)
    }

    private var recordingStatusText: String {
        if muted {
            return "muted"
        }
        switch viewModel.phase {
        case .recording:
            return "listening"
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

    static func fromTranscript(_ transcript: String) -> [RecordingTranscriptEntry] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        return [
            RecordingTranscriptEntry(
                time: "saved",
                speaker: "Transcript",
                initial: "T",
                text: trimmed,
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

private struct RecordingPostProcessDock: View {
    @ObservedObject var viewModel: ConversationSessionViewModel
    let onGenerateSummary: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if viewModel.phase == .transcribing || viewModel.phase == .summarizing {
                HStack(spacing: 9) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(AppTheme.fg)
                    Text(viewModel.phase == .transcribing ? "Transcribing..." : "Generating summary...")
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

private struct ExactSettingsHerScreen: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var bridge: WearablesBridge
    @ObservedObject var viewModel: ConversationSessionViewModel
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

                    SettingsSectionHeader(title: "glasses", hint: bridge.audioRoute.primaryDetectedDevice == nil ? "not connected" : "connected")
                    SettingsGlassesCard(bridge: bridge, onPair: onPair)

                    SettingsSectionHeader(title: "voice profile", hint: voiceProfiles.isEmpty ? "not enrolled" : "\(voiceProfiles.count) enrolled")
                    WwCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(voiceProfiles) { profile in
                                VoiceProfileRow(profile: profile) {
                                    Task { await deleteVoiceProfile(profile) }
                                }
                                DividerLine()
                            }
                            Button(action: { presentingVoiceEnrollment = true }) {
                                HStack(spacing: 14) {
                                    Image(systemName: "waveform.badge.plus")
                                        .font(.system(size: 16))
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Teach Her your voice")
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
                            SettingsValueRow(icon: "mic", label: "Wake word", subtitle: "\"hey \(settings.aiDisplayName.lowercased())\"", value: "custom")
                            DividerLine()
                            SettingsValueRow(icon: "sparkles", label: "Sensitivity", subtitle: "how easily I start listening", value: "default")
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
                        MonoLabel("storage unavailable")
                        Spacer()
                        Text("manage →")
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
        viewModel.phase == .recording ? "now · recording" : "today · local"
    }

    private var title: String {
        switch viewModel.phase {
        case .recording:
            return "Listening, \(settings.ownerDisplayName)..."
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
                        title: viewModel.phase == .recording ? "live" : "standby",
                        icon: "record.circle",
                        color: statusColor,
                        accented: viewModel.phase == .recording
                    )
                    StateChip(title: viewModel.activeInputName, icon: "mic", color: AppTheme.fg)
                }
            }
        }
    }

    private var statusIcon: String {
        switch viewModel.phase {
        case .recording:
            return "record.circle"
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

private struct TranscriptPanel: View {
    let transcript: String

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(label: "TRANSCRIPT", title: "Conversation", icon: "text.quote")
                DividerLine()

                Text(transcript)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(AppTheme.fg)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SummaryPanel: View {
    let summary: MeetingSummary

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(label: "SUMMARY", title: summary.title, icon: "doc.text.magnifyingglass")

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
                    ) { provider in
                        selectedProvider = provider
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
    let onSelect: (SignInProvider) -> Void

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
                .frame(height: 64)

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
        .overlay {
            if isWorking {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    ProgressView().progressViewStyle(.circular)
                }
            }
        }
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
            onSelect(.apple)
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
            onSelect(.google)
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
                    Text("Stored privately. You can re-record or delete this anytime in Settings › Voice profile.")
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

    private let suggestions = ["Her", "iris", "echo", "mira", "atlas", "wren", "lior"]

    var body: some View {
        VStack(spacing: 0) {
            OnboardingBackBar(onBack: onBack)
            WwSteps(step: 2, total: 5, label: "agent")
            WwHeader(pre: "your agent", title: "And what shall I call myself?", italic: true)

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

                Text("\"Hi, Ersultan — I'm \(displayName).\"")
                    .font(.system(size: 14, weight: .regular, design: .serif))
                    .italic()
                    .foregroundColor(AppTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .center)

                WwPrimaryButton("nice to meet you →", disabled: aiName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: onContinue)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 22)
        }
    }

    private var displayName: String {
        aiName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Her" : aiName
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
