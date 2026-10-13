import Foundation

struct SkipSegment: Equatable, Identifiable {
    enum Kind: String { case intro, recap, outro }
    var kind: Kind
    var start: Double
    var end: Double
    var source: String

    var id: String { "\(kind.rawValue)@\(Int(start))" }

    var buttonTitle: String {
        switch kind {
        case .intro: "Skip Intro"
        case .recap: "Skip Recap"
        case .outro: "Skip Credits"
        }
    }

    func contains(_ t: Double) -> Bool { t >= start - 0.5 && t < end - 1.5 }
}

/// Intro/recap/credits times for an episode or movie.
///
/// In order of trust:
///  1. Chapters in the file itself ("Opening", "Ending", …) – exact for this release.
///  2. IntroDB (api.introdb.app) – crowd-sourced, keyed by IMDb id + season/episode.
///  3. AniSkip (api.aniskip.com) – anime openings/endings, keyed by MAL id + episode.
///     ARM (arm.haglund.dev) maps IMDb seasons and Kitsu ids to MAL ids.
/// All three web sources are free and need no key.
enum SegmentService {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        return URLSession(configuration: cfg)
    }()

    // MARK: Chapters

    static func fromChapters(_ chapters: [(title: String, time: Double)], duration: Double) -> [SkipSegment] {
        var out: [SkipSegment] = []
        for (i, ch) in chapters.enumerated() {
            let end = i + 1 < chapters.count ? chapters[i + 1].time : duration
            let length = end - ch.time
            guard length > 5 else { continue }
            let t = ch.title.lowercased().trimmingCharacters(in: .whitespaces)
            let kind: SkipSegment.Kind?
            if matches(t, ["op", "opening", "intro", "introduction", "opening credits", "opening song", "title sequence", "theme song"]) {
                kind = .intro
            } else if matches(t, ["ed", "ending", "end credits", "credits", "outro", "closing credits", "ending song", "closing"]) {
                kind = .outro
            } else if matches(t, ["recap", "previously", "previously on"]) {
                kind = .recap
            } else {
                kind = nil
            }
            // A 20-minute "Intro" chapter is a mislabel, not something to skip.
            guard let kind, length < (kind == .outro ? 600 : 240) else { continue }
            out.append(SkipSegment(kind: kind, start: ch.time, end: end, source: "chapters"))
        }
        return out
    }

    private static func matches(_ title: String, _ words: [String]) -> Bool {
        words.contains { w in
            title == w || title.hasPrefix(w + " ") || title.hasPrefix(w + ":") || title.hasPrefix(w + "-")
                || title.range(of: "^\(NSRegularExpression.escapedPattern(for: w))\\s*\\d+$", options: .regularExpression) != nil
        }
    }

    // MARK: Web sources

    static func fetch(meta: Meta, video: Video?, duration: Double) async -> [SkipSegment] {
        let ids = episodeIds(meta: meta, video: video)

        if let imdb = ids.imdb {
            let found = await introDB(imdb: imdb, season: ids.season, episode: ids.episode)
            if !found.isEmpty { return found }
        }
        guard looksLikeAnime(meta), let episode = ids.episode ?? video?.episode else { return [] }
        guard let mal = await malId(meta: meta, imdb: ids.imdb, season: ids.season) else { return [] }
        return await aniSkip(mal: mal, episode: episode, duration: duration)
    }

    /// IMDb id and season/episode, from ids like `tt1355642:1:3`.
    private static func episodeIds(meta: Meta, video: Video?) -> (imdb: String?, season: Int?, episode: Int?) {
        if let v = video {
            let parts = v.id.split(separator: ":")
            if parts.count == 3, parts[0].hasPrefix("tt") {
                return (String(parts[0]), Int(parts[1]), Int(parts[2]))
            }
            return (meta.id.hasPrefix("tt") ? meta.id : nil, v.season, v.episode)
        }
        return (meta.id.hasPrefix("tt") ? meta.id : nil, nil, nil)
    }

    private static func looksLikeAnime(_ meta: Meta) -> Bool {
        meta.isAnimeLike || meta.genres.contains { $0.lowercased() == "animation" }
    }

    private struct IntroDBResponse: Decodable {
        struct Seg: Decodable { var start_sec: Double?; var end_sec: Double? }
        var intro: Seg?
        var recap: Seg?
        var outro: Seg?
    }

    private static func introDB(imdb: String, season: Int?, episode: Int?) async -> [SkipSegment] {
        var c = URLComponents(string: "https://api.introdb.app/segments")!
        c.queryItems = [URLQueryItem(name: "imdb_id", value: imdb)]
        if let season, let episode {
            c.queryItems! += [URLQueryItem(name: "season", value: String(season)),
                              URLQueryItem(name: "episode", value: String(episode))]
        } else {
            c.queryItems!.append(URLQueryItem(name: "is_movie", value: "true"))
        }
        guard let url = c.url, let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode(IntroDBResponse.self, from: data) else { return [] }
        let isMovie = season == nil
        let fields: [(IntroDBResponse.Seg?, SkipSegment.Kind)] = isMovie
            ? [(body.outro, .outro)]
            : [(body.intro, .intro), (body.recap, .recap), (body.outro, .outro)]
        return fields.compactMap { seg, kind in
            guard let s = seg?.start_sec, let e = seg?.end_sec, e > s else { return nil }
            return SkipSegment(kind: kind, start: s, end: e, source: "IntroDB")
        }
    }

    private struct ARMEntry: Decodable {
        var myanimelist: Int?
        var media: String?
        var thetvdbSeason: Int?
        var themoviedbSeason: Int?
        enum CodingKeys: String, CodingKey {
            case myanimelist, media
            case thetvdbSeason = "thetvdb-season"
            case themoviedbSeason = "themoviedb-season"
        }
    }

    private static func malId(meta: Meta, imdb: String?, season: Int?) async -> Int? {
        let prefix = meta.id.split(separator: ":").first.map(String.init) ?? ""
        let raw = meta.id.split(separator: ":").dropFirst().first.map(String.init) ?? ""
        // A MAL id names one season; trust it for single-season shows and season 1.
        if let id = meta.malId, (season ?? 1) <= 1 || meta.seasons.filter({ $0 > 0 }).count <= 1 {
            return id
        }
        if let imdb, let url = URL(string: "https://arm.haglund.dev/api/v2/imdb?id=\(imdb)"),
           let (data, _) = try? await session.data(from: url),
           let entries = try? JSONDecoder().decode(LossyArray<ARMEntry>.self, from: data).items, !entries.isEmpty {
            let tv = entries.filter { $0.media == nil || $0.media == "TV" }
            let s = season ?? 1
            let pick = tv.first { $0.thetvdbSeason == s } ?? tv.first { $0.themoviedbSeason == s }
                ?? (tv.count == 1 ? tv.first : nil)
            if let mal = pick?.myanimelist { return mal }
        }
        if ["kitsu", "anilist", "anidb"].contains(prefix), !raw.isEmpty,
           let url = URL(string: "https://arm.haglund.dev/api/v2/ids?source=\(prefix)&id=\(raw)"),
           let (data, _) = try? await session.data(from: url),
           let entry = try? JSONDecoder().decode(ARMEntry.self, from: data) {
            return entry.myanimelist
        }
        return prefix == "mal" ? Int(raw) : nil
    }

    private struct AniSkipResponse: Decodable {
        struct Result: Decodable {
            struct Interval: Decodable { var startTime: Double; var endTime: Double }
            var interval: Interval
            var skipType: String
            var episodeLength: Double?
        }
        var found: Bool
        var results: [Result]?
    }

    private static func aniSkip(mal: Int, episode: Int, duration: Double) async -> [SkipSegment] {
        let types = ["op", "ed", "recap", "mixed-op", "mixed-ed"].map { "types=\($0)" }.joined(separator: "&")
        guard let url = URL(string: "https://api.aniskip.com/v2/skip-times/\(mal)/\(episode)?\(types)&episodeLength=0"),
              let (data, _) = try? await session.data(from: url),
              let body = try? JSONDecoder().decode(AniSkipResponse.self, from: data), body.found else { return [] }
        // Submissions are per release; prefer ones whose episode length matches this file.
        let sorted = (body.results ?? []).sorted {
            abs(($0.episodeLength ?? duration) - duration) < abs(($1.episodeLength ?? duration) - duration)
        }
        var out: [SkipSegment] = []
        for r in sorted {
            let kind: SkipSegment.Kind
            switch r.skipType {
            case "op", "mixed-op": kind = .intro
            case "ed", "mixed-ed": kind = .outro
            case "recap": kind = .recap
            default: continue
            }
            guard !out.contains(where: { $0.kind == kind }) else { continue }
            // Off by more than ~20s means a different cut; its times would be wrong here.
            if let len = r.episodeLength, len > 0, duration > 0, abs(len - duration) > 20 { continue }
            out.append(SkipSegment(kind: kind, start: r.interval.startTime, end: r.interval.endTime, source: "AniSkip"))
        }
        return out
    }
}
