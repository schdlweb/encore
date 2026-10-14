import Foundation

// Stremio addon protocol types. Addons in the wild are loose with types (numbers
// as strings, strings as numbers, odd extras), so everything optional decodes
// leniently: a malformed field becomes nil instead of failing the whole response.

extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ key: Key, as: T.Type = T.self) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// A field that some addons send as a string and others as a number.
    func flexString(_ key: Key) -> String? {
        if let s = lenient(key, as: String.self) { return s.isEmpty ? nil : s }
        if let d = lenient(key, as: Double.self) {
            return d == d.rounded() ? String(Int(d)) : String(d)
        }
        return nil
    }

    func lossyArray<T: Decodable>(_ key: Key, of: T.Type = T.self) -> [T] {
        lenient(key, as: LossyArray<T>.self)?.items ?? []
    }
}

/// Decodes an array, dropping elements that fail rather than failing the array.
struct LossyArray<T: Decodable>: Decodable {
    var items: [T]
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) { out.append(v) } else { _ = try? c.decode(Skip.self) }
        }
        items = out
    }
    private struct Skip: Decodable {}
}

struct Manifest: Decodable {
    var id: String
    var name: String
    var version: String?
    var description: String?
    var logo: String?
    var types: [String]
    var catalogs: [CatalogDef]
    var resources: [Resource]

    enum K: String, CodingKey { case id, name, version, description, logo, types, catalogs, resources }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.lenient(.id) ?? "unknown"
        name = c.lenient(.name) ?? "Addon"
        version = c.flexString(.version)
        description = c.lenient(.description)
        logo = c.lenient(.logo)
        types = c.lenient(.types) ?? []
        catalogs = c.lossyArray(.catalogs)
        resources = c.lossyArray(.resources)
    }

    func supports(_ resource: String) -> Bool {
        resources.contains { $0.name == resource }
    }
}

struct Resource: Decodable {
    var name: String
    var types: [String]?
    var idPrefixes: [String]?

    enum K: String, CodingKey { case name, types, idPrefixes }
    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            name = s
            return
        }
        let c = try decoder.container(keyedBy: K.self)
        name = try c.decode(String.self, forKey: .name)
        types = c.lenient(.types)
        idPrefixes = c.lenient(.idPrefixes)
    }
}

struct CatalogExtra: Decodable, Hashable {
    var name: String
    var isRequired: Bool
    var options: [String]

    enum K: String, CodingKey { case name, isRequired, options }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        name = try c.decode(String.self, forKey: .name)
        isRequired = c.lenient(.isRequired) ?? false
        options = c.lossyArray(.options)
    }
}

struct CatalogDef: Decodable, Hashable, Identifiable {
    var type: String
    var id: String
    var name: String
    var extra: [CatalogExtra]

    var key: String { "\(type)|\(id)" }

    enum K: String, CodingKey { case type, id, name, extra, extraRequired, extraSupported }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        type = try c.decode(String.self, forKey: .type)
        id = try c.decode(String.self, forKey: .id)
        name = c.lenient(.name) ?? id
        var extra: [CatalogExtra] = c.lossyArray(.extra)
        // Legacy manifests list extras as bare names.
        let required: [String] = c.lenient(.extraRequired) ?? []
        let supported: [String] = c.lenient(.extraSupported) ?? []
        for n in supported where !extra.contains(where: { $0.name == n }) {
            extra.append(CatalogExtra(name: n, isRequired: required.contains(n), options: []))
        }
        self.extra = extra
    }

    func supports(_ extraName: String) -> Bool { extra.contains { $0.name == extraName } }

    var isSearchable: Bool { supports("search") }

    /// Can be shown as a plain row: no required extra other than a genre we can default.
    var isBrowsable: Bool {
        for e in extra where e.isRequired {
            if e.name == "genre", !e.options.isEmpty { continue }
            return false
        }
        return true
    }

    var defaultGenre: String? {
        extra.first { $0.name == "genre" && $0.isRequired }?.options.first
    }

    var displayType: String {
        switch type {
        case "movie": "Movies"
        case "series": "Series"
        case "anime": "Anime"
        case "tv": "TV"
        default: type.capitalized
        }
    }
}

extension CatalogExtra {
    init(name: String, isRequired: Bool, options: [String]) {
        self.name = name
        self.isRequired = isRequired
        self.options = options
    }
}

struct CastMember: Decodable, Hashable {
    var name: String
    var character: String?
    var photo: String?

    enum K: String, CodingKey { case name, character, photo }
    init(name: String, character: String? = nil, photo: String? = nil) {
        self.name = name
        self.character = character
        self.photo = photo
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        name = try c.decode(String.self, forKey: .name)
        character = c.lenient(.character)
        photo = c.lenient(.photo)
    }
}

struct MetaLink: Decodable, Hashable {
    var name: String
    var category: String
    var url: String?
}

struct Video: Decodable, Hashable, Identifiable {
    var id: String
    var title: String
    var season: Int?
    var episode: Int?
    var released: Date?
    var thumbnail: String?
    var overview: String?

    enum K: String, CodingKey { case id, title, name, season, episode, number, released, thumbnail, overview, description }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.lenient(.title) ?? c.lenient(.name) ?? ""
        season = c.lenient(.season) ?? c.flexString(.season).flatMap(Int.init)
        episode = c.lenient(.episode) ?? c.lenient(.number) ?? c.flexString(.episode).flatMap(Int.init)
        thumbnail = c.lenient(.thumbnail)
        overview = c.lenient(.overview) ?? c.lenient(.description)
        if let s = c.lenient(.released, as: String.self) { released = parseISODate(s) }
    }
}

extension Video {
    /// For an entry whose metahub artwork names a different season than the entry itself,
    /// the same video re-labelled with the artwork's season and episode.
    func refiledByArtwork() -> Video {
        guard let thumbnail, thumbnail.contains("episodes.metahub.space/"),
              let url = URL(string: thumbnail) else { return self }
        let parts = url.pathComponents // ["/", "tt7078180", "0", "2", "w780.jpg"]
        guard parts.count >= 5, let s = Int(parts[2]), let e = Int(parts[3]), s != season,
              let base = id.split(separator: ":").first else { return self }
        var v = self
        v.season = s
        v.episode = e
        v.id = "\(base):\(s):\(e)"
        return v
    }
}

func parseISODate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withFullDate]
    return f.date(from: String(s.prefix(10)))
}

struct Meta: Decodable, Hashable, Identifiable {
    var id: String
    var type: String
    var name: String
    var poster: String?
    var posterShape: String?
    var background: String?
    var logo: String?
    var description: String?
    var releaseInfo: String?
    /// Full release (or first-air) date, when the catalog gives one.
    var released: Date?
    var imdbRating: String?
    var runtime: String?
    var genres: [String]
    var cast: [CastMember]
    var directors: [String]
    var videos: [Video]
    var trailerYouTubeId: String?
    var writers: [String] = []
    var country: String?
    var status: String?
    var certification: String?
    private var rawMalId: String?
    private var rawImdbId: String?

    var malId: Int? {
        if id.hasPrefix("mal:") { return Int(id.dropFirst(4)) }
        return rawMalId.flatMap(Int.init)
    }

    /// The title's IMDb id, even when the addon keys it by MAL/Kitsu id.
    var imdbId: String? {
        if id.hasPrefix("tt") { return id }
        if id.hasPrefix("imdb:tt") { return String(id.dropFirst(5)) } // some catalogs prefix it
        if let r = rawImdbId, r.hasPrefix("tt") { return r }
        let fromVideo = videos.first?.id.split(separator: ":").first.map(String.init)
        return fromVideo?.hasPrefix("tt") == true ? fromVideo : nil
    }

    var isAnimeLike: Bool {
        ["mal:", "kitsu:", "anilist:", "anidb:"].contains { id.hasPrefix($0) } || rawMalId != nil
            || type.hasPrefix("anime")
            || genres.contains { ["anime"].contains($0.lowercased()) }
    }

    var year: String? {
        guard let r = releaseInfo else { return nil }
        return String(r.prefix(4))
    }

    var isSeriesLike: Bool { type == "series" || type == "anime" || videos.count > 1 }

    enum K: String, CodingKey {
        case id, type, name, poster, posterShape, background, logo, description, releaseInfo, year
        case imdbRating, runtime, genres, genre, cast, director, links, videos, trailers, app_extras, released
        case trailerStreams, writer, country, status, _malId, _imdbId, imdb_id
    }
    struct AppExtras: Decodable { var cast: LossyArray<CastMember>?; var certification: String? }
    struct Trailer: Decodable { var source: String?; var type: String? }
    struct TrailerStream: Decodable { var ytId: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        type = c.lenient(.type) ?? "movie"
        name = c.lenient(.name) ?? "Untitled"
        poster = c.lenient(.poster)
        posterShape = c.lenient(.posterShape)
        background = c.lenient(.background)
        logo = c.lenient(.logo)
        description = c.lenient(.description)
        releaseInfo = c.flexString(.releaseInfo) ?? c.flexString(.year)
        if let s = c.lenient(.released, as: String.self) { released = parseISODate(s) }
        imdbRating = c.flexString(.imdbRating)
        runtime = c.flexString(.runtime)
        let links: [MetaLink] = c.lossyArray(.links)
        let genreLinks = links.filter { $0.category == "Genres" }.map(\.name)
        genres = c.lenient(.genres) ?? c.lenient(.genre) ?? genreLinks
        if let extras = c.lenient(.app_extras, as: AppExtras.self), let cast = extras.cast?.items, !cast.isEmpty {
            self.cast = cast
        } else {
            let castLinks = links.filter { $0.category == "Cast" }.map { CastMember(name: $0.name) }
            let plain: [String] = c.lenient(.cast) ?? []
            self.cast = castLinks.isEmpty ? plain.map { CastMember(name: $0) } : castLinks
        }
        directors = (c.lenient(.director) as [String]?) ?? links.filter { $0.category == "Directors" }.map(\.name)
        // Some metadata files specials under season 1 with clashing ids (Breaking Bad's
        // minisodes, Violet Evergarden's OVA and films all claim tt…:1:1-4). Their artwork
        // link still says where they belong (metahub's …/0/2/w780.jpg = specials, episode
        // 2), so move them back there; any remaining clash keeps the first of each id.
        var seenVideos = Set<String>()
        videos = (c.lossyArray(.videos) as [Video]).map { $0.refiledByArtwork() }.filter { seenVideos.insert($0.id).inserted }
        let trailers: [Trailer] = c.lossyArray(.trailers)
        let streams: [TrailerStream] = c.lossyArray(.trailerStreams)
        trailerYouTubeId = trailers.first { $0.type == nil || $0.type == "Trailer" }?.source
            ?? trailers.first?.source ?? streams.first?.ytId
        writers = (c.lenient(.writer) as [String]?) ?? links.filter { $0.category == "Writers" }.map(\.name)
        country = c.flexString(.country) ?? (c.lenient(.country) as [String]?)?.first
        status = c.lenient(.status)
        certification = c.lenient(.app_extras, as: AppExtras.self)?.certification
        rawMalId = c.flexString(._malId)
        rawImdbId = c.lenient(._imdbId) ?? c.lenient(.imdb_id)
    }

    /// A bare preview, e.g. from an external search; the detail page fetches the rest.
    init(id: String, type: String, name: String, poster: String? = nil, releaseInfo: String? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.releaseInfo = releaseInfo
        genres = []
        cast = []
        directors = []
        videos = []
    }

    /// Fills gaps in a catalog preview from the full meta, keeping what the preview had.
    func merged(with full: Meta) -> Meta {
        var m = full
        m.poster = full.poster ?? poster
        m.background = full.background ?? background
        m.logo = full.logo ?? logo
        m.description = full.description ?? description
        m.imdbRating = full.imdbRating ?? imdbRating
        m.releaseInfo = full.releaseInfo ?? releaseInfo
        m.released = full.released ?? released
        if m.genres.isEmpty { m.genres = genres }
        m.trailerYouTubeId = full.trailerYouTubeId ?? trailerYouTubeId
        return m
    }

    var seasons: [Int] {
        Array(Set(videos.compactMap(\.season))).sorted { a, b in
            // Specials (season 0) go last.
            if a == 0 { return false }
            if b == 0 { return true }
            return a < b
        }
    }
}

struct StreamItem: Decodable, Hashable, Identifiable {
    var id: String { url ?? infoHash.map { "\($0):\(fileIdx ?? -1)" } ?? externalUrl ?? UUID().uuidString }
    var name: String?
    var title: String?
    var description: String?
    var url: String?
    var infoHash: String?
    var fileIdx: Int?
    var externalUrl: String?
    var bingeGroup: String?
    var filename: String?
    var videoSize: Int64?
    var requestHeaders: [String: String]

    var isPlayable: Bool { url != nil }

    /// AIOStreams puts the formatted summary in `name` and details in `description`.
    var headline: String { name ?? "Stream" }
    /// Dolby Vision without an HDR10 base layer (profile 5, typical of streaming-service
    /// WEB-DLs). mpv's embeddable renderer can't map its colors, so these play tinted.
    var isDolbyVisionOnly: Bool {
        let text = [name, description, title, filename].compactMap { $0 }.joined(separator: " ")
        let dv = text.range(of: #"(?i)(\bDV\b|\bDoVi\b|Dolby[ ._-]?Vision)"#, options: .regularExpression) != nil
        let hdr = text.range(of: #"(?i)\bHDR(10)?(\+|Plus)?\b"#, options: .regularExpression) != nil
        return dv && !hdr
    }

    /// Whether this looks like an OVA/special/extra rather than a regular episode.
    /// Anime torrents number OVAs and picture dramas "01, 02…", so a lookup for
    /// episode 1 often matches "OVA 1" too.
    var looksLikeExtra: Bool {
        Self.isExtraName([filename, description, title].compactMap { $0 }.joined(separator: " "))
    }

    static func isExtraName(_ text: String) -> Bool {
        text.range(of: #"(?i)(\b(OVA|OAD|ONA|NCOP|NCED|SP\d{0,2}|Specials?|Extras?|Bonus|Recap|Menu|PV)\b|Picture[ ._-]?Drama|Creditless)"#,
                   options: .regularExpression) != nil
    }

    /// Where the release came from, from its file name: Remux, BluRay, WEB-DL…
    var sourceTag: String? {
        let text = [filename, description, title].compactMap { $0 }.joined(separator: " ")
        let kinds: [(String, String)] = [
            (#"(?i)\bremux\b"#, "Remux"),
            (#"(?i)\b(blu-?ray|bdrip|brrip|bd)\b"#, "BluRay"),
            (#"(?i)\bweb-?dl\b"#, "WEB-DL"),
            (#"(?i)\bweb-?rip\b"#, "WEBRip"),
            (#"(?i)\bhdtv\b"#, "HDTV"),
            (#"(?i)\bweb\b"#, "WEB"),
        ]
        return kinds.first { text.range(of: $0.0, options: .regularExpression) != nil }?.1
    }

    /// Name and first detail line on one line, for status text.
    var oneLine: String {
        let head = headline.split(separator: "\n").joined(separator: " ")
        let first = details.split(separator: "\n").first.map(String.init)
        return [head, first].compactMap { $0 }.joined(separator: " · ")
    }
    var details: String { description ?? title ?? filename ?? "" }

    enum K: String, CodingKey { case name, title, description, url, infoHash, fileIdx, externalUrl, behaviorHints }
    struct Hints: Decodable {
        var bingeGroup: String?
        var filename: String?
        var videoSize: Int64?
        var proxyHeaders: ProxyHeaders?
    }
    struct ProxyHeaders: Decodable { var request: [String: String]? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        name = c.lenient(.name)
        title = c.lenient(.title)
        description = c.lenient(.description)
        url = c.lenient(.url)
        infoHash = c.lenient(.infoHash)
        fileIdx = c.lenient(.fileIdx)
        externalUrl = c.lenient(.externalUrl)
        let hints = c.lenient(.behaviorHints, as: Hints.self)
        bingeGroup = hints?.bingeGroup
        filename = hints?.filename
        videoSize = hints?.videoSize
        requestHeaders = hints?.proxyHeaders?.request ?? [:]
    }
}

struct SubtitleItem: Decodable, Hashable {
    var id: String?
    var url: String
    var lang: String
}

struct CatalogResponse: Decodable {
    var metas: [Meta]
    enum K: String, CodingKey { case metas }
    init(from decoder: Decoder) throws {
        metas = try decoder.container(keyedBy: K.self).lossyArray(.metas)
    }
}

struct MetaResponse: Decodable { var meta: Meta? }

struct StreamsResponse: Decodable {
    var streams: [StreamItem]
    enum K: String, CodingKey { case streams }
    init(from decoder: Decoder) throws {
        streams = try decoder.container(keyedBy: K.self).lossyArray(.streams)
    }
}

struct SubtitlesResponse: Decodable {
    var subtitles: [SubtitleItem]
    enum K: String, CodingKey { case subtitles }
    init(from decoder: Decoder) throws {
        subtitles = try decoder.container(keyedBy: K.self).lossyArray(.subtitles)
    }
}
