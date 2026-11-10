import AppKit
import SwiftUI

/// Hands back the NSWindow a view lives in.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
    }
}

/// The separate player window (Infuse-style). It shows whatever is playing and closes
/// itself when playback ends; closing it stops playback.
struct PlayerWindowContent: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZStack {
            Color.black
            if let request = app.playback {
                PlayerView(request: request).id(request.id)
            }
            if let status = app.playStatus, app.playback != nil {
                PlayStatusPanel(status: status)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 30)
                    .zIndex(5)
            }
        }
        .frame(minWidth: 480, minHeight: 270)
        .preferredColorScheme(.dark)
        .foregroundStyle(Theme.textPrimary)
        .ignoresSafeArea()
        .background(PlayerWindowConfigurator())
        .onAppear { if app.playback == nil { dismissWindow(id: "player") } }
        .onChange(of: app.playback == nil) { _, ended in if ended { dismissWindow(id: "player") } }
        .onDisappear { app.playback = nil } // red close button
    }
}

/// Sets up the player window for real full screen and keeps it that way. AppKit rebuilds
/// the title-bar buttons and SwiftUI resets the window's full-screen behavior when the
/// window leaves full screen, so this re-applies everything after each change instead of
/// once (which only made the green button work the first time).
struct PlayerWindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Attaches when the view actually lands in its window. (Doing it from updateNSView
    /// depended on SwiftUI redrawing this view after the window existed, which stopped
    /// happening once the player redrew less, and the green button went back to "zoom".)
    final class WindowWatcher: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowWatcher()
        let coordinator = context.coordinator
        view.onWindow = { w in MainActor.assumeIsolated { coordinator.attach(w) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let w = view.window { context.coordinator.attach(w) }
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        func attach(_ w: NSWindow) {
            configure(w)
            guard window !== w else { return }
            window = w
            observers.forEach(NotificationCenter.default.removeObserver)
            let names: [Notification.Name] = [
                NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let w = self.window else { return }
                        self.configure(w)
                        // The exit animation swaps the buttons in late; catch the final ones too.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                            if let w = self?.window { self?.configure(w) }
                        }
                    }
                }
            }
        }

        private func configure(_ w: NSWindow) {
            w.backgroundColor = .black
            w.isMovableByWindowBackground = true
            w.titlebarAppearsTransparent = true
            fixBehavior(w)
            if let green = w.standardWindowButton(.zoomButton) {
                green.target = self
                green.action = #selector(toggle(_:))
                green.isEnabled = true
            }
        }

        /// SwiftUI marks single-instance windows full-screen *auxiliary*; with that set,
        /// macOS just fills the screen instead of giving the player its own space.
        private func fixBehavior(_ w: NSWindow) {
            w.collectionBehavior.remove(.fullScreenAuxiliary)
            w.collectionBehavior.remove(.fullScreenNone)
            w.collectionBehavior.insert(.fullScreenPrimary)
        }

        @objc func toggle(_ sender: Any?) {
            guard let w = window else { return }
            fixBehavior(w)
            w.makeKeyAndOrderFront(nil)
            w.toggleFullScreen(nil)
        }
    }
}
