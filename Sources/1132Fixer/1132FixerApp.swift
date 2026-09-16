import SwiftUI
import AppKit

@main
struct Fixer1132App: App {
    init() {
        // SwiftPM executables are not app bundles and have no main bundle ID.
        // Disable automatic tabbing so AppKit does not try to index tabs by bundle identifier.
        NSWindow.allowsAutomaticWindowTabbing = false

        // Avoid Bundle.module here: if the SwiftPM resource bundle is missing in a packaged app,
        // Bundle.module can trap during startup and crash the app.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }
    }

    var body: some Scene {
        WindowGroup("1132 Fixer") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
