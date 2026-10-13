import Foundation

/// Sign-in tokens (AIOStreams, Simkl), kept in a file only your Mac account can read:
/// ~/Library/Application Support/Encore/credentials.json (permissions 600).
///
/// Not the Keychain: Encore is signed ad hoc, so every new build (and every update) looks
/// like a different app to the Keychain, which then asks for permission again each time.
/// The tokens only allow syncing watch progress, and signing out revokes them.
enum Keychain {
    private static let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Encore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("credentials.json")
    }()
    private static let lock = NSLock()

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    static func set(_ value: String?, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        var dict = load()
        dict[key] = value
        guard let data = try? JSONEncoder().encode(dict) else { return }
        // Created owner-only before anything is written to it.
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: file) // in place, so the file keeps its owner-only permissions
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return load()[key]
    }
}
