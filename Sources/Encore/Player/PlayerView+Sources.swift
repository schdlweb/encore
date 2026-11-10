import AppKit
import SwiftUI

extension PlayerView {
    var nextUntriedStream: StreamItem? {
        request.alternatives.first { $0.isPlayable && !triedURLs.contains($0.url ?? "") }
    }

    /// Checks a stream like the start of playback does, then switches to it in place.
    func switchStream(to s: StreamItem, player p: MPVController, resumeAt position: Double? = nil, onFailure: (() -> Void)? = nil) {
        guard checkingStream == nil else { return }
        let resumeAt = position ?? (p.position > 5 ? p.position : request.startAt)
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
                if let onFailure { onFailure() } else { p.errorMessage = "That stream didn't work: \(reason)" }
            }
        }
    }

    /// The stream stopped well before the end of the video. It isn't the end of the
    /// episode: get a fresh link and carry on from the same spot, or failing that, another
    /// source. Nothing is marked watched and the next episode doesn't start.
    func recoverFromCutoff(_ p: MPVController) {
        guard let at = p.cutOffAt, checkingStream == nil, !advancing else { return }
        p.cutOffAt = nil
        let attempt = CutoffRecovery.after(cutoff, position: at)
        cutoff = attempt
        switch attempt.action {
        case .retrySameStream:
            showToast("Lost the stream, reconnecting")
            switchStream(to: stream, player: p, resumeAt: at) { moveToAnotherStream(p, at: at) }
        case .tryAnotherStream:
            moveToAnotherStream(p, at: at)
        case .giveUp:
            p.errorMessage = streamStoppedMessage(at)
        }
    }

    /// Sources that check out as dead are skipped, up to `tries` of them.
    private func moveToAnotherStream(_ p: MPVController, at: Double, tries: Int = 4) {
        guard tries > 0, let alt = request.alternatives.first(where: {
            $0.isPlayable && !$0.looksLikeExtra && !request.matcher.isMismatch($0) && !triedURLs.contains($0.url ?? "")
        }) else {
            p.errorMessage = streamStoppedMessage(at)
            return
        }
        showToast("Lost the stream, trying another source")
        switchStream(to: alt, player: p, resumeAt: at) { moveToAnotherStream(p, at: at, tries: tries - 1) }
    }

    private func streamStoppedMessage(_ at: Double) -> String {
        "The stream stopped at \(formatClock(at)) and couldn't be resumed."
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
