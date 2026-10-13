import AppKit
import Foundation
import Observation
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case home = "Home", library = "Library", search = "Search", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "house"
        case .library: "books.vertical"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

enum Route: Hashable {
    case detail(Meta)
    case catalog(CatalogDef)
    /// A person, plus the IMDb id of the title they were found on (to identify them).
    case person(CastMember, context: String?)
}

struct TrailerRequest: Equatable {
    var youTubeId: String
    var title: String
}

enum LoadState: Equatable {
    case idle, loading, loaded, failed(String)
}

/// One catalog row; loads its first page the first time it scrolls into view.
@Observable
@MainActor
final class CatalogRowModel: Identifiable {
    let def: CatalogDef
    var items: [Meta] = []
    var state: LoadState = .idle
    var reachedEnd = false

    nonisolated var id: String { def.key }

    init(def: CatalogDef) { self.def = def }

    /// The first-page request. The row owns it, not the view that asked: scrolling a row
    /// out of view cancels the view's task, and that must not cancel (and fail) the load.
    @ObservationIgnored private var firstPage: Task<Void, Never>?

    func loadIfNeeded(_ client: AddonClient?) async {
        guard let client else { return }
        if state == .idle {
            state = .loading
            firstPage = Task { [def] in
                do {
                    let metas = try await client.catalog(def)
                    // The posters a row shows first, prepared before it scrolls into view.
                    ImagePipeline.shared.prefetch(metas.prefix(10).compactMap(\.poster), maxPixel: 450)
                    items = metas
                    state = .loaded
                    reachedEnd = metas.isEmpty
                } catch {
                    state = .failed(error.localizedDescription)
                }
            }
        }
        await firstPage?.value
    }

    func retry(_ client: AddonClient?) {
        guard case .failed = state else { return }
        state = .idle
        Task { await loadIfNeeded(client) }
    }

    func loadMore(_ client: AddonClient?) async {
        guard state == .loaded, !reachedEnd, def.supports("skip"), let client else { return }
        state = .loading
        do {
            let page = try await client.catalog(def, skip: items.count)
            let seen = Set(items.map(\.id))
            let fresh = page.filter { !seen.contains($0.id) }
            items += fresh
            reachedEnd = fresh.isEmpty
        } catch {
            reachedEnd = true
        }
        state = .loaded
    }
}

struct PlaybackRequest: Identifiable {
    let id = UUID()
    var meta: Meta
    var video: Video?
    var stream: StreamItem
    /// Where the stream's link resolved to when it was checked; mpv opens this.
    var url: URL
    var alternatives: [StreamItem]
    var startAt: Double?
    /// mpv `alang` list for this title, e.g. "jpn,ja" for original-language audio.
    var audioLanguages: String?
    /// Recognises files that belong to a different season/entry, for the after-open check.
    var matcher: EpisodeMatcher = .none

    var videoId: String { video?.id ?? meta.id }
    var title: String { meta.name }
    var subtitle: String? {
        guard let v = video else { return meta.year }
        let label = v.season.flatMap { s in v.episode.map { String(format: "S%d · E%d", s, $0) } }
        return [label, v.title.isEmpty ? nil : v.title].compactMap { $0 }.joined(separator: "  ")
    }
}

/// What the play-progress panel shows while a title is being started.
struct PlayStatus: Equatable {
    enum Phase: Equatable { case working, failed }
    var meta: Meta
    var video: Video?
    var phase: Phase = .working
    var message: String
    var detail: String?
    var failures: [String] = []

    var videoId: String { video?.id ?? meta.id }
    var label: String {
        guard let v = video, let s = v.season, let e = v.episode else { return meta.name }
        return "\(meta.name) · S\(s) E\(e)"
    }
}

@Observable
@MainActor
final class AppState {
    let settings = Settings()
    let watch = WatchStore()
    let downloads = DownloadManager()
    let updater = Updater()
    /// Watch progress shared with AIOStreams' Jellyfin profile (Odin etc.), and Simkl.
    let jellyfin: JellyfinSync
    let simkl: SimklSync

    var tab: Tab = .home { didSet { if tab != oldValue { routes = [] } } }
    var routes: [Route] = []
    var playback: PlaybackRequest?
    var playStatus: PlayStatus?
    var picker: PickerTarget?
    var trailer: TrailerRequest?
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private var prewarmTask: Task<Void, Never>?
    /// Stream lists fetched ahead of Play, by video id (the addon takes ~7 s per lookup).
    @ObservationIgnored private var prepared: [String: (task: Task<PreparedStreams, Error>, at: Date)] = [:]
    /// Streams already checked, by addon URL → the resolved file URL mpv can open directly.
    @ObservationIgnored private var probed: [String: (url: URL, at: Date)] = [:]
    @ObservationIgnored private var languageCache: [String: String?] = [:]

    var client: AddonClient?
    var manifest: Manifest?
    var connection: LoadState = .idle
    var rows: [CatalogRowModel] = []
    var heroes: [Meta] = []
    /// Next unaired episode of each show being followed, soonest first.
    var upcoming: [UpcomingEpisode] = []
    @ObservationIgnored private var upcomingCheckedAt: Date?
    /// Titles picked from what you've watched, best first.
    var recommendations: [Recommendation] = []
    @ObservationIgnored private var recommendationsBuiltAt: Date?
    var ambientImage: String?

    private var metaCache: [String: Meta] = [:]
    private var rowModels: [String: CatalogRowModel] = [:]

    init() {
        jellyfin = JellyfinSync(settings: settings, watch: watch)
        simkl = SimklSync(settings: settings)
        if !settings.manifestURL.isEmpty { Task { await connect() } }
        // Pick up what the other app played: on launch (after connecting), whenever Encore
        // comes to the front, and every 5 minutes.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.pullSync() } }
        }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.pullSync() } }
        }
    }

    // MARK: Sync (AIOStreams Jellyfin, Simkl)

    func pullSync() async {
        guard client != nil, ProcessInfo.processInfo.environment["ENCORE_ROUTE"] == nil else { return }
        await jellyfin.pull { [weak self] type, id in await self?.fullMeta(type: type, id: id) }
        await simkl.pull(watch: watch) { [weak self] type, id in await self?.fullMeta(type: type, id: id) }
    }

    func setWatched(_ meta: Meta, videos: [Video], watched: Bool) {
        watch.setWatched(meta, videos: videos, watched: watched)
        jellyfin.setWatched(meta: meta, videos: videos, watched: watched)
        simkl.setWatched(meta: meta, videos: videos, watched: watched)
    }

    /// Watched through this episode (and every regular one before it).
    func markWatched(upTo video: Video, in meta: Meta, episodes: [Video]) {
        watch.setWatched(meta, videos: episodes, watched: true)
        jellyfin.playedUpTo(meta: meta, video: video)
        simkl.setWatched(meta: meta, videos: episodes, watched: true)
    }

    func setDropped(_ metaId: String, _ dropped: Bool) {
        watch.setDropped(metaId, dropped)
        if let meta = metaCache[metaId] { jellyfin.setDropped(meta: meta, dropped: dropped) }
    }

    // MARK: Addon

    func connect() async {
        connection = .loading
        do {
            let client = try AddonClient(manifestURL: settings.manifestURL)
            let manifest = try await client.manifest()
            self.client = client
            self.manifest = manifest
            metaCache = [:]
            prepared = [:]
            probed = [:]
            rowModels = [:]
            heroes = []
            rebuildRows()
            connection = .loaded
            await loadHeroes()
            // The show you were last watching is the likeliest thing to be played next.
            await pullSync()
            if let latest = watch.continueWatching.first { prewarm(latest) }
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    /// Every browsable catalog, in the user's chosen order.
    var orderedCatalogs: [CatalogDef] {
        let all = (manifest?.catalogs ?? []).filter(\.isBrowsable)
        let rank = Dictionary(settings.catalogOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return all.enumerated().sorted { a, b in
            let ra = rank[a.element.key] ?? Int.max
            let rb = rank[b.element.key] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Addon catalogs worth searching: movie/show/anime ones, not debrid stores or libraries.
    var addonSearchCatalogs: [CatalogDef] {
        (manifest?.catalogs ?? []).filter { c in
            c.isSearchable && ["movie", "series", "anime", "anime.series", "anime.movie"].contains(c.type)
        }
    }

    func rebuildRows() {
        rows = orderedCatalogs
            .filter { !settings.hiddenCatalogs.contains($0.key) }
            .map { def in
                if let m = rowModels[def.key] { return m }
                let m = CatalogRowModel(def: def)
                rowModels[def.key] = m
                return m
            }
    }

    /// Loads the next few Home rows' first pages ahead of time (they load once each).
    func prefetchRows(after row: CatalogRowModel, count: Int = 3) {
        guard let client, let i = rows.firstIndex(where: { $0 === row }) else { return }
        for next in rows.dropFirst(i + 1).prefix(count) where next.state == .idle {
            Task { await next.loadIfNeeded(client) }
        }
    }

    func row(for def: CatalogDef) -> CatalogRowModel {
        if let m = rowModels[def.key] { return m }
        let m = CatalogRowModel(def: def)
        rowModels[def.key] = m
        return m
    }

    func moveCatalogs(from: IndexSet, to: Int) {
        var keys = orderedCatalogs.map(\.key)
        keys.move(fromOffsets: from, toOffset: to)
        settings.catalogOrder = keys
        rebuildRows()
    }

    func moveCatalog(_ def: CatalogDef, toTop: Bool) {
        var keys = orderedCatalogs.map(\.key)
        keys.removeAll { $0 == def.key }
        if toTop { keys.insert(def.key, at: 0) } else { keys.append(def.key) }
        settings.catalogOrder = keys
        rebuildRows()
    }

    func setCatalog(_ def: CatalogDef, visible: Bool) {
        if visible { settings.hiddenCatalogs.remove(def.key) } else { settings.hiddenCatalogs.insert(def.key) }
        rebuildRows()
    }

    /// The hero carousel: titles with artwork from the first rows that have any.
    private func loadHeroes() async {
        var picked: [Meta] = []
        for row in rows.prefix(4) {
            await row.loadIfNeeded(client)
            picked += row.items.filter { $0.background != nil }.prefix(3)
            if picked.count >= 6 { break }
        }
        heroes = Array(picked.prefix(6))
        ambientImage = heroes.first?.background
        // Logos and cast usually only come with the full meta.
        await withTaskGroup(of: Meta?.self) { group in
            for h in heroes { group.addTask { await self.fullMeta(h) } }
            for await full in group {
                guard let full, let i = heroes.firstIndex(where: { $0.id == full.id }) else { continue }
                heroes[i] = heroes[i].merged(with: full)
            }
        }
    }

    func fullMeta(_ preview: Meta) async -> Meta? {
        if let m = metaCache[preview.id] { return m }
        guard let client else { return nil }
        guard let full = try? await client.meta(type: preview.type, id: preview.id) else { return nil }
        let merged = await addingMissingAnimeSeasons(preview.merged(with: full))
        metaCache[preview.id] = merged
        return merged
    }

    func fullMeta(type: String, id: String) async -> Meta? {
        if let m = metaCache[id] { return m }
        guard let client, let full = try? await client.meta(type: type, id: id) else { return nil }
        let completed = await addingMissingAnimeSeasons(full)
        metaCache[id] = completed
        return completed
    }

    /// IMDb-keyed listings of anime often stop at the first season while anime databases
    /// already have the next (The Ramparts of Ice: Season 2 is its own MyAnimeList entry).
    /// Seasons with no episodes here are filled from the addon's anime entry for them,
    /// numbered as that season with IMDb-style ids, so streams resolve the same way.
    private func addingMissingAnimeSeasons(_ meta: Meta) async -> Meta {
        guard meta.isSeriesLike, let imdb = meta.imdbId, meta.id.hasPrefix("tt"), let client,
              meta.isAnimeLike || meta.genres.contains(where: { $0.lowercased() == "animation" }) else { return meta }
        let have = Set(meta.videos.compactMap(\.season))
        let missing = await DiscoveryService.animeSeasons(imdb: imdb).filter { !have.contains($0.key) }
        guard !missing.isEmpty else { return meta }
        var added: [Video] = []
        for (season, mal) in missing.sorted(by: { $0.key < $1.key }) {
            guard let entry = try? await client.meta(type: "anime", id: "mal:\(mal)") else { continue }
            for v in entry.videos where (v.season ?? 1) > 0 {
                var ep = v
                ep.season = season
                if let e = v.episode { ep.id = "\(imdb):\(season):\(e)" }
                added.append(ep)
            }
        }
        guard !added.isEmpty else { return meta }
        var m = meta
        var seen = Set(m.videos.map(\.id))
        m.videos += added.filter { seen.insert($0.id).inserted }
        return m
    }

    func streams(for meta: Meta, video: Video?) async throws -> [StreamItem] {
        guard let client else { return [] }
        return try await client.streams(type: meta.type, videoId: video?.id ?? meta.id)
    }

    // MARK: Upcoming

    /// Shows you're watching, saved, or have watched (not dropped): the next episode of
    /// each with a future air date. Up to 25 shows, refreshed at most every 30 minutes.
    func loadUpcoming() async {
        guard client != nil else { return }
        if let t = upcomingCheckedAt, Date().timeIntervalSince(t) < 30 * 60 { return }
        upcomingCheckedAt = Date()
        var seen = Set<String>()
        let followed = (watch.continueWatching.map(\.title) + watch.favorites + watch.watchHistory.map(\.title))
            .filter { $0.type != "movie" && !watch.isDropped($0.id) && seen.insert($0.id).inserted }
            .prefix(25)
        var found: [UpcomingEpisode] = []
        await withTaskGroup(of: UpcomingEpisode?.self) { group in
            for title in followed {
                group.addTask { @MainActor in
                    guard let meta = await self.fullMeta(type: title.type, id: title.id) else { return nil }
                    let now = Date()
                    let next = meta.videos
                        .filter { ($0.season ?? 1) > 0 && ($0.released ?? .distantPast) > now }
                        .min { ($0.released ?? .distantFuture) < ($1.released ?? .distantFuture) }
                    guard let next else { return nil }
                    let lengths = await DiscoveryService.episodeDetails(for: meta)
                    return UpcomingEpisode(meta: meta, video: next, runtime: lengths.minutes(season: next.season, episode: next.episode))
                }
            }
            for await item in group { if let item { found.append(item) } }
        }
        upcoming = found.sorted { ($0.video.released ?? .distantFuture) < ($1.video.released ?? .distantFuture) }
    }

    // MARK: Recommendations

    /// "Recommended for You": related titles of what you've watched lately (and My List),
    /// scored by how strongly and how often they're suggested, minus anything you've
    /// already seen or dropped. Built at most every 6 hours.
    func loadRecommendations(force: Bool = false) async {
        guard client != nil else { return }
        if !force, let t = recommendationsBuiltAt, Date().timeIntervalSince(t) < 6 * 3600 { return }
        recommendationsBuiltAt = Date()

        // Starting points: loved and liked titles first, then what you've watched lately and
        // My List. Disliked titles never seed, and pull their relatives down instead.
        var seenIds = Set<String>()
        let rated = watch.ratedTitles
        let positive = rated.filter { $0.rating != .dislike }.sorted { $0.rating.rawValue > $1.rating.rawValue }.map(\.title)
        let disliked = rated.filter { $0.rating == .dislike }.map(\.title)
        let seeds = (positive + watch.continueWatching.map(\.title) + watch.watchHistory.map(\.title) + watch.favorites)
            .filter { !watch.isDropped($0.id) && watch.rating(for: $0.id) != .dislike && seenIds.insert($0.id).inserted }
            .prefix(10)
        let negativeSeeds = Array(disliked.prefix(4))
        guard !seeds.isEmpty else { return }
        let watchedIds = Set(watch.watchHistory.map(\.title.id) + watch.history.map(\.title.id) + watch.favorites.map(\.id))
        let watchedNames = Set((watch.watchHistory.map(\.title.name) + watch.history.map(\.title.name)).map(Self.normalizedName))

        // How much a section counts: AniList's crowd recommendations most, franchise next.
        func weight(_ section: String) -> Double {
            switch section {
            case "You Might Also Like": 3
            case "Seasons & Related", "In This Franchise": 2
            default: 1
            }
        }
        var scores: [String: (meta: Meta, score: Double, because: String, best: Double)] = [:]
        await withTaskGroup(of: (SavedTitle, [DiscoveryService.Section]).self) { group in
            for (rank, seed) in (Array(seeds) + negativeSeeds).enumerated() {
                group.addTask { @MainActor in
                    guard let meta = await self.fullMeta(type: seed.type, id: seed.id) else { return (seed, []) }
                    _ = rank
                    return (seed, await DiscoveryService.related(to: meta))
                }
            }
            for await (seed, sections) in group {
                // More recent seeds count a little more; your rating scales it (negative for
                // titles you didn't like).
                let recency = 1 + 0.5 * Double(seeds.count - (seeds.firstIndex(of: seed) ?? 0)) / Double(seeds.count)
                let ratingWeight = watch.rating(for: seed.id)?.weight ?? 1
                for section in sections {
                    for (i, m) in section.items.prefix(20).enumerated() {
                        guard !watchedIds.contains(m.id), !watch.isDropped(m.id), !watch.isNotInterested(m.id),
                              !watchedNames.contains(Self.normalizedName(m.name)), m.poster != nil else { continue }
                        guard watch.rating(for: m.id) == nil else { continue }
                        let s = weight(section.title) * recency * ratingWeight * (1 - Double(i) / 25)
                        var entry = scores[m.id] ?? (m, 0, seed.name, 0)
                        entry.score += s
                        if s > entry.best { entry.best = s; entry.because = seed.name }
                        scores[m.id] = entry
                    }
                }
            }
        }
        recommendations = scores.values
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(48)
            .map { Recommendation(meta: $0.meta, because: $0.because) }
    }

    /// Rates a title and rebuilds recommendations around it.
    func rate(_ meta: SavedTitle, _ rating: Rating?) {
        watch.setRating(rating, for: meta)
        Task { await loadRecommendations(force: true) }
    }

    /// Hides a recommendation now and from future ones.
    func notInterested(in rec: Recommendation) {
        watch.markNotInterested(rec.meta.id)
        withAnimation(.easeOut(duration: 0.25)) { recommendations.removeAll { $0.id == rec.id } }
    }

    private static func normalizedName(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Navigation

    func open(_ meta: Meta) { routes.append(.detail(meta)) }
    func open(_ catalog: CatalogDef) { routes.append(.catalog(catalog)) }
    func open(_ person: CastMember, context: String? = nil) { routes.append(.person(person, context: context)) }
    func back() { _ = routes.popLast() }

    func open(_ saved: SavedTitle) {
        Task {
            let m = await fullMeta(type: saved.type, id: saved.id)
            if let m { open(m) }
        }
    }

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
            async let languages = audioLanguages(for: meta)
            switch await check(stream) {
            case .playable(let url):
                let alang = await languages
                guard !Task.isCancelled else { return }
                playStatus = nil
                play(meta: meta, video: video, stream: stream, url: url, alternatives: alternatives, audioLanguages: alang)
            case .failed(let reason):
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

    private func startPlayback(meta: Meta, video: Video?, preferBingeGroup: String?) async {
        prewarmTask?.cancel()
        var status = PlayStatus(meta: meta, video: video, message: "Finding streams…")
        playStatus = status
        async let languages = audioLanguages(for: meta)
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
            }
        }

        status.phase = .failed
        if streams.isEmpty {
            status.message = "No streams found"
            status.detail = "Your addon didn't return anything for this."
        } else if candidates.isEmpty {
            status.message = "No playable streams"
            status.detail = "Only torrent or external results came back; those need a debrid service in AIOStreams."
        } else {
            status.message = "None of the top \(candidates.count) streams worked"
            status.detail = nil
        }
        playStatus = status
    }

    /// Playable streams in the order to try them: the exact stream last played for this
    /// episode, then the same release group (the last episode's, else the one last used for
    /// this title), then AIOStreams' own order, with last resorts (worst last): files from
    /// another season/entry, OVAs/specials when a regular episode was asked for, and Dolby
    /// Vision-only files (wrong colors here).
    private func order(_ streams: [StreamItem], matcher: EpisodeMatcher, meta: Meta, video: Video?, preferBingeGroup: String?) -> [StreamItem] {
        let remembered = watch.streamChoice(for: meta.id)
        let group = preferBingeGroup ?? remembered?.bingeGroup
        var seen = Set<String>()
        let playable = streams.filter { $0.isPlayable && seen.insert($0.url!).inserted }
        let grouped = playable.filter { group != nil && $0.bingeGroup == group }
            + playable.filter { group == nil || $0.bingeGroup != group }
        let wantsRegularEpisode = (video?.season ?? 1) > 0 && !StreamItem.isExtraName(video?.title ?? "")
        // Series packs: no episode in the name and far bigger than the real episodes (a 33 GB
        // "Kusuriya no Hitorigoto" folder among 1.5 GB episodes). The debrid service picks
        // some file inside, often from another season, so they're tried last.
        let episodeSizes = playable.filter { matcher.identifiesEpisode($0) }.compactMap(\.videoSize).sorted()
        let typicalSize = episodeSizes.isEmpty ? nil : episodeSizes[episodeSizes.count / 2]
        func looksLikePack(_ s: StreamItem) -> Bool {
            guard video?.season != nil, !matcher.identifiesEpisode(s), let size = s.videoSize else { return false }
            return size > max(8_000_000_000, (typicalSize ?? 0) * 4)
        }
        func penalty(_ s: StreamItem) -> Int {
            (matcher.isMismatch(s) ? 4 : 0) + (looksLikePack(s) ? 3 : 0)
                + (wantsRegularEpisode && s.looksLikeExtra ? 2 : 0) + (s.isDolbyVisionOnly ? 1 : 0)
        }
        var ordered = grouped.enumerated()
            .sorted { (penalty($0.element), $0.offset) < (penalty($1.element), $1.offset) }
            .map(\.element)
        // The user's own pick (or what last played fine) beats the heuristics.
        // (Unless it's from another season/entry, so a wrong file played once can't stick.)
        if let remembered, remembered.videoId == (video?.id ?? meta.id),
           let i = ordered.firstIndex(where: { remembered.matches($0) && !matcher.isMismatch($0) }) {
            ordered.insert(ordered.remove(at: i), at: 0)
        }
        return ordered
    }

    /// The order Play would try streams in (for checking the ranking).
    func rankedStreams(meta: Meta, video: Video?) async -> [StreamItem] {
        guard let found = try? await preparedStreams(meta: meta, video: video).value else { return [] }
        return order(found.streams, matcher: found.matcher, meta: meta, video: video, preferBingeGroup: nil)
    }

    // MARK: Prefetching

    /// The stream list (and wrong-episode matcher) for a video, shared between prefetching
    /// and Play so the addon is asked once. Kept 15 minutes; failures aren't kept.
    private func preparedStreams(meta: Meta, video: Video?) -> Task<PreparedStreams, Error> {
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
            if case .failure = await task.result, prepared[key]?.task == task { prepared[key] = nil }
        }
        return task
    }

    /// Checks a stream, reusing a recent result. Only successes are remembered: debrid
    /// links stay valid for hours, but a failure (e.g. still downloading) may clear up.
    private func check(_ stream: StreamItem) async -> StreamProbe.Result {
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

    private func runPrewarm(_ target: @escaping () async -> (Meta, Video?)?) {
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

    private func play(meta: Meta, video: Video?, stream: StreamItem, url: URL, alternatives: [StreamItem], audioLanguages: String?) {
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
    private func audioLanguages(for meta: Meta) async -> String? {
        let key = "\(settings.preferOriginalAudio)|\(settings.preferredAudioLanguages)|\(meta.id)"
        if let hit = languageCache[key] { return hit }
        let result = await lookUpAudioLanguages(for: meta)
        languageCache[key] = result
        return result
    }

    private func lookUpAudioLanguages(for meta: Meta) async -> String? {
        let manual = settings.preferredAudioLanguages.trimmingCharacters(in: .whitespaces)
        guard settings.preferOriginalAudio else { return manual.isEmpty ? nil : manual }
        guard let code = await DiscoveryService.originalLanguage(of: meta) else { return manual.isEmpty ? nil : manual }
        var codes = [code]
        if let two = Locale.LanguageCode(code).identifier(.alpha2) { codes.append(two) }
        switch code {
        case "chi", "zho": codes += ["zho", "chi", "zh", "cmn"]
        case "fil", "tgl": codes += ["fil", "tgl", "tl"]
        case "fre", "fra": codes += ["fra", "fre"]
        case "ger", "deu": codes += ["deu", "ger"]
        default: break
        }
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

struct Recommendation: Identifiable {
    let meta: Meta
    /// The watched title that led here, for "Because you watched …".
    let because: String
    var id: String { meta.id }
}

struct UpcomingEpisode: Identifiable {
    let meta: Meta
    let video: Video
    var runtime: Int?
    var id: String { video.id }
}

struct PreparedStreams {
    let streams: [StreamItem]
    let matcher: EpisodeMatcher
}

func formatRemaining(_ seconds: Double) -> String {
    let m = Int(seconds / 60)
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(max(1, m))m"
}

func formatClock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let s = Int(seconds)
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}
