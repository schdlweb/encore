import Foundation

/// The app used to be called Marquee (bundle id `local.marquee.player`). Bring its
/// settings, manifest and watch history over the first time Encore runs.
enum Migration {
    static func runOnce() { _ = done }

    private static let done: Void = {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromMarquee") else { return }
        if let old = UserDefaults(suiteName: "local.marquee.player")?.persistentDomain(forName: "local.marquee.player") {
            for (key, value) in old where d.object(forKey: key) == nil { d.set(value, forKey: key) }
        }
        let fm = FileManager.default
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let old = support.appendingPathComponent("Marquee"), new = support.appendingPathComponent("Encore")
            if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
                try? fm.copyItem(at: old, to: new)
            }
        }
        d.set(true, forKey: "migratedFromMarquee")
    }()
}
