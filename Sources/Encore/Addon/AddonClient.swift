import Foundation

enum AddonError: LocalizedError {
    case badURL(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL(let s): "That doesn't look like an addon manifest URL: \(s)"
        case .http(let code, let path): "The addon returned HTTP \(code) for \(path)"
        }
    }
}

/// Talks the Stremio addon protocol to one addon (in practice, an AIOStreams manifest).
struct AddonClient: Sendable {
    let base: URL

    /// Accepts `https://…/manifest.json`, `stremio://…/manifest.json`, or the bare base URL.
    init(manifestURL raw: String) throws {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("stremio://") { s = "https://" + s.dropFirst("stremio://".count) }
        if s.hasSuffix("/manifest.json") { s.removeLast("/manifest.json".count) }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw AddonError.badURL(raw)
        }
        base = url
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 45
        cfg.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: cfg)
    }()

    /// Path components are encoded like the reference SDK's encodeURIComponent.
    private static func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'():")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        guard let url = URL(string: base.absoluteString + path) else { throw AddonError.badURL(path) }
        let (data, resp) = try await Self.session.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AddonError.http(http.statusCode, path)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func manifest() async throws -> Manifest {
        try await get("/manifest.json", as: Manifest.self)
    }

    func catalog(_ c: CatalogDef, search: String? = nil, genre: String? = nil, skip: Int = 0) async throws -> [Meta] {
        var extras: [(String, String)] = []
        if let search { extras.append(("search", search)) }
        if let g = genre ?? c.defaultGenre { extras.append(("genre", g)) }
        if skip > 0 { extras.append(("skip", String(skip))) }
        var path = "/catalog/\(Self.enc(c.type))/\(Self.enc(c.id))"
        if !extras.isEmpty {
            path += "/" + extras.map { "\(Self.enc($0.0))=\(Self.enc($0.1))" }.joined(separator: "&")
        }
        return try await get(path + ".json", as: CatalogResponse.self).metas
    }

    func meta(type: String, id: String) async throws -> Meta? {
        try await get("/meta/\(Self.enc(type))/\(Self.enc(id)).json", as: MetaResponse.self).meta
    }

    func streams(type: String, videoId: String) async throws -> [StreamItem] {
        try await get("/stream/\(Self.enc(type))/\(Self.enc(videoId)).json", as: StreamsResponse.self).streams
    }

    func subtitles(type: String, videoId: String) async throws -> [SubtitleItem] {
        try await get("/subtitles/\(Self.enc(type))/\(Self.enc(videoId)).json", as: SubtitlesResponse.self).subtitles
    }
}
