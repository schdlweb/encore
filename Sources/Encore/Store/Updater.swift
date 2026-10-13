import AppKit
import Foundation
import Observation

/// Updates from GitHub releases (github.com/schdlweb/encore): checks the latest release,
/// downloads its Encore.zip, swaps the app in place and relaunches. Downloads made by the
/// app itself aren't quarantined, so there's no Gatekeeper prompt after the first install.
@Observable
@MainActor
final class Updater {
    static let repo = "schdlweb/encore"

    struct Release: Equatable {
        let version: String
        let notes: String
        let zip: URL
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
        struct Asset: Decodable { var name: String; var browser_download_url: String }
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
            state = .available(Release(version: version, notes: release.body ?? "", zip: url))
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
            try await download(release.zip, to: zip)

            state = .installing
            let unzipped = work.appendingPathComponent("unzipped")
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path])
            guard let newApp = try FileManager.default.contentsOfDirectory(at: unzipped, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }),
                  Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                state = .failed("The download didn't contain Encore.")
                return
            }
            // Swap once this process has quit, then open the new copy.
            let script = """
            while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
            /bin/rm -rf "\(target.path).old"
            /bin/mv "\(target.path)" "\(target.path).old" && /bin/mv "\(newApp.path)" "\(target.path)" && /bin/rm -rf "\(target.path).old"
            /usr/bin/open "\(target.path)"
            /bin/rm -rf "\(work.path)"
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
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

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: "Encore", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(tool) failed"]) }
    }

    /// "1.10.0" > "1.9.2".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
