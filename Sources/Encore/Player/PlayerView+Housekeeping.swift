import AppKit
import SwiftUI

extension PlayerView {
    // MARK: Upkeep

    /// Twice a second while the player is up. Each step looks at the player and does its
    /// one job if it's due.
    func housekeeping() async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            tick += 1
            guard let p = player, !tornDown else { continue }
            autoHideControls(p)
            trackProgress(p, tick: tick)
            reportPlayback(p, tick: tick)
            refreshReadouts(p, tick: tick)
            if p.fileLoaded { runOncePerFile(p) }
            preparePreviews(p)
            fitWindowOnce(p)
            autoSkip(p)
            p.checkEndOfData()
            recoverFromCutoff(p)
            finishIfEnded(p)
        }
    }

    /// Hides the controls and the pointer after three idle seconds of playback.
    private func autoHideControls(_ p: MPVController) {
        let idle = Date().timeIntervalSince(lastActivity) > 3
            && ProcessInfo.processInfo.environment["ENCORE_NO_AUTOHIDE"] == nil
        // Never while the pointer is on the playbar (e.g. looking through previews).
        if controlsVisible, idle, !menuOpen, !pointerOnBar, hoverTime == nil, !p.paused, p.fileLoaded, scrubbing == nil {
            controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// Saves the position every 5 s (and the moment the end is reached), and logs screen
    /// time every 15 s: only time actually spent playing.
    private func trackProgress(_ p: MPVController, tick: Int) {
        if tick % 10 == 0 || (!markedWatched && reachedEnd(p)) { saveProgress() }
        if p.fileLoaded, !p.paused, !p.buffering { unloggedWatchTime += 0.5 }
        if tick % 30 == 0, unloggedWatchTime > 0 {
            app.watch.logWatchTime(unloggedWatchTime, isMovie: request.video == nil)
            unloggedWatchTime = 0
        }
    }

    /// Tells AIOStreams, Simkl and Control Center what's happening: the start, every
    /// pause and resume as they happen, and the position now and then in between.
    private func reportPlayback(_ p: MPVController, tick: Int) {
        guard p.fileLoaded else { return }
        if reportedPaused != p.paused {
            app.jellyfin.playbackProgress(meta: request.meta, video: request.video, position: p.position, paused: p.paused)
            app.simkl.scrobble(p.paused ? "pause" : "start", meta: request.meta, video: request.video, position: p.position, duration: p.duration)
        } else if tick % 60 == 0 {
            app.jellyfin.playbackProgress(meta: request.meta, video: request.video, position: p.position, paused: p.paused)
        }
        if reportedPaused != p.paused || tick % 10 == 0 {
            reportedPaused = p.paused
            nowPlaying?.update(position: p.position, duration: p.duration, paused: p.paused, speed: p.speed)
        }
        if !p.buffering, playingSince == nil {
            playingSince = Date()
            app.jellyfin.playbackStarted(meta: request.meta, video: request.video, position: p.position)
            app.simkl.scrobble("start", meta: request.meta, video: request.video, position: p.position, duration: p.duration)
        }
    }

    /// The info panel (while it's open), the quality tags, and HDR for the current screen.
    private func refreshReadouts(_ p: MPVController, tick: Int) {
        if showInfo, tick % 2 == 0 { info = p.mediaInfo() }
        if tick % 4 == 0 { refreshQualityTags(p); updateHDROutput(p) }
    }

    /// Everything that happens once for each file, as soon as what it needs is known.
    private func runOncePerFile(_ p: MPVController) {
        if !once.addonSubtitles {
            once.addonSubtitles = true
            Task { await loadAddonSubtitles(p) }
        }
        if !once.dubbedAudio, !p.audioTracks.isEmpty {
            once.dubbedAudio = true
            avoidDubbedDefault(p)
        }
        if !once.wrongFile {
            once.wrongFile = true
            moveOnFromWrongFile(p)
        }
        if !once.dolbyVision {
            once.dolbyVision = true
            if p.dolbyVisionProfile() == 5 { withAnimation { dolbyVisionWarning = true } }
        }
        if !once.subtitles, !p.subtitleTracks.isEmpty {
            once.subtitles = true
            refineSubtitleChoice(p)
        }
        if !once.segments, p.duration > 0 {
            once.segments = true
            Task { await loadSegments(p) }
        }
    }

    /// A season pack can resolve to an OVA, or to another season's file, instead of the
    /// episode asked for; move on to another stream if so.
    private func moveOnFromWrongFile(_ p: MPVController) {
        let regular = (request.video?.season ?? 1) > 0 && !StreamItem.isExtraName(request.video?.title ?? "")
        guard regular, request.video != nil, let name = p.openedFileName() else { return }
        let wrongEntry = request.matcher.isMismatch(name)
        guard wrongEntry || StreamItem.isExtraName(name),
              let alt = request.alternatives.first(where: {
                  $0.isPlayable && !$0.looksLikeExtra && !request.matcher.isMismatch($0) && !triedURLs.contains($0.url ?? "")
              }) else { return }
        showToast(wrongEntry ? "That file was a different season, trying another stream"
                             : "That file was an OVA/special, trying another stream")
        switchStream(to: alt, player: p)
    }

    /// Opens the preview renderer once playback is going (opening a 4K stream takes it a
    /// few seconds, so it's ready before the first hover), then fills the timeline in the
    /// background.
    private func preparePreviews(_ p: MPVController) {
        guard app.settings.scrubPreviews else { return }
        if thumbs == nil, p.duration > 0, let since = playingSince, Date().timeIntervalSince(since) > 2 {
            makeThumbnailer(p)
        }
        if let t = thumbs, !thumbsSweeping {
            thumbsSweeping = true
            t.prefetch()
        }
    }

    /// The player window takes the video's shape the first time it's known.
    private func fitWindowOnce(_ p: MPVController) {
        guard inWindow, !aspectApplied, p.fileLoaded, let size = p.videoDisplaySize(), let w = hostWindow else { return }
        aspectApplied = true
        fitWindow(w, to: size)
    }

    private func autoSkip(_ p: MPVController) {
        guard app.settings.autoSkipIntros, let seg = activeSegment, seg.kind != .outro,
              !autoSkipped.contains(seg.id), scrubbing == nil else { return }
        autoSkipped.insert(seg.id)
        skip(seg, player: p)
        showToast(seg.kind == .intro ? "Skipped intro" : "Skipped recap")
    }

    /// At the end of the file: on to the next episode, or close.
    private func finishIfEnded(_ p: MPVController) {
        guard p.endedNaturally, !advancing else { return }
        saveProgress()
        if app.settings.autoplayNext, let next = nextVideo { playNext(next) } else { close() }
    }

    // MARK: The pieces

    /// HDR output while an HDR video is on a screen that can show it (follows the window
    /// between screens; the built-in XDR display can, most external monitors can't).
    func updateHDROutput(_ p: MPVController) {
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

    /// Some releases make a dub their default audio (Russian ones often put theirs first)
    /// and carry the original as another track. If mpv ended up on a dub that isn't a
    /// language asked for (e.g. the original language couldn't be looked up), switch to
    /// a track that isn't one.
    func avoidDubbedDefault(_ p: MPVController) {
        guard let current = p.audioTracks.first(where: { $0.id == p.selectedAudio }), current.isDub else { return }
        let wanted = Set((audioLanguages ?? "").split(separator: ",").map { normalizeLang(String($0)) })
        if let lang = current.lang, wanted.contains(normalizeLang(lang)) { return }
        guard let original = p.audioTracks.first(where: { !$0.isDub && !$0.isExternal && $0.lang != current.lang }) else { return }
        p.selectAudio(original.id)
    }

    func refreshQualityTags(_ p: MPVController) {
        guard p.fileLoaded else { return }
        var tags = p.qualityTags()
        if let source = stream.sourceTag { tags.insert(source, at: min(tags.count, tags.firstIndex(where: { ["Atmos", "5.1", "7.1"].contains($0) }) ?? tags.count)) }
        if tags != qualityTags { qualityTags = tags }
    }

    func flashTimeline() {
        seekFlashVisible = true
        seekFlashTask?.cancel()
        seekFlashTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            if !Task.isCancelled { seekFlashVisible = false }
        }
    }

    func poke() {
        lastActivity = Date()
        if !controlsVisible { controlsVisible = true }
    }

    /// Counted as watched from the credits on (episodes with known credit times), or in a
    /// movie's last stretch (its final ~8%, at most 10 and at least 2 minutes). Once
    /// watched it stays watched, even if the credits keep playing.
    func reachedEnd(_ p: MPVController) -> Bool {
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

    func saveProgress() {
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

    func loadAddonSubtitles(_ p: MPVController) async {
        let limit = app.settings.addonSubtitleLimit
        guard limit > 0, app.manifest?.supports("subtitles") == true, let client = app.client else { return }
        guard let subs = try? await client.subtitles(type: request.meta.type, videoId: request.videoId), !subs.isEmpty else { return }
        var prefs = subtitlePrefs
        let saved = savedSubtitleLanguage
        if let saved, !prefs.contains(saved) { prefs.insert(saved, at: 0) }
        let wanted = prefs.isEmpty ? subs : subs.filter { prefs.contains(normalizeLang($0.lang)) }
        let embeddedPreferred = p.subtitleTracks.contains { t in t.lang.map { prefs.contains(normalizeLang($0)) } ?? false }
        for (i, s) in wanted.prefix(limit).enumerated() {
            let lang = normalizeLang(s.lang)
            let name = Locale.current.localizedString(forLanguageCode: lang) ?? s.lang
            p.addSubtitle(url: s.url, title: "\(name) \(i + 1)", lang: lang)
        }
        // Subtitles picked for this title that the file itself doesn't have: the addon's.
        if let saved {
            guard !p.subtitleTracks.contains(where: { !$0.isExternal && $0.lang.map(normalizeLang) == saved }) else { return }
            try? await Task.sleep(for: .seconds(2))
            if let track = p.subtitleTracks.first(where: { $0.isExternal && $0.lang.map(normalizeLang) == saved }) {
                p.selectSubtitle(track.id)
            }
            return
        }
        if app.trackChoiceSubtitlesOff(request.meta.id) { return }
        // If the file had nothing in a preferred language, turn the first addon track on.
        if app.settings.subtitlesOnByDefault, !embeddedPreferred, p.selectedSubtitle == nil, !wanted.isEmpty {
            try? await Task.sleep(for: .seconds(2))
            if let first = p.subtitleTracks.first(where: \.isExternal) { p.selectSubtitle(first.id) }
        }
    }

    func showToast(_ text: String) {
        if ProcessInfo.processInfo.environment["ENCORE_ROUTE"] != nil { print("[toast] \(text)"); fflush(stdout) }
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { if toast == text { toast = nil } }
        }
    }
}
