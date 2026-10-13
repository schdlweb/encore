import Foundation

/// Checks that a stream actually leads to a video before the player opens it.
///
/// Debrid links from AIOStreams (`/api/v1/debrid/playback/…`) and Torrentio
/// (`/resolve/…`) resolve on request and redirect to the file. When resolving
/// fails they redirect to a short explainer video instead (AIOStreams:
/// `/static/download_failed.mp4` and friends; Torrentio: `/videos/*.mp4`), which a
/// player would happily play. Following the redirect and reading only the response
/// headers tells the two apart, and the final URL is handed to mpv so the link
/// isn't resolved twice.
enum StreamProbe {
    enum Result {
        case playable(URL)
        case failed(String)
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 45
        return URLSession(configuration: cfg)
    }()

    /// AIOStreams' StaticFiles and Torrentio's status videos, by file name.
    private static let errorVideos: [(match: String, reason: String)] = [
        ("download_failed", "Debrid download failed"),
        ("failed_download", "Debrid download failed"),
        ("downloading", "Not cached yet (debrid is still downloading it)"),
        ("no_matching_file", "No matching file in that release"),
        ("store_limit_exceeded", "Debrid storage limit reached"),
        ("limits_exceeded", "Debrid limits reached"),
        ("content_proxy_limit_reached", "Too many proxy connections"),
        ("unavailable_for_legal_reasons", "Blocked by the debrid service"),
        ("failed_infringement", "Blocked by the debrid service"),
        ("payment_required", "Debrid subscription required"),
        ("failed_access", "Debrid account problem"),
        ("failed_rar", "Release is a RAR archive"),
        ("failed_opening", "Debrid couldn't open the file"),
        ("429", "Rate limited by the debrid service"),
        ("403", "Debrid service refused access"),
        ("401", "Debrid login failed"),
        ("500", "AIOStreams error"),
    ]

    static func check(_ stream: StreamItem) async -> Result {
        guard let raw = stream.url, let url = URL(string: raw) else { return .failed("No direct link") }
        var req = URLRequest(url: url)
        req.setValue("bytes=0-", forHTTPHeaderField: "Range")
        req.setValue("Encore/1.0", forHTTPHeaderField: "User-Agent")
        for (k, v) in stream.requestHeaders { req.setValue(v, forHTTPHeaderField: k) }

        do {
            // bytes(for:) returns once headers arrive; cancelling skips the body.
            let (bytes, response) = try await session.bytes(for: req)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse, let final = http.url else {
                return .failed("No response")
            }
            if let reason = errorVideoReason(final) { return .failed(reason) }
            guard (200..<300).contains(http.statusCode) else {
                return .failed("HTTP \(http.statusCode)")
            }
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if type.contains("text/html") || type.contains("json") || type.hasPrefix("text/plain") {
                return .failed("Got a web page instead of a video")
            }
            // A tiny file standing in for a big release is an error clip we don't know by name.
            let size = totalSize(http)
            if let size, size < 3_000_000, (stream.videoSize ?? Int64.max) > 50_000_000 {
                return .failed("Got a \(size / 1000) KB file instead of the video")
            }
            return .playable(final)
        } catch let e as URLError where e.code == .timedOut {
            return .failed("Timed out waiting for the debrid service")
        } catch is CancellationError {
            return .failed("Cancelled")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func errorVideoReason(_ url: URL) -> String? {
        let parts = url.pathComponents
        guard parts.count >= 2, url.pathExtension.lowercased() == "mp4" else { return nil }
        let dir = parts[parts.count - 2]
        guard dir == "static" || dir == "videos" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        if name == "200" { return nil }
        return errorVideos.first { name.contains($0.match) }?.reason ?? "The addon returned an error video (\(name))"
    }

    private static func totalSize(_ http: HTTPURLResponse) -> Int64? {
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last, let n = Int64(total) {
            return n
        }
        return http.expectedContentLength > 0 ? http.expectedContentLength : nil
    }
}
