import AppKit
import CryptoKit
import Foundation
import Observation

/// Updates from GitHub releases (github.com/schdlweb/encore): checks the latest release,
/// downloads its Encore.zip, swaps the app in place and relaunches. Downloads made by the
/// app itself aren't quarantined, so there's no Gatekeeper prompt after the first install.
///
/// Before anything is swapped the download has to match the SHA-256 GitHub recorded for
/// the release's zip when it was uploaded, and the app inside has to pass a signature
/// check (a damaged or cut-off download fails one or the other). If the new copy then
/// can't be opened, the old one is put back.
@Observable
@MainActor
final class Updater {
    static let repo = "schdlweb/encore"

    struct Release: Equatable {
        let version: String
        let notes: String
        let zip: URL
        /// Hex SHA-256 of the zip, as GitHub recorded it.
        let sha256: String?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)
    }

    var state: State = .idle
    /// The banner on the main window was dismissed for this version.
    var dismissedVersion: String?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var availableRelease: Release? {
        if case .available(let r) = state { return r }
        return nil
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable { var name: String; var browser_download_url: String; var digest: String? }
        var tag_name: String
        var body: String?
        var draft: Bool?
        var prerelease: Bool?
        var assets: [Asset]
    }

    func check(userInitiated: Bool = false) async {
        if case .downloading = state { return }
        if state == .installing { return }
        state = .checking
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Encore/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if (response as? HTTPURLResponse)?.statusCode == 404 { state = userInitiated ? .upToDate : .idle; return }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let version = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
                  let url = URL(string: asset.browser_download_url),
                  Self.isNewer(version, than: currentVersion) else {
                state = userInitiated ? .upToDate : .idle
                return
            }
            let sha = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst("sha256:".count)).lowercased() : nil }
            state = .available(Release(version: version, notes: release.body ?? "", zip: url, sha256: sha))
        } catch {
            state = userInitiated ? .failed("Couldn't reach GitHub: \(error.localizedDescription)") : .idle
        }
    }

    /// Downloads the release, replaces this app with it and relaunches.
    func install(_ release: Release) async {
        let target = Bundle.main.bundleURL
        let folder = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            state = .failed("Encore can't replace itself in \(folder.path). Move it to Applications and try again.")
            return
        }
        state = .downloading(0)
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("encore-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("Encore.zip")
            defer { if state != .installing { try? FileManager.default.removeItem(at: work) } }
            try await download(release.zip, to: zip)

            guard let expected = release.sha256 else {
                state = .failed("This release has no checksum to check the download against. Get it from github.com/\(Self.repo)/releases instead.")
                return
            }
            let actual = try await Task.detached { try Self.sha256(of: zip) }.value
            guard actual == expected else {
                state = .failed("The download doesn't match the release (it may be damaged or incomplete). Try again.")
                return
            }

            let unzipped = work.appendingPathComponent("unzipped")
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path])
            guard let newApp = try FileManager.default.contentsOfDirectory(at: unzipped, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }),
                  Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                state = .failed("The download didn't contain Encore.")
                return
            }
            do {
                try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
            } catch {
                state = .failed("The downloaded app is damaged (its signature doesn't check out). Try again.")
                return
            }
            state = .installing
            // Swap once this process has quit, then open the new copy. If the swap or the
            // launch fails, the old copy goes back and is opened instead. Paths are passed
            // as arguments ($1…$4), never pasted into the script.
            let script = """
            while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
            /bin/rm -rf "$2.old"
            if /bin/mv "$2" "$2.old"; then
              if /bin/mv "$3" "$2" && /usr/bin/open "$2"; then
                /bin/rm -rf "$2.old"
              else
                /bin/rm -rf "$2"
                /bin/mv "$2.old" "$2"
                /usr/bin/open "$2"
              fi
            else
              /usr/bin/open "$2"
            fi
            /bin/rm -rf "$4"
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script, "encore-update", String(ProcessInfo.processInfo.processIdentifier),
                           target.path, newApp.path, work.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("Update failed: \(error.localizedDescription)")
        }
    }

    /// Downloads in the background, reporting progress as it goes.
    func download(_ url: URL, to dest: URL) async throws {
        let progress = ProgressRelay { [weak self] f in Task { @MainActor in self?.state = .downloading(f) } }
        // A per-task delegate only reports progress; the file comes back from the call.
        let (tmp, response) = try await URLSession.shared.download(from: url, delegate: progress)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "Encore", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    /// Progress only: it must not implement the "finished downloading" callback, or the
    /// async download call never gets the file back.
    private final class ProgressRelay: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let report: @Sendable (Double) -> Void
        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
        private var observation: NSKeyValueObservation?
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.fractionCompleted) { [report] p, _ in report(p.fractionCompleted) }
        }
    }

    /// Hex SHA-256 of a file, read in pieces (the zip is tens of megabytes).
    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: "Encore", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(tool) failed"]) }
    }

    /// "1.10.0" > "1.9.2".
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
