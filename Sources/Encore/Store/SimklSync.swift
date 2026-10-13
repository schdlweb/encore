import AppKit
import Foundation
import Observation

/// Optional Simkl tracking: scrobbles what Encore plays (start, pause, stop; Simkl counts
/// it watched past 80%) and sends Mark as Watched / Unwatched to your Simkl history.
///
/// Signing in is approving a code at simkl.com/pin (OAuth 2.0 device flow) under Encore's
/// own Simkl app id, so there's nothing to set up first.
@Observable
@MainActor
final class SimklSync {
    enum Status: Equatable { case off, signedOut, waitingForCode(String, URL), signedIn, failed(String) }

    private(set) var status: Status = .off
    private let settings: Settings
    private var token: String? { Keychain.get("simkl.token") }
    private var polling: Task<Void, Never>?

    init(settings: Settings) {
        self.settings = settings
        refreshStatus()
    }

    func refreshStatus() {
        guard settings.simklSync else { status = .off; return }
        status = token == nil ? .signedOut : .signedIn
    }

    /// Encore's own Simkl app (Simkl ▸ Settings ▸ Developer). A client id is public by
    /// design: it names the app, not the person, and the device sign-in needs no secret.
    static let encoreClientId = "2ed7591b53d479327ab3fbfaf59ddd2c1b64babdf28526d499d0110f4b8ba8c5"

    /// Encore's id unless an override is set (defaults write … simklClientId).
    private var clientId: String {
        let custom = settings.simklClientId.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? Self.encoreClientId : custom
    }

    // MARK: Signing in (PIN flow)

    func signIn() {
        polling?.cancel()
        polling = Task {
            // OAuth 2.0 device flow: show a code, the user approves it on simkl.com/pin.
            struct Device: Decodable {
                var device_code: String; var user_code: String
                var verification_uri: String; var verification_uri_complete: String?
                var expires_in: Int?; var interval: Int?
            }
            guard let device: Device = await postJSON("/oauth2/device", ["client_id": clientId]),
                  let verify = URL(string: device.verification_uri_complete ?? device.verification_uri) else {
                status = .failed("Simkl didn't accept that Client ID.")
                return
            }
            status = .waitingForCode(device.user_code, verify)
            NSWorkspace.shared.open(verify)
            struct Token: Decodable { var access_token: String?; var error: String? }
            let deadline = Date().addingTimeInterval(TimeInterval(device.expires_in ?? 900))
            var wait = max(device.interval ?? 5, 3)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(wait))
                guard let t: Token = await postJSON("/oauth2/token", [
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": device.device_code,
                    "client_id": clientId,
                ]) else { continue }
                if let token = t.access_token {
                    Keychain.set(token, for: "simkl.token")
                    status = .signedIn
                    return
                }
                switch t.error {
                case "authorization_pending", nil: continue
                case "slow_down": wait += 5
                case "access_denied": status = .failed("Sign-in was declined on Simkl."); return
                default: status = .failed("Simkl sign-in failed (\(t.error ?? "?"))."); return
                }
            }
            if !Task.isCancelled { status = .failed("The code expired; try again.") }
        }
    }

    private func postJSON<T: Decodable>(_ path: String, _ body: [String: String]) async -> T? {
        guard let url = URL(string: "https://api.simkl.com" + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func signOut() {
        polling?.cancel()
        Keychain.set(nil, for: "simkl.token")
        refreshStatus()
    }

    private var active: Bool { settings.simklSync && status == .signedIn && !clientId.isEmpty }

    // MARK: Requests

    private func post(_ path: String, _ body: [String: Any]) async {
        guard let token, let url = URL(string: "https://api.simkl.com" + path) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(clientId, forHTTPHeaderField: "simkl-api-key")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        if let (_, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 401 {
            Keychain.set(nil, for: "simkl.token")
            status = .failed("Simkl signed Encore out; sign in again.")
        }
    }

    /// `movie`/`show` + `episode` for a title, by IMDb id.
    private func subject(meta: Meta, video: Video?) -> [String: Any]? {
        guard let imdb = meta.imdbId ?? (meta.id.hasPrefix("tt") ? meta.id : nil) else { return nil }
        if let v = video, let s = v.season, let e = v.episode {
            return ["show": ["ids": ["imdb": imdb]], "episode": ["season": s, "number": e]]
        }
        return ["movie": ["ids": ["imdb": imdb]]]
    }

    // MARK: Pulling

    private func get(_ path: String) async -> Data? {
        guard let token, let url = URL(string: "https://api.simkl.com" + path) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(clientId, forHTTPHeaderField: "simkl-api-key")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        if (resp as? HTTPURLResponse)?.statusCode == 401 {
            Keychain.set(nil, for: "simkl.token")
            status = .failed("Simkl signed Encore out; sign in again.")
            return nil
        }
        return data
    }

    private struct Ids: Decodable { var imdb: String? }
    private struct Titled: Decodable { var title: String?; var ids: Ids? }
    private struct Playback: Decodable {
        struct Ep: Decodable { var season: Int?; var episode: Int?; var number: Int?; var title: String? }
        var progress: Double?
        var paused_at: String?
        var type: String?
        var movie: Titled?
        var show: Titled?
        var episode: Ep?
    }
    private struct AllItems: Decodable {
        struct Show: Decodable {
            struct Season: Decodable {
                struct Ep: Decodable { var number: Int?; var watched_at: String? }
                var number: Int?
                var episodes: [Ep]?
            }
            var show: Titled?
            var seasons: [Season]?
        }
        struct Movie: Decodable { var movie: Titled?; var last_watched_at: String?; var status: String? }
        var shows: [Show]?
        var anime: [Show]?
        var movies: [Movie]?
    }

    /// Simkl's resume points and what was watched since the last pull (the last 30 days the
    /// first time). Newer than what's here wins, like the AIOStreams sync.
    func pull(watch: WatchStore, metaFor: (String, String) async -> Meta?) async {
        guard active else { return }
        let iso = ISO8601DateFormatter()
        func date(_ s: String?) -> Date? {
            guard let s else { return nil }
            if let d = iso.date(from: s) { return d }
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s)
        }
        var metas: [String: Meta] = [:]
        func meta(_ type: String, _ imdb: String) async -> Meta? {
            if let m = metas[imdb] { return m }
            let m = await metaFor(type, imdb)
            metas[imdb] = m
            return m
        }

        // Resume points (a percentage; turned into seconds with the episode's length).
        if let data = await get("/sync/playback"), let items = try? JSONDecoder().decode([Playback].self, from: data) {
            for p in items {
                guard let pct = p.progress, pct > 1, pct < 95, let at = date(p.paused_at) else { continue }
                let isEpisode = p.type == "episode"
                guard let imdb = (isEpisode ? p.show : p.movie)?.ids?.imdb else { continue }
                if (watch.entry(for: imdb)?.updatedAt ?? .distantPast) >= at { continue }
                guard let m = await meta(isEpisode ? "series" : "movie", imdb) else { continue }
                let s = p.episode?.season, e = p.episode?.episode ?? p.episode?.number
                let videoId = isEpisode ? "\(imdb):\(s ?? 1):\(e ?? 1)" : imdb
                let video = m.videos.first { $0.id == videoId }
                let minutes = Double(m.runtime.flatMap { Int($0.filter(\.isNumber)) } ?? (isEpisode ? 24 : 110))
                watch.applyRemoteProgress(title: SavedTitle(m), videoId: videoId, season: s, episode: e,
                                          episodeTitle: video?.title ?? p.episode?.title, thumbnail: video?.thumbnail,
                                          position: pct / 100 * minutes * 60, duration: minutes * 60, at: at)
            }
        }

        // Watched since the last pull.
        let since = UserDefaults.standard.object(forKey: "simklLastPull") as? Date ?? Date().addingTimeInterval(-30 * 86400)
        let stamp = ISO8601DateFormatter().string(from: since)
        guard let data = await get("/sync/all-items/?episode_watched_at=yes&date_from=\(stamp)"),
              let all = try? JSONDecoder().decode(AllItems.self, from: data) else { return }
        for show in (all.shows ?? []) + (all.anime ?? []) {
            guard let imdb = show.show?.ids?.imdb else { continue }
            var watched: [(Int, Int, Date)] = []
            for season in show.seasons ?? [] {
                for ep in season.episodes ?? [] {
                    if let s = season.number, let n = ep.number, let at = date(ep.watched_at), at > since { watched.append((s, n, at)) }
                }
            }
            guard !watched.isEmpty, let m = await meta("series", imdb) else { continue }
            for (s, n, at) in watched.sorted(by: { $0.2 < $1.2 }) {
                let videoId = "\(imdb):\(s):\(n)"
                let video = m.videos.first { $0.id == videoId }
                watch.applyRemoteWatched(title: SavedTitle(m), videoId: videoId, season: s, episode: n,
                                         episodeTitle: video?.title, thumbnail: video?.thumbnail, at: at)
            }
        }
        for movie in all.movies ?? [] {
            guard movie.status == nil || movie.status == "completed",
                  let imdb = movie.movie?.ids?.imdb, let at = date(movie.last_watched_at), at > since,
                  let m = await meta("movie", imdb) else { continue }
            watch.applyRemoteWatched(title: SavedTitle(m), videoId: imdb, season: nil, episode: nil,
                                     episodeTitle: nil, thumbnail: nil, at: at)
        }
        UserDefaults.standard.set(Date(), forKey: "simklLastPull")
    }

    // MARK: Scrobbling

    func scrobble(_ action: String, meta: Meta, video: Video?, position: Double, duration: Double) {
        guard active, duration > 0, var body = subject(meta: meta, video: video) else { return }
        body["progress"] = min(100, max(0, position / duration * 100))
        Task { await post("/scrobble/\(action)", body) }
    }

    func setWatched(meta: Meta, videos: [Video], watched: Bool) {
        guard active, let imdb = meta.imdbId ?? (meta.id.hasPrefix("tt") ? meta.id : nil) else { return }
        let body: [String: Any]
        if videos.isEmpty || meta.type == "movie" {
            body = ["movies": [["ids": ["imdb": imdb]]]]
        } else {
            let bySeason = Dictionary(grouping: videos.filter { $0.season != nil && $0.episode != nil }, by: { $0.season! })
            body = ["shows": [["ids": ["imdb": imdb],
                               "seasons": bySeason.map { ["number": $0.key, "episodes": $0.value.map { ["number": $0.episode!] }] }]]]
        }
        Task { await post(watched ? "/sync/history" : "/sync/history/remove", body) }
    }
}
