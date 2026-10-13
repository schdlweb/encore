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

    init(title: String, subtitle: String?, artworkURL: String?, skipInterval: Double, actions: Actions) {
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let artworkURL, let url = URL(string: artworkURL) {
            Task {
                guard let image = await ImagePipeline.shared.image(url, maxPixel: 600) else { return }
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    /// Call when playback state changes and every few seconds; macOS extrapolates
    /// the elapsed time between updates from the rate.
    func update(position: Double, duration: Double, paused: Bool, speed: Double) {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = paused ? 0 : speed
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
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
