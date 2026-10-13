import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var app = app
        ZStack {
            AmbientBackground(image: app.ambientImage)

            if app.manifest == nil && app.connection != .loaded {
                if app.settings.manifestURL.isEmpty || app.connection != .loading {
                    OnboardingView()
                } else {
                    ProgressView("Connecting to your addon…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // The tab stays alive under any pushed page, so its scroll position survives.
                tabContent
                    .opacity(app.routes.isEmpty ? 1 : 0)
                    .allowsHitTesting(app.routes.isEmpty)

                if let route = app.routes.last {
                    Group {
                        switch route {
                        case .detail(let meta): DetailView(preview: meta)
                        case .catalog(let def): CatalogGridView(def: def)
                        case .person(let member, let context): PersonView(member: member, context: context)
                        }
                    }
                    .id(route)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }

                if app.routes.isEmpty {
                    VStack {
                        NavBar()
                        Spacer()
                    }
                    .padding(.top, 14)
                    .transition(.opacity)
                }
            }

            if let request = app.playback, !app.settings.playerInWindow {
                PlayerView(request: request)
                    .id(request.id)
                    .transition(.opacity)
                    .zIndex(10)
            }

            if let release = app.updater.availableRelease, app.updater.dismissedVersion != release.version {
                UpdateBanner(release: release)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(13)
            }
            if case .downloading(let f) = app.updater.state {
                UpdateProgress(text: "Downloading update… \(Int(f * 100))%", fraction: f)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(20).zIndex(13)
            } else if app.updater.state == .installing {
                UpdateProgress(text: "Installing update…", fraction: nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(20).zIndex(13)
            }

            if !app.downloads.items.isEmpty {
                DownloadsPanel()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(20)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(12)
            }

            if let t = app.trailer {
                TrailerOverlay(youTubeId: t.youTubeId, title: t.title)
                    .transition(.opacity)
                    .zIndex(15)
            }

            // In window mode, a status for the next episode shows in the player window instead.
            if let status = app.playStatus, !(app.settings.playerInWindow && app.playback != nil) {
                PlayStatusPanel(status: status)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .sheet(item: $app.picker) { StreamPicker(target: $0) }
        .onChange(of: app.playback?.id) { _, id in
            if id != nil, app.settings.playerInWindow { openWindow(id: "player") }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.playStatus)
        .animation(.easeInOut(duration: 0.25), value: app.trailer)
        .animation(.easeInOut(duration: 0.25), value: app.routes)
        .animation(.easeInOut(duration: 0.3), value: app.playback?.id)
        .foregroundStyle(Theme.textPrimary)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var tabContent: some View {
        switch app.tab {
        case .home: HomeView()
        case .library: LibraryView()
        case .search: SearchView()
        case .settings: SettingsView()
        }
    }
}

struct NavBar: View {
    @Environment(AppState.self) private var app
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { app.tab = tab }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.icon).font(.system(size: 14, weight: .semibold))
                        Text(tab.rawValue).font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background {
                        if app.tab == tab {
                            Capsule().fill(Color.white.opacity(0.18)).matchedGeometryEffect(id: "sel", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            // Something is playing in the player window: one click back to it.
            if let playing = app.playback, app.settings.playerInWindow {
                Button { showPlayerWindow() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "play.rectangle.fill").font(.system(size: 13, weight: .semibold))
                        Text(playing.meta.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                    .frame(maxWidth: 220)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Theme.accent.opacity(0.28)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Show the player (⌘0)")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.playback?.id)
        .padding(5)
        .glass(tint: .black.opacity(0.2))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
    }
}

/// Bottom panel showing a title being started: which stream is being checked,
/// or why none worked.
struct PlayStatusPanel: View {
    let status: PlayStatus
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            RemoteImage(url: status.video?.thumbnail ?? status.meta.background ?? status.meta.poster, maxPixel: 300)
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                Text(status.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if status.phase == .working {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text(status.message).font(.system(size: 15, weight: .semibold))
                }
                if let d = status.detail {
                    Text(d).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                if status.phase == .failed, !status.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(status.failures.prefix(4), id: \.self) { f in
                            Text("• " + f).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                if status.phase == .failed {
                    Button("Choose Stream…") {
                        let target = PickerTarget(meta: status.meta, video: status.video)
                        app.cancelPlay()
                        app.picker = target
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    Button("Dismiss") { app.cancelPlay() }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Cancel") { app.cancelPlay() }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(16)
        .frame(width: 640)
        .glass(cornerRadius: 20, tint: .black.opacity(0.45))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
    }
}

/// Downloads in progress or just finished, in the bottom-right corner.
struct DownloadsPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(app.downloads.items.prefix(4)) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if case .finished(let url) = item.state {
                            Button { app.downloads.reveal(url) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.plain).help("Show in Finder")
                        }
                        Button { app.downloads.dismiss(item.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .help(item.state == .downloading || item.state == .checking ? "Cancel download" : "Dismiss")
                    }
                    switch item.state {
                    case .checking:
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                        caption("Checking the stream…")
                    case .downloading:
                        ProgressView(value: item.fraction).progressViewStyle(.linear).controlSize(.small)
                        caption(item.total > 0
                                ? "\(bytes(item.received)) of \(bytes(item.total)) · \(Int(item.fraction * 100))%"
                                : bytes(item.received))
                    case .finished:
                        caption("Saved to Downloads")
                    case .failed(let reason):
                        caption("Failed: \(reason)")
                    case .cancelled:
                        caption("Cancelled")
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 330)
        .glass(cornerRadius: 14, tint: .black.opacity(0.45))
        .animation(.easeInOut(duration: 0.2), value: app.downloads.items.map(\.id))
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

/// Brings the player window to the front (and un-minimizes it), if one is open.
@MainActor
func showPlayerWindow() {
    guard let w = NSApp.windows.first(where: { $0.title == "Player" && ($0.isVisible || $0.isMiniaturized) }) else { return }
    if w.isMiniaturized { w.deminiaturize(nil) }
    w.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}

/// "Encore 1.1.0 is available", with what's new and one-click install.
struct UpdateBanner: View {
    let release: Updater.Release
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                Text("Encore \(release.version) is available").font(.system(size: 13, weight: .semibold))
            }
            if !release.notes.isEmpty {
                Text(release.notes)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(4)
            }
            HStack(spacing: 8) {
                Button("Install & Relaunch") { Task { await app.updater.install(release) } }
                    .buttonStyle(PillButtonStyle(kind: .primary)).controlSize(.small)
                Button("Later") { app.updater.dismissedVersion = release.version }
                    .buttonStyle(PillButtonStyle()).controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .glass(cornerRadius: 14, tint: .black.opacity(0.45))
    }
}

private struct UpdateProgress: View {
    let text: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.system(size: 12, weight: .semibold))
            if let fraction { ProgressView(value: fraction).progressViewStyle(.linear) } else { ProgressView().progressViewStyle(.linear) }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .glass(cornerRadius: 14, tint: .black.opacity(0.45))
    }
}
