import Foundation
import Observation

/// Enough of a title to show it again without asking the addon.
struct SavedTitle: Codable, Hashable, Identifiable {
    var id: String
    var type: String
    var name: String
    var poster: String?
    var background: String?
    var logo: String?
    var releaseInfo: String?

    init(_ m: Meta) {
        id = m.id
        type = m.type
        name = m.name
        poster = m.poster
        background = m.background
        logo = m.logo
        releaseInfo = m.releaseInfo
    }
}

struct WatchEntry: Codable, Hashable, Identifiable {
    var title: SavedTitle
    var videoId: String
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    var episodeThumbnail: String?
    var position: Double
    var duration: Double
    var updatedAt: Date

    var id: String { title.id }
    var progress: Double { duration > 0 ? min(1, position / duration) : 0 }
    var isFinished: Bool { duration > 0 && progress > 0.92 }
    var remaining: Double { max(0, duration - position) }

    var episodeLabel: String? {
        guard let s = season, let e = episode else { return nil }
        return String(format: "S%02dE%02d", s, e)
    }
}

/// The stream last played for a title: resuming that episode tries it first, and other
/// episodes prefer the same release (AIOStreams' binge group).
struct StreamChoice: Codable, Hashable {
    var videoId: String
    var url: String?
    var filename: String?
    var bingeGroup: String?

    func matches(_ s: StreamItem) -> Bool {
        (url != nil && s.url == url) || (filename != nil && s.filename == filename)
    }
}

/// Watch progress, finished episodes and the user's library, saved as JSON in
/// Application Support.
@Observable
@MainActor
final class WatchStore {
    private struct Disk: Codable {
        var entries: [String: WatchEntry] = [:]
        var progress: [String: Double] = [:] // videoId -> fraction watched
        var favorites: [SavedTitle] = []
        var streams: [String: StreamChoice] = [:] // metaId -> last stream played

        init() {}
        // Every field optional on disk, so files from older versions still load.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entries = try c.decodeIfPresent([String: WatchEntry].self, forKey: .entries) ?? [:]
            progress = try c.decodeIfPresent([String: Double].self, forKey: .progress) ?? [:]
            favorites = try c.decodeIfPresent([SavedTitle].self, forKey: .favorites) ?? []
            streams = (try? c.decodeIfPresent([String: StreamChoice].self, forKey: .streams)) ?? [:]
        }
    }

    private var disk = Disk()
    private let file: URL
    /// Separate from `disk` so logging watch time doesn't redraw everything showing progress.
    private(set) var stats = StatsDisk()
    private let statsFile: URL

    init() {
        Migration.runOnce()
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Encore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("library.json")
        statsFile = dir.appendingPathComponent("stats.json")
        if let data = try? Data(contentsOf: file), let d = try? JSONDecoder().decode(Disk.self, from: data) {
            disk = d
        }
        if let data = try? Data(contentsOf: statsFile), let s = try? JSONDecoder().decode(StatsDisk.self, from: data) {
            stats = s
        }
        seedStatsIfNeeded()
    }

    /// Watching from before stats existed: each title's last session, counted on the day it happened.
    private func seedStatsIfNeeded() {
        guard !stats.seeded else { return }
        for e in disk.entries.values {
            let key = StatsDisk.hourFormat.string(from: e.updatedAt)
            if e.season == nil { stats.movieHours[key, default: 0] += e.position } else { stats.showHours[key, default: 0] += e.position }
            stats.history.append(HistoryItem(title: e.title, videoId: e.videoId, season: e.season, episode: e.episode,
                                             episodeTitle: e.episodeTitle, thumbnail: e.episodeThumbnail, watchedAt: e.updatedAt))
        }
        stats.history.sort { $0.watchedAt > $1.watchedAt }
        stats.seeded = true
        saveStats()
    }

    private func saveStats() {
        guard !isTestRun else { return }
        let snapshot = stats
        let file = statsFile
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }
    }

    // MARK: Stats

    /// Adds viewing time (seconds actually spent playing) to the current hour.
    func logWatchTime(_ seconds: Double, isMovie: Bool) {
        guard seconds > 0 else { return }
        let key = StatsDisk.hourFormat.string(from: .now)
        if isMovie { stats.movieHours[key, default: 0] += seconds } else { stats.showHours[key, default: 0] += seconds }
        saveStats()
    }

    func screenTime(_ period: ScreenTime.Period, _ kind: ScreenTime.Kind) -> ScreenTime {
        ScreenTime(stats: stats, period: period, kind: kind)
    }

    var watchHistory: [HistoryItem] { stats.history }

    func removeFromHistory(_ videoId: String) {
        stats.history.removeAll { $0.videoId == videoId }
        saveStats()
    }

    private func logHistory(_ e: WatchEntry) {
        stats.history.removeAll { $0.videoId == e.videoId }
        stats.history.insert(HistoryItem(title: e.title, videoId: e.videoId, season: e.season, episode: e.episode,
                                         episodeTitle: e.episodeTitle, thumbnail: e.episodeThumbnail, watchedAt: e.updatedAt), at: 0)
        if stats.history.count > 500 { stats.history.removeLast(stats.history.count - 500) }
        saveStats()
    }

    // MARK: Ratings

    func rating(for id: String) -> Rating? { stats.ratings[id]?.rating }

    func setRating(_ rating: Rating?, for title: SavedTitle) {
        if let rating { stats.ratings[title.id] = RatedTitle(title: title, rating: rating, ratedAt: .now) }
        else { stats.ratings[title.id] = nil }
        saveStats()
    }

    var ratedTitles: [RatedTitle] { stats.ratings.values.sorted { $0.ratedAt > $1.ratedAt } }

    // MARK: Not interested

    func isNotInterested(_ id: String) -> Bool { stats.notInterested.contains(id) }

    func markNotInterested(_ id: String) {
        guard !stats.notInterested.contains(id) else { return }
        stats.notInterested.append(id)
        saveStats()
    }

    func clearNotInterested() {
        stats.notInterested = []
        saveStats()
    }

    // MARK: Dropping

    func isDropped(_ metaId: String) -> Bool { stats.dropped.contains(metaId) }

    func setDropped(_ metaId: String, _ dropped: Bool) {
        stats.dropped.removeAll { $0 == metaId }
        if dropped { stats.dropped.insert(metaId, at: 0) }
        saveStats()
    }

    /// Dropped shows, newest first, as far as the library knows them.
    var droppedTitles: [SavedTitle] {
        stats.dropped.compactMap { id in
            disk.entries[id]?.title ?? disk.favorites.first { $0.id == id } ?? stats.history.first { $0.title.id == id }?.title
        }
    }

    /// Scripted test runs (ENCORE_ROUTE) play things; they mustn't land in the real history.
    private let isTestRun = ProcessInfo.processInfo.environment["ENCORE_ROUTE"] != nil

    private func save() {
        guard !isTestRun else { return }
        let snapshot = disk
        let file = file
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }
    }

    var continueWatching: [WatchEntry] {
        disk.entries.values
            .filter { $0.position > 30 && !$0.isFinished && !stats.dropped.contains($0.title.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var history: [WatchEntry] {
        disk.entries.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    var favorites: [SavedTitle] { disk.favorites }

    func entry(for metaId: String) -> WatchEntry? { disk.entries[metaId] }

    /// Fraction watched for one video (an episode, or a movie's single video).
    func progress(videoId: String) -> Double { disk.progress[videoId] ?? 0 }

    /// Seconds to resume one specific video from, if it's the one last played.
    func resumePosition(metaId: String, videoId: String) -> Double? {
        guard let e = disk.entries[metaId], e.videoId == videoId, e.position > 30, !e.isFinished else { return nil }
        return e.position
    }

    func record(_ entry: WatchEntry) {
        let isNewVideo = disk.entries[entry.title.id]?.videoId != entry.videoId
        disk.entries[entry.title.id] = entry
        disk.progress[entry.videoId] = entry.progress
        save()
        // History: once a minute in, and again when it moves to the front (another video).
        if entry.position > 60, isNewVideo || stats.history.first?.videoId != entry.videoId {
            logHistory(entry)
        }
    }

    func streamChoice(for metaId: String) -> StreamChoice? { disk.streams[metaId] }

    func rememberStream(_ s: StreamItem, metaId: String, videoId: String) {
        let choice = StreamChoice(videoId: videoId, url: s.url, filename: s.filename, bingeGroup: s.bingeGroup)
        guard disk.streams[metaId] != choice else { return }
        disk.streams[metaId] = choice
        save()
    }

    /// Forgets how much of one episode was watched. If it's the one Continue Watching
    /// points at, the show drops out of Continue Watching too.
    func clearProgress(metaId: String, videoId: String) {
        disk.progress[videoId] = nil
        if disk.entries[metaId]?.videoId == videoId { disk.entries[metaId] = nil }
        save()
    }

    // MARK: Marking watched

    /// Marks episodes (or, with no videos, the movie itself) as watched or unwatched.
    /// Watched ones count in History and move the show on to the next episode.
    func setWatched(_ meta: Meta, videos: [Video], watched: Bool) {
        let title = SavedTitle(meta)
        let items: [(id: String, video: Video?)] = videos.isEmpty ? [(meta.id, nil)] : videos.map { ($0.id, $0) }
        for item in items { disk.progress[item.id] = watched ? 1 : nil }
        if watched {
            // Continue from the furthest one marked, unless something later is in progress.
            let last = items.max { ($0.video?.season ?? 0, $0.video?.episode ?? 0) < ($1.video?.season ?? 0, $1.video?.episode ?? 0) }!
            let current = disk.entries[meta.id]
            let currentOrder = current.flatMap { e in videos.first { $0.id == e.videoId } }.map { ($0.season ?? 0, $0.episode ?? 0) }
            let lastOrder = (last.video?.season ?? 0, last.video?.episode ?? 0)
            if current == nil || currentOrder == nil || currentOrder! <= lastOrder || meta.videos.isEmpty {
                disk.entries[meta.id] = WatchEntry(
                    title: title, videoId: last.id, season: last.video?.season, episode: last.video?.episode,
                    episodeTitle: last.video?.title, episodeThumbnail: last.video?.thumbnail,
                    position: 1, duration: 1, updatedAt: .now
                )
            }
            for item in items {
                stats.history.removeAll { $0.videoId == item.id }
                stats.history.insert(HistoryItem(title: title, videoId: item.id, season: item.video?.season, episode: item.video?.episode,
                                                 episodeTitle: item.video?.title, thumbnail: item.video?.thumbnail, watchedAt: .now), at: 0)
            }
            if stats.history.count > 500 { stats.history.removeLast(stats.history.count - 500) }
        } else {
            let ids = Set(items.map(\.id))
            if let e = disk.entries[meta.id], ids.contains(e.videoId) { disk.entries[meta.id] = nil }
            stats.history.removeAll { ids.contains($0.videoId) }
        }
        save()
        saveStats()
    }

    func isWatched(_ videoId: String) -> Bool { (disk.progress[videoId] ?? 0) > 0.92 }

    /// Progress played in another app (AIOStreams' Jellyfin), newer than what's here.
    func applyRemoteProgress(title: SavedTitle, videoId: String, season: Int?, episode: Int?,
                             episodeTitle: String?, thumbnail: String?, position: Double, duration: Double, at: Date) {
        let entry = WatchEntry(title: title, videoId: videoId, season: season, episode: episode,
                               episodeTitle: episodeTitle, episodeThumbnail: thumbnail,
                               position: position, duration: duration > 0 ? duration : max(position * 1.5, 1), updatedAt: at)
        disk.entries[title.id] = entry
        if duration > 0 { disk.progress[videoId] = entry.progress }
        save()
    }

    /// A video finished in another app (AIOStreams' Jellyfin, Simkl): checked off here, and
    /// if it's the newest thing watched for that title, the title moves on past it.
    func applyRemoteWatched(title: SavedTitle, videoId: String, season: Int?, episode: Int?,
                            episodeTitle: String?, thumbnail: String?, at: Date) {
        disk.progress[videoId] = 1
        if (disk.entries[title.id]?.updatedAt ?? .distantPast) < at {
            disk.entries[title.id] = WatchEntry(title: title, videoId: videoId, season: season, episode: episode,
                                                episodeTitle: episodeTitle, episodeThumbnail: thumbnail,
                                                position: 1, duration: 1, updatedAt: at)
        }
        if !stats.history.contains(where: { $0.videoId == videoId }) {
            stats.history.append(HistoryItem(title: title, videoId: videoId, season: season, episode: episode,
                                             episodeTitle: episodeTitle, thumbnail: thumbnail, watchedAt: at))
            stats.history.sort { $0.watchedAt > $1.watchedAt }
            saveStats()
        }
        save()
    }

    func removeFromContinue(_ metaId: String) {
        disk.entries[metaId] = nil
        save()
    }

    func isFavorite(_ id: String) -> Bool { disk.favorites.contains { $0.id == id } }

    func toggleFavorite(_ meta: Meta) {
        if let i = disk.favorites.firstIndex(where: { $0.id == meta.id }) {
            disk.favorites.remove(at: i)
        } else {
            disk.favorites.insert(SavedTitle(meta), at: 0)
        }
        save()
    }
}
