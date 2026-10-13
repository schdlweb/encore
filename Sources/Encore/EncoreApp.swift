import AppKit
import SwiftUI

@main
struct EncoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()

    init() {
        // Artwork is fetched constantly; keep plenty of it on disk.
        URLCache.shared = URLCache(memoryCapacity: 256 << 20, diskCapacity: 2 << 30)
    }

    var body: some Scene {
        WindowGroup("Encore") {
            RootView()
                .environment(app)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear { DebugHooks.install(app: app) }
                .task {
                    // Quietly look for a new version a few seconds after launch.
                    guard app.settings.autoUpdateCheck, ProcessInfo.processInfo.environment["ENCORE_ROUTE"] == nil else { return }
                    try? await Task.sleep(for: .seconds(6))
                    await app.updater.check()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await app.updater.check(userInitiated: true) } }
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Go") {
                Button("Home") { app.tab = .home }.keyboardShortcut("1")
                Button("Library") { app.tab = .library }.keyboardShortcut("2")
                Button("Search") { app.tab = .search }.keyboardShortcut("f")
                Button("Settings") { app.tab = .settings }.keyboardShortcut(",")
                Divider()
                Button("Reload Addon") { Task { await app.connect() } }.keyboardShortcut("r")
                Divider()
                Button("Show Player") { showPlayerWindow() }.keyboardShortcut("0")
                    .disabled(app.playback == nil)
            }
        }

        // Infuse-style player window; it closes itself if reopened with nothing playing.
        Window("Player", id: "player") {
            PlayerWindowContent().environment(app)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        .defaultPosition(.center)
        .commandsRemoved()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare binary rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { ScrollActivity.install() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Clicking the Dock icon while something plays brings the player forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        let hasPlayer = sender.windows.contains { $0.title == "Player" && ($0.isVisible || $0.isMiniaturized) }
        guard hasPlayer else { return true }
        MainActor.assumeIsolated { showPlayerWindow() }
        return false
    }
}
