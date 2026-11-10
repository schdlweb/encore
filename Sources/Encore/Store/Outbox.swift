import Foundation

/// Sync reports on their way out (AIOStreams, Simkl). They're sent in the background,
/// and tracked here so quitting can give the last ones (a "stopped at 31:20") a moment
/// to arrive instead of dropping them.
@MainActor
final class Outbox {
    static let shared = Outbox()

    private var tasks: [UUID: Task<Void, Never>] = [:]

    var isEmpty: Bool { tasks.isEmpty }

    func send(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        tasks[id] = Task { [weak self] in
            await work()
            self?.tasks[id] = nil
        }
    }

    /// Waits for what's in flight, up to `timeout` seconds.
    func drain(timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !tasks.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
