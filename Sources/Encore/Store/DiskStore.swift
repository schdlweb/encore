import Foundation

/// One JSON file on disk: reads it without ever losing what's there, and writes
/// snapshots strictly in the order they were handed over.
///
/// Reading: a file that can't be decoded (or that had entries dropped while decoding) is
/// copied aside as `<name>.unreadable-<timestamp>.json` before the app carries on, so the
/// next save can't be the thing that destroys it.
///
/// Writing: every write goes through one serial queue. (Each save used to be its own
/// detached task; two close together could finish in reverse and leave the older
/// snapshot on disk.)
final class DiskStore: @unchecked Sendable {
    let file: URL
    private let queue: DispatchQueue

    init(file: URL) {
        self.file = file
        queue = DispatchQueue(label: "encore.disk." + file.lastPathComponent, qos: .utility)
    }

    /// nil when there's no file yet, or it couldn't be read at all.
    func load<T: Decodable>(_ type: T.Type) -> T? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let losses = DecodeLosses()
        let decoder = JSONDecoder()
        decoder.userInfo[.decodeLosses] = losses
        do {
            let value = try decoder.decode(T.self, from: try Data(contentsOf: file))
            if losses.count > 0 {
                NSLog("Encore: %d entries in %@ couldn't be read and were skipped", losses.count, file.lastPathComponent)
                setAside()
            }
            return value
        } catch {
            NSLog("Encore: couldn't read %@ (%@)", file.lastPathComponent, String(describing: error))
            setAside()
            return nil
        }
    }

    /// Keeps a copy of the file as it is now. At most five are kept per file.
    private func setAside() {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let base = file.deletingPathExtension().lastPathComponent
        let prefix = base + ".unreadable-"
        let dir = file.deletingLastPathComponent()
        try? fm.copyItem(at: file, to: dir.appendingPathComponent("\(prefix)\(stamp).json"))
        let old = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
        for name in old.dropLast(5) { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
    }

    /// Queues a snapshot to be written; returns at once.
    func write<T: Encodable & Sendable>(_ snapshot: T) {
        queue.async { self.store(snapshot) }
    }

    /// Writes a snapshot and waits for it (and everything queued before it) to be on disk.
    func writeNow<T: Encodable & Sendable>(_ snapshot: T) {
        queue.sync { store(snapshot) }
    }

    private func store<T: Encodable>(_ snapshot: T) {
        do {
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        } catch {
            NSLog("Encore: couldn't save %@ (%@)", file.lastPathComponent, String(describing: error))
        }
    }
}

/// Counts what `Lenient` had to skip during one decode.
final class DecodeLosses {
    var count = 0
}

extension CodingUserInfoKey {
    static let decodeLosses = CodingUserInfoKey(rawValue: "encore.decodeLosses")!
}

/// A value that decodes to nil instead of failing everything around it, so one damaged
/// entry costs that entry and not the whole file.
struct Lenient<T: Decodable>: Decodable {
    var value: T?

    init(from decoder: Decoder) throws {
        do {
            value = try T(from: decoder)
        } catch {
            value = nil
            (decoder.userInfo[.decodeLosses] as? DecodeLosses)?.count += 1
        }
    }
}

extension KeyedDecodingContainer {
    /// A dictionary, minus any values that don't decode; empty if the key is missing or
    /// isn't a dictionary at all.
    func lenientDictionary<V: Decodable>(_ key: Key, of: V.Type = V.self) -> [String: V] {
        guard contains(key) else { return [:] }
        guard let raw = try? decode([String: Lenient<V>].self, forKey: key) else {
            noteLoss()
            return [:]
        }
        return raw.compactMapValues(\.value)
    }

    /// An array, minus any elements that don't decode.
    func lenientArray<V: Decodable>(_ key: Key, of: V.Type = V.self) -> [V] {
        guard contains(key) else { return [] }
        guard let raw = try? decode([Lenient<V>].self, forKey: key) else {
            noteLoss()
            return []
        }
        return raw.compactMap(\.value)
    }

    /// A single value, or the default if it's missing or doesn't decode.
    func lenientValue<V: Decodable>(_ key: Key, default fallback: V) -> V {
        guard contains(key) else { return fallback }
        guard let v = try? decode(V.self, forKey: key) else {
            noteLoss()
            return fallback
        }
        return v
    }

    private func noteLoss() {
        guard let decoder = try? superDecoder() else { return }
        (decoder.userInfo[.decodeLosses] as? DecodeLosses)?.count += 1
    }
}
