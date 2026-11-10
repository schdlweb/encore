import Foundation

/// The result of `work`, or `fallback` if it isn't ready in time. The work isn't cancelled:
/// it carries on and whatever it caches is there for next time. For extras (a language
/// lookup, franchise names) that shouldn't hold up something already ready to go.
func withinTime<T: Sendable>(_ seconds: Double, fallback: T, _ work: @escaping @Sendable () async -> T) async -> T {
    await withCheckedContinuation { continuation in
        let once = ResumeOnce(continuation)
        Task { once.resume(await work()) }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            once.resume(fallback)
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}
