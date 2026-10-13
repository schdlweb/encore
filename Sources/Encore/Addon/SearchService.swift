import Foundation

/// Title search that doesn't go through the addon. Addon catalogs search slowly
/// (AIOStreams fans each query out to every searchable catalog, debrid stores
/// included), so Encore asks two fast, free, keyless sources instead:
///  - IMDb's suggestion endpoint for movies and shows (IMDb ids: `tt…`)
///  - AniList's GraphQL API for anime (opened by MAL id: `mal:…`)
/// Both id kinds are understood by AIOMetadata/AIOStreams for metadata and streams.
enum SearchService {
    struct Section: Identifiable {
        var id: String { title }
        var title: String
        var items: [Meta]
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        return URLSession(configuration: cfg)
    }()

    static func search(_ query: String) async -> [Section] {
        async let imdb = imdbSearch(query)
        async let anime = anilistSearch(query)
        let (titles, animeTitles) = await (imdb, anime)
        // An anime that's also in the IMDb results (any of its seasons) shows once, as the
        // show: opening it there brings in all seasons.
        let imdbIds = Set(titles.map(\.id))
        var duplicates = Set<String>()
        await withTaskGroup(of: (String, String?).self) { group in
            for a in animeTitles.prefix(10) {
                guard let mal = Int(a.id.dropFirst("mal:".count)) else { continue }
                group.addTask { (a.id, await DiscoveryService.imdbId(forMAL: mal)) }
            }
            for await (id, imdb) in group where imdb.map(imdbIds.contains) == true { duplicates.insert(id) }
        }
        return [
            Section(title: "Movies", items: titles.filter { $0.type == "movie" }),
            Section(title: "Shows", items: titles.filter { $0.type == "series" }),
            Section(title: "Anime", items: animeTitles.filter { !duplicates.contains($0.id) }),
        ].filter { !$0.items.isEmpty }
    }

    // MARK: IMDb

    private struct IMDbResponse: Decodable {
        struct Item: Decodable {
            struct Img: Decodable { var imageUrl: String? }
            var id: String
            var l: String?
            var qid: String?
            var y: Int?
            var yr: String?
            var s: String?
            var i: Img?
        }
        var d: LossyArray<Item>?
    }

    static func imdbSearch(_ query: String) async -> [Meta] {
        // The endpoint wants a lowercased path segment; the first letter is only a shard hint.
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard let enc = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let first = q.first,
              let url = URL(string: "https://v3.sg.media-imdb.com/suggestion/\(first.isLetter ? String(first) : "x")/\(enc).json")
        else { return [] }
        guard let (data, _) = try? await session.data(from: url),
              let resp = try? JSONDecoder().decode(IMDbResponse.self, from: data) else { return [] }
        return (resp.d?.items ?? []).compactMap { item -> Meta? in
            guard item.id.hasPrefix("tt"), let name = item.l else { return nil }
            let type: String
            switch item.qid {
            case "movie", "tvMovie": type = "movie"
            case "tvSeries", "tvMiniSeries": type = "series"
            default: return nil
            }
            return Meta(id: item.id, type: type, name: name,
                        poster: item.i?.imageUrl.map(resizedIMDbImage),
                        releaseInfo: item.yr ?? item.y.map(String.init))
        }
    }

    /// IMDb image URLs accept size directives; the originals are up to 3000px.
    private static func resizedIMDbImage(_ url: String) -> String {
        url.replacingOccurrences(of: "._V1_.jpg", with: "._V1_QL80_UX400_.jpg")
    }

    // MARK: AniList

    private struct AniListResponse: Decodable {
        struct Media: Decodable {
            struct Title: Decodable { var romaji: String?; var english: String? }
            struct Cover: Decodable { var extraLarge: String?; var large: String? }
            var idMal: Int?
            var format: String?
            var seasonYear: Int?
            var averageScore: Int?
            var genres: [String]?
            var title: Title?
            var coverImage: Cover?
            var bannerImage: String?
        }
        struct Page: Decodable { var media: [Media] }
        struct DataBox: Decodable { var Page: Page }
        var data: DataBox?
    }

    static func anilistSearch(_ query: String) async -> [Meta] {
        let gql = """
        query($s:String){Page(perPage:20){media(search:$s,type:ANIME,isAdult:false,sort:SEARCH_MATCH){
          idMal format seasonYear averageScore genres title{romaji english} coverImage{extraLarge large} bannerImage}}}
        """
        var req = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": gql, "variables": ["s": query]])
        guard let (data, _) = try? await session.data(for: req),
              let resp = try? JSONDecoder().decode(AniListResponse.self, from: data) else { return [] }
        return (resp.data?.Page.media ?? []).compactMap { m -> Meta? in
            // Streams resolve by MAL id; entries without one (mostly unreleased) can't play.
            guard let mal = m.idMal else { return nil }
            var meta = Meta(
                id: "mal:\(mal)",
                type: m.format == "MOVIE" ? "movie" : "series",
                name: m.title?.english ?? m.title?.romaji ?? "Untitled",
                poster: m.coverImage?.extraLarge ?? m.coverImage?.large,
                releaseInfo: m.seasonYear.map(String.init)
            )
            meta.background = m.bannerImage
            meta.genres = m.genres ?? []
            meta.imdbRating = m.averageScore.map { String(format: "%.1f", Double($0) / 10) }
            return meta
        }
    }
}
