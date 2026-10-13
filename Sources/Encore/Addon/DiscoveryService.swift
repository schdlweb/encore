import Foundation

/// People, related titles and original language, from two free, keyless sources:
///  - Wikidata (query.wikidata.org): filmographies, franchises, sequels, directors'
///    other work and original language, all keyed by IMDb id.
///  - AniList (graphql.anilist.co): voice-actor roles, anime relations and
///    recommendations, keyed by MAL id.
/// Results come back as Meta previews (IMDb or MAL ids) that open through the addon.
enum DiscoveryService {
    struct Section: Identifiable {
        var id: String { title }
        var title: String
        var items: [Meta]
        /// Shown under a poster, e.g. the character an actor played.
        var captions: [String: String] = [:]
    }

    struct Person {
        var name: String
        var photo: String?
        var description: String?
        var sections: [Section]
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    // MARK: People

    static func person(_ member: CastMember, context: String? = nil) async -> Person {
        async let works = wikidataFilmography(name: member.name, context: context)
        async let anime = anilistRoles(name: member.name)
        let (w, a) = await (works, anime)
        var sections: [Section] = []
        let movies = w.items.filter { $0.type == "movie" }
        let shows = w.items.filter { $0.type == "series" }
        if !movies.isEmpty { sections.append(Section(title: "Movies", items: movies)) }
        if !shows.isEmpty { sections.append(Section(title: "Shows", items: shows)) }
        if let a, !a.items.isEmpty { sections.append(a) }
        return Person(name: member.name, photo: member.photo, description: w.description, sections: sections)
    }

    /// Finds the person through the title they were listed on when there is one (fast and
    /// unambiguous), otherwise by name, then reads their credits by Wikidata id.
    private static func wikidataFilmography(name: String, context: String?) async -> (items: [Meta], description: String?) {
        let n = sparqlString(name)
        var person: String?
        if let context {
            let q = """
            SELECT ?p WHERE { ?w wdt:P345 \(sparqlString(context)).
              ?w (wdt:P161|wdt:P57|wdt:P58|wdt:P725|wdt:P170) ?p. ?p rdfs:label \(n)@en. } LIMIT 1
            """
            person = await sparql(q)?.first?["p"]
        }
        if person == nil {
            let q = "SELECT ?p WHERE { ?p rdfs:label \(n)@en; wdt:P31 wd:Q5. FILTER EXISTS { ?w (wdt:P161|wdt:P57) ?p } } LIMIT 1"
            person = await sparql(q)?.first?["p"]
        }
        guard let uri = person, let qid = uri.split(separator: "/").last else { return ([], nil) }
        let q = """
        SELECT ?imdb (MIN(?date) AS ?d) (SAMPLE(?label) AS ?title)
               (GROUP_CONCAT(DISTINCT STRAFTER(STR(?t), "entity/")) AS ?types) WHERE {
          VALUES ?p { wd:\(qid) }
          ?work (wdt:P161|wdt:P57|wdt:P58|wdt:P725|wdt:P170) ?p; wdt:P345 ?imdb.
          FILTER(STRSTARTS(?imdb, "tt"))
          OPTIONAL { ?work wdt:P577 ?date }
          OPTIONAL { ?work wdt:P31 ?t }
          OPTIONAL { ?work rdfs:label ?label FILTER(LANG(?label) = "en") }
        } GROUP BY ?imdb ORDER BY DESC(?d) LIMIT 150
        """
        let descQ = "SELECT ?desc WHERE { wd:\(qid) schema:description ?desc FILTER(LANG(?desc) = \"en\") } LIMIT 1"
        async let rows = sparql(q)
        async let desc = sparql(descQ)
        let (r, d) = await (rows, desc)
        return ((r ?? []).compactMap(metaFromRow), d?.first?["desc"])
    }

    private struct AniListStaffResponse: Decodable {
        struct Staff: Decodable {
            struct Name: Decodable { var full: String?; var native: String? }
            struct Edge: Decodable {
                struct Node: Decodable {
                    struct Title: Decodable { var english: String?; var romaji: String? }
                    struct Cover: Decodable { var large: String? }
                    var idMal: Int?
                    var format: String?
                    var seasonYear: Int?
                    var title: Title?
                    var coverImage: Cover?
                }
                struct Character: Decodable { struct N: Decodable { var full: String? }; var name: N? }
                var node: Node?
                var characters: [Character?]?
            }
            struct Media: Decodable { var edges: [Edge] }
            var name: Name?
            var characterMedia: Media?
        }
        struct D: Decodable { var Staff: Staff? }
        var data: D?
    }

    private static func anilistRoles(name: String) async -> Section? {
        let gql = """
        query($s:String){ Staff(search:$s){ name{full native}
          characterMedia(sort:POPULARITY_DESC, perPage:40){ edges{
            node{ idMal format seasonYear title{english romaji} coverImage{large} }
            characters{ name{full} } } } } }
        """
        guard let resp: AniListStaffResponse = await anilist(gql, ["s": name]),
              let staff = resp.data?.Staff,
              // AniList search is fuzzy; only accept the exact person.
              staff.name?.full?.lowercased() == name.lowercased() || staff.name?.native == name
        else { return nil }
        var captions: [String: String] = [:]
        var seen = Set<Int>()
        let items: [Meta] = (staff.characterMedia?.edges ?? []).compactMap { edge in
            guard let n = edge.node, let mal = n.idMal, seen.insert(mal).inserted else { return nil }
            let meta = Meta(id: "mal:\(mal)", type: n.format == "MOVIE" ? "movie" : "series",
                            name: n.title?.english ?? n.title?.romaji ?? "Untitled",
                            poster: n.coverImage?.large, releaseInfo: n.seasonYear.map(String.init))
            if let ch = edge.characters?.compactMap({ $0?.name?.full }).first { captions[meta.id] = "as \(ch)" }
            return meta
        }
        return Section(title: "Anime Roles", items: items, captions: captions)
    }

    // MARK: Related

    static func related(to meta: Meta) async -> [Section] {
        // Anime opened from an IMDb-keyed row: find its MyAnimeList id for AniList's picks.
        var mal = meta.malId
        if mal == nil, let imdb = meta.imdbId, meta.isAnimeLike || meta.genres.contains(where: { $0.lowercased() == "animation" }) {
            mal = await malIdForIMDb(imdb)
        }
        if let mal {
            let anime = await anilistRelated(mal: mal)
            if !anime.isEmpty { return anime }
        }
        guard let imdb = meta.imdbId else { return [] }
        return await wikidataRelated(imdb: imdb, isSeries: meta.isSeriesLike)
    }

    /// Small id-only queries in parallel (one big UNION query takes Wikidata 40s+),
    /// then one query for the titles, years and types of everything found.
    private static func wikidataRelated(imdb: String, isSeries: Bool) async -> [Section] {
        let me = "?me wdt:P345 \(sparqlString(imdb))."
        let tail = "?work wdt:P345 ?imdb. FILTER(STRSTARTS(?imdb, \"tt\")) FILTER(?work != ?me) } LIMIT 40"
        let franchiseQueries = [
            "SELECT DISTINCT ?imdb WHERE { \(me) ?me (wdt:P155|wdt:P156) ?work. \(tail)",
            "SELECT DISTINCT ?imdb WHERE { \(me) ?me wdt:P179 ?s. ?work wdt:P179 ?s. \(tail)",
            "SELECT DISTINCT ?imdb WHERE { \(me) ?me wdt:P8345 ?f. ?work wdt:P8345 ?f. \(tail)",
            "SELECT DISTINCT ?imdb WHERE { \(me) { ?me wdt:P144 ?src. ?work wdt:P144 ?src. } UNION { ?work wdt:P144 ?me. } \(tail)",
        ]
        // Shows list every episode's director, so match shows on creator only.
        let role = isSeries ? "wdt:P170" : "wdt:P57"
        let creatorQuery = """
        SELECT DISTINCT ?imdb ?who WHERE { \(me) ?me \(role) ?person. ?work \(role) ?person.
          OPTIONAL { ?person rdfs:label ?who FILTER(LANG(?who) = "en") } \(tail)
        """

        var franchiseIds: [String] = []
        var creatorIds: [String] = []
        var who: String?
        await withTaskGroup(of: (Bool, [[String: String]]).self) { group in
            for q in franchiseQueries { group.addTask { (true, await sparql(q) ?? []) } }
            group.addTask { (false, await sparql(creatorQuery) ?? []) }
            for await (isFranchise, rows) in group {
                let ids = rows.compactMap { $0["imdb"] }
                if isFranchise { franchiseIds += ids } else {
                    creatorIds += ids
                    who = rows.first?["who"]
                }
            }
        }
        var seen = Set([imdb])
        franchiseIds = franchiseIds.filter { seen.insert($0).inserted }
        creatorIds = creatorIds.filter { seen.insert($0).inserted }
        let all = franchiseIds + creatorIds
        guard !all.isEmpty else { return [] }

        let values = all.map(sparqlString).joined(separator: " ")
        let details = """
        SELECT ?imdb (MIN(?date) AS ?d) (SAMPLE(?label) AS ?title)
               (GROUP_CONCAT(DISTINCT STRAFTER(STR(?t), "entity/")) AS ?types) WHERE {
          VALUES ?imdb { \(values) }
          ?work wdt:P345 ?imdb.
          OPTIONAL { ?work wdt:P577 ?date }
          OPTIONAL { ?work wdt:P31 ?t }
          OPTIONAL { ?work rdfs:label ?label FILTER(LANG(?label) = "en") }
        } GROUP BY ?imdb
        """
        let metas = Dictionary(((await sparql(details)) ?? []).compactMap { row in
            metaFromRow(row).map { ($0.id, $0) }
        }, uniquingKeysWith: { a, _ in a })
        let byYear: ([String]) -> [Meta] = { ids in
            ids.compactMap { metas[$0] }.sorted { ($0.releaseInfo ?? "9999") < ($1.releaseInfo ?? "9999") }
        }

        var out: [Section] = []
        let franchise = byYear(franchiseIds)
        if !franchise.isEmpty { out.append(Section(title: "In This Franchise", items: franchise)) }
        let creator = Array(byYear(creatorIds).reversed())
        if !creator.isEmpty {
            out.append(Section(title: who.map { "More from \($0)" } ?? (isSeries ? "More from the Creator" : "More from the Director"),
                               items: creator))
        }
        return out
    }

    private struct AniListMediaResponse: Decodable {
        struct Node: Decodable {
            struct Title: Decodable { var english: String?; var romaji: String? }
            struct Cover: Decodable { var large: String? }
            var idMal: Int?
            var type: String?
            var format: String?
            var seasonYear: Int?
            var title: Title?
            var coverImage: Cover?
        }
        struct Media: Decodable {
            struct Rel: Decodable { struct E: Decodable { var relationType: String?; var node: Node? }; var edges: [E] }
            struct Rec: Decodable { struct N: Decodable { var mediaRecommendation: Node? }; var nodes: [N] }
            var relations: Rel?
            var recommendations: Rec?
        }
        struct D: Decodable { var Media: Media? }
        var data: D?
    }

    private static func anilistRelated(mal: Int) async -> [Section] {
        let node = "idMal type format seasonYear title{english romaji} coverImage{large}"
        let gql = """
        query($m:Int){ Media(idMal:$m, type:ANIME){
          relations{ edges{ relationType node{ \(node) } } }
          recommendations(sort:RATING_DESC, perPage:20){ nodes{ mediaRecommendation{ \(node) } } } } }
        """
        guard let resp: AniListMediaResponse = await anilist(gql, ["m": mal]), let media = resp.data?.Media else { return [] }
        func meta(_ n: AniListMediaResponse.Node?) -> Meta? {
            guard let n, n.type == "ANIME", let id = n.idMal else { return nil }
            return Meta(id: "mal:\(id)", type: n.format == "MOVIE" ? "movie" : "series",
                        name: n.title?.english ?? n.title?.romaji ?? "Untitled",
                        poster: n.coverImage?.large, releaseInfo: n.seasonYear.map(String.init))
        }
        var captions: [String: String] = [:]
        let order = ["PREQUEL": 0, "SEQUEL": 1, "PARENT": 2, "SIDE_STORY": 3, "SPIN_OFF": 4, "ALTERNATIVE": 5, "SUMMARY": 6]
        let relations: [Meta] = (media.relations?.edges ?? [])
            .sorted { (order[$0.relationType ?? ""] ?? 9) < (order[$1.relationType ?? ""] ?? 9) }
            .compactMap { e in
                guard let m = meta(e.node) else { return nil }
                captions[m.id] = e.relationType?.replacingOccurrences(of: "_", with: " ").capitalized
                return m
            }
        let recs = (media.recommendations?.nodes ?? []).compactMap { meta($0.mediaRecommendation) }
        var out: [Section] = []
        if !relations.isEmpty { out.append(Section(title: "Seasons & Related", items: relations, captions: captions)) }
        if !recs.isEmpty { out.append(Section(title: "You Might Also Like", items: recs)) }
        return out
    }

    // MARK: Cast fallback

    /// Cast for titles whose metadata has none (the addon only sends cast for anime):
    /// TVmaze for shows (billing order, photos, characters), Wikidata for movies.
    static func cast(for meta: Meta) async -> [CastMember] {
        // Animation (anime movies opened from a regular row included): AniList's characters
        // and Japanese voice cast, found through the IMDb→MAL mapping.
        let animated = meta.isAnimeLike || meta.genres.contains { $0.lowercased() == "animation" }
        if animated {
            var mal = meta.malId
            if mal == nil, let imdb = meta.imdbId { mal = await malIdForIMDb(imdb) }
            if let mal {
                let voices = await anilistCast(mal: mal)
                if !voices.isEmpty { return voices }
            }
        }
        guard let imdb = meta.imdbId else { return [] }
        if meta.isSeriesLike {
            let tv = await tvmazeCast(imdb: imdb)
            if !tv.isEmpty { return tv }
        }
        return await wikidataCast(imdb: imdb)
    }

    // MARK: Anime seasons

    private struct ARMSeasonEntry: Decodable {
        var myanimelist: Int?
        var media: String?
        var tvdbSeason: Int?
        enum CodingKeys: String, CodingKey { case myanimelist, media, tvdbSeason = "thetvdb-season" }
    }
    private struct ARMIds: Decodable { var imdb: String? }

    /// For an anime with an IMDb id: each TV season's MyAnimeList id (season → MAL),
    /// from ARM. Anime databases keep every season as its own entry.
    static func animeSeasons(imdb: String) async -> [Int: Int] {
        guard let url = URL(string: "https://arm.haglund.dev/api/v2/imdb?id=\(imdb)"),
              let (data, _) = try? await session.data(from: url),
              let entries = try? JSONDecoder().decode(LossyArray<ARMSeasonEntry>.self, from: data).items else { return [:] }
        var out: [Int: Int] = [:]
        for e in entries where (e.media ?? "TV") == "TV" {
            if let s = e.tvdbSeason, s > 0, let mal = e.myanimelist, out[s] == nil { out[s] = mal }
        }
        return out
    }

    /// The IMDb id an anime entry belongs to, if ARM knows it.
    static func imdbId(forMAL mal: Int) async -> String? {
        guard let url = URL(string: "https://arm.haglund.dev/api/v2/ids?source=myanimelist&id=\(mal)"),
              let (data, _) = try? await session.data(from: url) else { return nil }
        return (try? JSONDecoder().decode(ARMIds.self, from: data))?.imdb
    }

    // MARK: Episode lengths

    /// Per-episode extras the addon doesn't give: length in minutes, a summary, and a
    /// still, from TVmaze (keyed "season:episode"), with a typical length as the fallback
    /// (AniList's for anime, whose real length TVmaze rounds up to the 30-minute slot).
    struct EpisodeDetails: Sendable {
        var runtimes: [String: Int] = [:]
        var summaries: [String: String] = [:]
        var images: [String: String] = [:]
        var typical: Int?
        /// Anime: ignore TVmaze's per-episode lengths in favour of `typical`.
        var preferTypical = false

        private func key(_ s: Int?, _ e: Int?) -> String? { s.flatMap { s in e.map { "\(s):\($0)" } } }
        func minutes(season: Int?, episode: Int?) -> Int? {
            guard !preferTypical, let k = key(season, episode) else { return typical }
            return runtimes[k] ?? typical
        }
        func summary(season: Int?, episode: Int?) -> String? { key(season, episode).flatMap { summaries[$0] } }
        func image(season: Int?, episode: Int?) -> String? { key(season, episode).flatMap { images[$0] } }
    }

    private static let detailsCache = DetailsCache()
    private actor DetailsCache {
        var store: [String: EpisodeDetails] = [:]
        func get(_ k: String) -> EpisodeDetails? { store[k] }
        func set(_ k: String, _ v: EpisodeDetails) { store[k] = v }
    }

    private struct TVmazeEpisode: Decodable {
        struct Img: Decodable { var medium: String?; var original: String? }
        var season: Int?; var number: Int?; var runtime: Int?; var summary: String?; var image: Img?
    }
    private struct TVmazeShowInfo: Decodable { var id: Int; var averageRuntime: Int?; var runtime: Int? }

    static func episodeDetails(for meta: Meta) async -> EpisodeDetails {
        if let hit = await detailsCache.get(meta.id) { return hit }
        var result = EpisodeDetails()
        if let imdb = meta.imdbId,
           let lookup = URL(string: "https://api.tvmaze.com/lookup/shows?imdb=\(imdb)"),
           let (data, _) = try? await session.data(from: lookup),
           let show = try? JSONDecoder().decode(TVmazeShowInfo.self, from: data) {
            result.typical = show.averageRuntime ?? show.runtime
            if let url = URL(string: "https://api.tvmaze.com/shows/\(show.id)/episodes"),
               let (epData, _) = try? await session.data(from: url),
               let eps = try? JSONDecoder().decode(LossyArray<TVmazeEpisode>.self, from: epData).items {
                for e in eps {
                    guard let s = e.season, let n = e.number else { continue }
                    let k = "\(s):\(n)"
                    if let r = e.runtime { result.runtimes[k] = r }
                    if let text = e.summary.map(plainText), !text.isEmpty { result.summaries[k] = text }
                    if let img = e.image?.original ?? e.image?.medium {
                        result.images[k] = img.replacingOccurrences(of: "http://", with: "https://")
                    }
                }
            }
        }
        if meta.isAnimeLike || meta.genres.contains(where: { $0.lowercased() == "animation" }) {
            var mal = meta.malId
            if mal == nil, let imdb = meta.imdbId { mal = await malIdForIMDb(imdb) }
            if let mal, let minutes = await anilistDuration(mal: mal) {
                result.typical = minutes
                result.preferTypical = true
            }
        }
        if result.typical != nil || !result.runtimes.isEmpty || !result.summaries.isEmpty {
            await detailsCache.set(meta.id, result)
        }
        return result
    }

    /// TVmaze summaries are small HTML fragments ("<p>…</p>").
    private static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct AniListDuration: Decodable {
        struct M: Decodable { var duration: Int? }
        struct D: Decodable { var Media: M? }
        var data: D?
    }

    private static func anilistDuration(mal: Int) async -> Int? {
        var req = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": "{ Media(idMal: \(mal), type: ANIME) { duration } }"])
        guard let (data, _) = try? await session.data(for: req) else { return nil }
        return (try? JSONDecoder().decode(AniListDuration.self, from: data))?.data?.Media?.duration
    }

    private struct TVmazeShow: Decodable { var id: Int }
    private struct TVmazeCredit: Decodable {
        struct Img: Decodable { var medium: String? }
        struct Person: Decodable { var name: String; var image: Img? }
        struct Character: Decodable { var name: String? }
        var person: Person
        var character: Character?
    }

    private static func tvmazeCast(imdb: String) async -> [CastMember] {
        guard let lookup = URL(string: "https://api.tvmaze.com/lookup/shows?imdb=\(imdb)"),
              let (data, _) = try? await session.data(from: lookup),
              let show = try? JSONDecoder().decode(TVmazeShow.self, from: data),
              let url = URL(string: "https://api.tvmaze.com/shows/\(show.id)/cast"),
              let (castData, _) = try? await session.data(from: url),
              let credits = try? JSONDecoder().decode(LossyArray<TVmazeCredit>.self, from: castData).items else { return [] }
        var seen = Set<String>()
        return credits.compactMap { c in
            guard seen.insert(c.person.name).inserted else { return nil }
            return CastMember(name: c.person.name, character: c.character?.name, photo: c.person.image?.medium)
        }
    }

    private static func wikidataCast(imdb: String) async -> [CastMember] {
        let q = """
        SELECT ?name (SAMPLE(?img) AS ?photo) (SAMPLE(?role) AS ?character) WHERE {
          ?w wdt:P345 \(sparqlString(imdb)).
          { ?w p:P161 ?st. ?st ps:P161 ?p. } UNION { ?w p:P725 ?st. ?st ps:P725 ?p. }
          OPTIONAL { ?st pq:P453 ?r. ?r rdfs:label ?role FILTER(LANG(?role) = "en") }
          ?p rdfs:label ?name FILTER(LANG(?name) = "en")
          OPTIONAL { ?p wdt:P18 ?img }
        } GROUP BY ?name LIMIT 30
        """
        guard let rows = await sparql(q) else { return [] }
        // Credited roles first: Wikidata doesn't keep billing order, but named roles are the leads.
        return rows.compactMap { row -> CastMember? in
            guard let name = row["name"] else { return nil }
            let photo = row["photo"].map { $0.replacingOccurrences(of: "http://", with: "https://") + "?width=300" }
            return CastMember(name: name, character: row["character"], photo: photo)
        }
        .sorted { ($0.character == nil ? 1 : 0, $0.photo == nil ? 1 : 0) < ($1.character == nil ? 1 : 0, $1.photo == nil ? 1 : 0) }
    }

    private struct ARMEntry: Decodable { var myanimelist: Int? }

    private static func malIdForIMDb(_ imdb: String) async -> Int? {
        guard let url = URL(string: "https://arm.haglund.dev/api/v2/imdb?id=\(imdb)"),
              let (data, _) = try? await session.data(from: url) else { return nil }
        return (try? JSONDecoder().decode(LossyArray<ARMEntry>.self, from: data))?.items.compactMap(\.myanimelist).first
    }

    private struct AniListCharacters: Decodable {
        struct Name: Decodable { var full: String? }
        struct Img: Decodable { var large: String? }
        struct VA: Decodable { var name: Name?; var image: Img? }
        struct Edge: Decodable {
            struct Node: Decodable { var name: Name? }
            var node: Node?
            var voiceActors: [VA]?
        }
        struct Chars: Decodable { var edges: [Edge] }
        struct M: Decodable { var characters: Chars? }
        struct D: Decodable { var Media: M? }
        var data: D?
    }

    private static func anilistCast(mal: Int) async -> [CastMember] {
        let gql = """
        query($m:Int){ Media(idMal:$m, type:ANIME){ characters(sort:[ROLE, RELEVANCE], perPage:25){ edges{
          node{ name{full} } voiceActors(language:JAPANESE, sort:[RELEVANCE]){ name{full} image{large} } } } } }
        """
        guard let resp: AniListCharacters = await anilist(gql, ["m": mal]) else { return [] }
        var seen = Set<String>()
        return (resp.data?.Media?.characters?.edges ?? []).compactMap { e in
            guard let va = e.voiceActors?.first, let name = va.name?.full, seen.insert(name).inserted else { return nil }
            return CastMember(name: name, character: e.node?.name?.full, photo: va.image?.large)
        }
    }

    // MARK: Original language

    /// ISO 639-2 code of the title's original language, best effort.
    static func originalLanguage(of meta: Meta) async -> String? {
        if let imdb = meta.imdbId {
            let q = "SELECT ?code WHERE { ?w wdt:P345 \(sparqlString(imdb)); wdt:P364 ?l. ?l wdt:P219 ?code } LIMIT 1"
            if let code = await sparql(q)?.first?["code"] { return code }
        }
        if meta.isAnimeLike { return "jpn" }
        return meta.country.flatMap(languageForCountry)
    }

    private static func languageForCountry(_ raw: String) -> String? {
        let c = raw.lowercased()
        if c.count == 3, Locale.LanguageCode(c).isISOLanguage { return c } // already a language code ("jpn")
        let table: [(String, String)] = [
            ("japan", "jpn"), ("jp", "jpn"), ("korea", "kor"), ("kr", "kor"), ("china", "chi"), ("cn", "chi"),
            ("taiwan", "chi"), ("tw", "chi"), ("hong kong", "chi"), ("hk", "chi"), ("thailand", "tha"), ("th", "tha"),
            ("philippines", "fil"), ("ph", "fil"), ("india", "hin"), ("in", "hin"), ("france", "fre"), ("fr", "fre"),
            ("spain", "spa"), ("es", "spa"), ("mexico", "spa"), ("germany", "ger"), ("de", "ger"), ("italy", "ita"),
            ("it", "ita"), ("brazil", "por"), ("br", "por"), ("united states", "eng"), ("usa", "eng"), ("us", "eng"),
            ("united kingdom", "eng"), ("uk", "eng"), ("gb", "eng"), ("canada", "eng"), ("australia", "eng"),
        ]
        return table.first { c == $0.0 || c.hasPrefix($0.0) }?.1
    }

    // MARK: Plumbing

    private static func sparqlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private struct SPARQLResponse: Decodable {
        struct Value: Decodable { var value: String }
        struct Results: Decodable { var bindings: [[String: Value]] }
        var results: Results
    }

    private static func sparql(_ query: String) async -> [[String: String]]? {
        var c = URLComponents(string: "https://query.wikidata.org/sparql")!
        c.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        // Wikimedia asks clients to identify themselves.
        req.setValue("Encore/0.1 (personal media player)", forHTTPHeaderField: "User-Agent")
        // Wikidata sometimes stalls on a query; give up rather than hold up the page.
        req.timeoutInterval = 8
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode(SPARQLResponse.self, from: data) else { return nil }
        return body.results.bindings.map { $0.mapValues(\.value) }
    }

    private static let seriesTypes: Set<String> = ["Q5398426", "Q581714", "Q63952888", "Q1259759", "Q526877", "Q117467246"]
    private static let skipTypes: Set<String> = ["Q21191270", "Q3464665", "Q7889", "Q193977", "Q1261214"] // episodes, seasons, games, music videos, TV specials

    private static func metaFromRow(_ row: [String: String]) -> Meta? {
        guard let imdb = row["imdb"], let title = row["title"] else { return nil }
        let types = Set((row["types"] ?? "").split(separator: " ").map(String.init))
        guard types.isDisjoint(with: skipTypes) else { return nil }
        let type = types.isDisjoint(with: seriesTypes) ? "movie" : "series"
        // Wikidata has no artwork; metahub serves posters by IMDb id (as Cinemeta does).
        return Meta(id: imdb, type: type, name: title,
                    poster: "https://images.metahub.space/poster/medium/\(imdb)/img",
                    releaseInfo: row["d"].map { String($0.prefix(4)) })
    }

    private static func anilist<T: Decodable>(_ query: String, _ variables: [String: Any]) async -> T? {
        var req = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        guard let (data, _) = try? await session.data(for: req) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
