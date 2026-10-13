import Foundation
import Observation

/// Shares watch progress with AIOStreams' built-in Jellyfin server (the one apps like
/// Odin connect to), as one of its profiles. Encore reports what it plays (start,
/// progress, stop, watched, watched-up-to, dropped) and pulls the profile's Continue
/// Watching and recent history, so either app can pick up where the other left off.
///
/// Items are addressed by AIOStreams' own "packed" ids, which encode an IMDb id with the
/// season and episode, so both apps always mean exactly the same title.
@Observable
@MainActor
final class JellyfinSync {
    enum Status: Equatable { case off, signedOut, signingIn, signedIn(String), failed(String) }

    private(set) var status: Status = .off
    private(set) var lastPull: Date?

    private let settings: Settings
    private let watch: WatchStore
    private var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: "jellyfinDeviceId") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "jellyfinDeviceId")
        return id
    }
    private var token: String? { Keychain.get("jellyfin.token") }
    private var userId: String? { UserDefaults.standard.string(forKey: "jellyfinUserId") }

    init(settings: Settings, watch: WatchStore) {
        self.settings = settings
        self.watch = watch
        refreshStatus()
    }

    func refreshStatus() {
        guard settings.jellyfinSync else { status = .off; return }
        if token != nil, userId != nil { status = .signedIn(settings.jellyfinProfile) } else { status = .signedOut }
    }

    // MARK: Where the server is

    /// `https://host/jellyfin` and the config id, from the AIOStreams manifest URL
    /// (`https://host/stremio/<uuid>/<secret>/manifest.json`).
    var server: (base: URL, configId: String)? {
        guard let url = URL(string: settings.manifestURL), let host = url.host, let scheme = url.scheme else { return nil }
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "stremio"), i + 1 < parts.count else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        guard let base = URL(string: "\(scheme)://\(host)\(port)/jellyfin") else { return nil }
        return (base, parts[i + 1])
    }

    private var authHeader: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
        var h = "MediaBrowser Client=\"Encore\", Device=\"Mac\", DeviceId=\"\(deviceId)\", Version=\"\(version)\""
        if let token { h += ", Token=\"\(token)\"" }
        return h
    }

    // MARK: Signing in

    /// Signs in as `<config id>/<profile>` with the AIOStreams config password
    /// (`password/PIN` when the profile has a PIN). Only the token is kept.
    func signIn(password: String) async {
        guard let server else { status = .failed("Connect an AIOStreams addon first."); return }
        let profile = settings.jellyfinProfile.trimmingCharacters(in: .whitespaces)
        guard !profile.isEmpty else { status = .failed("Enter the profile name."); return }
        status = .signingIn
        Keychain.set(nil, for: "jellyfin.token")
        var req = URLRequest(url: server.base.appendingPathComponent("Users/AuthenticateByName"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["Username": "\(server.configId)/\(profile)", "Pw": password])
        struct Auth: Decodable { struct U: Decodable { var Id: String; var Name: String? }; var AccessToken: String; var User: U }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let auth = try? JSONDecoder().decode(Auth.self, from: data) else {
                status = .failed(code == 401 ? "Wrong password or PIN for that profile." :
                                 code == 404 ? "No profile called \(profile)." :
                                 code == 429 ? "Too many tries; wait a minute." : "Sign-in failed (HTTP \(code)).")
                return
            }
            Keychain.set(auth.AccessToken, for: "jellyfin.token")
            UserDefaults.standard.set(auth.User.Id, forKey: "jellyfinUserId")
            status = .signedIn(auth.User.Name ?? profile)
            await pull()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func signOut() {
        Keychain.set(nil, for: "jellyfin.token")
        UserDefaults.standard.removeObject(forKey: "jellyfinUserId")
        refreshStatus()
    }

    private var active: Bool {
        if case .signedIn = status { return settings.jellyfinSync }
        return false
    }

    // MARK: Ids

    /// AIOStreams' packed item id: a1, kind<<4 | imdb (1), media type, the IMDb number
    /// (48 bits), season and episode (16 bits each, ffff for none), then zeros.
    static func itemId(imdb: String, type: String, season: Int? = nil, episode: Int? = nil, kind: String? = nil) -> String? {
        guard imdb.hasPrefix("tt"), let numeric = UInt64(imdb.dropFirst(2)) else { return nil }
        let kindCode: UInt8 = switch kind ?? (episode != nil ? "episode" : season != nil ? "season" : type == "movie" ? "movie" : "series") {
            case "movie": 1
            case "series": 2
            case "season": 3
            case "episode": 4
            default: 2
        }
        let media: UInt8 = switch type {
            case "movie": 1
            case "anime": 3
            case "tv": 4
            default: 2
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0xa1
        bytes[1] = (kindCode << 4) | 1
        bytes[2] = media
        for i in 0..<6 { bytes[3 + i] = UInt8((numeric >> (8 * UInt64(5 - i))) & 0xff) }
        let s = UInt16(season ?? 0xffff), e = UInt16(episode ?? 0xffff)
        bytes[9] = UInt8(s >> 8); bytes[10] = UInt8(s & 0xff)
        bytes[11] = UInt8(e >> 8); bytes[12] = UInt8(e & 0xff)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The other way: (IMDb id, kind, season, episode) for a packed IMDb id.
    static func decode(_ id: String) -> (imdb: String, kind: Int, season: Int?, episode: Int?)? {
        let hex = id.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex.count == 32, hex.hasPrefix("a1") else { return nil }
        var b = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); b.append(UInt8(hex[i..<j], radix: 16) ?? 0); i = j }
        guard b[1] & 0x0f == 1 else { return nil } // IMDb ids only
        var numeric: UInt64 = 0
        for k in 3..<9 { numeric = numeric << 8 | UInt64(b[k]) }
        let s = Int(b[9]) << 8 | Int(b[10]), e = Int(b[11]) << 8 | Int(b[12])
        return ("tt" + String(format: "%07llu", numeric), Int(b[1] >> 4), s == 0xffff ? nil : s, e == 0xffff ? nil : e)
    }

    private func itemId(meta: Meta, video: Video?) -> String? {
        guard let imdb = meta.imdbId ?? (meta.id.hasPrefix("tt") ? meta.id : nil) else { return nil }
        if let v = video, let s = v.season, let e = v.episode {
            return Self.itemId(imdb: imdb, type: meta.type, season: s, episode: e)
        }
        return Self.itemId(imdb: imdb, type: meta.type)
    }

    // MARK: Requests

    @discardableResult
    private func send(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async -> Data? {
        guard let server else { return nil }
        var comps = URLComponents(url: server.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        if (resp as? HTTPURLResponse)?.statusCode == 401 {
            // The token was revoked (e.g. signed out from AIOStreams): ask to sign in again.
            Keychain.set(nil, for: "jellyfin.token")
            status = .failed("Signed out by AIOStreams; sign in again.")
            return nil
        }
        return data
    }

    // MARK: Reporting what Encore plays

    func playbackStarted(meta: Meta, video: Video?, position: Double) {
        guard active, let id = itemId(meta: meta, video: video) else { return }
        Task { await send("POST", "Sessions/Playing", body: ["ItemId": id, "PositionTicks": ticks(position), "CanSeek": true, "PlayMethod": "DirectPlay"]) }
    }

    func playbackProgress(meta: Meta, video: Video?, position: Double, paused: Bool) {
        guard active, let id = itemId(meta: meta, video: video) else { return }
        Task { await send("POST", "Sessions/Playing/Progress", body: ["ItemId": id, "PositionTicks": ticks(position), "IsPaused": paused]) }
    }

    func playbackStopped(meta: Meta, video: Video?, position: Double, finished: Bool) {
        guard active, let id = itemId(meta: meta, video: video) else { return }
        Task {
            await send("POST", "Sessions/Playing/Stopped", body: ["ItemId": id, "PositionTicks": ticks(position)])
            if finished { await send("POST", "UserPlayedItems/\(id)", query: userQuery) }
        }
    }

    func setWatched(meta: Meta, videos: [Video], watched: Bool) {
        guard active else { return }
        let ids = videos.isEmpty ? [itemId(meta: meta, video: nil)].compactMap { $0 } : videos.compactMap { itemId(meta: meta, video: $0) }
        Task { for id in ids { await send(watched ? "POST" : "DELETE", "UserPlayedItems/\(id)", query: userQuery) } }
    }

    func playedUpTo(meta: Meta, video: Video) {
        guard active, let id = itemId(meta: meta, video: video) else { return }
        Task { await send("POST", "AIOStreams/PlayedUpTo/\(id)") }
    }

    /// Dropping a show is a "dislike" on the series in AIOStreams; picking it back up, a like.
    func setDropped(meta: Meta, dropped: Bool) {
        guard active, let imdb = meta.imdbId, let id = Self.itemId(imdb: imdb, type: meta.type) else { return }
        Task { await send("POST", "UserItems/\(id)/Rating", query: userQuery.merging(["likes": dropped ? "false" : "true"]) { a, _ in a }) }
    }

    private var userQuery: [String: String] { userId.map { ["userId": $0] } ?? [:] }
    private func ticks(_ seconds: Double) -> Int64 { Int64(max(0, seconds) * 10_000_000) }

    // MARK: Pulling what the other app played

    private struct ItemsPage: Decodable { var Items: [Item] }
    private struct Item: Decodable {
        struct UserData: Decodable { var PlaybackPositionTicks: Int64?; var Played: Bool?; var LastPlayedDate: String? }
        var Id: String
        var Name: String?
        var SeriesName: String?
        var SeriesId: String?
        var `Type`: String?
        var ParentIndexNumber: Int?
        var IndexNumber: Int?
        var RunTimeTicks: Int64?
        var UserData: UserData?
    }

    /// Brings in the profile's Continue Watching: anything played more recently there
    /// than here becomes the resume point here. `metaFor` looks a title up for its art.
    func pull(metaFor: ((String, String) async -> Meta?)? = nil) async {
        guard active else { return }
        guard let data = await send("GET", "UserItems/Resume", query: userQuery.merging(["Limit": "40", "Fields": "ProviderIds", "EnableUserData": "true"]) { a, _ in a }),
              let page = try? JSONDecoder().decode(ItemsPage.self, from: data) else { return }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for item in page.Items {
            guard let ids = Self.decode(item.Id), let ticks = item.UserData?.PlaybackPositionTicks, ticks > 0 else { continue }
            let when = item.UserData?.LastPlayedDate.flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } ?? .now
            let isEpisode = ids.episode != nil
            let videoId = isEpisode ? "\(ids.imdb):\(ids.season ?? 1):\(ids.episode!)" : ids.imdb
            if let local = watch.entry(for: ids.imdb), local.updatedAt >= when { continue }
            guard let meta = await metaFor?(isEpisode ? "series" : "movie", ids.imdb) else { continue }
            let video = meta.videos.first { $0.id == videoId }
            watch.applyRemoteProgress(
                title: SavedTitle(meta), videoId: videoId, season: ids.season, episode: ids.episode,
                episodeTitle: video?.title ?? item.Name, thumbnail: video?.thumbnail,
                position: Double(ticks) / 10_000_000,
                duration: Double(item.RunTimeTicks ?? 0) / 10_000_000,
                at: when
            )
        }
        lastPull = .now
    }
}
