import SwiftUI

@main
struct ShellApp: App {
    var body: some Scene {
        WindowGroup {
            // No `preferredColorScheme` here: ShellRootView applies whichever scheme the user's
            // saved theme selects, so forcing one at the scene level would override the toggle.
            ShellRootView()
        }
        .windowStyle(.hiddenTitleBar)
        // Ties the window's resize floor to the content's declared minimum, alongside the
        // NSWindow.minSize that WindowSizing pins directly.
        .windowResizability(.contentMinSize)
    }
}
