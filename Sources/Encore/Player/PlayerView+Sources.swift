import AppKit
import SwiftUI

extension PlayerView {
    var nextUntriedStream: StreamItem? {
        request.alternatives.first { $0.isPlayable && !triedURLs.contains($0.url ?? "") }
    }

    /// Checks a stream like the start of playback does, then switches to it in place.
    func switchStream(to s: StreamItem, player p: MPVController) {
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
                p.errorMessage = "That stream didn't work: \(reason)"
            }
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
