import AppKit
import Foundation
import Observation

/// Downloads streams to ~/Downloads, with progress shown in the app.
///
/// The stream is checked first (same as before playing), so a debrid error clip isn't
/// saved in place of the file, and its resolved link is what gets downloaded.
@Observable
@MainActor
final class DownloadManager {
    struct Item: Identifiable {
        enum State: Equatable { case checking, downloading, finished(URL), failed(String), cancelled }
        let id = UUID()
        var name: String
        var state: State = .checking
        var received: Int64 = 0
        var total: Int64 = 0
        var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var tasks: [UUID: URLSessionDownloadTask] = [:]
    @ObservationIgnored private lazy var delegate = Delegate(owner: self)
    @ObservationIgnored private lazy var session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

    var active: [Item] { items.filter { $0.state == .checking || $0.state == .downloading } }

    func download(_ stream: StreamItem, title: String) {
        let name = Self.fileName(for: stream, title: title)
        var item = Item(name: name)
        let id = item.id
        items.insert(item, at: 0)
        Task {
            switch await StreamProbe.check(stream) {
            case .failed(let reason):
                update(id) { $0.state = .failed(reason) }
            case .playable(let url):
                guard self.items.contains(where: { $0.id == id && $0.state == .checking }) else { return }
                var req = URLRequest(url: url)
                for (k, v) in stream.requestHeaders { req.setValue(v, forHTTPHeaderField: k) }
                let task = session.downloadTask(with: req)
                task.taskDescription = id.uuidString
                tasks[id] = task
                item.state = .downloading
                update(id) { $0.state = .downloading }
                task.resume()
            }
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        update(id) { $0.state = .cancelled }
    }

    func dismiss(_ id: UUID) {
        if tasks[id] != nil { cancel(id) }
        items.removeAll { $0.id == id }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: Delegate callbacks (hopped to the main actor)

    fileprivate func progress(_ id: UUID, received: Int64, total: Int64) {
        update(id) { $0.received = received; $0.total = total }
    }

    fileprivate func finished(_ id: UUID, at file: URL) {
        tasks[id] = nil
        guard let name = items.first(where: { $0.id == id })?.name else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dest = downloads.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            dest = downloads.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: file, to: dest)
            update(id) { $0.state = .finished(dest) }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    fileprivate func failed(_ id: UUID, _ message: String) {
        tasks[id] = nil
        update(id) { if $0.state == .downloading { $0.state = .failed(message) } }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    /// The release's own file name when the addon gives one, else the title.
    private static func fileName(for s: StreamItem, title: String) -> String {
        let raw = s.filename ?? s.url.flatMap { URL(string: $0)?.lastPathComponent.removingPercentEncoding } ?? title
        var name = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
        if (name as NSString).pathExtension.isEmpty { name += ".mkv" }
        return name
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate {
        weak var owner: DownloadManager?
        private var lastReport: [UUID: Date] = [:]
        private let lock = NSLock()
        init(owner: DownloadManager) { self.owner = owner }

        private func id(_ task: URLSessionTask) -> UUID? { task.taskDescription.flatMap(UUID.init) }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard let id = id(downloadTask) else { return }
            // A few updates a second is plenty for a progress bar.
            lock.lock()
            let due = Date().timeIntervalSince(lastReport[id] ?? .distantPast) > 0.3
            if due { lastReport[id] = Date() }
            lock.unlock()
            guard due else { return }
            Task { @MainActor [weak owner] in owner?.progress(id, received: totalBytesWritten, total: totalBytesExpectedToWrite) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let id = id(downloadTask) else { return }
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Task { @MainActor [weak owner] in owner?.failed(id, "HTTP \(http.statusCode)") }
                return
            }
            // The temporary file is deleted when this returns; move it somewhere stable first.
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            guard (try? FileManager.default.moveItem(at: location, to: keep)) != nil else { return }
            Task { @MainActor [weak owner] in owner?.finished(id, at: keep) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error, let id = id(task), (error as? URLError)?.code != .cancelled else { return }
            Task { @MainActor [weak owner] in owner?.failed(id, error.localizedDescription) }
        }
    }
}
