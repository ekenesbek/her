import Foundation

#if canImport(AppIntents)
import AppIntents

extension Notification.Name {
    static let herStartRecordingRequested = Notification.Name("her.recording.startRequested")
    static let herStopRecordingRequested = Notification.Name("her.recording.stopRequested")
    static let herToggleRecordingRequested = Notification.Name("her.recording.toggleRequested")
}

@available(iOS 16.0, *)
struct StartHerRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Her recording"
    static var description = IntentDescription("Begin recording a conversation in Her.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            NotificationCenter.default.post(name: .herStartRecordingRequested, object: nil)
        }
        return .result(dialog: "Started recording.")
    }
}

@available(iOS 16.0, *)
struct StopHerRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Her recording"
    static var description = IntentDescription("Stop the ongoing Her recording and queue transcription.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            NotificationCenter.default.post(name: .herStopRecordingRequested, object: nil)
        }
        return .result(dialog: "Stopping recording.")
    }
}

@available(iOS 16.0, *)
struct ToggleHerRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Her recording"
    static var description = IntentDescription("Start or stop a Her recording — handy for the Action Button.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            NotificationCenter.default.post(name: .herToggleRecordingRequested, object: nil)
        }
        return .result(dialog: "Toggling recording.")
    }
}

@available(iOS 16.0, *)
struct HerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartHerRecordingIntent(),
            phrases: [
                "Start \(.applicationName) recording",
                "Begin \(.applicationName) recording",
                "Record with \(.applicationName)",
                "Запиши \(.applicationName)",
                "Начни запись \(.applicationName)"
            ],
            shortTitle: "Start recording",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopHerRecordingIntent(),
            phrases: [
                "Stop \(.applicationName) recording",
                "End \(.applicationName) recording",
                "Останови \(.applicationName)",
                "Заверши запись \(.applicationName)"
            ],
            shortTitle: "Stop recording",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: ToggleHerRecordingIntent(),
            phrases: [
                "Toggle \(.applicationName)",
                "\(.applicationName) toggle",
                "Переключи \(.applicationName)"
            ],
            shortTitle: "Toggle recording",
            systemImageName: "record.circle"
        )
    }
}
#endif
