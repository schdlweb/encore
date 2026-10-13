import Foundation

/// Sanity-checks that a stream's file is the episode that was asked for.
///
/// Scrapers match anime loosely: a request for S1E1 can return "Kaguya 2 - 01"
/// (season 2), a later entry the uploader numbered as its own S01E01 ("…The First
/// Kiss That Never Ends - S01E01"), or "OVA 1". This reads the season/episode
/// markers in file names, and for anime also learns the names of the franchise's
/// other entries (via ARM + AniList) so files from those can be recognised.
struct EpisodeMatcher: Sendable {
    let season: Int?
    let episode: Int?
    /// Distinctive title phrases of other entries (other seasons, movies, OVAs), normalized.
    let foreignPhrases: [String]
    /// The episode's number counting through all earlier seasons ("Show - 49" for S3E1 when
    /// the first two seasons have 24 each), as anime packs often number them.
    var absoluteEpisode: Int? = nil

    static let none = EpisodeMatcher(season: nil, episode: nil, foreignPhrases: [])

    /// True when the text clearly names a different season/episode or entry.
    func isMismatch(_ text: String) -> Bool {
        guard let season else { return false }
        let norm = " " + Self.significant(text).joined(separator: " ") + " "
        if foreignPhrases.contains(where: { phrase in
            let w = Self.significant(phrase)
            return w.count >= 2 && norm.contains(" " + w.joined(separator: " ") + " ")
        }) { return true }
        let m = Self.markers(in: text)
        if let range = m.seasonRange { return !range.contains(season) }
        if let s = m.season, s != season { return true }
        if let e = m.episode, m.season == season, let episode, e != episode { return true }
        // A bare episode number ("Show - 05"), as files inside series packs are often named.
        if m.season == nil, let e = m.episode, let episode, e != episode, e != absoluteEpisode { return true }
        return false
    }

    /// Whether the stream's name says which season or episode it is at all.
    func identifiesEpisode(_ stream: StreamItem) -> Bool {
        let m = Self.markers(in: [stream.filename, stream.title, stream.description].compactMap { $0 }.joined(separator: " "))
        return m.season != nil || m.episode != nil || m.seasonRange != nil
    }

    func isMismatch(_ stream: StreamItem) -> Bool {
        isMismatch([stream.filename, stream.title].compactMap { $0 }.joined(separator: " "))
    }

    // MARK: Building

    static func make(meta: Meta, video: Video?) async -> EpisodeMatcher {
        guard let video, let season = video.season, season > 0 else { return .none }
        var phrases: [String] = []
        // Not gated on the title looking like anime: IMDb-keyed listings (Cinemeta) only say
        // "Animation". ARM knows only anime, so for anything else this is one quick miss.
        if let imdb = meta.imdbId {
            phrases = await PhraseCache.shared.phrases(imdb: imdb, season: season) {
                await foreignTitlePhrases(imdb: imdb, season: season, baseTitle: meta.name)
            }
        }
        // Regular episodes in the seasons before this one, for absolute numbering.
        let earlier = meta.videos.filter { ($0.season ?? 0) > 0 && ($0.season ?? 0) < season }.count
        return EpisodeMatcher(season: season, episode: video.episode, foreignPhrases: phrases,
                              absoluteEpisode: video.episode.map { earlier + $0 })
    }

    /// Franchise phrases per show and season, kept for the session: every episode (and
    /// every prefetch) would otherwise re-crawl AniList, which allows only 30 requests a minute.
    private actor PhraseCache {
        static let shared = PhraseCache()
        private var done: [String: [String]] = [:]
        private var running: [String: Task<[String], Never>] = [:]

        func phrases(imdb: String, season: Int, load: @escaping @Sendable () async -> [String]) async -> [String] {
            let key = "\(imdb):\(season)"
            if let hit = done[key] { return hit }
            if let task = running[key] { return await task.value }
            let task = Task { await load() }
            running[key] = task
            let result = await task.value
            running[key] = nil
            if !result.isEmpty { done[key] = result } // an empty result may be a failed lookup; try again next time
            return result
        }
    }

    private struct ARMEntry: Decodable {
        var myanimelist: Int?
        var media: String?
        var tvdbSeason: Int?
        enum CodingKeys: String, CodingKey { case myanimelist, media, tvdbSeason = "thetvdb-season" }
    }

    private struct AniListTitles: Decodable {
        struct M: Decodable {
            struct T: Decodable { var english: String?; var romaji: String? }
            var idMal: Int?
            var title: T?
            var synonyms: [String]?
        }
        struct P: Decodable { var media: [M] }
        struct D: Decodable { var Page: P }
        var data: D?
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 6
        return URLSession(configuration: cfg)
    }()

    /// Titles of the franchise's entries that aren't the requested season, reduced to
    /// the words that set them apart from the series' own name.
    private static func foreignTitlePhrases(imdb: String, season: Int, baseTitle: String) async -> [String] {
        guard let url = URL(string: "https://arm.haglund.dev/api/v2/imdb?id=\(imdb)"),
              let (data, _) = try? await session.data(from: url),
              let entries = try? JSONDecoder().decode(LossyArray<ARMEntry>.self, from: data).items else { return [] }
        let mine = Set(entries.filter { $0.tvdbSeason == season && ($0.media ?? "TV") == "TV" }.compactMap(\.myanimelist))
        guard let anchor = mine.first else { return [] }
        // Entries with their own IMDb id (movies, spin-offs) aren't in ARM's list for the
        // show, so also walk AniList's relation graph two steps out.
        let known = Set(entries.compactMap(\.myanimelist)).union([anchor])
        var related = Set<Int>()
        await withTaskGroup(of: Set<Int>.self) { group in
            for id in known.prefix(8) { group.addTask { await relatedMalIds(id) } }
            for await ids in group { related.formUnion(ids) }
        }
        var others = known.union(related).subtracting(mine)
        others.remove(0)
        guard !others.isEmpty else { return [] }

        let ids = (Array(mine) + Array(others)).map(String.init).joined(separator: ",")
        let gql = "{ Page(perPage: 50) { media(idMal_in: [\(ids)], type: ANIME) { idMal title { english romaji } synonyms } } }"
        var req = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": gql])
        guard let (body, _) = try? await session.data(for: req),
              let resp = try? JSONDecoder().decode(AniListTitles.self, from: body) else { return [] }
        let media = resp.data?.Page.media ?? []

        // Words of the requested entry's own names don't count as "distinctive".
        var common = Set(words(baseTitle))
        for m in media where mine.contains(m.idMal ?? -1) {
            for t in [m.title?.english, m.title?.romaji].compactMap({ $0 }) + (m.synonyms ?? []) { common.formUnion(words(t)) }
        }
        var phrases = Set<String>()
        for m in media where !mine.contains(m.idMal ?? -1) {
            for t in [m.title?.english, m.title?.romaji].compactMap({ $0 }) {
                let w = words(t)
                // Longest run of distinctive words, e.g. "the first kiss that never ends", "ultra romantic".
                var best: [String] = [], run: [String] = []
                for word in w {
                    if common.contains(word) { run = [] } else { run.append(word); if run.count > best.count { best = run } }
                }
                let phrase = best.joined(separator: " ")
                // Two or more words; single words ("stairway") match too much by accident.
                if best.count >= 2 { phrases.insert(phrase) }
            }
        }
        return Array(phrases)
    }

    private struct AniListRelations: Decodable {
        struct Node: Decodable { var idMal: Int?; var type: String?; var relations: Edges? }
        struct Edge: Decodable { var node: Node? }
        struct Edges: Decodable { var edges: [Edge] }
        struct M: Decodable { var relations: Edges? }
        struct D: Decodable { var Media: M? }
        var data: D?
    }

    private static func relatedMalIds(_ mal: Int) async -> Set<Int> {
        let gql = "{ Media(idMal: \(mal), type: ANIME) { relations { edges { node { idMal type relations { edges { node { idMal type } } } } } } } }"
        var req = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": gql])
        guard let (data, _) = try? await session.data(for: req),
              let resp = try? JSONDecoder().decode(AniListRelations.self, from: data) else { return [] }
        var out = Set<Int>()
        for e in resp.data?.Media?.relations?.edges ?? [] {
            guard let n = e.node, n.type == "ANIME" else { continue }
            if let id = n.idMal { out.insert(id) }
            for e2 in n.relations?.edges ?? [] where e2.node?.type == "ANIME" {
                if let id = e2.node?.idMal { out.insert(id) }
            }
        }
        return out
    }

    // MARK: Parsing

    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
    }

    /// Words that carry the meaning, so "The First Kiss Never Ends" still matches
    /// "The First Kiss That Never Ends".
    static func significant(_ s: String) -> [String] {
        words(s).filter { !stopWords.contains($0) }
    }

    private static let stopWords: Set<String> = ["the", "a", "an", "of", "that", "to", "is", "and", "in", "on", "wa", "no", "ga", "wo", "ni"]

    private static func words(_ s: String) -> [String] {
        normalize(s).split(separator: " ").map(String.init)
    }

    struct Markers { var season: Int?; var episode: Int?; var seasonRange: ClosedRange<Int>? }

    static func markers(in text: String) -> Markers {
        func first(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<m.numberOfRanges).map { i in
                Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
            }
        }
        var out = Markers()
        if let g = first(#"\bS(\d{1,2})\s*-\s*S?(\d{1,2})\b(?!\s*\d)"#), let a = Int(g[0]), let b = Int(g[1]), b > a {
            out.seasonRange = a...b // "S01-03", "Season 1 to 3" handled below
            return out
        }
        if let g = first(#"\bSeasons?\s*(\d{1,2})\s*(?:-|to|~)\s*(\d{1,2})\b"#), let a = Int(g[0]), let b = Int(g[1]), b > a {
            out.seasonRange = a...b
            return out
        }
        if let g = first(#"\bS(\d{1,2})[ ._-]?E(\d{1,4})\b"#) {
            out.season = Int(g[0]); out.episode = Int(g[1]); return out
        }
        if let g = first(#"\bS(\d{1,2})\s+-\s+(\d{1,4})\b"#) { // "S3 - 01"
            out.season = Int(g[0]); out.episode = Int(g[1]); return out
        }
        if let g = first(#"\bSeason[ ._-]?(\d{1,2})\b"#) { out.season = Int(g[0]); return out }
        if let g = first(#"\b(\d)(?:st|nd|rd|th)[ ._-]Season\b"#) { out.season = Int(g[0]); return out }
        if let g = first(#"\bS(\d{1,2})(?:v\d)?\b"#) { out.season = Int(g[0]); return out } // "S03", "S01v2" packs
        if let g = first(#"[A-Za-z][ ._]([2-9])[ ._]-[ ._](\d{2,4})\b"#) { // "Kaguya 2 - 01"
            out.season = Int(g[0]); out.episode = Int(g[1]); return out
        }
        if let g = first(#"\s-\s(\d{1,3})(?:v\d)?(?=[\s\[\(._]|$)"#) { // "Show - 05", "Show - 05v2 [1080p]"
            out.episode = Int(g[0]); return out
        }
        return out
    }
}
