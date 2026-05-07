import SwiftUI

@main
struct ConversationSummarizerApp: App {
    @StateObject private var wearablesBridge = WearablesBridge()

    var body: some Scene {
        WindowGroup {
            RootView(wearablesBridge: wearablesBridge)
                .onOpenURL { url in
                    Task {
                        await wearablesBridge.handleCallback(url: url)
                    }
                }
        }
    }
}
