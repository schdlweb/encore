import AppKit
import Foundation
import Observation

/// Optional Simkl tracking: scrobbles what Encore plays (start, pause, stop; Simkl counts
/// it watched past 80%) and sends Mark as Watched / Unwatched to your Simkl history.
///
/// Simkl needs an app "Client ID" on every request. Create one free at
/// simkl.com/settings/developer (redirect URI `urn:ietf:wg:oauth:2.0:oob`) and paste it in
/// Settings; signing in is then approving a code at simkl.com/pin (OAuth 2.0 device flow).
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

    private var clientId: String { settings.simklClientId.trimmingCharacters(in: .whitespaces) }

    // MARK: Signing in (PIN flow)

    func signIn() {
        guard !clientId.isEmpty else { status = .failed("Paste your Simkl Client ID first."); return }
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
