import AppKit
import Foundation
import SwiftUI

extension AppState {
    // MARK: Playback

    /// True while this title/episode is being started.
    func isStarting(_ videoId: String) -> Bool {
        playStatus?.phase == .working && playStatus?.videoId == videoId
    }

    /// Finds streams and plays the first one that checks out. Progress and failures
    /// show in the status panel, which can cancel it.
    func requestPlay(meta: Meta, video: Video?, preferBingeGroup: String? = nil) {
        playTask?.cancel()
        playTask = Task { await startPlayback(meta: meta, video: video, preferBingeGroup: preferBingeGroup) }
    }

    /// Plays one stream the user picked, after checking it.
    func requestPlay(meta: Meta, video: Video?, stream: StreamItem, alternatives: [StreamItem]) {
        playTask?.cancel()
        playTask = Task {
            playStatus = PlayStatus(meta: meta, video: video, message: "Checking stream…", detail: stream.oneLine)
            async let languages = boundedAudioLanguages(for: meta)
            switch await check(stream) {
            case .playable(let url):
                let alang = await languages
                guard !Task.isCancelled else { return }
                playStatus = nil
                play(meta: meta, video: video, stream: stream, url: url, alternatives: alternatives, audioLanguages: alang)
            case .failed(let reason), .unreachable(let reason):
                guard !Task.isCancelled else { return }
                playStatus = PlayStatus(meta: meta, video: video, phase: .failed,
                                        message: "That stream didn't work", detail: reason)
            }
        }
    }

    func cancelPlay() {
        playTask?.cancel()
        playTask = nil
        playStatus = nil
    }

    func startPlayback(meta: Meta, video: Video?, preferBingeGroup: String?) async {
        prewarmTask?.cancel()
        var status = PlayStatus(meta: meta, video: video, message: "Finding streams…")
        playStatus = status
        async let languages = boundedAudioLanguages(for: meta)
        let found: PreparedStreams
        do {
            found = try await preparedStreams(meta: meta, video: video).value
        } catch {
            guard !Task.isCancelled else { return }
            status.phase = .failed
            status.message = "Couldn't get streams"
            status.detail = error.localizedDescription
            playStatus = status
            return
        }
        guard !Task.isCancelled else { return }
        let streams = found.streams, matcher = found.matcher
        let ordered = order(streams, matcher: matcher, meta: meta, video: video, preferBingeGroup: preferBingeGroup)
        let candidates = Array(ordered.prefix(8))

        // Check one stream ahead of the one being waited on, so a dead link doesn't cost a
        // full round trip before the next is tried. At most two checks are in flight.
        var checks: [Int: Task<StreamProbe.Result, Never>] = [:]
        func launch(_ i: Int) {
            guard i < candidates.count, checks[i] == nil else { return }
            let stream = candidates[i]
            checks[i] = Task { await self.check(stream) }
        }
        defer { checks.values.forEach { $0.cancel() } }
        var unreachableCount = 0
        launch(0)
        for (i, stream) in candidates.enumerated() {
            launch(i + 1)
            status.message = candidates.count > 1 ? "Checking stream \(i + 1) of \(candidates.count)…" : "Checking stream…"
            status.detail = stream.oneLine
            playStatus = status
            let result = await checks[i]!.value
            guard !Task.isCancelled else { return }
            switch result {
            case .playable(let url):
                let alang = await languages
                guard !Task.isCancelled else { return }
                playStatus = nil
                play(meta: meta, video: video, stream: stream, url: url, alternatives: ordered, audioLanguages: alang)
                playback?.matcher = matcher
                return
            case .failed(let reason):
                status.failures.append("\(stream.oneLine): \(reason)")
            case .unreachable(let reason):
                unreachableCount += 1
                status.failures.append("\(stream.oneLine): \(reason)")
            }
        }

        status.phase = .failed
        if streams.isEmpty {
            status.message = "No streams found"
            status.detail = "Your addon didn't return anything for this."
        } else if candidates.isEmpty {
            status.message = "No playable streams"
            status.detail = "Only torrent or external results came back; those need a debrid service in AIOStreams."
        } else if unreachableCount == candidates.count {
            status.message = "Can't reach the streams"
            status.detail = "Check your connection and try again."
        } else {
            status.message = "None of the top \(candidates.count) streams worked"
            status.detail = nil
        }
        playStatus = status
    }

    /// Playable streams in the order Play tries them (see `StreamRanking`), given what
    /// was last played for this title.
    func order(_ streams: [StreamItem], matcher: EpisodeMatcher, meta: Meta, video: Video?, preferBingeGroup: String?) -> [StreamItem] {
        StreamRanking.order(streams, matcher: matcher, video: video, videoId: video?.id ?? meta.id,
                            remembered: watch.streamChoice(for: meta.id), preferBingeGroup: preferBingeGroup)
    }

    /// The order Play would try streams in (for checking the ranking).
    func rankedStreams(meta: Meta, video: Video?) async -> [StreamItem] {
        guard let found = try? await preparedStreams(meta: meta, video: video).value else { return [] }
        return order(found.streams, matcher: found.matcher, meta: meta, video: video, preferBingeGroup: nil)
    }

    // MARK: Prefetching

    /// The stream list (and wrong-episode matcher) for a video, shared between prefetching
    /// and Play so the addon is asked once. Kept 15 minutes; failures aren't kept.
    func preparedStreams(meta: Meta, video: Video?) -> Task<PreparedStreams, Error> {
        let key = video?.id ?? meta.id
        if let hit = prepared[key], Date().timeIntervalSince(hit.at) < 15 * 60 { return hit.task }
        let task = Task<PreparedStreams, Error> {
            async let matcher = EpisodeMatcher.make(meta: meta, video: video)
            let streams = try await self.streams(for: meta, video: video)
            return PreparedStreams(streams: streams, matcher: await matcher)
        }
        prepared[key] = (task, Date())
        prepared = prepared.filter { Date().timeIntervalSince($0.value.at) < 15 * 60 }
        Task {
            // An empty answer isn't kept either: it's often the addon having a bad moment.
            let result = await task.result
            let useless = (try? result.get())?.streams.isEmpty ?? true
            if useless, prepared[key]?.task == task { prepared[key] = nil }
        }
        return task
    }

    /// Checks a stream, reusing a recent result. Only successes are remembered: debrid
    /// links stay valid for hours, but a failure (e.g. still downloading) may clear up.
    func check(_ stream: StreamItem) async -> StreamProbe.Result {
        guard let key = stream.url else { return await StreamProbe.check(stream) }
        if let hit = probed[key], Date().timeIntervalSince(hit.at) < 20 * 60 { return .playable(hit.url) }
        let result = await StreamProbe.check(stream)
        if case .playable(let url) = result {
            probed = probed.filter { Date().timeIntervalSince($0.value.at) < 20 * 60 }
            probed[key] = (url, Date())
        }
        return result
    }

    /// Gets a title ready to play before the user presses Play: fetches its stream list and
    /// checks the stream Play would pick first. That's two requests, done once per video for
    /// 15 minutes. Only the latest call runs (opening another page or hovering another
    /// card cancels the last one), it waits a moment so pages flicked past cost nothing,
    /// and it stays quiet while something is playing.
    func prewarm(meta: Meta, video: Video?) {
        if meta.isSeriesLike, video == nil { return }
        runPrewarm { (meta, video) }
    }

    /// Same, for a Continue Watching entry (looks up the title first; that's cached too).
    func prewarm(_ entry: WatchEntry) {
        runPrewarm { [weak self] in
            guard let meta = await self?.fullMeta(type: entry.title.type, id: entry.title.id) else { return nil }
            return (meta, meta.videos.first { $0.id == entry.videoId })
        }
    }

    func runPrewarm(_ target: @escaping () async -> (Meta, Video?)?) {
        guard client != nil, playback == nil, playStatus?.phase != .working else { return }
        prewarmTask?.cancel()
        prewarmTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let (meta, video) = await target(), !Task.isCancelled else { return }
            async let languages = audioLanguages(for: meta)
            guard let found = try? await preparedStreams(meta: meta, video: video).value, !Task.isCancelled,
                  let first = order(found.streams, matcher: found.matcher, meta: meta, video: video, preferBingeGroup: nil).first
            else { return }
            _ = await check(first)
            _ = await languages
        }
    }

    func play(meta: Meta, video: Video?, stream: StreamItem, url: URL, alternatives: [StreamItem], audioLanguages: String?) {
        let videoId = video?.id ?? meta.id
        watch.rememberStream(stream, metaId: meta.id, videoId: videoId)
        playback = PlaybackRequest(
            meta: meta, video: video, stream: stream, url: url, alternatives: alternatives,
            startAt: watch.resumePosition(metaId: meta.id, videoId: videoId),
            audioLanguages: audioLanguages
        )
    }

    /// mpv `alang` for a title: its original language when that setting is on (with the
    /// manual list as a fallback), otherwise the manual list.
    /// `audioLanguages`, but Play doesn't wait more than a few seconds for the lookup. It
    /// still finishes in the background, so the next episode has the answer.
    func boundedAudioLanguages(for meta: Meta) async -> String? {
        let manual = settings.preferredAudioLanguages.trimmingCharacters(in: .whitespaces)
        var fallback: String? = manual.isEmpty ? nil : manual
        if settings.preferOriginalAudio, meta.isAnimeLike {
            fallback = (languageCodes("jpn") + (manual.isEmpty ? [] : [manual])).joined(separator: ",")
        }
        return await withinTime(5, fallback: fallback) { [self] in await audioLanguages(for: meta) }
    }

    func audioLanguages(for meta: Meta) async -> String? {
        let key = "\(settings.preferOriginalAudio)|\(settings.preferredAudioLanguages)|\(meta.id)"
        if let hit = languageCache[key] { return hit }
        let result = await lookUpAudioLanguages(for: meta)
        // Only answers are kept: a lookup that failed (Wikidata stalls now and then) is tried
        // again next time instead of leaving every episode on the file's default track.
        if result != nil { languageCache[key] = result }
        return result
    }

    func lookUpAudioLanguages(for meta: Meta) async -> String? {
        let manual = settings.preferredAudioLanguages.trimmingCharacters(in: .whitespaces)
        guard settings.preferOriginalAudio else { return manual.isEmpty ? nil : manual }
        guard let code = await DiscoveryService.originalLanguage(of: meta) else { return manual.isEmpty ? nil : manual }
        var codes = languageCodes(code)
        if !manual.isEmpty { codes.append(manual) }
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }.joined(separator: ",")
    }

    func nextVideo(in meta: Meta, after video: Video?) -> Video? {
        guard let video else { return nil }
        let ordered = meta.videos
            .filter { ($0.season ?? 1) > 0 }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
        guard let i = ordered.firstIndex(where: { $0.id == video.id }), i + 1 < ordered.count else { return nil }
        return ordered[i + 1]
    }

    /// Where "Play" should start for a title: the episode in progress, else the next one, else the first.
    func resumeTarget(for meta: Meta) -> (video: Video?, label: String) {
        guard meta.isSeriesLike, !meta.videos.isEmpty else {
            if let e = watch.entry(for: meta.id), e.position > 30, !e.isFinished {
                return (nil, "Resume · \(formatRemaining(e.remaining)) left")
            }
            return (nil, "Play")
        }
        let ordered = meta.videos
            .filter { ($0.season ?? 1) > 0 }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
        if let e = watch.entry(for: meta.id), let current = ordered.first(where: { $0.id == e.videoId }) {
            if !e.isFinished {
                return (current, "Resume \(e.episodeLabel ?? "")")
            }
            if let next = nextVideo(in: meta, after: current) {
                let label = next.season.flatMap { s in next.episode.map { String(format: "S%02dE%02d", s, $0) } } ?? ""
                return (next, "Play \(label)")
            }
        }
        if let first = ordered.first {
            let label = first.season.flatMap { s in first.episode.map { String(format: "S%02dE%02d", s, $0) } } ?? ""
            return (first, "Play \(label)")
        }
        return (nil, "Play")
    }
}
