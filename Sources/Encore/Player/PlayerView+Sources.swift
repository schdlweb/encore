import AppKit
import SwiftUI

extension PlayerView {
    var nextUntriedStream: StreamItem? {
        request.alternatives.first { $0.isPlayable && !triedURLs.contains($0.url ?? "") }
    }

    /// Checks a stream like the start of playback does, then switches to it in place.
    func switchStream(to s: StreamItem, player p: MPVController, resumeAt position: Double? = nil, onFailure: ((_ connectionDown: Bool) -> Void)? = nil) {
        guard checkingStream == nil else { return }
        let resumeAt = position ?? (p.position > 5 ? p.position : request.startAt)
        triedURLs.insert(s.url ?? "")
        checkingStream = s
        p.problem = nil
        Task {
            let result = await StreamProbe.check(s)
            checkingStream = nil
            switch result {
            case .playable(let url):
                stream = s
                app.watch.rememberStream(s, metaId: request.meta.id, videoId: request.videoId)
                currentURL = url
                once = OncePerFile()
                segments = []
                thumbs?.shutdown()
                thumbs = nil
                thumbsSweeping = false
                preview = nil
                previewTime = nil
                previewFrameTime = nil
                dolbyVisionWarning = false
                playingSince = nil
                p.load(url: url.absoluteString, headers: s.requestHeaders, startAt: resumeAt,
                       audioLanguages: audioLanguages)
            case .failed(let reason):
                if let onFailure { onFailure(false) } else { p.problem = .sourceFailed(reason) }
            case .unreachable(let reason):
                // Says nothing about this source, so it stays available to try.
                if s.url != stream.url { triedURLs.remove(s.url ?? "") }
                if let onFailure { onFailure(true) } else { p.problem = .sourceFailed(reason) }
            }
        }
    }

    /// The stream stopped well before the end of the video. It isn't the end of the
    /// episode: get a fresh link and carry on from the same spot, or failing that, another
    /// source. Nothing is marked watched and the next episode doesn't start.
    func recoverFromCutoff(_ p: MPVController) {
        guard let at = p.cutOffAt, checkingStream == nil, !advancing, !waitingForConnection else { return }
        p.cutOffAt = nil
        let attempt = CutoffRecovery.after(cutoff, position: at)
        cutoff = attempt
        switch attempt.action {
        case .retrySameStream:
            showToast("Lost the stream, reconnecting")
            resume(with: stream, player: p, at: at) { moveToAnotherStream(p, at: at) }
        case .tryAnotherStream:
            moveToAnotherStream(p, at: at)
        case .giveUp:
            p.problem = .streamStopped(at: at)
        }
    }

    /// Sources that check out as dead are skipped, up to `tries` of them.
    private func moveToAnotherStream(_ p: MPVController, at: Double, tries: Int = 4) {
        guard tries > 0, let alt = request.alternatives.first(where: {
            $0.isPlayable && !$0.looksLikeExtra && !request.matcher.isMismatch($0) && !triedURLs.contains($0.url ?? "")
        }) else {
            p.problem = .streamStopped(at: at)
            return
        }
        showToast("Lost the stream, trying another source")
        resume(with: alt, player: p, at: at) { moveToAnotherStream(p, at: at, tries: tries - 1) }
    }

    /// Switches to `s`. If it's the connection that's down, no source would work, so
    /// none are used up: it waits for the connection instead.
    private func resume(with s: StreamItem, player p: MPVController, at: Double, otherwise: @escaping () -> Void) {
        switchStream(to: s, player: p, resumeAt: at) { connectionDown in
            if connectionDown { waitForConnection(p, at: at, trying: s, otherwise: otherwise) } else { otherwise() }
        }
    }

    private func waitForConnection(_ p: MPVController, at: Double, trying s: StreamItem, otherwise: @escaping () -> Void) {
        guard !waitingForConnection else { return }
        waitingForConnection = true
        Task {
            let deadline = Date().addingTimeInterval(CutoffRecovery.connectionPatience)
            var pause = 2.0
            while !tornDown, Date() < deadline {
                try? await Task.sleep(for: .seconds(pause))
                pause = min(pause * 1.5, 15)
                guard !tornDown else { break }
                if case .unreachable = await StreamProbe.check(s) { continue }
                waitingForConnection = false
                cutoff = nil // it was the connection, so the stream starts with a clean slate
                resume(with: s, player: p, at: at, otherwise: otherwise)
                return
            }
            waitingForConnection = false
            if !tornDown { p.problem = .streamStopped(at: at) }
        }
    }

    func loadSegments(_ p: MPVController) async {
        let fromFile = SegmentService.fromChapters(p.chapters(), duration: p.duration)
        let fromWeb = await SegmentService.fetch(meta: request.meta, video: request.video, duration: p.duration)
        // The file's own chapters win for any kind they cover.
        let kinds = Set(fromFile.map(\.kind))
        segments = (fromFile + fromWeb.filter { !kinds.contains($0.kind) }).sorted { $0.start < $1.start }
    }

    func skip(_ seg: SkipSegment, player p: MPVController) {
        // Credits running to the very end: skipping means finishing.
        if seg.kind == .outro, p.duration - seg.end < 5 {
            p.seek(to: max(0, p.duration - 1))
        } else {
            p.seek(to: seg.end)
        }
        poke()
    }

    func playNext(_ next: Video) {
        guard !advancing else { return }
        advancing = true
        saveProgress()
        app.requestPlay(meta: request.meta, video: next, preferBingeGroup: stream.bingeGroup)
    }
}
