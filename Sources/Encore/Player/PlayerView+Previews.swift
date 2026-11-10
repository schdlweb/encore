import AppKit
import SwiftUI

extension PlayerView {
    @discardableResult
    func makeThumbnailer(_ p: MPVController) -> ThumbnailGenerator {
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

    /// The frame in the bubble isn't the exact one for where the pointer is (yet).
    var previewIsStale: Bool {
        guard let h = hoverTime, let g = thumbs else { return preview == nil }
        guard preview != nil, let shown = previewTime else { return true }
        return abs(shown - g.bucketed(h)) > 0.01
    }

    /// How far the bubble may show a nearby ready frame (labelled with its own time)
    /// while the exact one loads.
    var snapWindow: Double { max(30, (player?.duration ?? 0) * 0.02) }

    func hoverPreview(_ t: Double?, player p: MPVController) {
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
}
