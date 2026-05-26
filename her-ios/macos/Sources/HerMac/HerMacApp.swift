import AppKit
import SwiftUI

@main
struct HerMacApp: App {
    @NSApplicationDelegateAdaptor(HerMacAppDelegate.self) private var appDelegate
    @StateObject private var store = HerMacStore()

    var body: some Scene {
        WindowGroup {
            HerMacRootView(store: store)
                .frame(minWidth: 1120, minHeight: 720)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))

        Settings {
            HerMacSettingsScene(store: store)
                .preferredColorScheme(.light)
        }
    }
}

final class HerMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
