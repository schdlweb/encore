import Foundation
import Observation

enum AudioChannels: String, CaseIterable, Identifiable {
    case autoSafe = "auto-safe"
    case auto = "auto"
    case stereo = "stereo"
    case surround51 = "5.1"
    case surround71 = "7.1"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .autoSafe: "Automatic (match device)"
        case .auto: "Automatic (all channels the device reports)"
        case .stereo: "Stereo"
        case .surround51: "5.1 Surround"
        case .surround71: "7.1 Surround"
        }
    }
}

/// Where mpv keeps the part of the stream it has downloaded ahead.
enum StreamBuffer: Int, CaseIterable, Identifiable {
    case memory = 0, disk2 = 2, disk4 = 4, disk8 = 8, disk16 = 16

    var id: Int { rawValue }
    var label: String { self == .memory ? "Memory (256 MB, default)" : "Disk, up to \(rawValue) GB" }
}

enum SubtitleSize: Double, CaseIterable, Identifiable {
    case small = 0.8, medium = 1.0, large = 1.25, huge = 1.5
    var id: Double { rawValue }
    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .huge: "Extra Large"
        }
    }
}

/// User preferences, persisted to UserDefaults on every change.
@Observable
@MainActor
final class Settings {
    private let d = UserDefaults.standard

    var manifestURL: String { didSet { d.set(manifestURL, forKey: "manifestURL") } }

    // Playback
    var hardwareDecoding: Bool { didSet { d.set(hardwareDecoding, forKey: "hwdec") } }
    var audioChannels: AudioChannels { didSet { d.set(audioChannels.rawValue, forKey: "audioChannels") } }
    var passthrough: Bool { didSet { d.set(passthrough, forKey: "passthrough") } }
    var exclusiveAudio: Bool { didSet { d.set(exclusiveAudio, forKey: "exclusiveAudio") } }
    var normalizeDownmix: Bool { didSet { d.set(normalizeDownmix, forKey: "normalizeDownmix") } }
    var hdrOutput: Bool { didSet { d.set(hdrOutput, forKey: "hdrOutput") } }
    var deband: Bool { didSet { d.set(deband, forKey: "deband") } }
    var preferredAudioLanguages: String { didSet { d.set(preferredAudioLanguages, forKey: "alang") } }
    /// Pick the audio track in the title's original language (Japanese for anime, Korean for K-dramas…).
    var preferOriginalAudio: Bool { didSet { d.set(preferOriginalAudio, forKey: "originalAudio") } }
    var preferredSubtitleLanguages: String { didSet { d.set(preferredSubtitleLanguages, forKey: "slang") } }
    var subtitlesOnByDefault: Bool { didSet { d.set(subtitlesOnByDefault, forKey: "subsOn") } }
    var subtitleSize: SubtitleSize { didSet { d.set(subtitleSize.rawValue, forKey: "subSize") } }
    /// How many of the addon's subtitles to add per video: 0 = none, `Int.max` = all.
    var addonSubtitleLimit: Int { didSet { d.set(addonSubtitleLimit, forKey: "addonSubLimit") } }
    var autoplayNext: Bool { didSet { d.set(autoplayNext, forKey: "autoplayNext") } }
    var streamBuffer: StreamBuffer { didSet { d.set(streamBuffer.rawValue, forKey: "streamBuffer") } }
    var skipInterval: Int { didSet { d.set(skipInterval, forKey: "skipInterval") } }
    var autoSkipIntros: Bool { didSet { d.set(autoSkipIntros, forKey: "autoSkipIntros") } }
    var scrubPreviews: Bool { didSet { d.set(scrubPreviews, forKey: "scrubPreviews") } }
    /// Play in a separate, resizable window (Infuse-style) instead of over the whole app.
    var jellyfinSync: Bool { didSet { d.set(jellyfinSync, forKey: "jellyfinSync") } }
    var jellyfinProfile: String { didSet { d.set(jellyfinProfile, forKey: "jellyfinProfile") } }
    var simklSync: Bool { didSet { d.set(simklSync, forKey: "simklSync") } }
    var simklClientId: String { didSet { d.set(simklClientId, forKey: "simklClientId") } }
    var autoUpdateCheck: Bool { didSet { d.set(autoUpdateCheck, forKey: "autoUpdateCheck") } }
    var showRecommendations: Bool { didSet { d.set(showRecommendations, forKey: "showRecommendations") } }
    var playerInWindow: Bool { didSet { d.set(playerInWindow, forKey: "playerInWindow") } }

    // Home layout: catalog keys in the user's order, and the ones hidden from Home.
    var catalogOrder: [String] { didSet { d.set(catalogOrder, forKey: "catalogOrder") } }
    var hiddenCatalogs: Set<String> { didSet { d.set(Array(hiddenCatalogs), forKey: "hiddenCatalogs") } }

    init() {
        Migration.runOnce()
        manifestURL = d.string(forKey: "manifestURL") ?? ""
        hardwareDecoding = d.object(forKey: "hwdec") as? Bool ?? true
        audioChannels = AudioChannels(rawValue: d.string(forKey: "audioChannels") ?? "") ?? .autoSafe
        passthrough = d.bool(forKey: "passthrough")
        exclusiveAudio = d.bool(forKey: "exclusiveAudio")
        normalizeDownmix = d.object(forKey: "normalizeDownmix") as? Bool ?? true
        deband = d.bool(forKey: "deband")
        hdrOutput = d.object(forKey: "hdrOutput") as? Bool ?? true
        preferredAudioLanguages = d.string(forKey: "alang") ?? ""
        preferOriginalAudio = d.object(forKey: "originalAudio") as? Bool ?? true
        preferredSubtitleLanguages = d.string(forKey: "slang") ?? "en,eng"
        subtitlesOnByDefault = d.object(forKey: "subsOn") as? Bool ?? true
        subtitleSize = SubtitleSize(rawValue: d.double(forKey: "subSize")) ?? .medium
        addonSubtitleLimit = d.object(forKey: "addonSubLimit") as? Int ?? 8
        autoplayNext = d.object(forKey: "autoplayNext") as? Bool ?? true
        skipInterval = d.object(forKey: "skipInterval") as? Int ?? 10
        streamBuffer = StreamBuffer(rawValue: d.integer(forKey: "streamBuffer")) ?? .memory
        autoSkipIntros = d.bool(forKey: "autoSkipIntros")
        scrubPreviews = d.object(forKey: "scrubPreviews") as? Bool ?? true
        playerInWindow = d.object(forKey: "playerInWindow") as? Bool ?? true
        showRecommendations = d.object(forKey: "showRecommendations") as? Bool ?? true
        autoUpdateCheck = d.object(forKey: "autoUpdateCheck") as? Bool ?? true
        jellyfinSync = d.bool(forKey: "jellyfinSync")
        jellyfinProfile = d.string(forKey: "jellyfinProfile") ?? ""
        simklSync = d.bool(forKey: "simklSync")
        simklClientId = d.string(forKey: "simklClientId") ?? ""
        catalogOrder = d.stringArray(forKey: "catalogOrder") ?? []
        hiddenCatalogs = Set(d.stringArray(forKey: "hiddenCatalogs") ?? [])
    }
}
