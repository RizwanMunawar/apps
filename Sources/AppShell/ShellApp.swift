import SwiftUI

@main
struct ShellApp: App {
    var body: some Scene {
        WindowGroup {
            ShellRootView()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
