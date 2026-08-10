import AppKit
import HudsonUI
import Store
import SwiftUI

/// A SwiftPM-built executable launches as a background/accessory process by
/// default (no Dock icon, no key window). This delegate promotes it to a
/// regular foreground app on launch so `swift run HudsonApp` shows a real,
/// focusable window we can screenshot — the fidelity gate for the design. A
/// notarized `.app` bundle (which gets this for free from its Info.plist) is a
/// later distribution concern.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct HudsonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// `--demo` (or `HUDSON_DEMO=1`) opens a throwaway demo database instead of
    /// the real mailbox — used for screenshots and manual QA without exposing
    /// real mail. The demo DB is seeded in Task 5; until then this resolves to a
    /// temp path that simply opens empty.
    private var databaseURL: URL {
        let demo = CommandLine.arguments.contains("--demo")
            || ProcessInfo.processInfo.environment["HUDSON_DEMO"] == "1"
        return demo
            ? FileManager.default.temporaryDirectory.appending(path: "hudson-demo.sqlite")
            : HudsonDatabase.defaultDatabaseURL
    }

    var body: some Scene {
        WindowGroup {
            RootView(databaseURL: databaseURL)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
