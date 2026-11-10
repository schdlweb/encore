import AppKit
import Foundation
import SwiftUI

extension AppState {
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
        var fresh: [WatchEntry] = []
        var unavailable = Set<String>()
        await withTaskGroup(of: (UpcomingEpisode?, WatchEntry?, String?).self) { group in
            for title in followed {
                group.addTask { @MainActor in
                    guard let meta = await self.fullMeta(type: title.type, id: title.id, mustBeFresh: true) else { return (nil, nil, title.id) }
                    let now = Date()
                    let newEpisode = self.newEpisode(of: meta, now: now)
                    let next = meta.videos
                        .filter { ($0.season ?? 1) > 0 && ($0.released ?? .distantPast) > now }
                        .min { ($0.released ?? .distantFuture) < ($1.released ?? .distantFuture) }
                    guard let next else { return (nil, newEpisode, nil) }
                    let lengths = await DiscoveryService.episodeDetails(for: meta)
                    return (UpcomingEpisode(meta: meta, video: next, runtime: lengths.minutes(season: next.season, episode: next.episode)), newEpisode, nil)
                }
            }
            for await (item, newEpisode, failedId) in group {
                if let item { found.append(item) }
                if let newEpisode { fresh.append(newEpisode) }
                if let failedId { unavailable.insert(failedId) }
            }
        }
        // Titles that couldn't be looked up keep what they had, and it's tried again soon.
        if !unavailable.isEmpty {
            found += upcoming.filter { unavailable.contains($0.meta.id) }
            fresh += newEpisodes.filter { unavailable.contains($0.title.id) }
            upcomingCheckedAt = Date().addingTimeInterval(-28 * 60)
        }
        upcoming = found.sorted { ($0.video.released ?? .distantFuture) < ($1.video.released ?? .distantFuture) }
        newEpisodes = fresh.filter { !hiddenNewEpisodes.contains($0.videoId) }
    }

    func hideNewEpisode(_ entry: WatchEntry) {
        hiddenNewEpisodes.insert(entry.videoId)
        newEpisodes.removeAll { $0.videoId == entry.videoId }
    }

    /// The episode after the one you last finished, if it came out after you finished it
    /// (so you were caught up) and you haven't watched it yet.
    func newEpisode(of meta: Meta, now: Date) -> WatchEntry? {
        guard let e = watch.entry(for: meta.id), e.isFinished,
              let last = meta.videos.first(where: { $0.id == e.videoId }),
              let next = nextVideo(in: meta, after: last),
              let aired = next.released, aired <= now, aired > e.updatedAt,
              !watch.isWatched(next.id) else { return nil }
        return WatchEntry(title: SavedTitle(meta), videoId: next.id, season: next.season, episode: next.episode,
                          episodeTitle: next.title.isEmpty ? nil : next.title, episodeThumbnail: next.thumbnail,
                          position: 0, duration: 0, updatedAt: aired)
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
            for seed in Array(seeds) + negativeSeeds {
                group.addTask { @MainActor in
                    guard let meta = await self.fullMeta(type: seed.type, id: seed.id) else { return (seed, []) }
                    return (seed, await DiscoveryService.related(to: meta))
                }
            }
            for await (seed, sections) in group {
                // More recent seeds count a little more; your rating scales it (negative for
                // titles you didn't like, which aren't in `seeds` and get no recency boost).
                let recency = seeds.firstIndex(of: seed).map { 1 + 0.5 * Double(seeds.count - $0) / Double(seeds.count) } ?? 1
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
        let built = scores.values
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(48)
            .map { Recommendation(meta: $0.meta, because: $0.because) }
        // Nothing at all usually means the lookups failed: keep the row, try again in 5 minutes.
        if built.isEmpty, !recommendations.isEmpty {
            recommendationsBuiltAt = Date().addingTimeInterval(-6 * 3600 + 300)
            return
        }
        if built.isEmpty { recommendationsBuiltAt = Date().addingTimeInterval(-6 * 3600 + 300) }
        recommendations = built
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

    static func normalizedName(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
