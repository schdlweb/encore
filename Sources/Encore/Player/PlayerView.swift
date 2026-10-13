import AppKit
import SwiftUI

struct VideoSurface: NSViewRepresentable {
    let controller: MPVController
    func makeNSView(context: Context) -> MPVVideoView { MPVVideoView(controller: controller) }
    func updateNSView(_ nsView: MPVVideoView, context: Context) {}
}

struct PlayerView: View {
    let request: PlaybackRequest
    @Environment(AppState.self) private var app
    @State private var player: MPVController?
    @State private var stream: StreamItem
    @State private var controlsVisible = true
    /// A player menu (speed, source, audio, subtitles) is open: never auto-hide under it,
    /// or the menu loses its button and the pick is dropped.
    @State private var menuOpen = false
    /// The pointer is over the playbar panel.
    @State private var pointerOnBar = false
    @State private var lastActivity = Date()
    @State private var seekFlashVisible = false
    @State private var unloggedWatchTime: Double = 0
    @State private var markedWatched = false
    @State private var skipPromptFresh = false
    @State private var skipPromptTask: Task<Void, Never>?
    /// "4K", "Dolby Vision", "BluRay", "5.1"…, shown beside the year/episode under the title.
    @State private var qualityTags: [String] = []
    @State private var seekFlashTask: Task<Void, Never>?
    @State private var showInfo = false
    @State private var info: [(String, String)] = []
    @State private var scrubbing: Double?
    @State private var upNextDismissed = false
    @State private var upNextFresh = false
    @State private var upNextTask: Task<Void, Never>?
    @State private var advancing = false
    @State private var addedAddonSubs = false
    @State private var currentURL: URL
    @State private var checkingStream: StreamItem?
    @State private var triedURLs: Set<String> = []
    @State private var segments: [SkipSegment] = []
    @State private var segmentsLoaded = false
    @State private var autoSkipped: Set<String> = []
    @State private var toast: String?
    @State private var thumbs: ThumbnailGenerator?
    @State private var thumbsSweeping = false
    @State private var preview: CGImage?
    @State private var dolbyVisionWarning = false
    @State private var dolbyVisionChecked = false
    @State private var subtitlesRefined = false
    @State private var playingSince: Date?
    @State private var extraChecked = false
    @State private var nowPlaying: NowPlaying?
    @State private var hostWindow: NSWindow?
    @State private var aspectApplied = false
    @State private var videoShape: CGSize?
    /// True from will-enter/exit full screen until shortly after it finishes.
    @State private var fullScreenTransition = false

    private var inWindow: Bool { app.settings.playerInWindow }
    @State private var reportedPaused: Bool?
    @FocusState private var focused: Bool

    init(request: PlaybackRequest) {
        self.request = request
        _stream = State(initialValue: request.stream)
        _currentURL = State(initialValue: request.url)
        _triedURLs = State(initialValue: [request.stream.url ?? ""])
    }

    private var activeSegment: SkipSegment? {
        guard let p = player, p.fileLoaded else { return nil }
        return segments.first { $0.contains(p.position) }
    }

    private var nextVideo: Video? { app.nextVideo(in: request.meta, after: request.video) }

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoSurface(controller: player)
                // Click to pause, double-click for full screen: on the picture only. On the
                // whole player, every playbar click first waited out the double-click delay.
                // Dims the picture while you look through the timeline, like Infuse.
                Color.black
                    .opacity(hoverTime != nil && controlsVisible ? 0.4 : 0)
                    .animation(.easeOut(duration: 0.2), value: hoverTime != nil)
                    .allowsHitTesting(false)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { toggleFullScreen() }
                    .onTapGesture { player.togglePause(); poke() }
                overlays(player)
            }
        }
        .ignoresSafeArea()
        .background(WindowReader { hostWindow = $0 })
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // Repeats too, so holding an arrow keeps skipping (other keys act once per press).
        .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press) }
        .onContinuousHover { _ in poke() }
        // No aspect-ratio lock on the window (macOS applies it to full screen too, which
        // left the video stretched to the top and bottom edges only). Instead, when a
        // manual resize ends, the window snaps back to the video's shape.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { n in
            guard inWindow, !fullScreenTransition, let w = n.object as? NSWindow, w === hostWindow,
                  !w.styleMask.contains(.fullScreen), let size = videoShape else { return }
            snap(w, to: size)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            menuOpen = true
            poke()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuOpen = false
            poke()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { n in
            if (n.object as? NSWindow) === hostWindow { fullScreenTransition = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { n in
            if (n.object as? NSWindow) === hostWindow { fullScreenTransition = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { n in
            if (n.object as? NSWindow) === hostWindow { endFullScreenTransition() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { n in
            if (n.object as? NSWindow) === hostWindow { endFullScreenTransition() }
        }
        .onAppear(perform: start)
        .onDisappear(perform: teardown)
        .task { await housekeeping() }
    }

    // MARK: Overlays

    @ViewBuilder
    private func overlays(_ p: MPVController) -> some View {
        if (!p.fileLoaded || p.buffering || p.seeking || checkingStream != nil) && p.errorMessage == nil {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.white)
                if let s = checkingStream {
                    Text("Checking stream…").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text(s.oneLine).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                } else if !p.fileLoaded {
                    Text(stream.headline.components(separatedBy: "\n").first ?? "")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if p.fileLoaded, p.buffering {
                    Text("Buffering…").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .allowsHitTesting(false)
        }

        if let error = p.errorMessage {
            errorCard(error)
        }

        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomBar(p)
        }
        .opacity(controlsVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .allowsHitTesting(controlsVisible)

        // Up Next (which also stands in for Skip Credits): shown when the credits start,
        // fades after a few seconds, and comes back with the controls when you move.
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                Spacer()
                upNextCard(p)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, controlsVisible ? 120 : 40)
        }
        .opacity(upNextFresh || controlsVisible ? 1 : 0)
        .allowsHitTesting(upNextFresh || controlsVisible)
        .animation(.easeInOut(duration: 0.4), value: upNextFresh)
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .onChange(of: upNextDue) { _, due in
            upNextTask?.cancel()
            guard due else { upNextFresh = false; return }
            upNextFresh = true
            upNextTask = Task {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { upNextFresh = false }
            }
        }

        VStack {
            Spacer()
            seekFlash(p)
        }
        .opacity(seekFlashVisible && !controlsVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: seekFlashVisible)
        .allowsHitTesting(false)

        VStack {
            Spacer()
            HStack {
                Spacer()
                skipButton
            }
            .padding(.horizontal, 40)
            .padding(.bottom, controlsVisible ? 110 : 40)
        }
        // Shown for a few seconds when an intro/credits starts, then only with the controls
        // (moving the mouse brings it back).
        .opacity(skipPromptFresh || controlsVisible ? 1 : 0)
        .allowsHitTesting(skipPromptFresh || controlsVisible)
        .animation(.easeInOut(duration: 0.4), value: skipPromptFresh)
        .onChange(of: activeSegment?.id) { _, id in
            skipPromptTask?.cancel()
            guard id != nil else { skipPromptFresh = false; return }
            skipPromptFresh = true
            skipPromptTask = Task {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { skipPromptFresh = false }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: activeSegment?.id)

        if dolbyVisionWarning {
            HStack(spacing: 12) {
                Image(systemName: "paintpalette").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dolby Vision–only video").font(.system(size: 13, weight: .semibold))
                    Text("This file has no HDR10/SDR layer, so colors may look green or purple on Mac.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                }
                if let alt = request.alternatives.first(where: { $0.isPlayable && !$0.isDolbyVisionOnly && !triedURLs.contains($0.url ?? "") }),
                   let p = player {
                    Button("Switch Version") {
                        dolbyVisionWarning = false
                        switchStream(to: alt, player: p)
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                }
                Button { withAnimation { dolbyVisionWarning = false } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .padding(14)
            .glass(cornerRadius: 16, tint: .black.opacity(0.45))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 100)
            .transition(.opacity)
        }

        if let toast {
            Text(toast)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .glass(tint: .black.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 50)
                .transition(.opacity)
                .allowsHitTesting(false)
        }

        if showInfo {
            infoPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 90)
                .padding(.trailing, 40)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var topBar: some View {
        if inWindow {
            // "✕ Close" under the traffic lights, the show's name and episode below it,
            // and the info button on the right.
            ZStack(alignment: .top) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Button { close() } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                                Text("Close").font(.system(size: 13, weight: .medium))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(request.title).font(.system(size: 22, weight: .bold))
                            subtitleLine(opacity: 0.75)
                        }
                        .padding(.leading, 8)
                        .shadow(color: .black.opacity(0.5), radius: 6)
                    }
                    Spacer()
                    circleButton("info.circle", help: "Media info (I)") { withAnimation { showInfo.toggle() } }
                        .padding(.top, 2)
                }
                .padding(.horizontal, 12)
                .padding(.trailing, 8)
                .padding(.top, 38)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 50)
            .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
        } else {
            HStack(alignment: .center, spacing: 16) {
                circleButton("chevron.left", help: "Close") { close() }
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title).font(.system(size: 20, weight: .bold))
                    subtitleLine(opacity: 0.7)
                }
                Spacer()
                circleButton("info.circle", help: "Media info (I)") { withAnimation { showInfo.toggle() } }
            }
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .padding(.bottom, 50)
            .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
        }
    }

    /// Compact floating panel like Infuse's: volume left, transport centred, track menus,
    /// a gear menu and full screen right; timeline with times on either side below.
    private func bottomBar(_ p: MPVController) -> some View {
        let skip = app.settings.skipInterval
        return VStack(spacing: 8) {
            ZStack {
                HStack(spacing: 6) {
                    controlIcon(p.muted || p.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 13, help: "Mute (M)") { p.toggleMute() }
                    Slider(value: Binding(get: { p.volume }, set: { p.setVolume($0) }), in: 0...130)
                        .frame(width: 84)
                        .controlSize(.mini)
                        .tint(.white)
                    Spacer()
                }
                HStack(spacing: 20) {
                    controlIcon("gobackward", size: 16, help: "Back \(skip)s (←)") { p.seek(by: -Double(skip)) }
                    controlIcon(p.paused ? "play.fill" : "pause.fill", size: 22, help: "Play/Pause (Space)") { p.togglePause() }
                        .frame(width: 26)
                    controlIcon("goforward", size: 16, help: "Forward \(skip)s (→)") { p.seek(by: Double(skip)) }
                    if let next = nextVideo {
                        controlIcon("forward.end.fill", size: 14, help: "Next episode (N)") { playNext(next) }
                    }
                }
                HStack(spacing: 12) {
                    Spacer()
                    SubtitleMenu(tracks: p.subtitleTracks, selected: p.selectedSubtitle,
                                 select: { p.selectSubtitle($0) }, setDelay: { p.setSubtitleDelay($0) })
                        .equatable()
                    AudioMenu(tracks: p.audioTracks, selected: p.selectedAudio,
                              select: { p.selectAudio($0) }, setDelay: { p.setAudioDelay($0) })
                        .equatable()
                    GearMenu(speed: p.speed, sources: request.alternatives.filter(\.isPlayable), current: stream,
                             showInfo: showInfo, setSpeed: { p.setSpeed($0) },
                             switchTo: { switchStream(to: $0, player: p) },
                             toggleInfo: { withAnimation { showInfo.toggle() } })
                        .equatable()
                    controlIcon(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                size: 13, help: "Full screen (F)") { toggleFullScreen() }
                }
            }
            .frame(height: 26)

            timeline(p)
        }
        .playerPanel(onHover: { pointerOnBar = $0 })
    }

    /// Elapsed | seek bar | remaining.
    private func timeline(_ p: MPVController) -> some View {
        HStack(spacing: 10) {
            Text(formatClock(scrubbing ?? p.position))
                .frame(width: 50, alignment: .leading)
            Scrubber(
                position: scrubbing ?? p.position, duration: p.duration, buffered: p.position + p.cacheSeconds,
                segments: segments, preview: preview, previewsEnabled: app.settings.scrubPreviews,
                previewLoading: previewIsStale,
                previewLabel: preview != nil ? previewFrameTime : nil,
                onSeek: { value, done in
                    scrubbing = done ? nil : value
                    // Seek to the same moment the preview was made from, so the click
                    // lands on the scene the preview showed.
                    if done {
                        // Land on the frame the bubble is showing (what you see is where
                        // you go); without one, on the keyframe for that spot.
                        if let frame = previewFrameTime, preview != nil, abs(frame - value) <= snapWindow {
                            p.seekExact(to: frame)
                        } else if let frame = thumbs?.frameTime(value) {
                            p.seekExact(to: frame)
                        } else {
                            p.seek(to: thumbs?.bucketed(value) ?? value)
                        }
                    }
                    poke()
                },
                onHover: { t in hoverPreview(t, player: p) }
            )
            Text("-" + formatClock(max(0, p.duration - (scrubbing ?? p.position))))
                .frame(width: 56, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.85))
    }

    /// Just the timeline, flashed briefly when skipping with the arrow keys so you can see
    /// where you landed without the whole playbar covering the picture.
    private func seekFlash(_ p: MPVController) -> some View {
        timeline(p)
            .allowsHitTesting(false)
            .playerPanel()
    }

    private var isFullScreen: Bool { hostWindow?.styleMask.contains(.fullScreen) ?? false }


    // MARK: Panels

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Now Playing").font(.system(size: 15, weight: .bold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                ForEach(info, id: \.0) { row in
                    GridRow {
                        Text(row.0).foregroundStyle(.white.opacity(0.55))
                        Text(row.1).foregroundStyle(.white)
                    }
                }
            }
            .font(.system(size: 12))
            Divider().overlay(Color.white.opacity(0.2))
            Text(stream.headline + "\n" + stream.details)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(8)
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        .glass(cornerRadius: 18, tint: .black.opacity(0.35))
    }

    @ViewBuilder
    /// At the credits (or the last 45 s): the next episode is up.
    private var upNextDue: Bool {
        guard let p = player, nextVideo != nil, !upNextDismissed, p.duration > 120 else { return false }
        return p.duration - p.position < 45 || activeSegment?.kind == .outro
    }

    /// One card for the credits: what's next, Play Next, or keep watching the credits.
    @ViewBuilder
    private func upNextCard(_ p: MPVController) -> some View {
        if let next = nextVideo, upNextDue {
            HStack(spacing: 12) {
                // The thumbnail is itself a play button.
                Button { playNext(next) } label: {
                    ZStack {
                        RemoteImage(url: next.thumbnail ?? request.meta.background, maxPixel: 240)
                        Color.black.opacity(0.25)
                        Image(systemName: advancing ? "hourglass" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 3)
                    }
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(advancing)

                VStack(alignment: .leading, spacing: 3) {
                    Text("UP NEXT" + (next.episode.map { " · E\($0)" } ?? ""))
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.55))
                    Text(next.title.isEmpty ? "Episode \(next.episode ?? 0)" : next.title)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 10) {
                        Button { playNext(next) } label: {
                            Label(advancing ? "Loading…" : "Play", systemImage: "play.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(.white))
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                        .disabled(advancing)
                        Button("Watch Credits") { withAnimation { upNextDismissed = true } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .fixedSize()
                    .padding(.top, 2)
                }
            }
            .padding(10)
            .frame(width: 330, alignment: .leading)
            .glass(cornerRadius: 14, tint: .black.opacity(0.4))
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack {
                if let alt = nextUntriedStream, let p = player {
                    Button("Try Next Stream") { switchStream(to: alt, player: p) }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                }
                Button("Close") { close() }.buttonStyle(PillButtonStyle())
            }
        }
        .padding(30)
        .glass(cornerRadius: 22, tint: .black.opacity(0.5))
    }

    private func circleButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 40, height: 40)
                .glass()
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func controlIcon(_ icon: String, size: CGFloat = 19, help: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); poke() }) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Lifecycle

    private func start() {
        focused = true
        let p = MPVController(settings: app.settings)
        player = p
        let skip = Double(app.settings.skipInterval)
        nowPlaying = NowPlaying(
            title: request.title, subtitle: request.video.map { _ in request.subtitle ?? "" },
            artworkURL: request.video?.thumbnail ?? request.meta.background ?? request.meta.poster,
            skipInterval: skip,
            actions: .init(
                togglePause: { p.togglePause(); poke() },
                setPaused: { p.setPaused($0); poke() },
                seekBy: { p.seek(by: $0); poke() },
                seekTo: { p.seek(to: $0); poke() },
                next: nextVideo.map { next in { playNext(next) } }
            )
        )
        p.load(url: currentURL.absoluteString, headers: stream.requestHeaders, startAt: request.startAt,
               audioLanguages: request.audioLanguages)
    }

    private func teardown() {
        saveProgress()
        if let p = player, playingSince != nil {
            let finished = markedWatched || reachedEnd(p)
            app.jellyfin.playbackStopped(meta: request.meta, video: request.video, position: finished ? p.duration : p.position, finished: finished)
            app.simkl.scrobble("stop", meta: request.meta, video: request.video, position: finished ? p.duration : p.position, duration: p.duration)
        }
        app.watch.logWatchTime(unloggedWatchTime, isMovie: request.video == nil)
        unloggedWatchTime = 0
        nowPlaying?.end()
        thumbs?.shutdown()
        player?.shutdown()
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    private func close() {
        // In its own window, clearing playback closes the window (full screen or not).
        if !inWindow, let w = hostWindow ?? NSApp.keyWindow, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        app.playback = nil
    }

    /// Periodic work while the player is up: auto-hide, progress saving, info refresh,
    /// addon subtitles once the file is open, and auto-advance at the end.
    private func housekeeping() async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            tick += 1
            guard let p = player else { continue }

            let idle = Date().timeIntervalSince(lastActivity) > 3
                && ProcessInfo.processInfo.environment["ENCORE_NO_AUTOHIDE"] == nil
            // Never while the pointer is on the playbar (e.g. looking through previews).
            if controlsVisible, idle, !menuOpen, !pointerOnBar, hoverTime == nil, !p.paused, p.fileLoaded, scrubbing == nil {
                controlsVisible = false
                NSCursor.setHiddenUntilMouseMoves(true)
            }
            if tick % 10 == 0 || (!markedWatched && reachedEnd(p)) { saveProgress() }
            // Screen time: only time actually spent playing, logged every 15 s.
            if p.fileLoaded, !p.paused, !p.buffering { unloggedWatchTime += 0.5 }
            if tick % 30 == 0, unloggedWatchTime > 0 {
                app.watch.logWatchTime(unloggedWatchTime, isMovie: request.video == nil)
                unloggedWatchTime = 0
            }
            // Keep Control Center / media keys in sync: on every pause change, else every 5 s.
            if p.fileLoaded, reportedPaused != p.paused {
                // Pause and resume reach AIOStreams and Simkl as they happen.
                app.jellyfin.playbackProgress(meta: request.meta, video: request.video, position: p.position, paused: p.paused)
                app.simkl.scrobble(p.paused ? "pause" : "start", meta: request.meta, video: request.video, position: p.position, duration: p.duration)
            } else if p.fileLoaded, tick % 60 == 0 {
                app.jellyfin.playbackProgress(meta: request.meta, video: request.video, position: p.position, paused: p.paused)
            }
            if p.fileLoaded, reportedPaused != p.paused || tick % 10 == 0 {
                reportedPaused = p.paused
                nowPlaying?.update(position: p.position, duration: p.duration, paused: p.paused, speed: p.speed)
            }
            if showInfo, tick % 2 == 0 { info = p.mediaInfo() }
            if tick % 4 == 0 { refreshQualityTags(p); updateHDROutput(p) }
            if p.fileLoaded, !addedAddonSubs {
                addedAddonSubs = true
                Task { await loadAddonSubtitles(p) }
            }
            if p.fileLoaded, !p.buffering, playingSince == nil {
                playingSince = Date()
                app.jellyfin.playbackStarted(meta: request.meta, video: request.video, position: p.position)
                app.simkl.scrobble("start", meta: request.meta, video: request.video, position: p.position, duration: p.duration)
            }
            // Open the preview renderer once playback is going (opening a 4K stream takes it
            // a few seconds, so it's ready before the first hover), and fill the timeline in
            // the background after playback has settled.
            if app.settings.scrubPreviews, thumbs == nil, p.duration > 0,
               let since = playingSince, Date().timeIntervalSince(since) > 2 {
                makeThumbnailer(p)
            }
            if app.settings.scrubPreviews, let t = thumbs, !thumbsSweeping {
                thumbsSweeping = true
                t.prefetch()
            }
            // A season pack can resolve to an OVA instead of the episode; move on if so.
            if inWindow, !aspectApplied, p.fileLoaded, let size = p.videoDisplaySize(), let w = hostWindow {
                aspectApplied = true
                fitWindow(w, to: size)
            }
            if p.fileLoaded, !extraChecked {
                extraChecked = true
                let regular = (request.video?.season ?? 1) > 0 && !StreamItem.isExtraName(request.video?.title ?? "")
                if regular, request.video != nil, let name = p.openedFileName() {
                    let wrongEntry = request.matcher.isMismatch(name)
                    if wrongEntry || StreamItem.isExtraName(name),
                       let alt = request.alternatives.first(where: {
                           $0.isPlayable && !$0.looksLikeExtra && !request.matcher.isMismatch($0) && !triedURLs.contains($0.url ?? "")
                       }) {
                        showToast(wrongEntry ? "That file was a different season, trying another stream"
                                             : "That file was an OVA/special, trying another stream")
                        switchStream(to: alt, player: p)
                    }
                }
            }
            if p.fileLoaded, !dolbyVisionChecked {
                dolbyVisionChecked = true
                if p.dolbyVisionProfile() == 5 { withAnimation { dolbyVisionWarning = true } }
            }
            if p.fileLoaded, !subtitlesRefined, !p.subtitleTracks.isEmpty {
                subtitlesRefined = true
                refineSubtitleChoice(p)
            }
            if p.fileLoaded, p.duration > 0, !segmentsLoaded {
                segmentsLoaded = true
                Task { await loadSegments(p) }
            }
            if app.settings.autoSkipIntros, let seg = activeSegment, seg.kind != .outro,
               !autoSkipped.contains(seg.id), scrubbing == nil {
                autoSkipped.insert(seg.id)
                skip(seg, player: p)
                showToast(seg.kind == .intro ? "Skipped intro" : "Skipped recap")
            }
            if p.endedNaturally, !advancing {
                saveProgress()
                if app.settings.autoplayNext, let next = nextVideo { playNext(next) }
                else { close() }
            }
        }
    }

    /// The year (or episode) with the quality tags beside it on the same line.
    private func subtitleLine(opacity: Double) -> some View {
        HStack(spacing: 8) {
            if let s = request.subtitle, !s.isEmpty {
                Text(s).font(.system(size: 13)).foregroundStyle(.white.opacity(opacity)).lineLimit(1)
            }
            ForEach(qualityTags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.45), lineWidth: 0.75))
                    .fixedSize()
            }
        }
        .animation(.easeOut(duration: 0.2), value: qualityTags)
    }

    /// HDR output while an HDR video is on a screen that can show it (follows the window
    /// between screens; the built-in XDR display can, most external monitors can't).
    private func updateHDROutput(_ p: MPVController) {
        guard p.fileLoaded else { return }
        let screen = hostWindow?.screen ?? NSScreen.main
        let headroom = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        let want = app.settings.hdrOutput && p.isHDRVideo && headroom > 1.5
        // SDR white is ~100 nits on this scale, so the headroom gives the screen's peak.
        let switching = want != p.hdrOutput
        p.setHDROutput(want, peakNits: max(400, Double(headroom) * 100))
        if switching {
            // Said as the picture fades back in (the switch itself happens while it's dark).
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                showToast(want ? "Switched to HDR" : "Switched to SDR")
            }
        }
    }

    private func refreshQualityTags(_ p: MPVController) {
        guard p.fileLoaded else { return }
        var tags = p.qualityTags()
        if let source = stream.sourceTag { tags.insert(source, at: min(tags.count, tags.firstIndex(where: { ["Atmos", "5.1", "7.1"].contains($0) }) ?? tags.count)) }
        if tags != qualityTags { qualityTags = tags }
    }

    private func flashTimeline() {
        seekFlashVisible = true
        seekFlashTask?.cancel()
        seekFlashTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            if !Task.isCancelled { seekFlashVisible = false }
        }
    }

    private func poke() {
        lastActivity = Date()
        if !controlsVisible { controlsVisible = true }
    }

    /// Counted as watched from the credits on (episodes with known credit times), or in a
    /// movie's last stretch (its final ~8%, at most 10 and at least 2 minutes). Once
    /// watched it stays watched, even if the credits keep playing.
    private func reachedEnd(_ p: MPVController) -> Bool {
        guard p.duration > 0 else { return false }
        if p.endedNaturally { return true }
        if let outro = segments.first(where: { $0.kind == .outro && $0.start > p.duration * 0.5 }), p.position >= outro.start {
            return true
        }
        if request.video == nil {
            return p.duration - p.position <= max(120, min(p.duration * 0.08, 600))
        }
        return false
    }

    private func saveProgress() {
        guard let p = player, p.duration > 0, p.position > 0 else { return }
        if !markedWatched, reachedEnd(p) { markedWatched = true }
        let ended = markedWatched
        app.watch.record(WatchEntry(
            title: SavedTitle(request.meta),
            videoId: request.videoId,
            season: request.video?.season,
            episode: request.video?.episode,
            episodeTitle: request.video?.title,
            episodeThumbnail: request.video?.thumbnail,
            position: ended ? p.duration : p.position,
            duration: p.duration,
            updatedAt: .now
        ))
    }

    private func loadAddonSubtitles(_ p: MPVController) async {
        guard app.manifest?.supports("subtitles") == true, let client = app.client else { return }
        guard let subs = try? await client.subtitles(type: request.meta.type, videoId: request.videoId), !subs.isEmpty else { return }
        let prefs = app.settings.preferredSubtitleLanguages
            .split(separator: ",").map { normalizeLang(String($0).trimmingCharacters(in: .whitespaces)) }
        let wanted = prefs.isEmpty ? subs : subs.filter { prefs.contains(normalizeLang($0.lang)) }
        let embeddedPreferred = p.subtitleTracks.contains { t in t.lang.map { prefs.contains(normalizeLang($0)) } ?? false }
        for (i, s) in wanted.prefix(8).enumerated() {
            let lang = normalizeLang(s.lang)
            let name = Locale.current.localizedString(forLanguageCode: lang) ?? s.lang
            p.addSubtitle(url: s.url, title: "\(name) \(i + 1)", lang: lang)
        }
        // If the file had nothing in a preferred language, turn the first addon track on.
        if app.settings.subtitlesOnByDefault, !embeddedPreferred, p.selectedSubtitle == nil, !wanted.isEmpty {
            try? await Task.sleep(for: .seconds(2))
            if let first = p.subtitleTracks.first(where: \.isExternal) { p.selectSubtitle(first.id) }
        }
    }

    private var nextUntriedStream: StreamItem? {
        request.alternatives.first { $0.isPlayable && !triedURLs.contains($0.url ?? "") }
    }

    /// Checks a stream like the start of playback does, then switches to it in place.
    private func switchStream(to s: StreamItem, player p: MPVController) {
        guard checkingStream == nil else { return }
        let resumeAt = p.position > 5 ? p.position : request.startAt
        triedURLs.insert(s.url ?? "")
        checkingStream = s
        p.errorMessage = nil
        Task {
            let result = await StreamProbe.check(s)
            checkingStream = nil
            switch result {
            case .playable(let url):
                stream = s
                app.watch.rememberStream(s, metaId: request.meta.id, videoId: request.videoId)
                currentURL = url
                addedAddonSubs = false
                segmentsLoaded = false
                segments = []
                thumbs?.shutdown()
                thumbs = nil
                thumbsSweeping = false
                preview = nil
                previewTime = nil
                previewFrameTime = nil
                dolbyVisionChecked = false
                dolbyVisionWarning = false
                extraChecked = false
                subtitlesRefined = false
                playingSince = nil
                p.load(url: url.absoluteString, headers: s.requestHeaders, startAt: resumeAt,
                       audioLanguages: request.audioLanguages)
            case .failed(let reason):
                p.errorMessage = "That stream didn't work: \(reason)"
            }
        }
    }

    private func loadSegments(_ p: MPVController) async {
        let fromFile = SegmentService.fromChapters(p.chapters(), duration: p.duration)
        let fromWeb = await SegmentService.fetch(meta: request.meta, video: request.video, duration: p.duration)
        // The file's own chapters win for any kind they cover.
        let kinds = Set(fromFile.map(\.kind))
        segments = (fromFile + fromWeb.filter { !kinds.contains($0.kind) }).sorted { $0.start < $1.start }
    }

    @ViewBuilder
    private var skipButton: some View {
        if let seg = activeSegment, let p = player {
            if seg.kind == .outro, nextVideo != nil {
                // The Up Next card covers the credits (Play Next skips them).
                EmptyView()
            } else {
                Button { skip(seg, player: p) } label: {
                    Label(seg.buttonTitle, systemImage: "forward.fill")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .help("Times from \(seg.source)")
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
    }

    private func skip(_ seg: SkipSegment, player p: MPVController) {
        // Credits running to the very end: skipping means finishing.
        if seg.kind == .outro, p.duration - seg.end < 5 {
            p.seek(to: max(0, p.duration - 1))
        } else {
            p.seek(to: seg.end)
        }
        poke()
    }

    private func showToast(_ text: String) {
        if ProcessInfo.processInfo.environment["ENCORE_ROUTE"] != nil { print("[toast] \(text)"); fflush(stdout) }
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { if toast == text { toast = nil } }
        }
    }

    @discardableResult
    private func makeThumbnailer(_ p: MPVController) -> ThumbnailGenerator {
        if let thumbs { return thumbs }
        let gen = ThumbnailGenerator(url: currentURL.absoluteString, headers: stream.requestHeaders, duration: p.duration) { t, img in
            guard let h = hoverTime, let g = thumbs else { return }
            // The exact frame for where the pointer is replaces any stand-in. A frame for a
            // spot already passed only fills an empty bubble (and only if it's near), so a
            // sweep doesn't flicker through scenes.
            let exact = t == g.bucketed(h)
            guard exact || (preview == nil && abs(t - h) <= snapWindow) else { return }
            preview = img
            previewTime = t
            previewFrameTime = g.frameTime(t) ?? t
        }
        thumbs = gen
        return gen
    }

    @State private var hoverTime: Double?

    /// The frame in the bubble isn't the exact one for where the pointer is (yet).
    private var previewIsStale: Bool {
        guard let h = hoverTime, let g = thumbs else { return preview == nil }
        guard preview != nil, let shown = previewTime else { return true }
        return abs(shown - g.bucketed(h)) > 0.01
    }
    /// The preview bucket of the frame in the bubble.
    @State private var previewTime: Double?
    /// That frame's real time: the bubble's label, and where a click lands.
    @State private var previewFrameTime: Double?
    /// How far the bubble may show a nearby ready frame (labelled with its own time)
    /// while the exact one loads.
    private var snapWindow: Double { max(30, (player?.duration ?? 0) * 0.02) }

    private func hoverPreview(_ t: Double?, player p: MPVController) {
        hoverTime = t
        guard app.settings.scrubPreviews, let t, p.duration > 0 else { return }
        let gen = makeThumbnailer(p)
        if let hit = gen.cached(t) {
            preview = hit
            previewTime = gen.bucketed(t)
            previewFrameTime = gen.frameTime(t)
        } else {
            // The nearest ready frame at once, labelled with its own time (a click goes
            // there); the exact one replaces it when it's ready.
            if let near = gen.nearestFrame(t, within: snapWindow) {
                preview = near.image
                previewTime = near.key
                previewFrameTime = near.frameTime
            } else {
                preview = nil
                previewFrameTime = nil
                previewTime = nil
                previewFrameTime = nil
            }
            gen.request(t)
        }
    }

    /// Anime releases often flag a "Signs & Songs" track as the English default; prefer
    /// the full-dialogue English track when there is one.
    private func refineSubtitleChoice(_ p: MPVController) {
        guard app.settings.subtitlesOnByDefault else { return }
        let prefs = app.settings.preferredSubtitleLanguages.split(separator: ",")
            .map { normalizeLang(String($0).trimmingCharacters(in: .whitespaces)) }
        func partial(_ t: MediaTrack) -> Bool {
            t.isForced || (t.title ?? "").range(of: #"(?i)sign|song|forced|commentary"#, options: .regularExpression) != nil
        }
        let wanted = p.subtitleTracks.filter { t in t.lang.map { prefs.contains(normalizeLang($0)) } ?? false }
        let current = p.subtitleTracks.first { $0.id == p.selectedSubtitle }
        if let full = wanted.first(where: { !partial($0) }), current == nil || partial(current!) {
            p.selectSubtitle(full.id)
        }
    }

    private func playNext(_ next: Video) {
        guard !advancing else { return }
        advancing = true
        saveProgress()
        app.requestPlay(meta: request.meta, video: next, preferBingeGroup: stream.bingeGroup)
    }

    /// Sizes the player window to the video's shape, keeping its width where it fits the screen.
    private func fitWindow(_ w: NSWindow, to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        videoShape = size
        guard !w.styleMask.contains(.fullScreen) else { return }
        let screen = (w.screen ?? NSScreen.main)?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        var width = min(max(w.frame.width, 960), screen.width * 0.9)
        var height = width * size.height / size.width
        if height > screen.height * 0.9 {
            height = screen.height * 0.9
            width = height * size.width / size.height
        }
        let center = CGPoint(x: w.frame.midX, y: w.frame.midY)
        var frame = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height))
        frame.origin = CGPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2)
        w.setFrame(w.constrainFrameRect(frame, to: w.screen), display: true, animate: true)
    }

    /// After a manual resize: keep the width the user chose, fix the height to the video's shape.
    private func snap(_ w: NSWindow, to size: CGSize) {
        let content = w.contentRect(forFrameRect: w.frame)
        let height = content.width * size.height / size.width
        guard abs(height - content.height) > 1 else { return }
        var frame = w.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - height, width: content.width, height: height))
        frame = w.constrainFrameRect(frame, to: w.screen)
        w.setFrame(frame, display: true, animate: true)
    }

    private func endFullScreenTransition() {
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            fullScreenTransition = false
        }
    }

    private func toggleFullScreen() {
        guard let w = hostWindow ?? NSApp.keyWindow else { return }
        w.collectionBehavior.remove(.fullScreenAuxiliary)
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.makeKeyAndOrderFront(nil)
        w.toggleFullScreen(nil)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard let p = player else { return .ignored }
        let arrows: [KeyEquivalent] = [.leftArrow, .rightArrow, .upArrow, .downArrow]
        if press.phase == .repeat, !arrows.contains(press.key) { return .handled }
        let skip = Double(app.settings.skipInterval)
        // Skips show only the timeline (unless the playbar is already up); other keys bring up the playbar.
        if press.key == .leftArrow || press.key == .rightArrow {
            p.seek(by: (press.modifiers.contains(.shift) ? 60 : skip) * (press.key == .leftArrow ? -1 : 1))
            if controlsVisible { poke() } else { flashTimeline() }
            return .handled
        }
        poke()
        switch press.key {
        case .space: p.togglePause()
        case .upArrow: p.setVolume(p.volume + 5)
        case .downArrow: p.setVolume(p.volume - 5)
        case .escape:
            if let w = hostWindow ?? NSApp.keyWindow, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) } else { close() }
        default:
            switch press.characters.lowercased() {
            case "f": toggleFullScreen()
            case "m": p.toggleMute()
            case "i": withAnimation { showInfo.toggle() }
            case "k": p.togglePause()
            case "n": if let n = nextVideo { playNext(n) }
            default: return .ignored
            }
        }
        return .handled
    }
}

/// "en" and "eng" both become "eng" so addon and file languages compare.
func normalizeLang(_ code: String) -> String {
    let c = code.lowercased()
    return Locale.LanguageCode(c).identifier(.alpha3) ?? c
}

/// Seek bar with buffered range, intro/credits marks, and a hover preview bubble
/// showing a thumbnail of that point (when previews are on) and its time.
struct Scrubber: View {
    let position: Double
    let duration: Double
    let buffered: Double
    var segments: [SkipSegment] = []
    var preview: CGImage?
    var previewsEnabled = true
    /// The exact frame is still being made: a small spinner on whatever's shown.
    var previewLoading = false
    /// The real time of the frame shown (the bubble's label); nil uses the pointer's time.
    var previewLabel: Double? = nil
    let onSeek: (Double, Bool) -> Void
    var onHover: (Double?) -> Void = { _ in }
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let frac = duration > 0 ? min(1, max(0, position / duration)) : 0
            let buf = duration > 0 ? min(1, max(0, buffered / duration)) : 0
            let active = hoverX != nil
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(0.35)).frame(width: w * buf)
                // Marks clamped to the timeline: segment times can run past a shorter cut.
                ForEach(segments.filter { duration > 0 && $0.start < duration }) { seg in
                    Rectangle()
                        .fill(Theme.accent.opacity(0.55))
                        .frame(width: max(2, w * (min(seg.end, duration) - seg.start) / duration))
                        .offset(x: w * seg.start / duration)
                }
                Capsule().fill(.white).frame(width: w * frac)
                Circle()
                    .fill(.white)
                    .frame(width: active ? 14 : 0, height: active ? 14 : 0)
                    .offset(x: w * frac - (active ? 7 : 0))
                    .shadow(radius: 3)
            }
            .frame(width: w, height: active ? 8 : 5, alignment: .leading)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .bottomLeading) {
                // Infuse-style: the frame sits on the playbar just above the timeline,
                // following the pointer, kept within the panel (which reaches past the
                // timeline by about the width of the time labels).
                if let x = hoverX, duration > 0 {
                    bubble(time: previewsEnabled ? (previewLabel ?? value(at: x, width: w)) : value(at: x, width: w))
                        .offset(x: min(max(-62, x - bubbleWidth / 2), w + 62 - bubbleWidth), y: -16)
                        .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        hoverX = v.location.x
                        let t = value(at: v.location.x, width: w)
                        onSeek(t, false)
                        onHover(t)
                    }
                    .onEnded { v in onSeek(value(at: v.location.x, width: w), true) }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    hoverX = loc.x
                    onHover(value(at: loc.x, width: w))
                case .ended:
                    hoverX = nil
                    onHover(nil)
                }
            }
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .frame(height: 20)
    }

    private var bubbleWidth: CGFloat { previewsEnabled ? 240 : 80 }

    /// The frame's own shape (2.39:1 films stay wide), 16:9 until the first frame arrives.
    private var previewAspect: CGFloat {
        guard let preview, preview.height > 0 else { return 16 / 9 }
        return CGFloat(preview.width) / CGFloat(preview.height)
    }

    private func bubble(time: Double) -> some View {
        VStack(spacing: 5) {
            Text(formatClock(time))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 3)
            if previewsEnabled {
                ZStack {
                    Color.black
                    if let preview {
                        Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        if previewLoading {
                            // A stand-in is showing: quiet spinner in the corner.
                            ProgressView().controlSize(.mini).tint(.white)
                                .padding(6)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        }
                    } else {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                .frame(width: bubbleWidth, height: bubbleWidth / previewAspect)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.55), radius: 14, y: 6)
            }
        }
        .frame(width: bubbleWidth)
    }

    private func value(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(0, x / width), 1)) * duration
    }
}

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
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let w = view.window { context.coordinator.attach(w) } }
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

// MARK: Menus

// The menus are separate views compared only on what they show. Inside the player's
// panel they would be rebuilt with every time update during playback, and rebuilding an
// open menu shifts its highlight away from the cursor and closes its submenus.


private extension View {
    /// The floating glass panel the playbar (and the arrow-key timeline) sit in.
    func playerPanel(onHover: ((Bool) -> Void)? = nil) -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(width: 520)
            // Drawn as a background (not a clip) so the scrub preview can rise above the panel.
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.3))
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
            .onHover { onHover?($0) }
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity)
    }

}

/// Speed, source and media info live behind one gear, as in Infuse.
private struct GearMenu: View, Equatable {
    let speed: Double
    let sources: [StreamItem]
    let current: StreamItem
    let showInfo: Bool
    let setSpeed: (Double) -> Void
    let switchTo: (StreamItem) -> Void
    let toggleInfo: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.speed == b.speed && a.sources == b.sources && a.current == b.current && a.showInfo == b.showInfo
    }

    var body: some View {
        NativeMenuButton(icon: "gearshape.fill", help: "Speed, source, media info", entries: entries)
            .onAppear {
                if ProcessInfo.processInfo.environment["ENCORE_DUMP_MENUS"] != nil { print("[menu]\n" + NativeMenu.describe(entries())); fflush(stdout) }
            }
    }

    private func entries() -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .submenu("Speed (\(String(format: "%gx", speed)))", [0.5, 0.75, 1, 1.25, 1.5, 2].map { s in
                .item(s == 1 ? "Normal" : String(format: "%gx", s), checked: abs(speed - s) < 0.01) { setSpeed(s) }
            }),
        ]
        if sources.count > 1 {
            entries.append(.submenu("Source", sources.prefix(25).map { s in
                .item(String(s.oneLine.prefix(90)), checked: s.url == current.url) { switchTo(s) }
            }))
        }
        entries += [.separator, .item(showInfo ? "Hide Media Info" : "Media Info") { toggleInfo() }]
        return entries
    }
}

private struct AudioMenu: View, Equatable {
    let tracks: [MediaTrack]
    let selected: Int?
    let select: (Int) -> Void
    let setDelay: (Double) -> Void

    static func == (a: Self, b: Self) -> Bool { a.tracks == b.tracks && a.selected == b.selected }

    var body: some View {
        NativeMenuButton(icon: "waveform", help: "Audio tracks") {
            [.header("Audio")]
                + tracks.map { t in
                    .item(t.label + (t.detail.isEmpty ? "" : "  —  \(t.detail)"), checked: selected == t.id) { select(t.id) }
                }
                + [.separator,
                   .submenu("Audio Offset", [-0.5, -0.25, -0.1, 0, 0.1, 0.25, 0.5].map { d in
                       .item(d == 0 ? "None" : String(format: "%+.2f s", d)) { setDelay(d) }
                   })]
        }
    }
}

private struct SubtitleMenu: View, Equatable {
    let tracks: [MediaTrack]
    let selected: Int?
    let select: (Int?) -> Void
    let setDelay: (Double) -> Void

    static func == (a: Self, b: Self) -> Bool { a.tracks == b.tracks && a.selected == b.selected }

    var body: some View {
        NativeMenuButton(icon: "captions.bubble", help: "Subtitles") {
            [.header("Subtitles"), .item("Off", checked: selected == nil) { select(nil) }]
                + tracks.map { t in
                    .item(t.label + (t.detail.isEmpty ? "" : "  —  \(t.detail)"), checked: selected == t.id) { select(t.id) }
                }
                + [.separator,
                   .submenu("Subtitle Offset", [-2.0, -1, -0.5, 0, 0.5, 1, 2].map { d in
                       .item(d == 0 ? "None" : String(format: "%+.1f s", d)) { setDelay(d) }
                   })]
        }
    }
}
