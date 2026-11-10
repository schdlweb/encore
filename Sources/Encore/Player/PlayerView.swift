import AppKit
import SwiftUI

struct VideoSurface: NSViewRepresentable {
    let controller: MPVController
    func makeNSView(context: Context) -> MPVVideoView { MPVVideoView(controller: controller) }
    func updateNSView(_ nsView: MPVVideoView, context: Context) {}
}

/// What the player does once for each file it opens (they wait for the file to load, or
/// for its tracks to be known). One value, so switching source resets them together.
struct OncePerFile {
    var addonSubtitles = false
    var dubbedAudio = false
    var segments = false
    var dolbyVision = false
    var subtitles = false
    var wrongFile = false
}

/// What to do when a stream stops well before the end of the video.
struct CutoffRecovery: Equatable {
    enum Action: Equatable { case retrySameStream, tryAnotherStream, giveUp }

    var position: Double
    var attempts: Int

    /// Playing this far past the last cutoff counts as having recovered from it.
    static let progressThatCounts: Double = 30

    /// Stopping this close to the end is the end: containers often overstate the length
    /// by a few seconds, and losing the last moments of the credits costs nothing.
    static func isRealEnding(position: Double, duration: Double) -> Bool {
        guard duration > 0 else { return true } // no known length to compare with
        return duration - position <= max(15, duration * 0.02)
    }

    /// A stream that keeps playing for a while can be reconnected any number of times;
    /// one that dies at the same spot gets one retry, then two other sources.
    static func after(_ previous: CutoffRecovery?, position: Double) -> CutoffRecovery {
        guard let previous, position - previous.position < progressThatCounts else {
            return CutoffRecovery(position: position, attempts: 1)
        }
        return CutoffRecovery(position: previous.position, attempts: previous.attempts + 1)
    }

    var action: Action {
        switch attempts {
        case 1: .retrySameStream
        case 2, 3: .tryAnotherStream
        default: .giveUp
        }
    }
}

/// The player: the picture, its overlays and controls. The pieces live in extensions:
/// `+Overlays` (what's drawn), `+Housekeeping` (the twice-a-second upkeep, progress and
/// sync), `+Sources` (switching stream, segments, next episode), `+Previews` (scrub
/// thumbnails), `+Tracks` (audio/subtitle choices) and `+Window` (size, full screen, keys).
struct PlayerView: View {
    let request: PlaybackRequest
    @Environment(AppState.self) var app
    @State var player: MPVController?
    @State var stream: StreamItem
    @State var controlsVisible = true
    /// A player menu (speed, source, audio, subtitles) is open: never auto-hide under it,
    /// or the menu loses its button and the pick is dropped.
    @State var menuOpen = false
    /// The pointer is over the playbar panel.
    @State var pointerOnBar = false
    @State var lastActivity = Date()
    @State var seekFlashVisible = false
    @State var unloggedWatchTime: Double = 0
    @State var markedWatched = false
    @State var skipPromptFresh = false
    @State var skipPromptTask: Task<Void, Never>?
    /// "4K", "Dolby Vision", "BluRay", "5.1"…, shown beside the year/episode under the title.
    @State var qualityTags: [String] = []
    @State var seekFlashTask: Task<Void, Never>?
    @State var showInfo = false
    @State var info: [(String, String)] = []
    @State var scrubbing: Double?
    @State var upNextDismissed = false
    @State var upNextFresh = false
    @State var upNextTask: Task<Void, Never>?
    @State var advancing = false
    /// What has been done for the file that's open; starts over when the source changes.
    @State var once = OncePerFile()
    /// The last time the stream cut out before the end, and how often it has there.
    @State var cutoff: CutoffRecovery?
    @State var currentURL: URL
    @State var checkingStream: StreamItem?
    @State var triedURLs: Set<String> = []
    @State var segments: [SkipSegment] = []
    @State var autoSkipped: Set<String> = []
    @State var toast: String?
    @State var thumbs: ThumbnailGenerator?
    @State var thumbsSweeping = false
    @State var preview: CGImage?
    @State var dolbyVisionWarning = false
    @State var playingSince: Date?
    @State var nowPlaying: NowPlaying?
    @State var hostWindow: NSWindow?
    @State var aspectApplied = false
    @State var videoShape: CGSize?
    /// True from will-enter/exit full screen until shortly after it finishes.
    @State var fullScreenTransition = false

    var inWindow: Bool { app.settings.playerInWindow }
    @State var reportedPaused: Bool?
    @FocusState var focused: Bool
    /// Where on the timeline the pointer is.
    @State var hoverTime: Double?
    /// The preview bucket of the frame in the bubble.
    @State var previewTime: Double?
    /// That frame's real time: the bubble's label, and where a click lands.
    @State var previewFrameTime: Double?
    /// Saved, reported and shut down already (leaving the player, or quitting).
    @State var tornDown = false

    init(request: PlaybackRequest) {
        self.request = request
        _stream = State(initialValue: request.stream)
        _currentURL = State(initialValue: request.url)
        _triedURLs = State(initialValue: [request.stream.url ?? ""])
    }

    var activeSegment: SkipSegment? {
        guard let p = player, p.fileLoaded else { return nil }
        return segments.first { $0.contains(p.position) }
    }

    var nextVideo: Video? { app.nextVideo(in: request.meta, after: request.video) }

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
        .onReceive(NotificationCenter.default.publisher(for: DebugHooks.pickTrack)) { n in
            // Test runs: pick a track the way the audio/subtitle menus do.
            guard let p = player, let kind = n.userInfo?["kind"] as? String, let lang = n.userInfo?["lang"] as? String else { return }
            let tracks = kind == "audio" ? p.audioTracks : p.subtitleTracks
            let id = lang == "off" ? nil : tracks.first { $0.lang.map(normalizeLang) == normalizeLang(lang) }?.id
            if kind == "audio" { if let id { p.selectAudio(id); rememberAudio(id, p) } }
            else { p.selectSubtitle(id); rememberSubtitles(id, p) }
        }
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

    // MARK: Lifecycle

    func start() {
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
               audioLanguages: audioLanguages)
        // Quitting never makes this view disappear; the app runs the teardown itself.
        let id = request.id
        app.playerTeardown = (id, { teardown() })
    }

    /// Runs once: when the view goes away, or when the app quits, whichever is first.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if app.playerTeardown?.id == request.id { app.playerTeardown = nil }
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

    func close() {
        // In its own window, clearing playback closes the window (full screen or not).
        if !inWindow, let w = hostWindow ?? NSApp.keyWindow, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        app.playback = nil
    }
}
