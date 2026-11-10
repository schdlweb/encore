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

    func retry(_ client: AddonClient?, force: Bool = false) {
        switch state {
        case .failed: break
        case .loaded where force && items.isEmpty: break
        default: return
        }
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

/// The app's shared state. This file has the addon connection, catalogs, title details
/// and navigation; `AppState+Playback` finds, checks and starts streams, and
/// `AppState+Discovery` builds Upcoming and Recommended for You.
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
    @ObservationIgnored var playTask: Task<Void, Never>?
    @ObservationIgnored var prewarmTask: Task<Void, Never>?
    /// Stream lists fetched ahead of Play, by video id (the addon takes ~7 s per lookup).
    @ObservationIgnored var prepared: [String: (task: Task<PreparedStreams, Error>, at: Date)] = [:]
    /// Streams already checked, by addon URL → the resolved file URL mpv can open directly.
    @ObservationIgnored var probed: [String: (url: URL, at: Date)] = [:]
    @ObservationIgnored var languageCache: [String: String?] = [:]

    var client: AddonClient?
    var manifest: Manifest?
    var connection: LoadState = .idle
    var rows: [CatalogRowModel] = []
    var heroes: [Meta] = []
    /// Next unaired episode of each show being followed, soonest first.
    var upcoming: [UpcomingEpisode] = []
    /// Shows you were caught up on whose next episode has since come out, as Continue
    /// Watching entries that haven't been started (duration 0). Found with `upcoming`.
    var newEpisodes: [WatchEntry] = []

    /// Continue Watching: titles in progress, plus new episodes of shows you're caught up
    /// on, most recent first. A new episode drops out once you start or hide it.
    var continueRow: [WatchEntry] {
        let inProgress = watch.continueWatching
        let ids = Set(inProgress.map(\.title.id))
        let fresh = newEpisodes.filter {
            !ids.contains($0.title.id) && !watch.isDropped($0.title.id) && watch.entry(for: $0.title.id)?.videoId != $0.videoId
        }
        return (inProgress + fresh).sorted { $0.updatedAt > $1.updatedAt }
    }
    @ObservationIgnored var upcomingCheckedAt: Date?
    /// Titles picked from what you've watched, best first.
    var recommendations: [Recommendation] = []
    @ObservationIgnored var recommendationsBuiltAt: Date?
    var ambientImage: String?

    /// Full title details by id, with when they were fetched. Shows are asked for again
    /// after an hour (that's how a new episode is noticed while Encore stays open);
    /// movies after a day.
    private var metaCache: [String: (meta: Meta, at: Date)] = [:]

    private func cachedMeta(_ id: String, allowStale: Bool = false) -> Meta? {
        guard let hit = metaCache[id] else { return nil }
        let lifetime: TimeInterval = hit.meta.isSeriesLike ? 3600 : 24 * 3600
        return allowStale || Date().timeIntervalSince(hit.at) < lifetime ? hit.meta : nil
    }

    /// The running app, for the app delegate (quitting) and nothing else.
    @ObservationIgnored static weak var current: AppState?
    /// Set by the player while it's up: saves progress and reports the stop. Run on quit,
    /// where the player's view never gets to disappear.
    @ObservationIgnored var playerTeardown: (id: UUID, run: () -> Void)?
    private var rowModels: [String: CatalogRowModel] = [:]

    init() {
        jellyfin = JellyfinSync(settings: settings, watch: watch)
        simkl = SimklSync(settings: settings)
        Self.current = self
        if !settings.manifestURL.isEmpty { Task { await connect() } }
        // Pick up what the other app played: on launch (after connecting), whenever Encore
        // comes to the front, and every 5 minutes.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.pullSync() } }
        }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.pullSync() } }
        }
    }

    /// Before quitting: the player saves and reports its stop, the library is written
    /// out, and sync reports still on their way get a moment to arrive.
    func prepareToQuit() async {
        playerTeardown?.run()
        playerTeardown = nil
        watch.flushNow()
        await Outbox.shared.drain(timeout: 2.5)
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

    func removeFromContinue(_ entry: WatchEntry) {
        watch.removeFromContinue(entry.title.id)
        let imdb = cachedMeta(entry.title.id, allowStale: true)?.imdbId ?? entry.title.id
        jellyfin.clearResume(imdb: imdb, type: entry.title.type, season: entry.season, episode: entry.episode)
    }

    /// Subtitles were turned off for this title (and are on by default).
    func trackChoiceSubtitlesOff(_ metaId: String) -> Bool {
        watch.trackChoice(for: metaId)?.subtitles == TrackChoice.off
    }

    func setDropped(_ metaId: String, _ dropped: Bool) {
        watch.setDropped(metaId, dropped)
        if let meta = cachedMeta(metaId, allowStale: true) { jellyfin.setDropped(meta: meta, dropped: dropped) }
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
        if let m = cachedMeta(preview.id) { return m }
        guard let client else { return nil }
        async let title = SearchService.imdbTitle(preview.id)
        // Couldn't refresh (offline, addon down): the copy from earlier is better than nothing.
        guard var full = try? await client.meta(type: preview.type, id: preview.id) else {
            return cachedMeta(preview.id, allowStale: true)
        }
        if let t = await title { full.name = t }
        let merged = await addingMissingAnimeSeasons(preview.merged(with: full))
        metaCache[preview.id] = (merged, Date())
        return merged
    }

    func fullMeta(type: String, id: String) async -> Meta? {
        if let m = cachedMeta(id) { return m }
        guard let client else { return nil }
        async let title = SearchService.imdbTitle(id)
        guard var full = try? await client.meta(type: type, id: id) else { return cachedMeta(id, allowStale: true) }
        // The addon names some titles by their original title; IMDb's is the English one.
        if let t = await title { full.name = t }
        let completed = await addingMissingAnimeSeasons(full)
        metaCache[id] = (completed, Date())
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

    // MARK: Getting a title page ready

    /// Hidden from Continue Watching for this session (right-click → Hide).
    @ObservationIgnored var hiddenNewEpisodes: Set<String> = []

    @ObservationIgnored private var warmTask: Task<Void, Never>?

    /// On hovering a poster: fetch the title's details and decode its full-size background
    /// and logo, so its page opens already sharp. Only the latest hover is worked on.
    func warmDetail(_ preview: Meta) {
        warmTask?.cancel()
        warmTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let full = await fullMeta(preview), !Task.isCancelled else { return }
            if let bg = full.background ?? preview.background { ImagePipeline.shared.prefetch([bg], maxPixel: 2600) }
            if let logo = full.logo { ImagePipeline.shared.prefetch([logo], maxPixel: 900) }
        }
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

/// The ways files tag one language (ISO 639-2, its two-letter code, other spellings), for
/// mpv's `alang`.
func languageCodes(_ code: String) -> [String] {
    var codes = [code]
    if let two = Locale.LanguageCode(code).identifier(.alpha2) { codes.append(two) }
    switch code {
    case "chi", "zho": codes += ["zho", "chi", "zh", "cmn"]
    case "fil", "tgl": codes += ["fil", "tgl", "tl"]
    case "fre", "fra": codes += ["fra", "fre"]
    case "ger", "deu": codes += ["deu", "ger"]
    case "dut", "nld": codes += ["nld", "dut"]
    case "per", "fas": codes += ["fas", "per"]
    case "rum", "ron": codes += ["ron", "rum"]
    case "gre", "ell": codes += ["ell", "gre"]
    case "cze", "ces": codes += ["ces", "cze"]
    default: break
    }
    var seen = Set<String>()
    return codes.filter { seen.insert($0).inserted }
}
