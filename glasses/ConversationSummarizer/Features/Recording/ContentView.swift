import AVFoundation
import CoreLocation
import Speech
import SwiftUI
import UserNotifications

struct RootView: View {
    @ObservedObject var wearablesBridge: WearablesBridge
    @StateObject private var settings = AppSettingsStore()

    var body: some View {
        if settings.onboardingCompleted {
            ContentView(wearablesBridge: wearablesBridge, settings: settings)
        } else {
            OnboardingView(wearablesBridge: wearablesBridge, settings: settings)
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
        aiName = defaults.string(forKey: Keys.aiName) ?? "meta"
        ownerName = defaults.string(forKey: Keys.ownerName) ?? ""
        signInProvider = defaults.string(forKey: Keys.signInProvider).flatMap(SignInProvider.init(rawValue:))
        onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)
        glassesSetupSkipped = defaults.bool(forKey: Keys.glassesSetupSkipped)
    }

    var aiDisplayName: String {
        let trimmed = aiName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "meta" : trimmed
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
        self.aiName = Self.clean(aiName, fallback: "meta")
        self.ownerName = Self.clean(ownerName, fallback: "Owner")
        self.signInProvider = signInProvider
        self.glassesSetupSkipped = glassesSetupSkipped
        onboardingCompleted = true
        persist()
    }

    func saveProfile(aiName: String, ownerName: String) {
        self.aiName = Self.clean(aiName, fallback: "meta")
        self.ownerName = Self.clean(ownerName, fallback: "Owner")
        persist()
    }

    func resetOnboarding() {
        aiName = "meta"
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

private enum MainRoute {
    case home
    case pair
    case conversations
    case detail
}

struct ContentView: View {
    @ObservedObject var wearablesBridge: WearablesBridge
    @ObservedObject var settings: AppSettingsStore
    @StateObject private var viewModel: ConversationSessionViewModel
    @State private var showingSettings = false
    @State private var route: MainRoute = .home

    init(wearablesBridge: WearablesBridge, settings: AppSettingsStore) {
        self.wearablesBridge = wearablesBridge
        self.settings = settings
        _viewModel = StateObject(
            wrappedValue: ConversationSessionViewModel(
                recorder: MeetingRecorder(),
                transcriber: SpeechTranscriber(),
                summaryService: SummaryServiceFactory.make()
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
                        onSettings: {
                            showingSettings = true
                        },
                        onPair: {
                            route = .pair
                        },
                        onConversations: {
                            route = .conversations
                        },
                        onMeta: {
                            showingSettings = true
                        }
                    )
                case .pair:
                    ExactPairRayBanScreen(
                        bridge: wearablesBridge,
                        onBack: { route = .home },
                        onFinish: { route = .home },
                        onSkip: { route = .home }
                    )
                case .conversations:
                    ExactConversationsScreen(
                        onBackHome: { route = .home },
                        onSelect: { route = .detail },
                        onMeta: { showingSettings = true }
                    )
                case .detail:
                    ExactConversationDetailScreen(
                        onBack: { route = .conversations }
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(settings: settings)
        }
    }
}

private struct ExactBrandBar: View {
    let status: String

    var body: some View {
        HStack(spacing: 10) {
            MetaOrb(size: 22)
            Text("meta")
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
    let onSettings: () -> Void
    let onPair: () -> Void
    let onConversations: () -> Void
    let onMeta: () -> Void

    private let recent = [
        ("14:22", "Standup with eng team", "Office · Almaty", "32m", "glasses"),
        ("11:08", "Walk to the bakery", "Dostyk Ave", "7m", "phone")
    ]

    var body: some View {
        VStack(spacing: 0) {
            ExactBrandBar(status: isRecording ? "● LISTENING" : "IDLE")

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    MonoLabel("thu · may 1 · almaty")
                    Text(isRecording ? "Listening, \(settings.ownerDisplayName)..." : "Good morning, \(settings.ownerDisplayName).")
                        .font(.system(size: 28, weight: .medium, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.fg)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .padding(.top, 6)

                    Text(isRecording ? "Capturing audio. Tap the centre button again to stop." : "Two new conversations since yesterday. One ask waiting.")
                        .font(.system(size: 14, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.muted)
                        .lineSpacing(4)
                        .padding(.top, 8)

                    ExactGlassesStatusCard(bridge: bridge, onPair: onPair)
                        .padding(.top, 18)

                    if let errorMessage = viewModel.errorMessage {
                        ErrorBanner(message: errorMessage)
                            .padding(.top, 14)
                    }

                    ExactTodaySnapshot()
                        .padding(.top, 18)

                    ExactRecentList(items: recent, onSelect: onConversations)
                        .padding(.top, 20)

                    ExactAskSuggestions()
                        .padding(.top, 20)
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 36)
            }

            ExactTabBar(activeIndex: 0, recording: isRecording, onHome: {}, onRecord: viewModel.primaryAction, onLog: onConversations, onMemory: {}, onMeta: onMeta)
        }
    }

    private var isRecording: Bool {
        viewModel.phase == .recording
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
                    Text("Ray-Ban meta")
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

private struct ExactTodaySnapshot: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel("today, so far")
            WwCard(background: AppTheme.bgSoft, showsBorder: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("You spoke with \(Text("3 people").italic()) across 39 minutes. Eng standup landed Q2 priorities — one item is for you.")
                        .font(.system(size: 16, weight: .regular, design: .serif))
                        .foregroundColor(AppTheme.fg)
                        .lineSpacing(5)
                    DividerLine()
                    HStack(spacing: 14) {
                        ExactMetric(value: "39m", label: "recorded")
                        ExactMetric(value: "3", label: "people")
                        ExactMetric(value: "1", label: "follow-up")
                    }
                }
            }
        }
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
    let items: [(String, String, String, String, String)]
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MonoLabel("recent")
                Spacer()
                Button(action: onSelect) {
                    Text("see all →")
                        .font(.system(size: 12, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.fg)
                }
                .buttonStyle(PlainButtonStyle())
            }

            WwCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        Button(action: onSelect) {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.0)
                                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                                        .foregroundColor(AppTheme.fg)
                                    Text(item.4.uppercased())
                                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                                        .foregroundColor(AppTheme.dim)
                                }
                                .frame(width: 50, alignment: .leading)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.1)
                                        .font(.system(size: 14, weight: .medium, design: .serif))
                                        .foregroundColor(AppTheme.fg)
                                    Text("\(item.2) · \(item.3)")
                                        .font(.system(size: 12, weight: .regular, design: .serif))
                                        .italic()
                                        .foregroundColor(AppTheme.dim)
                                }
                                Spacer()
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(AppTheme.fg)
                            }
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

private struct ExactAskSuggestions: View {
    private let suggestions = [
        "what did anya decide yesterday?",
        "remind me about mom's birthday on saturday",
        "summarize today's standup in 3 lines"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel("ask meta")
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.fg)
                        Text(suggestion)
                            .font(.system(size: 13.5, weight: .regular, design: .serif))
                            .italic()
                            .foregroundColor(AppTheme.muted)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 42)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.bg))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
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
            WwHeader(pre: "bluetooth", title: "Pair your Ray-Ban.", italic: true, onBack: onBack)

            VStack(alignment: .leading, spacing: 0) {
                Text("Open the case near your phone. We'll find them automatically.")
                    .font(.system(size: 14, weight: .regular, design: .serif))
                    .foregroundColor(AppTheme.muted)
                    .lineSpacing(5)

                ZStack {
                    ForEach([CGFloat(110), CGFloat(190), CGFloat(270)], id: \.self) { diameter in
                        Circle()
                            .stroke(AppTheme.border, lineWidth: 1)
                            .frame(width: diameter, height: diameter)
                    }
                    VStack(spacing: 18) {
                        LargeGlassesIcon()
                            .frame(width: 240, height: 90)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(AppTheme.fg)
                                .frame(width: 6, height: 6)
                            Text("searching...")
                                .font(.system(size: 13, weight: .regular, design: .serif))
                                .italic()
                                .foregroundColor(AppTheme.fg)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 388)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(AppTheme.bgSoft))
                .padding(.vertical, 20)

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
                            bridge.connectDetectedAudioRoute()
                            onFinish()
                        }) {
                            Text("pair")
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
        }
    }
}

private struct ExactConversationsScreen: View {
    let onBackHome: () -> Void
    let onSelect: () -> Void
    let onMeta: () -> Void

    private let items: [ConversationMock] = [
        .init(time: "14:22", date: "today", title: "Standup with eng team", loc: "Office · Almaty", dur: "32m", src: "glasses", tags: ["work", "q2 plan"]),
        .init(time: "11:08", date: "today", title: "Walk to the bakery", loc: "Dostyk Ave", dur: "7m", src: "phone", tags: ["voice note"]),
        .init(time: "20:45", date: "yesterday", title: "Coffee with Anya", loc: "Coffee Boom", dur: "21m", src: "glasses", tags: ["friend", "gift idea"]),
        .init(time: "09:12", date: "yesterday", title: "Morning thoughts", loc: "Home", dur: "4m", src: "phone", tags: ["journal"]),
        .init(time: "16:30", date: "apr 29", title: "Doctor Karimov", loc: "Mediker clinic", dur: "18m", src: "phone", tags: ["health", "sensitive"])
    ]

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

            HStack(spacing: 10) {
                MetaOrb(size: 16)
                Text("ask meta about any of these...")
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
                            Button(action: onSelect) {
                                ConversationListRow(item: item)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, 22)
            }

            ExactTabBar(activeIndex: 1, recording: false, onHome: onBackHome, onRecord: onBackHome, onLog: {}, onMemory: {}, onMeta: onMeta)
        }
    }

    private var groupedItems: [(date: String, items: [ConversationMock])] {
        var result: [(String, [ConversationMock])] = []
        for item in items {
            if result.last?.0 == item.date {
                result[result.count - 1].1.append(item)
            } else {
                result.append((item.date, [item]))
            }
        }
        return result
    }
}

private struct ConversationMock: Identifiable {
    let id = UUID()
    let time: String
    let date: String
    let title: String
    let loc: String
    let dur: String
    let src: String
    let tags: [String]
}

private struct ConversationListRow: View {
    let item: ConversationMock

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.time)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(AppTheme.fg)
                Text(item.src.uppercased())
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundColor(AppTheme.dim)
            }
            .frame(width: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundColor(AppTheme.fg)
                Text("\(item.loc) · \(item.dur)")
                    .font(.system(size: 12, weight: .regular, design: .serif))
                    .italic()
                    .foregroundColor(AppTheme.dim)
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

private struct ExactConversationDetailScreen: View {
    let onBack: () -> Void
    private let tabs = ["summary", "transcript", "chat"]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Button(action: onBack) {
                        Text("←")
                            .font(.system(size: 22, weight: .regular, design: .serif))
                            .foregroundColor(AppTheme.fg)
                    }
                    .buttonStyle(PlainButtonStyle())
                    MonoLabel("● ray-ban · yesterday 20:45")
                }
                .padding(.bottom, 8)

                Text("Coffee with Anya")
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .italic()
                    .foregroundColor(AppTheme.fg)

                HStack(spacing: 14) {
                    Text("Coffee Boom")
                        .font(.system(size: 13, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.dim)
                    Text("21 min")
                        .font(.system(size: 13, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.dim)
                    Text("3 speakers")
                        .font(.system(size: 13, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(AppTheme.dim)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 14)

            ExactSegmentedTabs(tabs: tabs)
                .padding(.horizontal, 22)
                .padding(.bottom, 14)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    WwCard(background: AppTheme.bgSoft, showsBorder: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            MonoLabel("tldr")
                            Text("Anya is leaving Yandex for a small startup. She's \(Text("nervous about money.").italic()) Her mom's birthday is Saturday — she wants to give an enamel pin from that shop on Pushkin.")
                                .font(.system(size: 16, weight: .regular, design: .serif))
                                .foregroundColor(AppTheme.fg)
                                .lineSpacing(5)
                        }
                    }

                    ExactKeyPoints()
                    ExactMemoryChips()
                    ExactTranscriptPreview()
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            }

            ExactAskInput()
        }
    }
}

private struct ExactSegmentedTabs: View {
    let tabs: [String]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                Text(tab)
                    .font(.system(size: 13, weight: .medium, design: .serif))
                    .italic()
                    .foregroundColor(index == 0 ? AppTheme.bg : AppTheme.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(Capsule().fill(index == 0 ? AppTheme.fg : Color.clear))
            }
        }
        .padding(4)
        .background(Capsule().fill(AppTheme.bgSoft).overlay(Capsule().stroke(AppTheme.border, lineWidth: 1)))
    }
}

private struct ExactKeyPoints: View {
    let points = [
        ("career", "Anya → startup, joins May 15"),
        ("money", "worried about runway"),
        ("gift", "enamel pin shop, Pushkin street"),
        ("next", "remind you Saturday morning")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel("key points")
            WwCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                        HStack(alignment: .top, spacing: 12) {
                            Text(point.0.uppercased())
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundColor(AppTheme.dim)
                                .tracking(1.5)
                                .frame(width: 78, alignment: .leading)
                            Text(point.1)
                                .font(.system(size: 13, weight: .regular, design: .serif))
                                .foregroundColor(AppTheme.fg)
                                .lineSpacing(3)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        if index < points.count - 1 {
                            DividerLine()
                        }
                    }
                }
            }
        }
    }
}

private struct ExactMemoryChips: View {
    let memories = ["anya · changing job", "anya · mom bday saturday", "place · enamel pins on pushkin"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel("added to memory")
            FlowWrap(items: memories) { memory in
                Text("+ \(memory)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(AppTheme.fg)
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .overlay(Capsule().stroke(AppTheme.borderStrong, lineWidth: 1))
            }
        }
    }
}

private struct ExactTranscriptPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MonoLabel("transcript")
                Spacer()
                Text("open full →")
                    .font(.system(size: 12, weight: .regular, design: .serif))
                    .italic()
                    .foregroundColor(AppTheme.fg)
            }
            WwCard {
                VStack(alignment: .leading, spacing: 2) {
                    MonoLabel("20:46 anya")
                    Text("\"Honestly, I think I'm going to do it. I told them yes this morning.\"")
                        .font(.system(size: 13.5, weight: .regular, design: .serif))
                        .foregroundColor(AppTheme.fg)
                        .lineSpacing(5)
                    MonoLabel("20:46 you")
                        .padding(.top, 12)
                    Text("\"Wait — really? Tell me everything...\"")
                        .font(.system(size: 13.5, weight: .regular, design: .serif))
                        .foregroundColor(AppTheme.fg)
                        .lineSpacing(5)
                }
            }
        }
    }
}

private struct ExactAskInput: View {
    var body: some View {
        HStack(spacing: 10) {
            MetaOrb(size: 16)
            Text("ask about this conversation...")
                .font(.system(size: 13.5, weight: .regular, design: .serif))
                .italic()
                .foregroundColor(AppTheme.dim)
            Spacer()
            Circle()
                .fill(AppTheme.fg)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "paperplane")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.bg)
                )
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 46)
        .background(Capsule().fill(AppTheme.bgSoft).overlay(Capsule().stroke(AppTheme.borderStrong, lineWidth: 1)))
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { DividerLine() }
    }
}

private struct ExactTabBar: View {
    let activeIndex: Int
    let recording: Bool
    let onHome: () -> Void
    let onRecord: () -> Void
    let onLog: () -> Void
    let onMemory: () -> Void
    let onMeta: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                tab(icon: "house", title: "home", index: 0, action: onHome)
                tab(icon: "square.stack.3d.up", title: "log", index: 1, action: onLog)
                Color.clear
                    .frame(width: 76, height: 1)
                tab(icon: "brain.head.profile", title: "memory", index: 2, action: onMemory)
                tab(icon: "gearshape", title: "meta", index: 3, action: onMeta)
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
        HStack(spacing: -1) {
            Circle().stroke(AppTheme.fg, lineWidth: 1.4).frame(width: 10, height: 10)
            Rectangle().fill(AppTheme.fg).frame(width: 5, height: 1.4)
            Circle().stroke(AppTheme.fg, lineWidth: 1.4).frame(width: 10, height: 10)
        }
        .frame(width: 28, height: 14)
    }
}

private struct LargeGlassesIcon: View {
    var body: some View {
        ZStack {
            HStack(spacing: 52) {
                Circle()
                    .fill(AppTheme.bg)
                    .overlay(Circle().stroke(AppTheme.fg, lineWidth: 1.8))
                    .frame(width: 68, height: 68)
                Circle()
                    .fill(AppTheme.bg)
                    .overlay(Circle().stroke(AppTheme.fg, lineWidth: 1.8))
                    .frame(width: 68, height: 68)
            }
            Rectangle()
                .fill(AppTheme.fg)
                .frame(width: 52, height: 1.8)
            HStack {
                Rectangle().fill(AppTheme.fg).frame(width: 20, height: 1.8).rotationEffect(.degrees(12))
                Spacer()
                Rectangle().fill(AppTheme.fg).frame(width: 20, height: 1.8).rotationEffect(.degrees(-12))
            }
        }
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
            }
            if !pre.isEmpty {
                MonoLabel(pre)
                    .padding(.bottom, 6)
            }
            Text(title)
                .font(.system(size: 32, weight: .medium, design: .serif))
                .italic()
                .foregroundColor(AppTheme.fg)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
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
            MetaOrb(size: 28)

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
        case .completed:
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
            return "Recording through \(viewModel.activeInputName). Stop when the meeting ends and \(settings.aiDisplayName) will summarize it."
        case .transcribing:
            return "The audio is being turned into a clean transcript."
        case .summarizing:
            return "Decisions, action items, follow-ups, and memory are being extracted."
        case .completed:
            return "Review the notes below or ask \(settings.aiDisplayName) about the conversation."
        case .failed:
            return "Check permissions, audio route, or the summary endpoint before trying again."
        case .idle:
            return "Tap to record or speak through the glasses."
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
                        MonoLabel("ray-ban meta")
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
        case .detected, .ready:
            return bridge.audioRoute.primaryDetectedDevice == nil ? AppTheme.dim : AppTheme.fg
        case .registrationStarted:
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

                if viewModel.phase == .recording {
                    WarmWaveform()
                        .frame(height: 28)
                } else {
                    MonoLabel(viewModel.primaryButtonTitle)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

private struct WarmWaveform: View {
    private let bars: [CGFloat] = [10, 18, 24, 14, 28, 20, 12, 26, 18]

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(AppTheme.fg)
                    .frame(width: 3, height: height)
            }
        }
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
        ("gearshape", "meta")
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
        case .completed:
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
                    StateChip(title: bridge.isDATLinked ? "DAT linked" : "DAT missing", icon: "shippingbox", color: bridge.isDATLinked ? AppTheme.success : AppTheme.dim)
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
                    OutlineButton(title: bridge.audioRoute.primaryDetectedDevice == nil ? "Scan" : "Use Audio", icon: "dot.radiowaves.left.and.right") {
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

    private var routeStatusColor: Color {
        switch bridge.state {
        case .failed:
            return AppTheme.danger
        case .sessionStarted:
            return AppTheme.success
        case .detected, .ready:
            return bridge.audioRoute.primaryDetectedDevice == nil ? AppTheme.dim : AppTheme.accent
        case .registrationStarted:
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

                Text(summary.overview)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(AppTheme.fg)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                DividerLine()

                SummaryList(title: "Decisions", items: summary.decisions, icon: "checkmark.seal")
                SummaryList(title: "Action Items", items: summary.actionItems, icon: "checklist")
                SummaryList(title: "Follow-ups", items: summary.followUps, icon: "arrow.clockwise")
            }
        }
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
    case permissions
    case glasses

    var label: String {
        switch self {
        case .account:
            return "ACCOUNT"
        case .ownerName:
            return "YOU"
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

    @StateObject private var locationPermission = LocationPermissionController()
    @State private var step: OnboardingStep = .account
    @State private var selectedProvider: SignInProvider?
    @State private var aiName: String
    @State private var ownerName: String
    @State private var microphonePermission: PermissionState = .unknown
    @State private var speechPermission: PermissionState = .unknown
    @State private var notificationPermission: PermissionState = .unknown

    init(wearablesBridge: WearablesBridge, settings: AppSettingsStore) {
        self.wearablesBridge = wearablesBridge
        self.settings = settings
        _selectedProvider = State(initialValue: settings.signInProvider)
        _aiName = State(initialValue: settings.aiDisplayName)
        _ownerName = State(initialValue: settings.ownerName)
    }

    var body: some View {
        NavigationView {
            ZStack {
                AppTheme.bg.ignoresSafeArea()

                if step == .account {
                    SetupAccountPage(selectedProvider: $selectedProvider) { provider in
                        selectedProvider = provider
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
    }

    @ViewBuilder
    private var currentPage: some View {
        switch step {
        case .account:
            SetupAccountPage(selectedProvider: $selectedProvider) { provider in
                selectedProvider = provider
                go(to: .ownerName)
            }
        case .ownerName:
            SetupOwnerNamePage(ownerName: $ownerName) {
                go(to: .aiName)
            }
        case .aiName:
            SetupAgentNamePage(aiName: $aiName) {
                go(to: .permissions)
            }
        case .permissions:
            SetupPermissionsPage(
                microphonePermission: microphonePermission,
                speechPermission: speechPermission,
                locationPermission: locationPermission.state,
                notificationPermission: notificationPermission,
                localDataPermission: .granted,
                bluetoothPermission: bluetoothPermission,
                onMicrophone: requestMicrophonePermission,
                onSpeech: requestSpeechPermission,
                onLocation: requestLocationPermission,
                onNotifications: requestNotificationPermission,
                onLocalData: {},
                onBluetooth: wearablesBridge.refreshAudioRoute
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
        guard let selectedProvider else {
            go(to: .account)
            return
        }

        settings.completeOnboarding(
            aiName: aiName,
            ownerName: ownerName,
            signInProvider: selectedProvider,
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

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            speechPermission = .granted
        case .denied, .restricted:
            speechPermission = .denied
        case .notDetermined:
            speechPermission = .unknown
        @unknown default:
            speechPermission = .unknown
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

    private func requestSpeechPermission() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                speechPermission = status == .authorized ? .granted : .denied
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
                    MetaOrb(size: 28)
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
        return trimmed.isEmpty ? "meta" : trimmed
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
    @Binding var selectedProvider: SignInProvider?
    let onSelect: (SignInProvider) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                MetaOrb(size: 26)
                Text("meta")
                    .font(.system(size: 18, weight: .medium, design: .serif))
                    .foregroundColor(AppTheme.fg)
                Spacer(minLength: 12)
                MonoLabel("v 0.1 · ios")
            }

            Color.clear
                .frame(height: 64)

            VStack(alignment: .leading, spacing: 14) {
                MonoLabel("personal AI · for ray-ban meta")
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
                    onSelect(.apple)
                }
                SetupProviderButton(
                    provider: .google,
                    selected: selectedProvider == .google,
                    primary: false
                ) {
                    onSelect(.google)
                }
            }

            WarmAuthTerms()
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SetupOwnerNamePage: View {
    @Binding var ownerName: String
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WwSteps(step: 1, total: 4, label: "you")
            WwHeader(pre: "from your apple id", title: "What should I call you?", italic: true)

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
                            Rectangle()
                                .fill(AppTheme.fg)
                                .frame(width: 2, height: 30)
                            Text("EDIT")
                                .font(.system(size: 9, weight: .regular, design: .monospaced))
                                .tracking(1.5)
                                .foregroundColor(AppTheme.fg)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .overlay(Capsule().stroke(AppTheme.borderStrong, lineWidth: 1))
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
                    Image(systemName: "apple.logo")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.muted)
                        .padding(.top, 2)
                    Text("Pulled from Apple ID. Editable anytime in Settings › Profile.")
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
}

private struct SetupAgentNamePage: View {
    @Binding var aiName: String
    let onContinue: () -> Void

    private let suggestions = ["meta", "iris", "echo", "mira", "atlas", "wren", "lior"]

    var body: some View {
        VStack(spacing: 0) {
            WwSteps(step: 2, total: 4, label: "agent")
            WwHeader(pre: "your agent", title: "And what shall I call myself?", italic: true)

            VStack(alignment: .leading, spacing: 16) {
                WwCard(padding: 28) {
                    VStack(alignment: .center, spacing: 0) {
                        MetaOrb(size: 38)
                        HStack(alignment: .center, spacing: 4) {
                            TextField("meta", text: $aiName)
                                .font(.system(size: 60, weight: .medium, design: .serif))
                                .foregroundColor(AppTheme.fg)
                                .multilineTextAlignment(.center)
                                .disableAutocorrection(true)
                                .textInputAutocapitalization(.never)
                                .frame(height: 66)
                            Rectangle()
                                .fill(AppTheme.fg)
                                .frame(width: 3, height: 46)
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
        aiName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "meta" : aiName
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
    let speechPermission: PermissionState
    let locationPermission: PermissionState
    let notificationPermission: PermissionState
    let localDataPermission: PermissionState
    let bluetoothPermission: PermissionState
    let onMicrophone: () -> Void
    let onSpeech: () -> Void
    let onLocation: () -> Void
    let onNotifications: () -> Void
    let onLocalData: () -> Void
    let onBluetooth: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WwSteps(step: 3, total: 4, label: "access")
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
                                icon: "square.stack.3d.up",
                                title: "Local data",
                                subtitle: "photos, contacts, calendar",
                                state: localDataPermission,
                                defaultOn: false,
                                action: onLocalData
                            )
                            DividerLine()
                            ExactPermissionRow(
                                icon: "eyeglasses",
                                title: "Bluetooth",
                                subtitle: "pair Ray-Ban meta",
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
                            + Text(" Never uploaded unless you ask meta to summarize."))
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

                Text("We will use the iOS audio route first. If Ray-Ban Meta is already paired in Bluetooth, meta can detect it here.")
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
        (Text("by continuing — ")
            + Text("terms").underline()
            + Text(" · ")
            + Text("privacy").underline())
            .font(.system(size: 12, weight: .regular, design: .serif))
            .italic()
            .foregroundColor(AppTheme.dim)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
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
                StateChip(title: bridge.isDATLinked ? "DAT linked" : "DAT missing", icon: "shippingbox", color: bridge.isDATLinked ? AppTheme.success : AppTheme.dim)
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
}

private struct PrivacyLinkText: View {
    var body: some View {
        (Text("By continuing, you agree to our ")
            + Text("Privacy Policy").underline()
            + Text(" & ")
            + Text("Terms of Use").underline()
            + Text("."))
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(AppTheme.dim)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.78)
    }
}

private struct PrivacyPolicyText: View {
    var body: some View {
        (Text("Governed by our ")
            + Text("Privacy Policy").underline()
            + Text(" and ")
            + Text("Terms of Service").underline()
            + Text("."))
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(AppTheme.dim)
            .fixedSize(horizontal: false, vertical: true)
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
                                ProfileTextField(label: "AI NAME", placeholder: "meta", text: $aiName)
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

private struct MetaOrb: View {
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        RootView(wearablesBridge: WearablesBridge())
    }
}
