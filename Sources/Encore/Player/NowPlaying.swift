import AppKit
import MediaPlayer

/// Registers the player with macOS "Now Playing": the keyboard's play/pause and
/// next keys, AirPods/headphone controls, and the Control Center media widget
/// (with artwork and a scrubber) all drive mpv while a video is open.
@MainActor
final class NowPlaying {
    struct Actions {
        var togglePause: () -> Void
        var setPaused: (Bool) -> Void
        var seekBy: (Double) -> Void
        var seekTo: (Double) -> Void
        var next: (() -> Void)?
    }

    private var targets: [(MPRemoteCommand, Any)] = []
    private var info: [String: Any] = [:]
    /// Whether the info has gone to macOS yet (it waits briefly for the artwork).
    private var published = false

    /// `artworkURLs`: tried in order until one loads (the episode's still, then the show's art).
    init(title: String, subtitle: String?, artworkURLs: [String?], skipInterval: Double, actions: Actions) {
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            targets.append((command, command.addTarget(handler: handler)))
        }
        on(center.togglePlayPauseCommand) { _ in actions.togglePause(); return .success }
        on(center.playCommand) { _ in actions.setPaused(false); return .success }
        on(center.pauseCommand) { _ in actions.setPaused(true); return .success }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        on(center.skipForwardCommand) { _ in actions.seekBy(skipInterval); return .success }
        on(center.skipBackwardCommand) { _ in actions.seekBy(-skipInterval); return .success }
        on(center.changePlaybackPositionCommand) { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            actions.seekTo(e.positionTime)
            return .success
        }
        if let next = actions.next {
            on(center.nextTrackCommand) { _ in next(); return .success }
        } else {
            center.nextTrackCommand.isEnabled = false
        }

        info[MPMediaItemPropertyTitle] = subtitle.map { "\(title): \($0)" } ?? title
        info[MPMediaItemPropertyArtist] = "Encore"
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue

        // macOS kept showing the app icon when the artwork arrived after the rest of the
        // info, so the first publish waits for it (up to 2 s; it's usually cached already).
        let urls = artworkURLs.compactMap { $0.flatMap(URL.init(string:)) }
        Task {
            for url in urls {
                guard let image = await ImagePipeline.shared.image(url, maxPixel: 600) else { continue }
                info[MPMediaItemPropertyArtwork] = Self.artwork(image)
                break
            }
            publish()
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if !published { publish() }
        }
    }

    /// Made outside the main actor: macOS asks for the image from a background thread.
    nonisolated private static func artwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func publish() {
        guard !targets.isEmpty else { return } // ended already
        published = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let paused = (info[MPNowPlayingInfoPropertyPlaybackRate] as? Double) == 0
        MPNowPlayingInfoCenter.default().playbackState = paused ? .paused : .playing
    }

    /// Call when playback state changes and every few seconds; macOS extrapolates
    /// the elapsed time between updates from the rate.
    func update(position: Double, duration: Double, paused: Bool, speed: Double) {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = paused ? 0 : speed
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        guard published else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = paused ? .paused : .playing
    }

    func end() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
