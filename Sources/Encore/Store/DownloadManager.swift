import AppKit
import Foundation
import Observation

/// Downloads streams to ~/Downloads, with progress and speed shown in the app.
///
/// The stream is checked first (same as before playing), so a debrid error clip isn't
/// saved in place of the file, and its resolved link is what gets downloaded. If the
/// connection drops, the download picks up where it stopped when the server allows it,
/// and otherwise starts over from a fresh link.
@Observable
@MainActor
final class DownloadManager {
    struct Item: Identifiable {
        enum State: Equatable { case checking, downloading, reconnecting, finished(URL), failed(String), cancelled }
        let id = UUID()
        var name: String
        var state: State = .checking
        var received: Int64 = 0
        var total: Int64 = 0
        /// Bytes per second, smoothed; 0 when nothing is arriving.
        var speed: Double = 0
        var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
        var secondsLeft: Double? { total > received && speed > 0 ? Double(total - received) / speed : nil }
        var isActive: Bool { state == .checking || state == .downloading || state == .reconnecting }
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var tasks: [UUID: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var streams: [UUID: StreamItem] = [:]
    @ObservationIgnored private var resumeData: [UUID: Data] = [:]
    @ObservationIgnored private var retries: [UUID: Int] = [:]
    @ObservationIgnored private var samples: [UUID: (received: Int64, at: Date)] = [:]
    @ObservationIgnored private var speedWatch: Task<Void, Never>?
    @ObservationIgnored private lazy var delegate = Delegate(owner: self)
    @ObservationIgnored private lazy var session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

    /// Waits before each automatic retry. Any progress in between starts the count over.
    private static let retryDelays: [Double] = [3, 10, 30, 60, 120]

    var active: [Item] { items.filter(\.isActive) }

    func download(_ stream: StreamItem, title: String) {
        let item = Item(name: Self.fileName(for: stream, title: title))
        items.insert(item, at: 0)
        streams[item.id] = stream
        start(item.id)
    }

    /// Checks the stream for a fresh link and downloads from the beginning.
    private func start(_ id: UUID) {
        guard let stream = streams[id] else { return }
        update(id) { $0.state = .checking; $0.speed = 0; $0.received = 0 }
        Task {
            switch await StreamProbe.check(stream) {
            case .failed(let reason):
                update(id) { $0.state = .failed(reason) }
            case .unreachable(let reason):
                retryLater(id, reason: reason)
            case .playable(let url):
                guard self.items.contains(where: { $0.id == id && $0.state == .checking }) else { return }
                var req = URLRequest(url: url)
                for (k, v) in stream.requestHeaders { req.setValue(v, forHTTPHeaderField: k) }
                begin(session.downloadTask(with: req), id: id)
            }
        }
    }

    private func begin(_ task: URLSessionDownloadTask, id: UUID) {
        task.taskDescription = id.uuidString
        tasks[id] = task
        samples[id] = nil
        update(id) { $0.state = .downloading; $0.speed = 0 }
        task.resume()
        watchSpeeds()
    }

    private func resumeOrRestart(_ id: UUID) {
        if let data = resumeData.removeValue(forKey: id) {
            begin(session.downloadTask(withResumeData: data), id: id)
        } else {
            start(id)
        }
    }

    private func retryLater(_ id: UUID, reason: String) {
        let attempt = retries[id] ?? 0
        guard attempt < Self.retryDelays.count else {
            update(id) { $0.state = .failed(reason) }
            return
        }
        retries[id] = attempt + 1
        update(id) { $0.state = .reconnecting; $0.speed = 0 }
        Task {
            try? await Task.sleep(for: .seconds(Self.retryDelays[attempt]))
            guard self.items.contains(where: { $0.id == id && $0.state == .reconnecting }) else { return }
            resumeOrRestart(id)
        }
    }

    /// The Retry button on a download that gave up.
    func retry(_ id: UUID) {
        retries[id] = 0
        resumeOrRestart(id)
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        forget(id)
        update(id) { $0.state = .cancelled; $0.speed = 0 }
    }

    func dismiss(_ id: UUID) {
        if tasks[id] != nil { cancel(id) }
        forget(id)
        items.removeAll { $0.id == id }
    }

    private func forget(_ id: UUID) {
        tasks[id] = nil
        resumeData[id] = nil
        retries[id] = nil
        samples[id] = nil
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// Progress only arrives while bytes do, so a stalled download needs telling apart.
    private func watchSpeeds() {
        guard speedWatch == nil else { return }
        speedWatch = Task {
            while !active.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                let now = Date()
                for item in items where item.state == .downloading && item.speed > 0 {
                    if let s = samples[item.id], now.timeIntervalSince(s.at) > 2 { update(item.id) { $0.speed = 0 } }
                }
            }
            speedWatch = nil
        }
    }

    // MARK: Delegate callbacks (hopped to the main actor)

    fileprivate func progress(_ id: UUID, received: Int64, total: Int64) {
        let now = Date()
        let last = samples[id]
        if let last, received > last.received { retries[id] = 0 }
        update(id) { item in
            if let last, received >= last.received, now > last.at {
                let rate = Double(received - last.received) / now.timeIntervalSince(last.at)
                item.speed = item.speed == 0 ? rate : item.speed * 0.7 + rate * 0.3
            }
            item.received = received
            item.total = total
        }
        samples[id] = (received, now)
    }

    fileprivate func finished(_ id: UUID, at file: URL) {
        tasks[id] = nil
        samples[id] = nil
        // Dismissed while it was finishing: nothing to keep.
        guard let name = items.first(where: { $0.id == id })?.name else {
            try? FileManager.default.removeItem(at: file)
            return
        }
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
            update(id) { $0.state = .finished(dest); $0.speed = 0 }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription); $0.speed = 0 }
        }
    }

    fileprivate func failed(_ id: UUID, _ message: String, resumeData data: Data? = nil, connectionProblem: Bool = false) {
        tasks[id] = nil
        guard items.contains(where: { $0.id == id && $0.state == .downloading }) else { return }
        if let data { resumeData[id] = data }
        if connectionProblem {
            retryLater(id, reason: message)
        } else {
            update(id) { $0.state = .failed(message); $0.speed = 0 }
        }
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

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        /// Only touched on the main actor.
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
            guard (try? FileManager.default.moveItem(at: location, to: keep)) != nil else {
                Task { @MainActor [weak owner] in owner?.failed(id, "Couldn't save the file") }
                return
            }
            Task { @MainActor [weak owner] in owner?.finished(id, at: keep) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error, let id = id(task), (error as? URLError)?.code != .cancelled else { return }
            let info = (error as NSError)
            let data = info.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            let connectionProblem = info.domain == NSURLErrorDomain
            let message = error.localizedDescription
            Task { @MainActor [weak owner] in owner?.failed(id, message, resumeData: data, connectionProblem: connectionProblem) }
        }
    }
}

func formatSpeed(_ bytesPerSecond: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
}

func formatTimeLeft(_ seconds: Double) -> String {
    seconds < 60 ? "under a minute left" : formatRemaining(seconds) + " left"
}
