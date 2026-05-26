import AppKit
import AVFoundation
import SwiftUI

enum HerMacSection: String, CaseIterable, Identifiable {
    case home
    case log
    case memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return "Home"
        case .log:
            return "Conversations"
        case .memory:
            return "Memory"
        }
    }

    var symbol: String {
        switch self {
        case .home:
            return "house"
        case .log:
            return "square.stack.3d.down.right"
        case .memory:
            return "brain.head.profile"
        }
    }
}

enum HerConversationTab: String, CaseIterable, Identifiable {
    case contents
    case summary
    case chat

    var id: String { rawValue }
}

private enum HerMacLaunchMode {
    case signIn
    case setup
    case dashboard
}

private enum HerMacProfileDefaults {
    static let ownerName = "app.settings.ownerName"
    static let agentName = "app.settings.aiName"
    static let fallbackAgentName = "Her"

    static func clean(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }
}

@MainActor
final class HerMacStore: ObservableObject {
    @Published private(set) var user: HerUser?
    @Published private(set) var meetings: [HerMeeting] = []
    @Published private(set) var subscription: HerSubscription = .empty
    @Published private(set) var voiceProfiles: [HerVoiceProfile] = []
    @Published private(set) var ownerName: String
    @Published private(set) var agentName: String
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published var selectedMeetingID: String?

    let authStore: HerAuthStore
    private let client: HerBackendClient?
    private let defaults: UserDefaults
    private var audioPreloadTask: Task<Void, Never>?
    private var audioPreloadedMeetingIDs = Set<String>()

    init(
        config: HerBackendConfig? = HerBackendConfig.fromEnvironment(),
        authStore: HerAuthStore? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        ownerName = defaults.string(forKey: HerMacProfileDefaults.ownerName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        agentName = HerMacProfileDefaults.clean(
            defaults.string(forKey: HerMacProfileDefaults.agentName),
            fallback: HerMacProfileDefaults.fallbackAgentName
        )
        self.authStore = authStore ?? HerAuthStore()
        if let config {
            client = HerBackendClient(config: config)
        } else {
            client = nil
        }
    }

    var selectedMeeting: HerMeeting? {
        meetings.first { $0.id == selectedMeetingID } ?? meetings.first
    }

    var memoryCandidates: [HerMemoryCandidate] {
        meetings.flatMap(\.memoryCandidates)
    }

    func refresh() async {
        guard let client else {
            loadError = "backend url is invalid"
            meetings = []
            subscription = .empty
            user = nil
            voiceProfiles = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        guard authStore.token != nil else {
            loadError = "backend auth token missing - set HER_AUTH_TOKEN"
            meetings = []
            subscription = .empty
            user = nil
            voiceProfiles = []
            selectedMeetingID = nil
            return
        }

        do {
            let loadedUser = try await client.currentUser()
            let displayUser = userWithSavedProfile(loadedUser)
            if authStore.session == nil {
                authStore.persistEnvironmentToken(user: displayUser)
            } else if authStore.session?.user != displayUser {
                authStore.updateUser(displayUser)
            }
            async let loadedMeetings = client.meetings()
            async let loadedSubscription = client.subscription()
            async let loadedProfiles = client.voiceProfiles()
            let result = try await (loadedMeetings, loadedSubscription, loadedProfiles)
            user = displayUser
            meetings = result.0
            subscription = result.1
            voiceProfiles = result.2
            selectedMeetingID = selectedMeetingID.flatMap { current in
                meetings.contains { $0.id == current } ? current : nil
            } ?? meetings.first?.id
            loadError = nil
            authStore.setError(nil)
            preloadAudioCache(for: result.0)
        } catch {
            meetings = []
            subscription = .empty
            user = nil
            voiceProfiles = []
            selectedMeetingID = nil
            loadError = error.localizedDescription
            authStore.setError(error.localizedDescription)
        }
    }

    @discardableResult
    func signInWithBackendSession() async -> Bool {
        await refresh()
        return user != nil
    }

    @discardableResult
    func bootstrapDesktopSession(createIfMissing: Bool = false) async -> Bool {
        guard let client else {
            loadError = "backend url is invalid"
            return false
        }
        guard client.config.allowsDesktopBootstrap else {
            return false
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let session = try await client.desktopSession(
                createIfMissing: createIfMissing,
                name: ownerName.nilIfBlank
            )
            authStore.setSession(session)
            await refresh()
            return user != nil
        } catch HerBackendError.backendFailed(404, _) {
            if createIfMissing {
                loadError = "local desktop account could not be created"
            }
            return false
        } catch {
            loadError = error.localizedDescription
            authStore.setError(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func signInWithApple(_ result: HerAppleSignInResult) async -> Bool {
        guard let client else {
            let message = "backend url is invalid"
            loadError = message
            authStore.setError(message)
            return false
        }

        isLoading = true
        do {
            let session = try await client.signInWithApple(
                identityToken: result.identityToken,
                fullName: result.fullName,
                email: result.email
            )
            authStore.setSession(session)
            isLoading = false
            await refresh()
            return user != nil
        } catch {
            isLoading = false
            loadError = error.localizedDescription
            authStore.setError(error.localizedDescription)
            return false
        }
    }

    func reportNativeSignInUnavailable(provider: String) {
        let message = "\(provider) native sign-in needs a macOS identity-token flow. Use backend session for this scaffold."
        loadError = message
        authStore.setError(message)
    }

    func reportSignInError(_ message: String) {
        loadError = message
        authStore.setError(message)
    }

    func saveProfile(displayName: String, agentName: String) {
        let fallbackName = user?.displayName ?? "Owner"
        ownerName = HerMacProfileDefaults.clean(displayName, fallback: fallbackName)
        self.agentName = HerMacProfileDefaults.clean(
            agentName,
            fallback: HerMacProfileDefaults.fallbackAgentName
        )
        defaults.set(ownerName, forKey: HerMacProfileDefaults.ownerName)
        defaults.set(self.agentName, forKey: HerMacProfileDefaults.agentName)

        if let user {
            let displayUser = user.replacingDisplayName(ownerName)
            self.user = displayUser
            authStore.updateUser(displayUser, isNewUser: false)
        }
    }

    func signOut() {
        audioPreloadTask?.cancel()
        audioPreloadTask = nil
        audioPreloadedMeetingIDs.removeAll()
        authStore.clear()
        user = nil
        meetings = []
        subscription = .empty
        voiceProfiles = []
        selectedMeetingID = nil
        loadError = authStore.hasEnvironmentToken ? "Keychain session cleared; using HER_AUTH_TOKEN." : "signed out"
    }

    func chatMessages(for meeting: HerMeeting) async throws -> [HerChatMessage] {
        guard let client else {
            throw HerBackendError.invalidURL
        }
        return try await client.chatMessages(meetingId: meeting.id)
    }

    func audioURL(for meeting: HerMeeting) -> URL? {
        client?.meetingAudioURL(meetingId: meeting.id)
    }

    @discardableResult
    func renameVoiceProfile(_ profile: HerVoiceProfile, name: String) async -> Bool {
        guard let client else {
            loadError = "backend url is invalid"
            return false
        }
        do {
            _ = try await client.renameVoiceProfile(id: profile.id, name: name)
            voiceProfiles = try await client.voiceProfiles()
            loadError = nil
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteVoiceProfile(_ profile: HerVoiceProfile) async -> Bool {
        guard let client else {
            loadError = "backend url is invalid"
            return false
        }
        do {
            try await client.deleteVoiceProfile(id: profile.id)
            voiceProfiles = try await client.voiceProfiles()
            loadError = nil
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    private func preloadAudioCache(for meetings: [HerMeeting]) {
        guard let client, authStore.token != nil else {
            return
        }
        let candidates = meetings
            .filter { $0.hasAudio && !audioPreloadedMeetingIDs.contains($0.id) }
        guard !candidates.isEmpty else {
            return
        }

        let token = authStore.token
        let preloadMeetings = Array(candidates)
        audioPreloadTask?.cancel()
        audioPreloadTask = Task { [weak self, client, token] in
            for meeting in preloadMeetings {
                guard !Task.isCancelled else {
                    return
                }
                let remoteURL = client.meetingAudioURL(meetingId: meeting.id)
                do {
                    _ = try await MacMeetingAudioCache.shared.localAudioURL(
                        for: meeting,
                        remoteURL: remoteURL,
                        authToken: token
                    )
                    await MainActor.run {
                        _ = self?.audioPreloadedMeetingIDs.insert(meeting.id)
                    }
                } catch {
                    continue
                }
            }
        }
    }

    func ask(_ question: String, about meeting: HerMeeting) async throws -> String {
        guard let client else {
            throw HerBackendError.invalidURL
        }
        return try await client.ask(meetingId: meeting.id, question: question)
    }

    private func userWithSavedProfile(_ user: HerUser) -> HerUser {
        let trimmedName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return user
        }
        return user.replacingDisplayName(trimmedName)
    }
}

private extension HerUser {
    func replacingDisplayName(_ displayName: String) -> HerUser {
        HerUser(id: id, provider: provider, email: email, name: displayName)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct HerMacRootView: View {
    @ObservedObject var store: HerMacStore
    @State private var section: HerMacSection = .home
    @State private var conversationTab: HerConversationTab = .summary
    @State private var launchMode: HerMacLaunchMode = .signIn
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            switch launchMode {
            case .dashboard:
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    MacSidebar(
                        activeSection: $section,
                        selectedMeetingID: $store.selectedMeetingID,
                        meetings: store.meetings,
                        user: store.user,
                        subscription: store.subscription,
                        loadError: store.loadError,
                        onSignOut: {
                            store.signOut()
                            launchMode = .signIn
                        }
                    )
                    .navigationSplitViewColumnWidth(min: 252, ideal: 252, max: 252)
                } detail: {
                    MacDashboardView(
                        section: $section,
                        conversationTab: $conversationTab,
                        store: store
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .navigationSplitViewStyle(.balanced)
            case .setup:
                VStack(spacing: 0) {
                    MacTitleBar(activeSection: $section, showNavigation: false, loadError: store.loadError)
                    MacOnboardingView(
                        user: store.user,
                        savedOwnerName: store.ownerName,
                        savedAgentName: store.agentName,
                        loadError: store.loadError,
                        isLoading: store.isLoading,
                        initialStep: .profile,
                        onUseBackendSession: {
                            await store.signInWithBackendSession()
                        },
                        onAppleSignIn: { result in
                            await store.signInWithApple(result)
                        },
                        onNativeSignInUnavailable: { provider in
                            store.reportNativeSignInUnavailable(provider: provider)
                        },
                        onSignInError: { message in
                            store.reportSignInError(message)
                        },
                        onSaveProfile: { displayName, agentName in
                            store.saveProfile(displayName: displayName, agentName: agentName)
                        },
                        onFinish: { launchMode = .dashboard }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .signIn:
                VStack(spacing: 0) {
                    MacTitleBar(activeSection: $section, showNavigation: false, loadError: store.loadError)
                    MacSignInView(
                        loadError: store.loadError,
                        isLoading: store.isLoading,
                        onAppleSignIn: { result in
                            guard await store.signInWithApple(result) else {
                                return
                            }
                            routeAfterAuthenticatedSession()
                        },
                        onGoogle: {
                            store.reportNativeSignInUnavailable(provider: "Google")
                        },
                        onSignInError: { message in
                            store.reportSignInError(message)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(HerTheme.background)
        .foregroundStyle(HerTheme.ink)
        .toolbar {
            if launchMode == .dashboard, section == .log, store.selectedMeeting != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    ToolbarPillButton("Share")
                    ToolbarPillButton("Export")
                    ToolbarPillButton("ellipsis", systemImage: "ellipsis")
                }
            }
        }
        .task {
            guard store.authStore.token != nil else {
                if await store.bootstrapDesktopSession(createIfMissing: false) {
                    routeAfterAuthenticatedSession()
                } else if store.loadError == nil,
                          await store.bootstrapDesktopSession(createIfMissing: true) {
                    routeAfterAuthenticatedSession()
                } else {
                    launchMode = .signIn
                }
                return
            }
            await store.refresh()
            routeAfterAuthenticatedSession()
        }
        .onChange(of: store.user?.id) { _, userID in
            if userID == nil {
                launchMode = .signIn
            }
        }
    }

    private func routeAfterAuthenticatedSession() {
        guard store.user != nil else {
            launchMode = .signIn
            return
        }
        launchMode = store.authStore.session?.isExistingAccount == false ? .setup : .dashboard
    }
}

struct HerMacSettingsScene: View {
    @ObservedObject var store: HerMacStore

    var body: some View {
        MacSettingsView(
            user: store.user,
            ownerName: store.ownerName,
            agentName: store.agentName,
            subscription: store.subscription,
            meetings: store.meetings,
            voiceProfiles: store.voiceProfiles,
            loadError: store.loadError,
            onSaveProfile: { displayName, agentName in
                store.saveProfile(displayName: displayName, agentName: agentName)
            },
            onRefresh: {
                await store.refresh()
            },
            onRenameVoiceProfile: { profile, name in
                await store.renameVoiceProfile(profile, name: name)
            },
            onDeleteVoiceProfile: { profile in
                await store.deleteVoiceProfile(profile)
            },
            onSignOut: {
                store.signOut()
            }
        )
        .frame(width: 720, height: 640)
        .task {
            await store.refresh()
        }
    }
}

private struct MacDashboardView: View {
    @Binding var section: HerMacSection
    @Binding var conversationTab: HerConversationTab
    @ObservedObject var store: HerMacStore

    var body: some View {
        Group {
            switch section {
            case .home:
                MacHomeView(
                    user: store.user,
                    meetings: store.meetings,
                    subscription: store.subscription,
                    loadError: store.loadError,
                    onOpenLog: { section = .log }
                )
            case .log:
                MacConversationsView(
                    meetings: store.meetings,
                    selectedMeetingID: $store.selectedMeetingID,
                    selectedTab: $conversationTab,
                    store: store
                )
            case .memory:
                MacMemoryView(meetings: store.meetings)
            }
        }
    }
}

private struct MacTitleBar: View {
    @Binding var activeSection: HerMacSection
    let showNavigation: Bool
    let loadError: String?

    var body: some View {
        HStack(spacing: 8) {
            if showNavigation {
                HStack(spacing: 4) {
                    ForEach(HerMacSection.allCases) { item in
                        Button {
                            activeSection = item
                        } label: {
                            Text(item.title)
                                .font(.system(size: 11, weight: activeSection == item ? .semibold : .regular))
                                .foregroundStyle(activeSection == item ? HerTheme.ink : HerTheme.inkDim)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(activeSection == item ? HerTheme.backgroundDeep : .clear)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 18)
            }

            Spacer()
            HStack(spacing: 8) {
                HerMark(size: 14)
                Text("Her")
                    .font(HerTheme.serif(13, weight: .medium))
                    .italic()
                    .foregroundStyle(HerTheme.inkSoft)
            }
            Spacer()

            Color.clear
                .frame(width: 72)
                .padding(.trailing, 14)
        }
        .frame(height: 32)
        .background(HerTheme.backgroundSoft)
        .overlay(alignment: .bottom) {
            Rectangle().fill(HerTheme.line).frame(height: 1)
        }
    }
}

private struct UserPopover: View {
    let user: HerUser
    @Binding var selectedLanguage: String
    let onSignOut: () -> Void
    let dismiss: () -> Void

    @State private var page: UserPopoverPage = .main

    var body: some View {
        Group {
            switch page {
            case .main:
                mainContent
            case .language:
                languageContent
            }
        }
        .frame(width: 260)
        .padding(.vertical, 4)
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            accountHeader
            Divider()

            VStack(spacing: 0) {
                SettingsLink {
                    UserPopoverRow(
                        icon: "gearshape",
                        title: "Settings",
                        trailing: "⌘,"
                    )
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    dismiss()
                })

                Button {
                    page = .language
                } label: {
                    UserPopoverRow(
                        icon: "globe",
                        title: "Language",
                        subtitle: languageTitle,
                        trailingSymbol: "chevron.right"
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)

            Divider()

            Button(role: .destructive) {
                onSignOut()
            } label: {
                UserPopoverRow(
                    icon: "rectangle.portrait.and.arrow.right",
                    title: "Log out",
                    tint: .red
                )
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }

    private var languageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                page = .main
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16)
                    Text("Language")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            VStack(spacing: 0) {
                ForEach(languageOptions) { option in
                    Button {
                        selectedLanguage = option.id
                        page = .main
                    } label: {
                        UserPopoverRow(
                            icon: option.symbol,
                            title: option.title,
                            subtitle: option.subtitle,
                            trailingSymbol: selectedLanguage == option.id ? "checkmark" : nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var accountHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(accountTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let accountSubtitle {
                Text(accountSubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(HerTheme.ink)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var accountTitle: String {
        guard let email = user.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            return user.displayName
        }
        return email
    }

    private var accountSubtitle: String? {
        guard let email = user.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            return nil
        }
        return user.displayName == email ? nil : user.displayName
    }

    private var languageTitle: String {
        languageOptions.first { $0.id == selectedLanguage }?.title ?? "System"
    }

    private var languageOptions: [UserLanguageOption] {
        [
            UserLanguageOption(id: "system", title: "System", subtitle: "use macOS language", symbol: "desktopcomputer"),
            UserLanguageOption(id: "en", title: "English", subtitle: "desktop UI", symbol: "textformat"),
            UserLanguageOption(id: "ru", title: "Русский", subtitle: "интерфейс Her", symbol: "textformat"),
            UserLanguageOption(id: "kk", title: "Қазақша", subtitle: "Her интерфейсі", symbol: "textformat")
        ]
    }
}

private enum UserPopoverPage {
    case main
    case language
}

private struct UserLanguageOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
}

private struct UserPopoverRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil
    var trailingSymbol: String? = nil
    var tint: Color? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
                .foregroundStyle(tint ?? HerTheme.ink)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(tint ?? HerTheme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Color.gray.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

private struct MacSidebar: View {
    @Binding var activeSection: HerMacSection
    @Binding var selectedMeetingID: String?
    let meetings: [HerMeeting]
    let user: HerUser?
    let subscription: HerSubscription
    let loadError: String?
    let onSignOut: () -> Void

    @AppStorage("her.mac.language") private var selectedLanguage = "system"
    @State private var showUserMenu = false
    @State private var isAccountRowHovered = false

    private var recents: [HerMeeting] {
        Array(meetings.prefix(20))
    }

    private var navigationSections: [HerMacSection] {
        [.home, .memory]
    }

    var body: some View {
        List {
            // Quick actions
            Section {
                Button {} label: {
                    Label {
                        Text("Start recording")
                            .font(.system(size: 13, weight: .medium))
                    } icon: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(HerTheme.coral)
                    }
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)

                ForEach(navigationSections) { item in
                    Button {
                        activeSection = item
                        selectedMeetingID = nil
                    } label: {
                        Label {
                            HStack(spacing: 8) {
                                Text(item.title)
                                    .font(.system(size: 13, weight: .medium))
                                Spacer(minLength: 0)
                            }
                        } icon: {
                            Image(systemName: item.symbol)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(activeSection == item ? HerTheme.ink : HerTheme.inkSoft)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(activeSection == item ? HerTheme.line : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                }
            }

            // Recents
            if !recents.isEmpty {
                Section {
                    ForEach(recents) { meeting in
                        Button {
                            activeSection = .log
                            selectedMeetingID = meeting.id
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(selectedMeetingID == meeting.id ? HerTheme.coral : HerTheme.lineStrong)
                                    .frame(width: 6, height: 6)
                                Text(meeting.title)
                                    .font(.system(size: 12, weight: selectedMeetingID == meeting.id ? .semibold : .regular))
                                    .foregroundStyle(HerTheme.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("Recents")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(HerTheme.inkDim)
                        .textCase(.lowercase)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let user {
                Button {
                    showUserMenu.toggle()
                } label: {
                    HStack(spacing: 10) {
                        Text(initials(for: user))
                            .font(HerTheme.serif(13, weight: .semibold))
                            .italic()
                            .frame(width: 30, height: 30)
                            .foregroundStyle(HerTheme.background)
                            .background(Circle().fill(HerTheme.ink))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(user.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(HerTheme.ink)
                                .lineLimit(1)
                            Text(subscriptionTagline)
                                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(HerTheme.inkDim)
                            .rotationEffect(.degrees(showUserMenu ? 180 : 0))
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 12)
                    .padding(.vertical, 9)
                    .background(isAccountRowHovered || showUserMenu ? HerTheme.backgroundDeep : HerTheme.backgroundSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(showUserMenu ? HerTheme.lineStrong : HerTheme.line, lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .background(HerTheme.backgroundSoft)
                .onHover { isAccountRowHovered = $0 }
                .popover(isPresented: $showUserMenu, arrowEdge: .bottom) {
                    UserPopover(
                        user: user,
                        selectedLanguage: $selectedLanguage,
                        onSignOut: {
                            showUserMenu = false
                            onSignOut()
                        },
                        dismiss: { showUserMenu = false }
                    )
                }
            }
        }
    }

    private var subscriptionTagline: String {
        let plan = subscription.plan.capitalized
        let minutes = subscription.remainingMinutes
        if minutes > 0 {
            return "\(plan) · \(minutes) min left"
        }
        return plan
    }

    private func initials(for user: HerUser) -> String {
        if let name = user.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let parts = name.split(separator: " ").prefix(2)
            let chars = parts.compactMap { $0.first.map(String.init) }
            let joined = chars.joined()
            if !joined.isEmpty { return joined.uppercased() }
        }
        if let email = user.email, let first = email.first {
            return String(first).uppercased()
        }
        return "H"
    }
}

private struct SidebarRow: View {
    let item: HerMacSection
    let isActive: Bool
    let count: Int?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 17)
            Text(item.title)
                .font(HerTheme.serif(15, weight: isActive ? .semibold : .medium))
                .italic(isActive)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(isActive ? HerTheme.background.opacity(0.7) : HerTheme.inkDim)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .foregroundStyle(isActive ? HerTheme.background : HerTheme.ink)
        .background(isActive ? HerTheme.ink : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DeviceChip: View {
    let loadError: String?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(loadError == nil ? HerTheme.ink : HerTheme.inkDim)
                .frame(width: 7, height: 7)
            Image(systemName: "eyeglasses")
                .font(.system(size: 16, weight: .medium))
            Text(loadError == nil ? "shared backend" : "backend auth")
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(HerTheme.inkSoft)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(HerTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(HerTheme.lineStrong, lineWidth: 1)
        }
    }
}

private struct MacSignInView: View {
    let loadError: String?
    let isLoading: Bool
    let onAppleSignIn: (HerAppleSignInResult) async -> Void
    let onGoogle: () -> Void
    let onSignInError: (String) -> Void

    @StateObject private var appleSignIn = HerAppleSignInService()

    var body: some View {
        GeometryReader { geometry in
            let brandWidth = signInBrandWidth(for: geometry.size.width)
            HStack(spacing: 0) {
                signInBrandPanel
                    .frame(width: brandWidth, height: geometry.size.height)
                    .clipped()

                signInActionPanel
                    .frame(width: max(0, geometry.size.width - brandWidth), height: geometry.size.height)
                    .background(HerTheme.backgroundSoft)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(HerTheme.line).frame(width: 1)
                    }
            }
        }
        .background(HerTheme.background)
    }

    private func signInBrandWidth(for totalWidth: CGFloat) -> CGFloat {
        let actionMinimum: CGFloat = 560
        let preferred = totalWidth * 0.48
        return max(420, min(620, preferred, totalWidth - actionMinimum))
    }

    private var signInBrandPanel: some View {
        ZStack(alignment: .topLeading) {
            RadialGradient(
                colors: [HerTheme.coral.opacity(0.13), HerTheme.background.opacity(0)],
                center: UnitPoint(x: 0.16, y: 0.04),
                startRadius: 0,
                endRadius: 260
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 13) {
                    HerMark(size: 32)
                    Text("Her")
                        .font(HerTheme.serif(26, weight: .medium))
                        .italic()
                        .foregroundStyle(HerTheme.coral)
                }

                Spacer(minLength: 78)

                MacEyebrow("personal AI · desktop", color: HerTheme.coral)
                Text("Hello.\nI'm ")
                    .font(HerTheme.display(94))
                    .lineSpacing(-5)
                    .padding(.top, 24)
                    .overlay(alignment: .bottomLeading) {
                        Text("Her.")
                            .font(HerTheme.display(94))
                            .italic()
                            .foregroundStyle(HerTheme.coral)
                            .offset(x: 178, y: 5)
                    }

                Text("A personal AI who listens through your phone, your glasses, and now your Mac — and remembers what mattered.")
                    .font(HerTheme.serif(21, weight: .semibold))
                    .foregroundStyle(HerTheme.inkSoft)
                    .lineSpacing(8)
                    .frame(maxWidth: 490, alignment: .leading)
                    .padding(.top, 34)

                Spacer()

                Text("v 0.4.2 · macos 14+ · made in almaty")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(HerTheme.inkDim)
                    .textCase(.uppercase)
                    .tracking(1.1)
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 64)
        }
    }

    private var signInActionPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                MacEyebrow("sign in")
                Spacer()
                Text("no passwords. ever.")
                    .font(HerTheme.serif(13, weight: .semibold))
                    .italic()
                    .foregroundStyle(HerTheme.inkSoft)
            }

            Text("Welcome back.")
                .font(HerTheme.serif(42, weight: .medium))
                .italic()
                .padding(.top, 24)

            Text("Use your Apple or Google account to pick up where you left off on iPhone or Ray-Ban.")
                .font(HerTheme.serif(16, weight: .semibold))
                .foregroundStyle(HerTheme.inkSoft)
                .lineSpacing(6)
                .frame(maxWidth: 430, alignment: .leading)
                .padding(.top, 20)

            VStack(spacing: 12) {
                MacAuthButton(
                    title: isLoading ? "Checking Apple..." : "Continue with Apple",
                    kind: .apple,
                    action: {
                        Task {
                            do {
                                let result = try await appleSignIn.signIn()
                                await onAppleSignIn(result)
                            } catch {
                                onSignInError(error.localizedDescription)
                            }
                        }
                    }
                )
                MacAuthButton(
                    title: "Continue with Google",
                    kind: .google,
                    action: onGoogle
                )
            }
            .frame(maxWidth: 460)
            .padding(.top, 40)

            VStack(alignment: .leading, spacing: 10) {
                MacEyebrow("already on iphone?")
                Text("Sign in with the same account and your conversations, memory and pairings follow you over end-to-end sync.")
                    .font(HerTheme.serif(14.5, weight: .semibold))
                    .foregroundStyle(HerTheme.ink)
            }
            .lineSpacing(6)
            .padding(22)
            .frame(maxWidth: 500, alignment: .leading)
            .background(HerTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(HerTheme.line, lineWidth: 1)
            }
            .padding(.top, 34)

            if let loadError {
                Text(loadError)
                    .font(HerTheme.serif(13))
                    .italic()
                    .foregroundStyle(HerTheme.warn)
                    .lineSpacing(5)
                    .frame(maxWidth: 500, alignment: .leading)
                    .padding(.top, 16)
            }

            Spacer()

            Text("By continuing you agree to our terms and privacy. Audio is processed on-device first — we never see your recordings.")
                .font(HerTheme.serif(12.5, weight: .semibold))
                .italic()
                .foregroundStyle(HerTheme.inkDim)
                .lineSpacing(6)
                .frame(maxWidth: 500, alignment: .leading)
        }
        .padding(.horizontal, 66)
        .padding(.vertical, 64)
    }
}

private struct MacEyebrow: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color = HerTheme.inkDim) {
        self.text = text
        self.color = color
    }

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(color.opacity(0.5))
                .frame(width: 20, height: 1)
            Text(text)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .tracking(1.8)
                .textCase(.uppercase)
        }
        .foregroundStyle(color)
    }
}

private enum MacAuthButtonKind {
    case apple
    case google
}

private struct MacAuthButton: View {
    let title: String
    let kind: MacAuthButtonKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if kind == .apple {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 18, weight: .semibold))
                } else {
                    Text("G")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: 0x4285f4))
                }

                Text(title)
                    .font(HerTheme.serif(17, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .foregroundStyle(kind == .apple ? HerTheme.background : HerTheme.ink)
            .background(kind == .apple ? HerTheme.ink : HerTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(kind == .apple ? Color.clear : HerTheme.lineStrong, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private enum MacOnboardingStep: Int, CaseIterable {
    case signIn
    case account
    case profile
    case access
    case ready

    var label: String {
        switch self {
        case .signIn:
            return "sign in"
        case .account:
            return "account"
        case .profile:
            return "profile"
        case .access:
            return "access"
        case .ready:
            return "ready"
        }
    }

    var next: MacOnboardingStep? {
        MacOnboardingStep(rawValue: rawValue + 1)
    }

    var previous: MacOnboardingStep? {
        MacOnboardingStep(rawValue: rawValue - 1)
    }
}

private struct MacOnboardingView: View {
    let user: HerUser?
    let savedOwnerName: String
    let savedAgentName: String
    let loadError: String?
    let isLoading: Bool
    let initialStep: MacOnboardingStep
    let onUseBackendSession: () async -> Bool
    let onAppleSignIn: (HerAppleSignInResult) async -> Bool
    let onNativeSignInUnavailable: (String) -> Void
    let onSignInError: (String) -> Void
    let onSaveProfile: (String, String) -> Void
    let onFinish: () -> Void

    @StateObject private var appleSignIn = HerAppleSignInService()
    @State private var step: MacOnboardingStep = .signIn
    @State private var displayName = ""
    @State private var agentName = HerMacProfileDefaults.fallbackAgentName
    @State private var allowMicrophone = true
    @State private var allowNotifications = true
    @State private var allowLocation = true
    @State private var allowBluetooth = false

    var body: some View {
        VStack(spacing: 0) {
            onboardingProgress
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    MonoLabel(step.label)
                    Text(title)
                        .font(HerTheme.display(48))
                        .italic()
                        .lineLimit(3)
                        .lineSpacing(2)
                        .padding(.top, 16)
                    Text(subtitle)
                        .font(HerTheme.serif(17))
                        .italic()
                        .foregroundStyle(HerTheme.inkSoft)
                        .lineSpacing(6)
                        .frame(maxWidth: 460, alignment: .leading)
                        .padding(.top, 18)

                    Spacer()

                    HStack(spacing: 10) {
                        if let previous = step.previous {
                            Button {
                                step = previous
                            } label: {
                                Text("back")
                                    .font(HerTheme.serif(14, weight: .medium))
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 11)
                                    .overlay { Capsule().stroke(HerTheme.lineStrong, lineWidth: 1) }
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            continueAction()
                        } label: {
                            Text(step == .ready ? "open Her" : "continue")
                                .font(HerTheme.serif(14, weight: .semibold))
                                .foregroundStyle(HerTheme.background)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 12)
                                .background(HerTheme.ink)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 56)
                .padding(.vertical, 52)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(HerTheme.background)

                VStack(alignment: .leading, spacing: 18) {
                    sideContent
                }
                .padding(.horizontal, 52)
                .padding(.vertical, 52)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(HerTheme.backgroundSoft)
                .overlay(alignment: .leading) {
                    Rectangle().fill(HerTheme.line).frame(width: 1)
                }
            }
        }
        .background(HerTheme.background)
        .onAppear {
            if step == .signIn, initialStep != .signIn {
                step = initialStep
            }
            if displayName.isEmpty {
                let restoredOwnerName = savedOwnerName.trimmingCharacters(in: .whitespacesAndNewlines)
                displayName = restoredOwnerName.isEmpty
                    ? (user?.displayName == "Her" ? "" : (user?.displayName ?? ""))
                    : restoredOwnerName
            }
            if agentName == HerMacProfileDefaults.fallbackAgentName {
                agentName = HerMacProfileDefaults.clean(
                    savedAgentName,
                    fallback: HerMacProfileDefaults.fallbackAgentName
                )
            }
        }
    }

    private var onboardingProgress: some View {
        HStack(spacing: 14) {
            HerMark(size: 20)
            Text("Her")
                .font(HerTheme.serif(15, weight: .medium))
                .italic()
            HStack(spacing: 8) {
                ForEach(MacOnboardingStep.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? HerTheme.ink : HerTheme.backgroundDeep)
                        .frame(width: item == step ? 42 : 18, height: 3)
                }
            }
            .padding(.leading, 20)
            MonoLabel(String(format: "%02d · %@", step.rawValue, step.label), size: 9)
            Spacer()
            Button("skip") {
                onFinish()
            }
            .buttonStyle(.plain)
            .font(HerTheme.serif(13))
            .italic()
            .foregroundStyle(HerTheme.inkDim)
        }
        .padding(.horizontal, 36)
        .frame(height: 58)
        .background(HerTheme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(HerTheme.line).frame(height: 1)
        }
    }

    private var title: String {
        switch step {
        case .signIn:
            return "Hello. I'm Her."
        case .account:
            return "Start with your account."
        case .profile:
            return "What should I call you?"
        case .access:
            return "Let Her help."
        case .ready:
            return "Her is ready."
        }
    }

    private var subtitle: String {
        switch step {
        case .signIn:
            return "Sign in first, then Her can open the same backend account you use on iPhone. No sample data, no separate desktop identity."
        case .account:
            return "Use the same backend account as iPhone so conversations, memory candidates, voice profiles, and subscription state come from one place."
        case .profile:
            return "This is the name Her uses in the desktop shell, summaries, and notifications. You can change it later in Settings."
        case .access:
            return "macOS permissions are explicit. Decline anything now and the matching feature stays off until you enable it."
        case .ready:
            return "The desktop app starts from onboarding, then opens into your conversation workspace. Settings now live in the macOS Settings window."
        }
    }

    @ViewBuilder
    private var sideContent: some View {
        switch step {
        case .signIn:
            OnboardingSignInCard(
                user: user,
                loadError: loadError,
                isLoading: isLoading,
                onApple: {
                    Task {
                        do {
                            let result = try await appleSignIn.signIn()
                            if await onAppleSignIn(result) {
                                continueAction()
                            }
                        } catch {
                            onSignInError(error.localizedDescription)
                        }
                    }
                },
                onGoogle: {
                    onNativeSignInUnavailable("Google")
                },
                onUseBackendSession: {
                    Task {
                        if await onUseBackendSession() {
                            continueAction()
                        }
                    }
                }
            )
        case .account:
            OnboardingAccountCard(user: user, loadError: loadError, isLoading: isLoading)
        case .profile:
            VStack(alignment: .leading, spacing: 16) {
                OnboardingField(label: "your name", text: $displayName, placeholder: "Your name")
                OnboardingField(label: "agent name", text: $agentName, placeholder: "Her")
                Text("Her will use this name across the macOS app, just like the iPhone onboarding profile.")
                    .font(HerTheme.serif(13))
                    .italic()
                    .foregroundStyle(HerTheme.inkDim)
                    .lineSpacing(5)
                    .padding(16)
                    .background(HerTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(HerTheme.line, lineWidth: 1)
                    }
            }
        case .access:
            VStack(spacing: 0) {
                PermissionRow(symbol: "mic", title: "Microphone", subtitle: "record desktop conversations later", isOn: $allowMicrophone)
                PermissionRow(symbol: "bell", title: "Notifications", subtitle: "brief only when it matters", isOn: $allowNotifications)
                PermissionRow(symbol: "location", title: "Location", subtitle: "tag meetings with place", isOn: $allowLocation)
                PermissionRow(symbol: "wave.3.right", title: "Bluetooth", subtitle: "Ray-Ban pairing later", isOn: $allowBluetooth, isLast: true)
            }
            .background(HerTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(HerTheme.lineStrong, lineWidth: 1)
            }
        case .ready:
            VStack(alignment: .leading, spacing: 14) {
                SummaryRow(label: "account", value: profileDisplayName)
                SummaryRow(label: "agent", value: agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Her" : agentName)
                SummaryRow(label: "permissions", value: enabledPermissionText)
                SummaryRow(label: "settings", value: "Her -> Settings..., or Command-,")
            }
            .padding(22)
            .background(HerTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(HerTheme.lineStrong, lineWidth: 1)
            }
        }
    }

    private func continueAction() {
        if let next = step.next {
            step = next
        } else {
            onSaveProfile(profileDisplayName, profileAgentName)
            onFinish()
        }
    }

    private var profileDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return user?.displayName ?? "Owner"
    }

    private var profileAgentName: String {
        HerMacProfileDefaults.clean(
            agentName,
            fallback: HerMacProfileDefaults.fallbackAgentName
        )
    }

    private var enabledPermissionText: String {
        [
            allowMicrophone ? "mic" : nil,
            allowNotifications ? "notifications" : nil,
            allowLocation ? "location" : nil,
            allowBluetooth ? "bluetooth" : nil
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

private struct OnboardingSignInCard: View {
    let user: HerUser?
    let loadError: String?
    let isLoading: Bool
    let onApple: () -> Void
    let onGoogle: () -> Void
    let onUseBackendSession: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                HerMark(size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(user == nil ? "Sign in to Her" : "Welcome back.")
                        .font(HerTheme.serif(22, weight: .medium))
                        .italic()
                    MonoLabel(statusText, size: 9)
                }
                Spacer()
                Circle()
                    .fill(user == nil ? HerTheme.inkDim : HerTheme.ink)
                    .frame(width: 8, height: 8)
            }

            VStack(spacing: 10) {
                SignInButton(symbol: "apple.logo", title: "Continue with Apple", subtitle: "native token -> /v1/auth/apple", isPrimary: true, action: onApple)
                SignInButton(symbol: "g.circle", title: "Continue with Google", subtitle: "requires Google OAuth setup", isPrimary: false, action: onGoogle)
                SignInButton(symbol: "key", title: "Use backend session", subtitle: "HER_AUTH_TOKEN or Keychain", isPrimary: false, action: onUseBackendSession)
            }

            Text(detailText)
                .font(HerTheme.serif(13))
                .italic()
                .foregroundStyle(HerTheme.inkDim)
                .lineSpacing(5)
                .padding(16)
                .background(HerTheme.backgroundSoft)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(HerTheme.line, lineWidth: 1)
                }
        }
        .padding(24)
        .background(HerTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(HerTheme.lineStrong, lineWidth: 1)
        }
    }

    private var statusText: String {
        if isLoading {
            return "checking backend"
        }
        return user == nil ? "00 · sign in" : "signed in · \(user?.provider ?? "backend")"
    }

    private var detailText: String {
        if let user {
            return "Using \(user.displayName)'s backend account. Continue to review profile and permissions."
        }
        if let loadError {
            return "\(loadError). This scaffold can still continue so you can review onboarding, but real data appears only after backend auth."
        }
        return "Desktop uses the same auth contract as iPhone. Apple Sign-In posts an identity token to the shared backend; local token handoff is only for development."
    }
}

private struct SignInButton: View {
    let symbol: String
    let title: String
    let subtitle: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(HerTheme.serif(15, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .textCase(.uppercase)
                        .foregroundStyle(isPrimary ? HerTheme.background.opacity(0.64) : HerTheme.inkDim)
                }
                Spacer()
                Text("->")
                    .font(HerTheme.serif(16))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .foregroundStyle(isPrimary ? HerTheme.background : HerTheme.ink)
            .background(isPrimary ? HerTheme.ink : HerTheme.backgroundSoft)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isPrimary ? Color.clear : HerTheme.lineStrong, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct OnboardingAccountCard: View {
    let user: HerUser?
    let loadError: String?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                HerMark(size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(user?.displayName ?? "Shared backend")
                        .font(HerTheme.serif(20, weight: .medium))
                    MonoLabel(statusText, size: 9)
                }
                Spacer()
                Circle()
                    .fill(user == nil ? HerTheme.inkDim : HerTheme.ink)
                    .frame(width: 8, height: 8)
            }

            Text(detailText)
                .font(HerTheme.serif(15))
                .italic()
                .foregroundStyle(HerTheme.inkSoft)
                .lineSpacing(6)

            VStack(spacing: 10) {
                OnboardingActionRow(symbol: "person.crop.circle", title: "Same account as iPhone", value: user?.email ?? "pending")
                OnboardingActionRow(symbol: "server.rack", title: "Backend", value: "127.0.0.1:8787")
                OnboardingActionRow(symbol: "key", title: "Token source", value: user == nil ? "HER_AUTH_TOKEN / Keychain" : "active")
            }
        }
        .padding(24)
        .background(HerTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(HerTheme.lineStrong, lineWidth: 1)
        }
    }

    private var statusText: String {
        if isLoading {
            return "loading"
        }
        return user == nil ? "auth needed" : "signed in"
    }

    private var detailText: String {
        if let loadError, user == nil {
            return loadError
        }
        return "Conversations, memory candidates, voice profiles, and subscription state are loaded from the backend."
    }
}

private struct OnboardingField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(label)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(HerTheme.serif(28, weight: .medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(HerTheme.background)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(HerTheme.lineStrong, lineWidth: 1)
                }
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var isLast = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(HerTheme.serif(15, weight: .medium))
                Text(subtitle)
                    .font(HerTheme.serif(12))
                    .italic()
                    .foregroundStyle(HerTheme.inkDim)
            }
            Spacer()
            ToggleCapsule(isOn: isOn)
                .onTapGesture {
                    isOn.toggle()
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(HerTheme.line).frame(height: 1)
            }
        }
    }
}

private struct OnboardingActionRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 18)
            Text(title)
                .font(HerTheme.serif(13, weight: .medium))
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(HerTheme.inkDim)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(HerTheme.backgroundSoft)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SummaryRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            MonoLabel(label)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(HerTheme.serif(15, weight: .medium))
                .lineSpacing(4)
            Spacer()
        }
        .padding(.vertical, 7)
    }
}

private struct MacHomeView: View {
    let user: HerUser?
    let meetings: [HerMeeting]
    let subscription: HerSubscription
    let loadError: String?
    let onOpenLog: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MonoLabel(homeContextLabel)
                Text("Good morning, \(user?.displayName ?? "Her").")
                    .font(HerTheme.display(54))
                    .italic()
                    .foregroundStyle(HerTheme.ink)
                    .lineLimit(2)
                    .padding(.top, 14)
                Text("\(meetings.count) saved conversations.")
                    .font(HerTheme.serif(20))
                    .italic()
                    .foregroundStyle(HerTheme.inkSoft)
                    .padding(.top, 12)

                if let loadError {
                    StatusPill(text: loadError)
                        .padding(.top, 18)
                }

                TodaySnapshot(meetings: meetings, subscription: subscription)
                    .padding(.top, 34)

                HStack(alignment: .top, spacing: 28) {
                    RecentMeetingsCard(meetings: Array(meetings.prefix(3)), onOpenLog: onOpenLog)
                        .frame(maxWidth: .infinity)
                    AskHerCard(meetings: meetings)
                        .frame(width: 350)
                }
                .padding(.top, 36)
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 40)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HerTheme.background)
    }

    private var homeContextLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE - MMM d"
        let dateText = formatter.string(from: Date())
        if let location = meetings.first?.locationName?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            return "\(dateText) - \(location)"
        }
        return dateText
    }
}

private struct TodaySnapshot: View {
    let meetings: [HerMeeting]
    let subscription: HerSubscription

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                MonoLabel("today, so far")
                Spacer()
                Text(todayMeetings.isEmpty ? "no recordings yet" : "\(todayMeetings.count) saved today")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(HerTheme.inkSoft)
            }

            Text(todayMeetings.isEmpty ? "No conversations recorded today." : "Latest backend recordings are synced from the shared meeting store.")
                .font(HerTheme.serif(20))
                .italic()
                .foregroundStyle(HerTheme.inkSoft)
                .lineSpacing(5)

            HStack(spacing: 36) {
                StatBlock(number: recordedText, label: "recorded")
                StatBlock(number: "\(todayMeetings.count)", label: "saved")
                StatBlock(number: "\(todayMeetings.flatMap(\.followUps).count)", label: "follow-up")
                StatBlock(number: "\(subscription.remainingSeconds / 60)", label: "min left")
            }
            .padding(.top, 20)
            .overlay(alignment: .top) {
                Rectangle().fill(HerTheme.line).frame(height: 1)
            }
        }
        .padding(28)
        .background(HerTheme.backgroundSoft)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(HerTheme.line, lineWidth: 1)
        }
    }

    private var todayMeetings: [HerMeeting] {
        meetings.filter { Calendar.current.isDateInToday($0.createdAt) }
    }

    private var recordedText: String {
        let seconds = todayMeetings.compactMap(\.durationSeconds).reduce(0, +)
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes)m"
    }
}

private struct RecentMeetingsCard: View {
    let meetings: [HerMeeting]
    let onOpenLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                MonoLabel("recent")
                Spacer()
                Button("see all ->", action: onOpenLog)
                    .buttonStyle(.plain)
                    .font(HerTheme.serif(13))
                    .italic()
                    .foregroundStyle(HerTheme.ink)
            }

            VStack(spacing: 0) {
                if meetings.isEmpty {
                    Text("Backend conversations will appear here after auth loads.")
                        .font(HerTheme.serif(14))
                        .italic()
                        .foregroundStyle(HerTheme.inkDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                } else {
                    ForEach(Array(meetings.enumerated()), id: \.element.id) { index, meeting in
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.timeText)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                            MonoLabel(meeting.sourceLabel, size: 9)
                        }
                        .frame(width: 70, alignment: .leading)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.title)
                                .font(HerTheme.serif(15, weight: .medium))
                                .lineLimit(2)
                            Text("\(meeting.displayLocation) - \(meeting.durationText)")
                                .font(HerTheme.serif(12))
                                .italic()
                                .foregroundStyle(HerTheme.inkDim)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("->")
                            .font(HerTheme.serif(18))
                            .foregroundStyle(HerTheme.inkDim)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .overlay(alignment: .bottom) {
                        if index < meetings.count - 1 {
                            Rectangle().fill(HerTheme.line).frame(height: 1)
                        }
                    }
                }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(HerTheme.lineStrong, lineWidth: 1)
            }
        }
    }
}

private struct AskHerCard: View {
    let meetings: [HerMeeting]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MonoLabel("ask Her")
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    HerMark(size: 20)
                    Text(meetings.isEmpty ? "ask Her after backend auth" : "ask about your conversations")
                        .font(HerTheme.serif(13))
                        .italic()
                        .foregroundStyle(HerTheme.inkDim)
                    Spacer()
                    MonoLabel("cmd k", size: 10)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(HerTheme.backgroundSoft)
                .clipShape(Capsule())
                .overlay { Capsule().stroke(HerTheme.lineStrong, lineWidth: 1) }

                VStack(spacing: 8) {
                    ForEach(prompts, id: \.self) { prompt in
                        HStack(spacing: 8) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(HerTheme.ink)
                            Text(prompt)
                                .font(HerTheme.serif(13.5))
                                .italic()
                                .foregroundStyle(HerTheme.inkSoft)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(HerTheme.line, lineWidth: 1)
                        }
                    }
                }
            }
            .padding(22)
            .background(HerTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(HerTheme.lineStrong, lineWidth: 1)
            }
        }
    }

    private var prompts: [String] {
        let recent = meetings.prefix(3)
        guard !recent.isEmpty else {
            return ["connect backend auth to ask over saved meetings"]
        }
        return recent.map { "ask about \($0.title)" }
    }
}

private struct MacConversationsView: View {
    let meetings: [HerMeeting]
    @Binding var selectedMeetingID: String?
    @Binding var selectedTab: HerConversationTab
    @ObservedObject var store: HerMacStore

    private var selectedMeeting: HerMeeting? {
        meetings.first { $0.id == selectedMeetingID } ?? meetings.first
    }

    var body: some View {
        Group {
            if let selectedMeeting {
                ConversationDetailPane(meeting: selectedMeeting, selectedTab: $selectedTab, store: store)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.down.right")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(HerTheme.inkDim)
                    Text("No conversations")
                        .font(HerTheme.serif(20, weight: .medium))
                    Text(meetings.isEmpty
                         ? "Shared backend has no saved meetings yet."
                         : "Pick a conversation from the sidebar.")
                        .font(HerTheme.serif(14))
                        .italic()
                        .foregroundStyle(HerTheme.inkDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedMeetingID == nil {
                selectedMeetingID = meetings.first?.id
            }
        }
    }
}

private struct ConversationDetailPane: View {
    let meeting: HerMeeting
    @Binding var selectedTab: HerConversationTab
    @ObservedObject var store: HerMacStore
    @StateObject private var playback = MacMeetingAudioPlaybackController()

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(meeting: meeting)
            AudioStrip(
                meeting: meeting,
                audioURL: store.audioURL(for: meeting),
                authToken: store.authStore.token,
                playback: playback
            )
            TabStrip(selectedTab: $selectedTab)

            ScrollView {
                Group {
                    switch selectedTab {
                    case .contents:
                        ContentsPanel(
                            meeting: meeting,
                            audioURL: store.audioURL(for: meeting),
                            authToken: store.authStore.token,
                            playback: playback
                        )
                    case .summary:
                        SummaryPanel(meeting: meeting)
                    case .chat:
                        ChatPanel(meeting: meeting, store: store)
                    }
                }
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.vertical, 32)
            }
        }
        .background(HerTheme.background)
        .task(id: meeting.id) {
            playback.preload(
                for: meeting,
                audioURL: store.audioURL(for: meeting),
                authToken: store.authStore.token
            )
        }
        .onChange(of: meeting.id) { _ in
            playback.stop()
        }
    }
}

private struct DetailHeader: View {
    let meeting: HerMeeting

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(meeting.title)
                .font(HerTheme.serif(36, weight: .medium))
                .italic()
                .lineLimit(3)
                .lineSpacing(2)
                .frame(maxWidth: 760, alignment: .leading)

            HStack(spacing: 16) {
                MonoLabel(meeting.displayLocation, size: 11)
                MonoLabel("-", size: 11)
                MonoLabel(meeting.durationText, size: 11)
                MonoLabel("-", size: 11)
                MonoLabel("\(meeting.dateText), \(meeting.timeText)", size: 11)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) {
            Rectangle().fill(HerTheme.line).frame(height: 1)
        }
    }
}

private struct AudioStrip: View {
    let meeting: HerMeeting
    let audioURL: URL?
    let authToken: String?
    @ObservedObject var playback: MacMeetingAudioPlaybackController
    @ObservedObject private var progress: MacMeetingAudioPlaybackProgress

    init(
        meeting: HerMeeting,
        audioURL: URL?,
        authToken: String?,
        playback: MacMeetingAudioPlaybackController
    ) {
        self.meeting = meeting
        self.audioURL = audioURL
        self.authToken = authToken
        self.playback = playback
        _progress = ObservedObject(wrappedValue: playback.progress)
    }

    var body: some View {
        HStack(spacing: 18) {
            Button {
                playback.toggleFullPlayback(
                    for: meeting,
                    audioURL: audioURL,
                    authToken: authToken
                )
            } label: {
                ZStack {
                    Circle().fill(canPlay ? HerTheme.ink : HerTheme.inkDim)
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(HerTheme.background)
                        .offset(x: playback.isPlaying ? 0 : 2)
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!canPlay || playback.isLoading)

            Text("\(MacMeetingTimeFormatter.fullTimestamp(progress.currentTime)) / \(durationClock)")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(HerTheme.ink)
                .frame(width: 150, alignment: .leading)

            Waveform(progress: progressRatio)

            HStack(spacing: 10) {
                RoundControl("-15") {
                    playback.skip(by: -15, meeting: meeting, audioURL: audioURL, authToken: authToken)
                }
                RoundControl("+15") {
                    playback.skip(by: 15, meeting: meeting, audioURL: audioURL, authToken: authToken)
                }
                Button {
                    playback.cyclePlaybackRate()
                } label: {
                    Text(playback.playbackRateLabel)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(HerTheme.background)
                        .clipShape(Capsule())
                        .overlay { Capsule().stroke(HerTheme.lineStrong, lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .disabled(!canPlay)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 16)
        .background(HerTheme.backgroundSoft)
        .overlay(alignment: .bottom) {
            Rectangle().fill(HerTheme.line).frame(height: 1)
        }
        .overlay(alignment: .bottomLeading) {
            if let errorMessage = playback.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(HerTheme.danger)
                    .padding(.leading, 36)
                    .padding(.bottom, 2)
            }
        }
    }

    private var canPlay: Bool {
        meeting.hasAudio && audioURL != nil
    }

    private var durationClock: String {
        MacMeetingTimeFormatter.fullTimestamp(playback.durationSeconds(for: meeting))
    }

    private var progressRatio: Double {
        let duration = max(0.1, playback.durationSeconds(for: meeting))
        return min(max(progress.currentTime / duration, 0), 1)
    }
}

private struct Waveform: View {
    var progress: Double = 0

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<96, id: \.self) { index in
                let height = abs(sin(Double(index) * 0.42) * cos(Double(index) * 0.13)) * 28 + 4
                RoundedRectangle(cornerRadius: 1)
                    .fill(Double(index) / 95 <= progress ? HerTheme.ink : HerTheme.lineStrong)
                    .frame(width: 3, height: height)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
    }
}

private struct RoundControl: View {
    let label: String
    var action: () -> Void = {}

    init(_ label: String, action: @escaping () -> Void = {}) {
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .frame(width: 32, height: 32)
                .background(HerTheme.background)
                .clipShape(Circle())
                .overlay { Circle().stroke(HerTheme.lineStrong, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

private struct TabStrip: View {
    @Binding var selectedTab: HerConversationTab

    var body: some View {
        HStack(spacing: 32) {
            ForEach(HerConversationTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(HerTheme.serif(14, weight: selectedTab == tab ? .semibold : .medium))
                        .italic(selectedTab == tab)
                        .foregroundStyle(selectedTab == tab ? HerTheme.ink : HerTheme.inkSoft)
                        .padding(.vertical, 14)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(selectedTab == tab ? HerTheme.ink : .clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 36)
        .overlay(alignment: .bottom) {
            Rectangle().fill(HerTheme.line).frame(height: 1)
        }
    }
}

private struct ContentsPanel: View {
    let meeting: HerMeeting
    let audioURL: URL?
    let authToken: String?
    @ObservedObject var playback: MacMeetingAudioPlaybackController
    @ObservedObject private var progress: MacMeetingAudioPlaybackProgress
    @State private var activeChunkID: String?
    @State private var playbackIsPlaying = false

    init(
        meeting: HerMeeting,
        audioURL: URL?,
        authToken: String?,
        playback: MacMeetingAudioPlaybackController
    ) {
        self.meeting = meeting
        self.audioURL = audioURL
        self.authToken = authToken
        self.playback = playback
        _progress = ObservedObject(wrappedValue: playback.progress)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            if !meeting.outline.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    MonoLabel("outline")
                    Text("\(meeting.outline.count) chapters. Tap to jump.")
                        .font(HerTheme.serif(24, weight: .medium))
                        .italic()

                    VStack(spacing: 0) {
                        ForEach(meeting.outline) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 18) {
                                Text(item.timeText)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .frame(width: 90, alignment: .leading)
                                Text(item.title)
                                    .font(HerTheme.serif(16))
                                    .lineSpacing(4)
                                Spacer()
                                Text("↗")
                                    .font(HerTheme.serif(16))
                                    .italic()
                                    .foregroundStyle(HerTheme.inkDim)
                            }
                            .padding(.vertical, 16)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(HerTheme.line).frame(height: 1)
                            }
                        }
                    }
                    .overlay(alignment: .top) {
                        Rectangle().fill(HerTheme.lineStrong).frame(height: 1)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                MonoLabel("transcript")
                if displayChunks.isEmpty {
                    Text("No transcript available for this conversation.")
                        .font(HerTheme.serif(17))
                        .italic()
                        .foregroundStyle(HerTheme.inkDim)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(displayChunks) { chunk in
                            ConversationTranscriptSegmentRow(
                                chunk: chunk,
                                speakerName: displayName(for: chunk),
                                isActive: activeChunkID == chunk.id,
                                isPlaying: playbackIsPlaying && activeChunkID == chunk.id,
                                playbackProgress: progress,
                                onTogglePlay: {
                                    toggleChunkPlayback(chunk)
                                },
                                onPlayFromText: {
                                    toggleChunkPlayback(chunk)
                                }
                            )
                            .id(chunk.id)
                        }
                    }
                    .overlay(alignment: .top) {
                        Rectangle().fill(HerTheme.lineStrong).frame(height: 1)
                    }
                }
            }
        }
        .background(
            MacPlaybackProgressObserver(
                playback: playback,
                progress: progress,
                chunks: displayChunks,
                onActiveChunkChange: { chunkID in
                    activeChunkID = chunkID
                },
                onPlayingChange: { isPlaying in
                    playbackIsPlaying = isPlaying
                }
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
        .onAppear {
            activeChunkID = chunkID(at: playback.currentTime)
            playbackIsPlaying = playback.isPlaying
        }
        .onDisappear {
            playback.pausePlayback()
        }
        .onChange(of: meeting.id) { _ in
            activeChunkID = chunkID(at: playback.currentTime)
        }
    }

    private var displayChunks: [MacTranscriptDisplayChunk] {
        MacTranscriptDisplayChunk.group(segments: transcriptSegments, speakerKey: speakerKey(for:))
    }

    private var transcriptSegments: [HerTranscriptSegment] {
        let usableSegments = meeting.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !usableSegments.isEmpty {
            return usableSegments
        }

        let transcript = meeting.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return []
        }
        return [
            HerTranscriptSegment(
                start: 0,
                end: meeting.durationSeconds ?? 0,
                text: transcript,
                speaker: "Transcript"
            )
        ]
    }

    private func speakerKey(for segment: HerTranscriptSegment) -> String {
        let trimmed = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Speaker" : trimmed
    }

    private func displayName(for chunk: MacTranscriptDisplayChunk) -> String {
        if !chunk.speakerKey.localizedCaseInsensitiveContains("speaker") {
            return chunk.speakerKey
        }

        let orderedKeys = speakerOrder
        if let index = orderedKeys.firstIndex(of: chunk.speakerKey) {
            return "Speaker \(index + 1)"
        }
        return "Speaker"
    }

    private var speakerOrder: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for segment in transcriptSegments {
            let key = speakerKey(for: segment)
            if seen.insert(key).inserted {
                ordered.append(key)
            }
        }
        return ordered
    }

    private func toggleChunkPlayback(_ chunk: MacTranscriptDisplayChunk) {
        if activeChunkID == chunk.id {
            if playback.isPlaying {
                playback.pausePlayback()
            } else if playback.currentTime >= max(chunk.start, chunk.end - 0.15) {
                playback.playFrom(chunk.start, meeting: meeting, audioURL: audioURL, authToken: authToken)
            } else {
                playback.resumePlayback(for: meeting, audioURL: audioURL, authToken: authToken)
            }
        } else {
            playback.playChunk(chunk, meeting: meeting, audioURL: audioURL, authToken: authToken)
        }
    }

    private func chunkID(at time: Double) -> String? {
        guard playback.isPlaying || playback.hasPlaybackPosition else {
            return nil
        }
        return displayChunks.first { chunk in
            time + 0.05 >= chunk.start && time <= chunk.end + 0.25
        }?.id
    }
}

private struct ConversationTranscriptSegmentRow: View {
    let chunk: MacTranscriptDisplayChunk
    let speakerName: String
    let isActive: Bool
    let isPlaying: Bool
    @ObservedObject var playbackProgress: MacMeetingAudioPlaybackProgress
    let onTogglePlay: () -> Void
    let onPlayFromText: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Button(action: onTogglePlay) {
                    HStack(spacing: 6) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(MacMeetingTimeFormatter.timestamp(chunk.start))
                            .font(.system(size: 15, weight: .regular, design: .monospaced))
                    }
                    .foregroundStyle(isPlaying ? HerTheme.ink : HerTheme.inkDim)
                    .frame(width: 86, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button(action: onTogglePlay) {
                    Text(speakerName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(HerTheme.ink)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }

            if isActive {
                TranscriptPlaybackHighlightedText(
                    chunk: chunk,
                    progress: playbackProgress,
                    isPlaying: isPlaying
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: onPlayFromText)
            } else {
                Text(chunk.text)
                    .foregroundStyle(HerTheme.ink)
                    .font(.system(size: 18, weight: .regular))
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onPlayFromText)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? HerTheme.backgroundSoft : Color.clear)
        )
    }
}

private struct MacPlaybackProgressObserver: View {
    @ObservedObject var playback: MacMeetingAudioPlaybackController
    @ObservedObject var progress: MacMeetingAudioPlaybackProgress
    let chunks: [MacTranscriptDisplayChunk]
    let onActiveChunkChange: (String?) -> Void
    let onPlayingChange: (Bool) -> Void
    @State private var lastActiveChunkID: String?
    @State private var lastIsPlaying = false

    var body: some View {
        Color.clear
            .onAppear {
                publishState(force: true)
            }
            .onChange(of: progress.currentTime) { _ in
                publishState(force: false)
            }
            .onChange(of: playback.isPlaying) { _ in
                publishState(force: true)
            }
            .onChange(of: playback.hasPlaybackPosition) { _ in
                publishState(force: true)
            }
            .onChange(of: chunks) { _ in
                publishState(force: true)
            }
    }

    private func publishState(force: Bool) {
        let nextActiveChunkID = activeChunkID()
        if force || nextActiveChunkID != lastActiveChunkID {
            lastActiveChunkID = nextActiveChunkID
            onActiveChunkChange(nextActiveChunkID)
        }

        if force || playback.isPlaying != lastIsPlaying {
            lastIsPlaying = playback.isPlaying
            onPlayingChange(playback.isPlaying)
        }
    }

    private func activeChunkID() -> String? {
        guard playback.isPlaying || playback.hasPlaybackPosition else {
            return nil
        }
        let time = progress.currentTime
        return chunks.first { chunk in
            time + 0.05 >= chunk.start && time <= chunk.end + 0.25
        }?.id
    }
}

private struct MacTranscriptDisplayChunk: Identifiable, Equatable {
    let id: String
    let start: Double
    let end: Double
    let speakerKey: String
    let text: String
    let segmentIndexes: [Int]
    let timeline: [MacTranscriptDisplayChunkTimelineItem]

    static func group(
        segments: [HerTranscriptSegment],
        speakerKey: (HerTranscriptSegment) -> String
    ) -> [MacTranscriptDisplayChunk] {
        let usableSegments = segments.enumerated().filter { _, segment in
            !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var groups: [[(offset: Int, element: HerTranscriptSegment)]] = []
        var current: [(offset: Int, element: HerTranscriptSegment)] = []

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
            return MacTranscriptDisplayChunk(
                id: "\(startBucket)-\(endBucket)-\(key)",
                start: first.start,
                end: max(first.end, last.end),
                speakerKey: key,
                text: group.map { $0.element.text }.joined(separator: " "),
                segmentIndexes: group.map { $0.offset },
                timeline: group.map { item in
                    MacTranscriptDisplayChunkTimelineItem(
                        start: item.element.start,
                        end: max(item.element.start + 0.1, item.element.end),
                        text: item.element.text
                    )
                }
            )
        }
    }

    private static func shouldStartNewGroup(
        next: HerTranscriptSegment,
        after previous: HerTranscriptSegment,
        current: [HerTranscriptSegment],
        speakerKey: (HerTranscriptSegment) -> String
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

private struct MacTranscriptDisplayChunkTimelineItem: Equatable {
    let start: Double
    let end: Double
    let text: String

    var wordCount: Int {
        TranscriptPlaybackTextToken.wordCount(in: text)
    }
}

private struct TranscriptPlaybackHighlightedText: View {
    let chunk: MacTranscriptDisplayChunk
    @ObservedObject var progress: MacMeetingAudioPlaybackProgress
    let isPlaying: Bool

    var body: some View {
        highlightedText
            .font(.system(size: 18, weight: .regular))
            .lineSpacing(6)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var highlightedText: Text {
        let highlightedCount = highlightedPlaybackWordCount
        var rendered = Text("")
        var wordIndex = 0

        for token in TranscriptPlaybackTextToken.tokenize(chunk.text) {
            if token.isWord {
                let color = wordIndex < highlightedCount ? HerTheme.playbackBlue : HerTheme.ink
                rendered = rendered + Text(token.value).foregroundColor(color)
                wordIndex += 1
            } else {
                rendered = rendered + Text(token.value).foregroundColor(HerTheme.ink)
            }
        }

        return rendered
    }

    private var highlightedPlaybackWordCount: Int {
        let wordCount = TranscriptPlaybackTextToken.wordCount(in: chunk.text)
        guard wordCount > 0 else {
            return 0
        }

        let readableLeadSeconds = isPlaying ? 0.7 : 0
        let targetTime = progress.currentTime + readableLeadSeconds
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

@MainActor
private final class MacMeetingAudioPlaybackProgress: ObservableObject {
    @Published private(set) var currentTime: Double = 0

    func update(_ time: Double) {
        let normalized = time.isFinite ? max(0, time) : 0
        guard abs(normalized - currentTime) >= 0.03 || normalized == 0 else {
            return
        }
        currentTime = normalized
    }
}

private actor MacMeetingAudioCache {
    static let shared = MacMeetingAudioCache()

    private var downloads: [String: Task<URL, Error>] = [:]

    func localAudioURL(for meeting: HerMeeting, remoteURL: URL, authToken: String?) async throws -> URL {
        let localURL = try Self.cacheURL(for: meeting)
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
        if let download = downloads[meeting.id] {
            return try await download.value
        }

        let download = Task<URL, Error> {
            try await Self.downloadAudio(
                for: meeting,
                remoteURL: remoteURL,
                authToken: authToken,
                localURL: localURL
            )
        }
        downloads[meeting.id] = download
        do {
            let fileURL = try await download.value
            downloads[meeting.id] = nil
            return fileURL
        } catch {
            downloads[meeting.id] = nil
            throw error
        }
    }

    private static func cacheURL(for meeting: HerMeeting) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HerMacAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(safeFileName(meeting.id)).m4a")
    }

    private static func downloadAudio(
        for meeting: HerMeeting,
        remoteURL: URL,
        authToken: String?,
        localURL: URL
    ) async throws -> URL {
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        var request = URLRequest(url: remoteURL)
        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw NSError(
                domain: "HerMacAudio",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Audio request failed with \(httpResponse.statusCode)."]
            )
        }
        try data.write(to: localURL, options: .atomic)
        return localURL
    }

    private static func safeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? Character($0).description : "-" }.joined()
    }
}

@MainActor
private final class MacMeetingAudioPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var playbackRate: Double = 1
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasPlaybackPosition = false
    private(set) var currentTime: Double = 0
    let progress = MacMeetingAudioPlaybackProgress()

    private var player: AVAudioPlayer?
    private var loadedMeetingID: String?
    private var stopAt: Double?
    private var timer: Timer?
    private var preloadTask: Task<Void, Never>?

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

    func durationSeconds(for meeting: HerMeeting) -> Double {
        if duration.isFinite, duration > 0 {
            return duration
        }
        return max(0, meeting.durationSeconds ?? 0)
    }

    func preload(for meeting: HerMeeting, audioURL: URL?, authToken: String?) {
        guard canPlay(meeting: meeting, audioURL: audioURL) else {
            return
        }
        guard loadedMeetingID != meeting.id || player == nil else {
            return
        }

        preloadTask?.cancel()
        preloadTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                _ = try await self.preparePlayer(for: meeting, audioURL: audioURL, authToken: authToken)
            } catch is CancellationError {
                return
            } catch {
                self.errorMessage = nil
            }
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

    func toggleFullPlayback(for meeting: HerMeeting, audioURL: URL?, authToken: String?) {
        Task { @MainActor in
            guard canPlay(meeting: meeting, audioURL: audioURL) else {
                errorMessage = "Audio is not available for this conversation."
                return
            }
            if isPlaying && stopAt == nil {
                pause()
                return
            }
            do {
                guard let player = try await preparePlayer(for: meeting, audioURL: audioURL, authToken: authToken) else {
                    return
                }
                stopAt = nil
                if isAtEnd(player) {
                    player.currentTime = 0
                    updateCurrentTime(0)
                }
                hasPlaybackPosition = true
                try play(player)
                isPlaying = true
                startTimer()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func playChunk(
        _ chunk: MacTranscriptDisplayChunk,
        meeting: HerMeeting,
        audioURL: URL?,
        authToken: String?
    ) {
        Task { @MainActor in
            guard canPlay(meeting: meeting, audioURL: audioURL) else {
                errorMessage = "Audio is not available for this conversation."
                return
            }
            do {
                guard let player = try await preparePlayer(for: meeting, audioURL: audioURL, authToken: authToken) else {
                    return
                }
                player.currentTime = max(0, chunk.start)
                updateCurrentTime(player.currentTime)
                hasPlaybackPosition = true
                stopAt = max(chunk.start, chunk.end)
                try play(player)
                isPlaying = true
                startTimer()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func playFrom(_ seconds: Double, meeting: HerMeeting, audioURL: URL?, authToken: String?) {
        Task { @MainActor in
            guard canPlay(meeting: meeting, audioURL: audioURL) else {
                errorMessage = "Audio is not available for this conversation."
                return
            }
            do {
                guard let player = try await preparePlayer(for: meeting, audioURL: audioURL, authToken: authToken) else {
                    return
                }
                player.currentTime = clampedTime(seconds)
                updateCurrentTime(player.currentTime)
                hasPlaybackPosition = true
                stopAt = nil
                try play(player)
                isPlaying = true
                startTimer()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func resumePlayback(for meeting: HerMeeting, audioURL: URL?, authToken: String?) {
        Task { @MainActor in
            guard canPlay(meeting: meeting, audioURL: audioURL) else {
                return
            }
            do {
                guard let player = try await preparePlayer(for: meeting, audioURL: audioURL, authToken: authToken) else {
                    return
                }
                if isAtEnd(player) {
                    player.currentTime = 0
                    updateCurrentTime(0)
                }
                hasPlaybackPosition = true
                try play(player)
                isPlaying = true
                startTimer()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func pausePlayback() {
        pause()
    }

    func skip(by delta: Double, meeting: HerMeeting, audioURL: URL?, authToken: String?) {
        Task { @MainActor in
            guard canPlay(meeting: meeting, audioURL: audioURL) else {
                return
            }
            do {
                guard let player = try await preparePlayer(for: meeting, audioURL: audioURL, authToken: authToken) else {
                    return
                }
                player.currentTime = clampedTime(player.currentTime + delta)
                updateCurrentTime(player.currentTime)
                hasPlaybackPosition = true
                if isPlaying {
                    try play(player)
                    startTimer()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        loadedMeetingID = nil
        stopAt = nil
        preloadTask?.cancel()
        preloadTask = nil
        isPlaying = false
        hasPlaybackPosition = false
        duration = 0
        updateCurrentTime(0)
        stopTimer()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isPlaying = false
            stopAt = nil
            stopTimer()
            updateCurrentTime(player.duration)
        }
    }

    private func canPlay(meeting: HerMeeting, audioURL: URL?) -> Bool {
        meeting.hasAudio && audioURL != nil
    }

    private func preparePlayer(for meeting: HerMeeting, audioURL: URL?, authToken: String?) async throws -> AVAudioPlayer? {
        if loadedMeetingID == meeting.id, let player {
            return player
        }
        guard let audioURL else {
            return nil
        }

        isLoading = true
        defer { isLoading = false }
        let localURL = try await MacMeetingAudioCache.shared.localAudioURL(
            for: meeting,
            remoteURL: audioURL,
            authToken: authToken
        )
        let newPlayer = try AVAudioPlayer(contentsOf: localURL)
        newPlayer.delegate = self
        applyPlaybackRate(to: newPlayer)
        newPlayer.prepareToPlay()
        player = newPlayer
        loadedMeetingID = meeting.id
        duration = newPlayer.duration
        errorMessage = nil
        if !hasPlaybackPosition {
            updateCurrentTime(newPlayer.currentTime)
        }
        return newPlayer
    }

    private func applyPlaybackRate(to player: AVAudioPlayer) {
        player.enableRate = true
        player.rate = Float(playbackRate)
    }

    private func play(_ player: AVAudioPlayer) throws {
        applyPlaybackRate(to: player)
        guard player.play() else {
            throw NSError(
                domain: "HerMacAudio",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Audio playback could not start."]
            )
        }
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        if let player {
            updateCurrentTime(player.currentTime)
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player else {
            stopTimer()
            isPlaying = false
            return
        }
        updateCurrentTime(player.currentTime)
        if let stopAt, player.currentTime >= stopAt {
            player.currentTime = stopAt
            updateCurrentTime(stopAt)
            pause()
        }
    }

    private func updateCurrentTime(_ time: Double) {
        currentTime = max(0, time)
        progress.update(currentTime)
    }

    private func clampedTime(_ seconds: Double) -> Double {
        let upperBound = max(0, duration)
        guard upperBound > 0 else {
            return max(0, seconds)
        }
        return min(max(0, seconds), upperBound)
    }

    private func isAtEnd(_ player: AVAudioPlayer) -> Bool {
        player.duration > 0 && player.currentTime >= max(0, player.duration - 0.15)
    }
}

private enum MacMeetingTimeFormatter {
    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func fullTimestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}

private struct SummaryPanel: View {
    let meeting: HerMeeting

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                MonoLabel("meeting note")
                Text(meeting.title)
                    .font(HerTheme.serif(24, weight: .medium))
                    .lineLimit(2)
                    .lineSpacing(3)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HerTheme.backgroundSoft)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(HerTheme.line, lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 10) {
                MonoLabel("overview")
                Text(meeting.overview)
                    .font(HerTheme.serif(17))
                    .lineSpacing(8)
                    .frame(maxWidth: 760, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 22) {
                BulletPanel(title: "# key topics", items: meeting.keyTopics)
                BulletPanel(title: "# action items", items: meeting.actionItems)
            }

            if !meeting.memoryCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    MonoLabel("added to memory")
                    FlowLayout(items: meeting.memoryCandidates.map { "+ \($0.kind) - \($0.text)" })
                }
            }
        }
    }
}

private struct BulletPanel: View {
    let title: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MonoLabel(title)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                        Text(item)
                            .lineSpacing(4)
                    }
                    .font(HerTheme.serif(14.5))
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(HerTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(HerTheme.lineStrong, lineWidth: 1)
        }
    }
}

private struct ChatPanel: View {
    let meeting: HerMeeting
    @ObservedObject var store: HerMacStore

    @State private var messages: [HerChatMessage] = []
    @State private var draft = ""
    @State private var isLoadingHistory = false
    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if isLoadingHistory {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.7)
                    MonoLabel("loading backend chat", size: 9)
                }
                .padding(.leading, 38)
            } else if messages.isEmpty {
                contextCard
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        ChatMessageBubble(message: message)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(HerTheme.serif(13))
                    .italic()
                    .foregroundStyle(HerTheme.warn)
                    .padding(.leading, 38)
            }

            VStack(alignment: .leading, spacing: 8) {
                MonoLabel("Her suggests")
                HStack(spacing: 8) {
                    ForEach(suggestedPrompts, id: \.self) { prompt in
                        Button {
                            Task {
                                await submit(prompt)
                            }
                        } label: {
                            Text(prompt)
                                .font(HerTheme.serif(12.5))
                                .italic()
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(HerTheme.background)
                                .clipShape(Capsule())
                                .overlay { Capsule().stroke(HerTheme.lineStrong, lineWidth: 1) }
                        }
                        .buttonStyle(.plain)
                        .disabled(isSending)
                    }
                }
            }
            .padding(.leading, 38)

            HStack(spacing: 10) {
                HerMark(size: 20)
                TextField("Ask about this conversation", text: $draft)
                    .textFieldStyle(.plain)
                    .font(HerTheme.serif(14))
                    .onSubmit {
                        Task {
                            await submit(draft)
                        }
                    }
                Spacer()
                MonoLabel("cmd enter", size: 9)
                Button {
                    Task {
                        await submit(draft)
                    }
                } label: {
                    Image(systemName: isSending ? "hourglass" : "paperplane.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(canSubmit ? HerTheme.ink : HerTheme.inkDim))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background(HerTheme.backgroundSoft)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(HerTheme.lineStrong, lineWidth: 1)
            }
        }
        .task(id: meeting.id) {
            await loadMessages()
        }
    }

    private var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private var contextCard: some View {
        HStack(alignment: .top, spacing: 12) {
            HerMark(size: 26)
            VStack(alignment: .leading, spacing: 6) {
                MonoLabel("Her - backend conversation context", size: 9)
                VStack(alignment: .leading, spacing: 12) {
                    Text(meeting.title)
                        .font(HerTheme.serif(16, weight: .semibold))
                    if !meeting.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ChatInfoBlock(title: "Overview", detail: meeting.overview)
                    }
                    if !meeting.actionItems.isEmpty {
                        ChatInfoBlock(title: "Action items", detail: meeting.actionItems.joined(separator: "\n"))
                    }
                    if !meeting.followUps.isEmpty {
                        ChatInfoBlock(title: "Follow-ups", detail: meeting.followUps.joined(separator: "\n"))
                    }
                    if meeting.overview.isEmpty && meeting.actionItems.isEmpty && meeting.followUps.isEmpty {
                        Text("Backend has not produced chat context for this conversation yet.")
                            .font(HerTheme.serif(14))
                            .italic()
                            .foregroundStyle(HerTheme.inkDim)
                    }
                }
                .padding(18)
                .background(HerTheme.backgroundSoft)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(HerTheme.line, lineWidth: 1)
                }
            }
        }
    }

    private var suggestedPrompts: [String] {
        let actionPrompts = meeting.actionItems.prefix(2).map { "follow up: \($0)" }
        let followUpPrompts = meeting.followUps.prefix(2).map { "review: \($0)" }
        let topicPrompts = meeting.keyTopics.prefix(2).map { "ask about: \($0)" }
        let prompts = actionPrompts + followUpPrompts + topicPrompts
        if prompts.isEmpty {
            return ["summarize this backend recording"]
        }
        return Array(prompts.prefix(3))
    }

    @MainActor
    private func loadMessages() async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            messages = try await store.chatMessages(for: meeting)
            errorMessage = nil
        } catch {
            messages = []
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func submit(_ rawQuestion: String) async {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else {
            return
        }

        draft = ""
        errorMessage = nil
        isSending = true
        messages.append(
            HerChatMessage(
                id: "local-user-\(UUID().uuidString)",
                role: "user",
                content: question,
                createdAt: Date()
            )
        )

        do {
            let answer = try await store.ask(question, about: meeting)
            messages.append(
                HerChatMessage(
                    id: "local-assistant-\(UUID().uuidString)",
                    role: "assistant",
                    content: answer,
                    createdAt: Date()
                )
            )
            messages = try await store.chatMessages(for: meeting)
        } catch {
            errorMessage = error.localizedDescription
        }
        isSending = false
    }
}

private struct ChatInfoBlock: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(HerTheme.serif(14.5, weight: .semibold))
            Text(detail)
                .font(HerTheme.serif(14))
                .lineSpacing(4)
        }
    }
}

private struct ChatMessageBubble: View {
    let message: HerChatMessage

    private var isUser: Bool {
        message.role.lowercased() == "user"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isUser {
                Spacer(minLength: 80)
            } else {
                HerMark(size: 24)
            }

            VStack(alignment: .leading, spacing: 6) {
                MonoLabel(isUser ? "you" : "Her", size: 9)
                    .foregroundStyle(isUser ? HerTheme.background.opacity(0.74) : HerTheme.inkDim)
                Text(message.content)
                    .font(HerTheme.serif(15))
                    .lineSpacing(5)
                    .foregroundStyle(isUser ? HerTheme.background : HerTheme.ink)
            }
            .padding(16)
            .background(isUser ? HerTheme.ink : HerTheme.backgroundSoft)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isUser ? HerTheme.ink : HerTheme.lineStrong, lineWidth: 1)
            }
            .frame(maxWidth: 560, alignment: isUser ? .trailing : .leading)

            if !isUser {
                Spacer(minLength: 80)
            }
        }
    }
}

private struct MacMemoryView: View {
    let meetings: [HerMeeting]

    private var candidates: [HerMemoryCandidate] {
        meetings.flatMap(\.memoryCandidates)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MonoLabel("your mind, indexed")
                Text("What I know")
                    .font(HerTheme.display(64))
                    .padding(.top, 10)
                Text("about you.")
                    .font(HerTheme.display(64))
                    .italic()
                Text("\(candidates.count) reviewable candidates from \(meetings.count) saved conversations.")
                    .font(HerTheme.serif(19))
                    .italic()
                    .foregroundStyle(HerTheme.inkSoft)
                    .padding(.top, 12)

                HStack(spacing: 22) {
                    HStack(spacing: 12) {
                        HerMark(size: 20)
                        Text("ask - \"what do you remember?\"")
                            .font(HerTheme.serif(14))
                            .italic()
                            .foregroundStyle(HerTheme.inkDim)
                        Spacer()
                        MonoLabel("cmd k", size: 10)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(HerTheme.backgroundSoft)
                    .clipShape(Capsule())
                    .overlay { Capsule().stroke(HerTheme.lineStrong, lineWidth: 1) }

                    HStack(spacing: 28) {
                        StatBlock(number: "\(candidates.count)", label: "candidates")
                        StatBlock(number: "\(meetings.count)", label: "sources")
                        StatBlock(number: "\(candidates.filter { $0.status.lowercased() == "pending" }.count)", label: "pending")
                    }
                    .padding(18)
                    .background(HerTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(HerTheme.lineStrong, lineWidth: 1)
                    }
                }
                .padding(.top, 28)

                HStack(alignment: .firstTextBaseline) {
                    MonoLabel("recent candidates")
                    Spacer()
                    ForEach(["all", "action", "fact", "person", "place"], id: \.self) { filter in
                        Tag(text: filter, selected: filter == "all")
                    }
                }
                .padding(.top, 36)

                VStack(spacing: 12) {
                    if candidates.isEmpty {
                        Text("Shared backend has no memory candidates for review yet.")
                            .font(HerTheme.serif(15))
                            .italic()
                            .foregroundStyle(HerTheme.inkDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .background(HerTheme.background)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(HerTheme.lineStrong, lineWidth: 1)
                            }
                    } else {
                        ForEach(candidates) { candidate in
                            MemoryCandidateRow(candidate: candidate, meetingTitle: meetingTitle(for: candidate))
                        }
                    }
                }
                .padding(.top, 14)
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 40)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HerTheme.background)
    }

    private func meetingTitle(for candidate: HerMemoryCandidate) -> String {
        meetings.first { $0.id == candidate.meetingId }?.title ?? "source conversation"
    }
}

private struct MemoryCandidateRow: View {
    let candidate: HerMemoryCandidate
    let meetingTitle: String

    var body: some View {
        HStack(spacing: 16) {
            Tag(text: candidate.kindLabel)
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.text)
                    .font(HerTheme.serif(15, weight: .medium))
                    .lineSpacing(4)
                Text("\(meetingTitle) - \(candidate.confidenceText) - \(candidate.sensitivity)")
                    .font(HerTheme.serif(12))
                    .italic()
                    .foregroundStyle(HerTheme.inkDim)
                    .lineLimit(1)
            }
            Spacer()
            Tag(text: "save", selected: true)
            Tag(text: "skip")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(HerTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(HerTheme.lineStrong, lineWidth: 1)
        }
    }
}

private struct MacSettingsView: View {
    @Environment(\.openURL) private var openURL

    let user: HerUser?
    let ownerName: String
    let agentName: String
    let subscription: HerSubscription
    let meetings: [HerMeeting]
    let voiceProfiles: [HerVoiceProfile]
    let loadError: String?
    let onSaveProfile: (String, String) -> Void
    let onRefresh: () async -> Void
    let onRenameVoiceProfile: (HerVoiceProfile, String) async -> Bool
    let onDeleteVoiceProfile: (HerVoiceProfile) async -> Bool
    let onSignOut: () -> Void

    @AppStorage("her.mac.settings.processOnDevice") private var processOnDevice = true
    @AppStorage("her.mac.settings.redactPII") private var redactPII = true
    @AppStorage("her.mac.settings.requireFaceID") private var requireFaceID = false
    @AppStorage("her.mac.settings.silenceTrim") private var silenceTrim = true
    @AppStorage("her.mac.settings.dailySummary") private var dailySummary = true
    @AppStorage("her.mac.settings.followUps") private var followUps = true
    @AppStorage("her.mac.settings.wifiOnly") private var wifiOnly = false
    @AppStorage("her.mac.language") private var selectedLanguage = "system"

    @State private var page: MacSettingsPage = .home
    @State private var showingBilling = false
    @State private var presentingDocument: MacSettingsDocument?
    @State private var editingVoiceProfile: HerVoiceProfile?
    @State private var statusMessage: MacSettingsStatusMessage?

    var body: some View {
        Group {
            switch page {
            case .home:
                settingsHome
            case .backend:
                backendPage
            case .conversations:
                conversationsPage
            case .people:
                peoplePage
            case .memory:
                memoryPage
            case .language:
                languagePage
            case .savedAudio:
                savedAudioPage
            }
        }
        .background(HerTheme.background)
        .sheet(isPresented: $showingBilling) {
            MacBillingSheet(subscription: subscription)
                .frame(width: 520, height: 520)
        }
        .sheet(item: $presentingDocument) { document in
            MacSettingsDocumentSheet(document: document)
                .frame(width: 560, height: 520)
        }
        .sheet(item: $editingVoiceProfile) { profile in
            MacVoiceProfileEditorSheet(
                profile: profile,
                onRename: { name in
                    await onRenameVoiceProfile(profile, name)
                },
                onDelete: {
                    await onDeleteVoiceProfile(profile)
                },
                onRefresh: onRefresh
            )
            .frame(width: 460, height: 320)
        }
        .alert(item: $statusMessage) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.detail),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var settingsHome: some View {
        settingsScroll {
            VStack(alignment: .leading, spacing: 0) {
                MonoLabel("your account")
                Text("Settings.")
                    .font(HerTheme.display(56))
                    .italic()
                    .padding(.top, 10)

                AccountCard(
                    user: user,
                    ownerName: ownerName,
                    agentName: agentName,
                    subscription: subscription,
                    loadError: loadError,
                    onSaveProfile: onSaveProfile
                )
                    .padding(.top, 26)

                SettingsSection(label: "subscription", hint: subscription.plan) {
                    SettingsRow(
                        symbol: "creditcard",
                        title: "Billing",
                        subtitle: billingSubtitle,
                        action: { showingBilling = true },
                        isLast: true
                    )
                }

                SettingsSection(label: "backend", hint: loadError == nil ? "connected" : "auth needed") {
                    SettingsRow(symbol: "server.rack", title: "Shared backend", subtitle: backendSubtitle, action: { page = .backend })
                    SettingsRow(symbol: "person.crop.circle", title: "Account", subtitle: accountSubtitle, action: { page = .backend })
                    SettingsRow(symbol: "clock.arrow.circlepath", title: "Conversations", subtitle: "\(meetings.count) backend records", action: { page = .conversations }, isLast: true)
                }

                SettingsSection(label: "people", hint: "\(voiceProfiles.count) known") {
                    SettingsRow(symbol: "person.2", title: "People", subtitle: peopleSummary, action: { page = .people }, isLast: true)
                }

                SettingsSection(label: "memory & data") {
                    SettingsRow(symbol: "brain.head.profile", title: "What Her knows", subtitle: "\(memoryCandidateCount) reviewable backend candidates", action: { page = .memory })
                    SettingsRow(symbol: "square.and.arrow.up", title: "Export everything", subtitle: "json + backend data archive", action: exportEverything, isLast: true)
                }

                SettingsSection(label: "privacy", hint: "on-device first") {
                    SettingsRow(symbol: "lock", title: "Process on-device", subtitle: "ship to cloud only when you ask", control: .toggle(processOnDevice), action: { processOnDevice.toggle() })
                    SettingsRow(symbol: "shield", title: "Redact PII in cloud", subtitle: "phone numbers, addresses, names", control: .toggle(redactPII), action: { redactPII.toggle() })
                    SettingsRow(symbol: "faceid", title: "Require Face ID", subtitle: "to open conversations", control: .toggle(requireFaceID), action: { requireFaceID.toggle() }, isLast: true)
                }

                SettingsSection(label: "voice & capture") {
                    SettingsRow(symbol: "globe", title: "Language", control: .value(languageTitle), action: { page = .language })
                    SettingsRow(symbol: "waveform", title: "Silence trim", control: .toggle(silenceTrim), action: { silenceTrim.toggle() })
                    SettingsRow(symbol: "waveform.path", title: "Saved audio", subtitle: "\(audioMeetings.count) conversations have audio", action: { page = .savedAudio }, isLast: true)
                }

                SettingsSection(label: "notifications") {
                    SettingsRow(symbol: "sparkles", title: "Daily summary", subtitle: "disabled until backend schedule is connected", control: .toggle(dailySummary), action: { dailySummary.toggle() })
                    SettingsRow(symbol: "pin", title: "Follow-ups", subtitle: "when Her finds an action item", control: .toggle(followUps), action: { followUps.toggle() })
                    SettingsRow(symbol: "wifi", title: "Sync over Wi-Fi only", control: .toggle(wifiOnly), action: { wifiOnly.toggle() }, isLast: true)
                }

                SettingsSection(label: "about") {
                    SettingsRow(symbol: "gearshape", title: "Version", control: .value(appVersion), action: { presentingDocument = .about })
                    SettingsRow(symbol: "shield", title: "Privacy policy", action: { presentingDocument = .privacy })
                    SettingsRow(symbol: "doc.text", title: "Terms of service", action: { presentingDocument = .terms })
                    SettingsRow(symbol: "bubble.left.and.bubble.right", title: "Help & feedback", action: openHelp)
                    SettingsRow(symbol: "curlybraces", title: "Open source licenses", action: { presentingDocument = .licenses }, isLast: true)
                }

                SettingsSection(label: "account") {
                    SettingsRow(
                        symbol: "rectangle.portrait.and.arrow.right",
                        title: "Sign out",
                        subtitle: "clear this Mac session",
                        isDanger: true,
                        action: onSignOut,
                        isLast: true
                    )
                }

                Text("made carefully · almaty · 2026")
                    .font(HerTheme.serif(12))
                    .italic()
                    .foregroundStyle(HerTheme.inkDim)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
            }
        }
    }

    private var backendPage: some View {
        settingsDetailPage(title: "Backend.", eyebrow: "shared account") {
            SettingsSection(label: "connection", hint: loadError == nil ? "connected" : "auth needed") {
                SettingsRow(symbol: "server.rack", title: "Shared backend", subtitle: backendSubtitle, control: .value(loadError == nil ? "ok" : "error"))
                SettingsRow(symbol: "person.crop.circle", title: "Account", subtitle: accountSubtitle, control: .value(user?.provider ?? "none"))
                SettingsRow(symbol: "sparkles", title: "Ask AI", subtitle: subscription.askAiEnabled ? "enabled by subscription" : "disabled by plan", control: .value(subscription.askAiEnabled ? "on" : "off"), isLast: true)
            }
            Button {
                Task { await onRefresh() }
            } label: {
                Text("refresh backend")
                    .font(HerTheme.serif(14, weight: .semibold))
                    .foregroundStyle(HerTheme.background)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(HerTheme.ink)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
        }
    }

    private var conversationsPage: some View {
        settingsDetailPage(title: "Conversations.", eyebrow: "\(meetings.count) backend records") {
            SettingsSection(label: "recent") {
                if meetings.isEmpty {
                    SettingsRow(symbol: "clock.arrow.circlepath", title: "No conversations", subtitle: "backend has no saved meetings", control: .value("empty"), isLast: true)
                } else {
                    ForEach(Array(meetings.prefix(20).enumerated()), id: \.element.id) { index, meeting in
                        SettingsRow(
                            symbol: meeting.hasAudio ? "waveform" : "doc.text",
                            title: meeting.title,
                            subtitle: "\(meeting.dateText) · \(meeting.durationText)",
                            control: .value(meeting.hasAudio ? "audio" : "text"),
                            isLast: index == min(meetings.count, 20) - 1
                        )
                    }
                }
            }
        }
    }

    private var peoplePage: some View {
        settingsDetailPage(title: "People.", eyebrow: "\(voiceProfiles.count) known") {
            SettingsSection(label: "you") {
                SettingsRow(
                    symbol: "person.crop.circle.fill",
                    title: "\(user?.displayName ?? ownerName.nilIfBlank ?? "Owner") (you)",
                    subtitle: accountSubtitle,
                    control: .value("you"),
                    isLast: true
                )
            }
            SettingsSection(label: "recognized speakers", hint: voiceProfiles.isEmpty ? "empty" : "\(voiceProfiles.count) saved") {
                if voiceProfiles.isEmpty {
                    SettingsRow(symbol: "person.2", title: "No other speakers yet", subtitle: "voice profiles will appear here after recordings", control: .value("empty"), isLast: true)
                } else {
                    ForEach(Array(voiceProfiles.enumerated()), id: \.element.id) { index, profile in
                        SettingsRow(
                            symbol: "person.wave.2",
                            title: profile.name,
                            subtitle: voiceProfileSubtitle(for: profile),
                            action: { editingVoiceProfile = profile },
                            isLast: index == voiceProfiles.count - 1
                        )
                    }
                }
            }
        }
        .task {
            await onRefresh()
        }
    }

    private var memoryPage: some View {
        settingsDetailPage(title: "Memory.", eyebrow: "\(memoryCandidateCount) candidates") {
            SettingsSection(label: "reviewable candidates") {
                if memoryCandidates.isEmpty {
                    SettingsRow(symbol: "brain.head.profile", title: "What Her knows", subtitle: "backend memory candidates are empty", control: .value("empty"), isLast: true)
                } else {
                    ForEach(Array(memoryCandidates.prefix(30).enumerated()), id: \.element.id) { index, candidate in
                        SettingsRow(
                            symbol: "brain.head.profile",
                            title: candidate.text,
                            subtitle: "\(candidate.kindLabel) · \(candidate.confidenceText) · \(meetingTitle(for: candidate))",
                            control: .value(candidate.status),
                            isLast: index == min(memoryCandidates.count, 30) - 1
                        )
                    }
                }
            }
        }
    }

    private var languagePage: some View {
        settingsDetailPage(title: "Language.", eyebrow: "voice & capture") {
            SettingsSection(label: "desktop language", hint: languageTitle) {
                ForEach(Array(languageOptions.enumerated()), id: \.element.id) { index, option in
                    SettingsRow(
                        symbol: option.symbol,
                        title: option.title,
                        subtitle: option.subtitle,
                        control: .value(selectedLanguage == option.id ? "selected" : ""),
                        action: { selectedLanguage = option.id },
                        isLast: index == languageOptions.count - 1
                    )
                }
            }
            SettingsSection(label: "backend transcript", hint: primaryLanguage) {
                SettingsRow(symbol: "globe", title: "Detected language", subtitle: "from recent backend meetings", control: .value(primaryLanguage), isLast: true)
            }
        }
    }

    private var savedAudioPage: some View {
        settingsDetailPage(title: "Saved audio.", eyebrow: "\(audioMeetings.count) files") {
            SettingsSection(label: "audio-backed conversations") {
                if audioMeetings.isEmpty {
                    SettingsRow(symbol: "waveform", title: "No saved audio", subtitle: "backend returned no audio-backed conversations", control: .value("empty"), isLast: true)
                } else {
                    ForEach(Array(audioMeetings.enumerated()), id: \.element.id) { index, meeting in
                        SettingsRow(
                            symbol: "waveform",
                            title: meeting.title,
                            subtitle: "\(meeting.dateText) · \(meeting.durationText)",
                            control: .value("cached"),
                            isLast: index == audioMeetings.count - 1
                        )
                    }
                }
            }
        }
    }

    private func settingsScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, 56)
                .padding(.vertical, 40)
                .frame(maxWidth: 960, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsDetailPage<Content: View>(
        title: String,
        eyebrow: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        settingsScroll {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        page = .home
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .overlay(Circle().stroke(HerTheme.lineStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    MonoLabel(eyebrow)
                    Spacer()
                }

                Text(title)
                    .font(HerTheme.display(48))
                    .italic()
                    .padding(.top, 16)

                content()
            }
        }
    }

    private var backendSubtitle: String {
        loadError ?? "http://127.0.0.1:8787 or HER_BACKEND_URL"
    }

    private var billingSubtitle: String {
        if subscription.plan.lowercased() == "free" {
            return "free · \(subscription.limitMinutes) min/mo · Ask AI locked"
        }
        return "\(subscription.plan) · \(subscription.limitMinutes) min/mo · Ask AI"
    }

    private var accountSubtitle: String {
        if let user {
            return user.email ?? user.provider
        }
        return "set HER_AUTH_TOKEN or sign in on this Mac"
    }

    private var voiceProfileSubtitle: String {
        guard !voiceProfiles.isEmpty else {
            return "backend has no saved voice profiles"
        }
        return peopleSummary
    }

    private var peopleSummary: String {
        let speakerCount = voiceProfiles.count
        let suffix = speakerCount == 1 ? "1 recognized speaker" : "\(speakerCount) recognized speakers"
        return "\(user?.displayName ?? ownerName.nilIfBlank ?? "Owner") (you) · \(suffix)"
    }

    private func voiceProfileSubtitle(for profile: HerVoiceProfile) -> String {
        var parts: [String] = []
        if profile.sampleCount > 0 {
            parts.append(profile.sampleCount == 1 ? "1 sample" : "\(profile.sampleCount) samples")
        }
        if let duration = profile.durationSeconds, duration.isFinite, duration > 0 {
            parts.append(String(format: "%.0fs voice", duration))
        }
        return parts.isEmpty ? "recognized speaker" : parts.joined(separator: " · ")
    }

    private var memoryCandidateCount: Int {
        memoryCandidates.count
    }

    private var memoryCandidates: [HerMemoryCandidate] {
        meetings.flatMap(\.memoryCandidates)
    }

    private var audioMeetings: [HerMeeting] {
        meetings.filter(\.hasAudio)
    }

    private var primaryLanguage: String {
        let languages = meetings.compactMap { $0.language?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return languages.first ?? "auto"
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.2"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var languageTitle: String {
        languageOptions.first { $0.id == selectedLanguage }?.title ?? "System"
    }

    private var languageOptions: [MacSettingsLanguageOption] {
        [
            MacSettingsLanguageOption(id: "system", title: "System", subtitle: "use macOS language", symbol: "desktopcomputer"),
            MacSettingsLanguageOption(id: "en", title: "English", subtitle: "desktop UI", symbol: "textformat"),
            MacSettingsLanguageOption(id: "ru", title: "Русский", subtitle: "интерфейс Her", symbol: "textformat"),
            MacSettingsLanguageOption(id: "kk", title: "Қазақша", subtitle: "Her интерфейсі", symbol: "textformat")
        ]
    }

    private func meetingTitle(for candidate: HerMemoryCandidate) -> String {
        meetings.first { $0.id == candidate.meetingId }?.title ?? "source conversation"
    }

    private func openHelp() {
        guard let url = URL(string: "mailto:support@her.local?subject=Her%20macOS%20feedback") else {
            return
        }
        openURL(url) { accepted in
            if !accepted {
                statusMessage = MacSettingsStatusMessage(
                    title: "Help",
                    detail: "Mail could not open. Send feedback to support@her.local."
                )
            }
        }
    }

    private func exportEverything() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "her-export-\(Self.exportDateFormatter.string(from: Date())).json"
        panel.allowedFileTypes = ["json"]
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            do {
                let payload = MacSettingsExportPayload(
                    exportedAt: Date(),
                    user: user.map(MacSettingsExportUser.init(user:)),
                    ownerName: ownerName,
                    agentName: agentName,
                    subscription: subscription,
                    meetings: meetings.map(MacSettingsExportMeeting.init(meeting:)),
                    voiceProfiles: voiceProfiles,
                    settings: MacSettingsExportPreferences(
                        language: selectedLanguage,
                        processOnDevice: processOnDevice,
                        redactPII: redactPII,
                        requireFaceID: requireFaceID,
                        silenceTrim: silenceTrim,
                        dailySummary: dailySummary,
                        followUps: followUps,
                        wifiOnly: wifiOnly
                    )
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(payload)
                try data.write(to: url, options: .atomic)
                statusMessage = MacSettingsStatusMessage(title: "Export saved", detail: url.path)
            } catch {
                statusMessage = MacSettingsStatusMessage(title: "Export failed", detail: error.localizedDescription)
            }
        }
    }

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private enum MacSettingsPage {
    case home
    case backend
    case conversations
    case people
    case memory
    case language
    case savedAudio
}

private struct MacSettingsLanguageOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
}

private struct MacSettingsStatusMessage: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

private enum MacSettingsDocument: String, Identifiable {
    case about
    case privacy
    case terms
    case licenses

    var id: String { rawValue }

    var title: String {
        switch self {
        case .about:
            return "About Her."
        case .privacy:
            return "Privacy policy."
        case .terms:
            return "Terms of service."
        case .licenses:
            return "Open source licenses."
        }
    }

    var eyebrow: String {
        switch self {
        case .about:
            return "macos"
        case .privacy:
            return "privacy"
        case .terms:
            return "legal"
        case .licenses:
            return "licenses"
        }
    }

    var body: String {
        switch self {
        case .about:
            return "Her for macOS shares the same backend account, meetings, subscription state, voice profiles, and memory candidates as the iOS app. This desktop build stores profile display names and UI preferences locally in UserDefaults."
        case .privacy:
            return "Her is on-device first. Recordings and transcripts are processed locally where possible and sent to the shared backend only for authenticated features such as sync, summaries, Ask AI, voice profiles, and export. Do not store secrets in exported archives."
        case .terms:
            return "This development build is for local testing of the Her Apple clients. Backend data, subscriptions, and auth are connected to the same service used by iOS, but production billing, legal text, and cloud-only operation are not final."
        case .licenses:
            return "Her macOS uses SwiftUI, AppKit, AVFoundation, and the local HerShared Swift package. Third-party package notices should be added here when external macOS dependencies are introduced."
        }
    }
}

private struct MacSettingsDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let document: MacSettingsDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    MonoLabel(document.eyebrow)
                    Text(document.title)
                        .font(HerTheme.display(36))
                        .italic()
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .overlay(Circle().stroke(HerTheme.lineStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(24)

            Rectangle().fill(HerTheme.line).frame(height: 1)

            ScrollView {
                Text(document.body)
                    .font(HerTheme.serif(17))
                    .lineSpacing(8)
                    .foregroundStyle(HerTheme.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
        .background(HerTheme.background)
    }
}

private struct MacBillingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let subscription: HerSubscription

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    MonoLabel("billing")
                    Text("Subscription.")
                        .font(HerTheme.display(36))
                        .italic()
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .overlay(Circle().stroke(HerTheme.lineStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(24)

            Rectangle().fill(HerTheme.line).frame(height: 1)

            VStack(alignment: .leading, spacing: 14) {
                MacBillingPlanCard(
                    title: "Free",
                    subtitle: "60 min/mo",
                    isCurrent: subscription.plan.lowercased() == "free",
                    items: ["60 recording minutes per month", "Meeting transcripts and summaries", "Ask AI locked"]
                )
                MacBillingPlanCard(
                    title: "Plus",
                    subtitle: "1200 min/mo · Ask AI",
                    isCurrent: subscription.plan.lowercased() != "free",
                    isEmphasized: true,
                    items: ["1200 recording minutes per month", "Ask AI for every conversation", "App Store subscription billing"]
                )
                Text("Current usage: \(subscription.usedSeconds / 60)m used, \(subscription.remainingMinutesText).")
                    .font(HerTheme.serif(12.5))
                    .italic()
                    .foregroundStyle(HerTheme.inkDim)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(24)
        }
        .background(HerTheme.background)
    }
}

private struct MacBillingPlanCard: View {
    let title: String
    let subtitle: String
    let isCurrent: Bool
    var isEmphasized = false
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(HerTheme.serif(21, weight: .medium))
                Spacer()
                if isCurrent {
                    MonoLabel("current", size: 9)
                }
            }
            Text(subtitle)
                .font(HerTheme.serif(13))
                .italic()
                .foregroundStyle(HerTheme.inkDim)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                    Text(item)
                }
                .font(HerTheme.serif(13))
                .foregroundStyle(HerTheme.inkSoft)
            }
        }
        .padding(18)
        .background(isEmphasized ? HerTheme.backgroundSoft : HerTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isCurrent ? HerTheme.ink : HerTheme.lineStrong, lineWidth: isCurrent ? 1.5 : 1)
        }
    }
}

private struct MacVoiceProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: HerVoiceProfile
    let onRename: (String) async -> Bool
    let onDelete: () async -> Bool
    let onRefresh: () async -> Void

    @State private var draftName = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    MonoLabel("person")
                    Text(profile.name)
                        .font(HerTheme.display(30))
                        .italic()
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .overlay(Circle().stroke(HerTheme.lineStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            SettingsProfileField(label: "name", text: $draftName)

            if let errorMessage {
                Text(errorMessage)
                    .font(HerTheme.serif(12))
                    .italic()
                    .foregroundStyle(HerTheme.warn)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await saveName() }
                } label: {
                    Text(isWorking ? "saving..." : "rename")
                        .font(HerTheme.serif(13, weight: .semibold))
                        .foregroundStyle(HerTheme.background)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(HerTheme.ink)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isWorking || trimmedDraftName.isEmpty || trimmedDraftName == profile.name)
                .opacity(isWorking || trimmedDraftName.isEmpty || trimmedDraftName == profile.name ? 0.45 : 1)

                Button(role: .destructive) {
                    Task { await deleteProfile() }
                } label: {
                    Text("delete")
                        .font(HerTheme.serif(13, weight: .medium))
                        .foregroundStyle(HerTheme.danger)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .overlay { Capsule().stroke(HerTheme.lineStrong, lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .disabled(isWorking)

                Spacer()
            }
        }
        .padding(24)
        .background(HerTheme.background)
        .onAppear {
            draftName = profile.name
        }
    }

    private var trimmedDraftName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveName() async {
        isWorking = true
        defer { isWorking = false }
        if await onRename(trimmedDraftName) {
            await onRefresh()
            dismiss()
        } else {
            errorMessage = "Rename failed. Check backend auth and try again."
        }
    }

    private func deleteProfile() async {
        isWorking = true
        defer { isWorking = false }
        if await onDelete() {
            await onRefresh()
            dismiss()
        } else {
            errorMessage = "Delete failed. Check backend auth and try again."
        }
    }
}

private struct MacSettingsExportPayload: Encodable {
    let exportedAt: Date
    let user: MacSettingsExportUser?
    let ownerName: String
    let agentName: String
    let subscription: HerSubscription
    let meetings: [MacSettingsExportMeeting]
    let voiceProfiles: [HerVoiceProfile]
    let settings: MacSettingsExportPreferences
}

private struct MacSettingsExportUser: Encodable {
    let id: String
    let provider: String
    let email: String?
    let name: String?

    init(user: HerUser) {
        id = user.id
        provider = user.provider
        email = user.email
        name = user.name
    }
}

private struct MacSettingsExportMeeting: Encodable {
    let id: String
    let title: String
    let overview: String
    let transcript: String
    let segments: [HerTranscriptSegment]
    let keyTopics: [String]
    let decisions: [String]
    let actionItems: [String]
    let followUps: [String]
    let outline: [HerOutlineItem]
    let memoryCandidates: [HerMemoryCandidate]
    let language: String?
    let durationSeconds: Double?
    let source: String?
    let deviceName: String?
    let locationName: String?
    let hasAudio: Bool
    let createdAt: Date
    let generatedAt: Date?
    let summaryStatus: String?
    let summaryMode: String?

    init(meeting: HerMeeting) {
        id = meeting.id
        title = meeting.title
        overview = meeting.overview
        transcript = meeting.transcript
        segments = meeting.segments
        keyTopics = meeting.keyTopics
        decisions = meeting.decisions
        actionItems = meeting.actionItems
        followUps = meeting.followUps
        outline = meeting.outline
        memoryCandidates = meeting.memoryCandidates
        language = meeting.language
        durationSeconds = meeting.durationSeconds
        source = meeting.source
        deviceName = meeting.deviceName
        locationName = meeting.locationName
        hasAudio = meeting.hasAudio
        createdAt = meeting.createdAt
        generatedAt = meeting.generatedAt
        summaryStatus = meeting.summaryStatus
        summaryMode = meeting.summaryMode
    }
}

private struct MacSettingsExportPreferences: Encodable {
    let language: String
    let processOnDevice: Bool
    let redactPII: Bool
    let requireFaceID: Bool
    let silenceTrim: Bool
    let dailySummary: Bool
    let followUps: Bool
    let wifiOnly: Bool
}

private struct AccountCard: View {
    let user: HerUser?
    let ownerName: String
    let agentName: String
    let subscription: HerSubscription
    let loadError: String?
    let onSaveProfile: (String, String) -> Void

    @State private var isEditing = false
    @State private var draftOwnerName = ""
    @State private var draftAgentName = ""

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 16) {
                Text(accountInitial)
                    .font(HerTheme.serif(26, weight: .medium))
                    .italic()
                    .foregroundStyle(HerTheme.background)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(HerTheme.ink))
                VStack(alignment: .leading, spacing: 3) {
                    Text(user?.displayName ?? "Not signed in")
                        .font(HerTheme.serif(22, weight: .medium))
                    MonoLabel(accountStatus, size: 11)
                }
                Spacer()
                Button {
                    if isEditing {
                        isEditing = false
                    } else {
                        resetDrafts()
                        isEditing = true
                    }
                } label: {
                    HeaderButton(isEditing ? "close" : "edit")
                }
                .buttonStyle(.plain)
            }

            if isEditing {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsProfileField(label: "your name", text: $draftOwnerName)
                    SettingsProfileField(label: "agent name", text: $draftAgentName)

                    HStack(spacing: 10) {
                        Button {
                            onSaveProfile(draftOwnerName, draftAgentName)
                            isEditing = false
                        } label: {
                            Text("save")
                                .font(HerTheme.serif(13, weight: .semibold))
                                .foregroundStyle(HerTheme.background)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(HerTheme.ink)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(draftOwnerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(draftOwnerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)

                        Button {
                            resetDrafts()
                            isEditing = false
                        } label: {
                            Text("cancel")
                                .font(HerTheme.serif(13, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .overlay { Capsule().stroke(HerTheme.lineStrong, lineWidth: 1) }
                        }
                        .buttonStyle(.plain)

                        Spacer()
                        MonoLabel("local userdefaults", size: 9)
                    }
                }
                .padding(.top, 2)
            }

            HStack(spacing: 18) {
                AccountStat(label: "plan", value: subscription.plan)
                AccountStat(label: "storage", value: "local")
                AccountStat(label: "ask ai", value: subscription.askAiEnabled ? "on" : "off")
            }
            .padding(.top, 18)
            .overlay(alignment: .top) {
                Rectangle().fill(HerTheme.line).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 7) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(HerTheme.backgroundDeep)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(HerTheme.ink)
                            .frame(width: max(12, proxy.size.width * usageRatio))
                    }
                }
                .frame(height: 4)

                HStack {
                    MonoLabel("\(subscription.limitSeconds / 60) min / mo", size: 10)
                    Spacer()
                    Text(subscription.remainingMinutesText)
                        .font(HerTheme.serif(12))
                        .italic()
                }
            }
        }
        .padding(24)
        .background(HerTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(HerTheme.lineStrong, lineWidth: 1)
        }
        .onAppear(perform: resetDrafts)
    }

    private var usageRatio: Double {
        guard subscription.limitSeconds > 0 else { return 0 }
        return min(1, max(0.02, Double(subscription.usedSeconds) / Double(subscription.limitSeconds)))
    }

    private var accountInitial: String {
        String((user?.displayName ?? "H").prefix(1)).uppercased()
    }

    private var accountStatus: String {
        if let email = user?.email, !email.isEmpty {
            return email
        }
        if let user {
            return user.provider
        }
        return loadError ?? "backend auth required"
    }

    private func resetDrafts() {
        let savedOwnerName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        draftOwnerName = savedOwnerName.isEmpty ? (user?.displayName ?? "") : savedOwnerName
        draftAgentName = HerMacProfileDefaults.clean(
            agentName,
            fallback: HerMacProfileDefaults.fallbackAgentName
        )
    }
}

private struct SettingsProfileField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            MonoLabel(label, size: 9)
            TextField(label, text: $text)
                .textFieldStyle(.plain)
                .font(HerTheme.serif(16, weight: .medium))
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(HerTheme.backgroundSoft)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(HerTheme.lineStrong, lineWidth: 1)
                }
        }
    }
}

private struct AccountStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            MonoLabel(label)
            Text(value)
                .font(HerTheme.serif(17, weight: .medium))
                .italic()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum SettingsControl {
    case chevron
    case toggle(Bool)
    case value(String)
}

private struct SettingsSection<Content: View>: View {
    let label: String
    let hint: String?
    @ViewBuilder let content: Content

    init(label: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                MonoLabel(label)
                Spacer()
                if let hint {
                    Text(hint)
                        .font(HerTheme.serif(13))
                        .italic()
                        .foregroundStyle(HerTheme.inkSoft)
                }
            }
            VStack(spacing: 0) {
                content
            }
            .background(HerTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(HerTheme.lineStrong, lineWidth: 1)
            }
        }
        .padding(.top, 28)
    }
}

private struct SettingsRow: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var control: SettingsControl = .chevron
    var isDanger = false
    var action: (() -> Void)?
    var isLast = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(HerTheme.line).frame(height: 1)
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isDanger ? HerTheme.danger : HerTheme.ink)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(HerTheme.serif(15, weight: .medium))
                    .foregroundStyle(isDanger ? HerTheme.danger : HerTheme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(HerTheme.serif(12))
                        .italic()
                        .foregroundStyle(HerTheme.inkDim)
                }
            }
            Spacer()
            controlView
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var controlView: some View {
        switch control {
        case .chevron:
            Text("->")
                .font(HerTheme.serif(14))
                .foregroundStyle(HerTheme.inkDim)
        case let .toggle(on):
            ToggleCapsule(isOn: on)
        case let .value(value):
            HStack(spacing: 6) {
                MonoLabel(value, size: 11)
                Text("->")
                    .font(HerTheme.serif(14))
                    .foregroundStyle(HerTheme.inkDim)
            }
        }
    }
}

private struct ToggleCapsule: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? HerTheme.ink : HerTheme.backgroundDeep)
            Circle()
                .fill(HerTheme.background)
                .frame(width: 20, height: 20)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                .padding(2)
        }
        .frame(width: 42, height: 24)
    }
}

private struct FlowLayout: View {
    let items: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items.prefix(5), id: \.self) { item in
                Text(item)
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(HerTheme.background)
                    .clipShape(Capsule())
                    .overlay { Capsule().stroke(HerTheme.lineStrong, lineWidth: 1) }
            }
        }
    }
}

private struct StatusPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .regular, design: .monospaced))
        .foregroundStyle(HerTheme.inkSoft)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(HerTheme.backgroundSoft)
        .clipShape(Capsule())
        .overlay { Capsule().stroke(HerTheme.lineStrong, lineWidth: 1) }
    }
}

private struct HeaderButton: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .padding(.horizontal, title == "..." ? 8 : 12)
            .padding(.vertical, 5)
            .overlay { Capsule().stroke(HerTheme.lineStrong, lineWidth: 1) }
    }
}

private struct ToolbarPillButton: View {
    let title: String
    let systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Button {} label: {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18)
                } else {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(HerTheme.ink)
            .padding(.horizontal, systemImage == nil ? 12 : 8)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(HerTheme.background.opacity(0.82))
        .clipShape(Capsule())
        .overlay { Capsule().stroke(HerTheme.lineStrong, lineWidth: 1) }
    }
}

private struct Tag: View {
    let text: String
    var selected = false

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
            .textCase(.uppercase)
            .foregroundStyle(selected ? HerTheme.background : HerTheme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? HerTheme.ink : HerTheme.background)
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(selected ? HerTheme.ink : HerTheme.lineStrong, lineWidth: 1)
            }
    }
}

private struct StatBlock: View {
    let number: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(number)
                .font(HerTheme.serif(32, weight: .medium))
            MonoLabel(label)
        }
    }
}

private struct MonoLabel: View {
    let text: String
    let size: CGFloat

    init(_ text: String, size: CGFloat = 10) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .regular, design: .monospaced))
            .tracking(size > 9 ? 1.5 : 0.8)
            .foregroundStyle(HerTheme.inkDim)
    }
}

private struct HerMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(HerTheme.ink, lineWidth: max(0.75, size * 0.045))
            Circle()
                .stroke(HerTheme.ink, lineWidth: max(0.6, size * 0.035))
                .padding(size * 0.18)
            Circle()
                .fill(HerTheme.ink)
                .padding(size * 0.39)
        }
        .frame(width: size, height: size)
    }
}

private enum HerTheme {
    static let textScale: CGFloat = 0.9
    static let displayScale: CGFloat = 0.78
    static let background = Color.white
    static let backgroundSoft = Color(hex: 0xfafaf8)
    static let backgroundDeep = Color(hex: 0xf3f2ee)
    static let ink = Color(hex: 0x0f0f0f)
    static let inkSoft = Color(hex: 0x3a3a3a)
    static let inkDim = Color(hex: 0x7a7a7a)
    static let coral = Color(hex: 0xc1573d)
    static let danger = Color(hex: 0xa00000)
    static let success = Color(hex: 0x2f6b2f)
    static let warn = Color(hex: 0xa06a00)
    static let playbackBlue = Color(hex: 0x1c5cff)
    static let line = Color.black.opacity(0.08)
    static let lineStrong = Color.black.opacity(0.18)

    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * textScale, weight: weight, design: .serif)
    }

    static func display(_ size: CGFloat) -> Font {
        .system(size: size * displayScale, weight: .medium, design: .serif)
    }
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xff) / 255
        let green = Double((hex >> 8) & 0xff) / 255
        let blue = Double(hex & 0xff) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
