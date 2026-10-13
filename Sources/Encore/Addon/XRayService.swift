import Foundation

/// Song names for the "now playing" pop-up: an anime's openings and endings from
/// AnimeThemes, with the episodes each one plays in, matched to the opening/credits
/// times Encore already knows.
enum XRayService {
    struct Song: Identifiable, Hashable {
        enum Kind: String { case opening = "Opening", ending = "Ending", insert = "Insert Song" }
        var id: String { "\(kind.rawValue)\(number)|\(title)" }
        let kind: Kind
        let number: Int
        let title: String
        let artists: [String]
        var byline: String { artists.isEmpty ? title : "\(title) — \(artists.joined(separator: ", "))" }
    }

    struct Info {
        var songs: [Song] = []
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        return URLSession(configuration: cfg)
    }()

    static func info(meta: Meta, video: Video?) async -> Info {
        let animated = meta.isAnimeLike || meta.genres.contains { $0.lowercased() == "animation" }
        var mal = meta.malId
        if animated, mal == nil, let imdb = meta.imdbId {
            // The MAL entry for this season (anime databases keep each season separately).
            let seasons = await DiscoveryService.animeSeasons(imdb: imdb)
            mal = seasons[video?.season ?? 1] ?? seasons.values.min()
        }
        var info = Info()
        if let mal { info.songs = await animeSongs(mal: mal, episode: video?.episode) }
        return info
    }

    // MARK: Songs (AnimeThemes)

    private struct ThemesResponse: Decodable {
        struct Anime: Decodable { var animethemes: [Theme]? }
        struct Theme: Decodable {
            var type: String?
            var sequence: Int?
            var song: SongInfo?
            var animethemeentries: [Entry]?
        }
        struct SongInfo: Decodable { var title: String?; var artists: [Artist]? }
        struct Artist: Decodable { var name: String }
        struct Entry: Decodable { var episodes: String? }
        var anime: [Anime]
    }

    private static func animeSongs(mal: Int, episode: Int?) async -> [Song] {
        let q = "filter[has]=resources&filter[site]=MyAnimeList&filter[external_id]=\(mal)&include=animethemes.song.artists,animethemes.animethemeentries"
        guard let url = URL(string: "https://api.animethemes.moe/anime?" + q),
              let (data, _) = try? await session.data(from: url),
              let resp = try? JSONDecoder().decode(ThemesResponse.self, from: data) else { return [] }
        var out: [Song] = []
        for theme in resp.anime.first?.animethemes ?? [] {
            guard let title = theme.song?.title else { continue }
            // Only the themes used in this episode (no episode list means all of them).
            let ranges = (theme.animethemeentries ?? []).compactMap(\.episodes)
            if let episode, !ranges.isEmpty, !ranges.contains(where: { covers($0, episode) }) { continue }
            let kind: Song.Kind = theme.type == "OP" ? .opening : theme.type == "ED" ? .ending : .insert
            let song = Song(kind: kind, number: theme.sequence ?? 1, title: title, artists: (theme.song?.artists ?? []).map(\.name))
            if !out.contains(where: { $0.kind == song.kind && $0.title == song.title }) { out.append(song) }
        }
        return out.sorted { ($0.kind == .opening ? 0 : $0.kind == .ending ? 1 : 2, $0.number) < ($1.kind == .opening ? 0 : $1.kind == .ending ? 1 : 2, $1.number) }
    }

    /// "2, 4-12" covers 2 and 4…12; "1-" or odd text counts as all.
    static func covers(_ spec: String, _ episode: Int) -> Bool {
        let parts = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var understood = false
        for p in parts {
            let bounds = p.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bounds.count == 1, let n = bounds[0] { understood = true; if n == episode { return true } }
            if bounds.count == 2, let a = bounds[0] {
                understood = true
                if episode >= a && episode <= (bounds[1] ?? Int.max) { return true }
            }
        }
        return !understood
    }
}
