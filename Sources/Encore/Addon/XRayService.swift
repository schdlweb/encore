import Foundation

/// X-Ray data for what's playing: the songs (anime openings and endings, from
/// AnimeThemes, with the episodes each one plays in) and who's in it (anime characters
/// and their voice actors from AniList; a show's cast and the episode's guest stars from
/// TVmaze; a film's cast). No per-scene data exists for free, so songs are tied to the
/// opening/credits times Encore already knows, and people are per episode/title.
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

    struct Person: Identifiable, Hashable {
        var id: String { name + "|" + (role ?? "") }
        let name: String
        /// The character played (or the voice actor, for anime characters).
        let role: String?
        let photo: String?
        var isGuest = false
    }

    struct Info {
        var songs: [Song] = []
        var people: [Person] = []
        /// "Characters" for anime, "Cast" otherwise.
        var peopleTitle = "Cast"
        var isEmpty: Bool { songs.isEmpty && people.isEmpty }
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
        if let mal {
            async let songs = animeSongs(mal: mal, episode: video?.episode)
            async let characters = anilistCharacters(mal: mal)
            info.songs = await songs
            info.people = await characters
            info.peopleTitle = "Characters"
        }
        if info.people.isEmpty {
            info.people = await livePeople(meta: meta, video: video)
            info.peopleTitle = "Cast"
        }
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

    // MARK: People

    private struct AniListCharacters: Decodable {
        struct Name: Decodable { var full: String? }
        struct Img: Decodable { var large: String? }
        struct VA: Decodable { var name: Name? }
        struct Edge: Decodable {
            struct Node: Decodable { var name: Name?; var image: Img? }
            var role: String?
            var node: Node?
            var voiceActors: [VA]?
        }
        struct Chars: Decodable { var edges: [Edge] }
        struct M: Decodable { var characters: Chars? }
        struct D: Decodable { var Media: M? }
        var data: D?
    }

    private static func anilistCharacters(mal: Int) async -> [Person] {
        let gql = "{ Media(idMal: \(mal), type: ANIME) { characters(sort: [ROLE, RELEVANCE], perPage: 25) { edges { role node { name { full } image { large } } voiceActors(language: JAPANESE) { name { full } } } } } }"
        var req = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": gql])
        guard let (data, _) = try? await session.data(for: req),
              let resp = try? JSONDecoder().decode(AniListCharacters.self, from: data) else { return [] }
        return (resp.data?.Media?.characters?.edges ?? []).compactMap { e in
            guard let name = e.node?.name?.full else { return nil }
            return Person(name: name, role: e.voiceActors?.first?.name?.full.map { "Voiced by \($0)" }, photo: e.node?.image?.large)
        }
    }

    private struct TVmazeLookup: Decodable { var id: Int }
    private struct TVmazeEpisode: Decodable { var id: Int }
    private struct TVmazeCredit: Decodable {
        struct Img: Decodable { var medium: String? }
        struct P: Decodable { var name: String; var image: Img? }
        struct C: Decodable { var name: String?; var image: Img? }
        var person: P
        var character: C?
    }

    /// A show's main cast plus this episode's guest stars (TVmaze); a film's cast otherwise.
    private static func livePeople(meta: Meta, video: Video?) async -> [Person] {
        if meta.isSeriesLike, let imdb = meta.imdbId,
           let lookup = URL(string: "https://api.tvmaze.com/lookup/shows?imdb=\(imdb)"),
           let (data, _) = try? await session.data(from: lookup),
           let show = try? JSONDecoder().decode(TVmazeLookup.self, from: data) {
            func credits(_ path: String) async -> [TVmazeCredit] {
                guard let url = URL(string: "https://api.tvmaze.com" + path),
                      let (d, _) = try? await session.data(from: url) else { return [] }
                return (try? JSONDecoder().decode(LossyArray<TVmazeCredit>.self, from: d))?.items ?? []
            }
            var guests: [TVmazeCredit] = []
            if let s = video?.season, let e = video?.episode,
               let epURL = URL(string: "https://api.tvmaze.com/shows/\(show.id)/episodebynumber?season=\(s)&number=\(e)"),
               let (ed, _) = try? await session.data(from: epURL),
               let ep = try? JSONDecoder().decode(TVmazeEpisode.self, from: ed) {
                guests = await credits("/episodes/\(ep.id)/guestcast")
            }
            let main = await credits("/shows/\(show.id)/cast")
            func person(_ c: TVmazeCredit, guest: Bool) -> Person {
                Person(name: c.person.name, role: c.character?.name, photo: (c.person.image ?? c.character?.image)?.medium?
                    .replacingOccurrences(of: "http://", with: "https://"), isGuest: guest)
            }
            let people = main.map { person($0, guest: false) } + guests.map { person($0, guest: true) }
            var seen = Set<String>()
            if !people.isEmpty { return people.filter { seen.insert($0.name).inserted } }
        }
        let cast = meta.cast.isEmpty ? await DiscoveryService.cast(for: meta) : meta.cast
        return cast.map { Person(name: $0.name, role: $0.character, photo: $0.photo) }
    }
}
