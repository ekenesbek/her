import Foundation

#if canImport(AppIntents)
import AppIntents

extension Notification.Name {
    static let metaStartRecordingRequested = Notification.Name("meta.recording.startRequested")
    static let metaStopRecordingRequested = Notification.Name("meta.recording.stopRequested")
    static let metaToggleRecordingRequested = Notification.Name("meta.recording.toggleRequested")
}

@available(iOS 16.0, *)
struct StartMetaRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start meta recording"
    static var description = IntentDescription("Begin recording a conversation in meta.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            NotificationCenter.default.post(name: .metaStartRecordingRequested, object: nil)
        }
        return .result(dialog: "Started recording.")
    }
}

@available(iOS 16.0, *)
struct StopMetaRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop meta recording"
    static var description = IntentDescription("Stop the ongoing meta recording and queue transcription.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            NotificationCenter.default.post(name: .metaStopRecordingRequested, object: nil)
        }
        return .result(dialog: "Stopping recording.")
    }
}

@available(iOS 16.0, *)
struct ToggleMetaRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle meta recording"
    static var description = IntentDescription("Start or stop a meta recording — handy for the Action Button.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            NotificationCenter.default.post(name: .metaToggleRecordingRequested, object: nil)
        }
        return .result(dialog: "Toggling recording.")
    }
}

@available(iOS 16.0, *)
struct MetaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartMetaRecordingIntent(),
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
            intent: StopMetaRecordingIntent(),
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
            intent: ToggleMetaRecordingIntent(),
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
