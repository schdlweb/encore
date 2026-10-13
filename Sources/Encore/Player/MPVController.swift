import AppKit
import CMpv
import Observation
import OpenGL.GL3

struct MediaTrack: Identifiable, Hashable {
    var id: Int
    var type: String
    var title: String?
    var lang: String?
    var codec: String?
    var profile: String?
    var channels: Int?
    var isExternal: Bool
    var isDefault: Bool
    var isForced: Bool

    var languageName: String? {
        guard let lang, lang != "und" else { return nil }
        return Locale.current.localizedString(forLanguageCode: lang) ?? lang.uppercased()
    }

    var codecName: String? {
        guard let codec else { return nil }
        switch codec {
        case "truehd": return "Dolby TrueHD"
        case "eac3": return "Dolby Digital Plus"
        case "ac3": return "Dolby Digital"
        case "dts":
            if let p = profile, p.contains("MA") { return "DTS-HD MA" }
            if let p = profile, p.contains("HRA") || p.contains("HR") { return "DTS-HD HRA" }
            if let p = profile, p.contains("X") { return "DTS:X" }
            return "DTS"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "mp3": return "MP3"
        case "subrip": return "SRT"
        case "ass", "ssa": return "ASS"
        case "hdmv_pgs_subtitle": return "PGS"
        case "webvtt": return "WebVTT"
        case "dvd_subtitle": return "VobSub"
        default: return codec.uppercased()
        }
    }

    var channelLayout: String? {
        switch channels {
        case nil: nil
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        case let n?: "\(n) ch"
        }
    }

    var label: String {
        var head = languageName ?? title ?? "Track \(id)"
        if let t = title, languageName != nil, t.lowercased() != languageName?.lowercased() { head += " – \(t)" }
        return head
    }

    var detail: String {
        var parts = [codecName, channelLayout].compactMap { $0 }
        if isForced { parts.append("Forced") }
        if isExternal { parts.append("Addon") }
        return parts.joined(separator: " · ")
    }
}

/// Owns one libmpv instance: options, the event loop, and the OpenGL render context.
/// Observable state is only touched on the main thread; libmpv calls come from its
/// own event queue and from Core Animation's render callback.
@Observable
@MainActor
final class MPVController {
    var position: Double = 0
    var duration: Double = 0
    var paused = false
    var buffering = true
    var seeking = false
    var cacheSeconds: Double = 0
    var volume: Double = 100
    var muted = false
    var speed: Double = 1
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var selectedAudio: Int?
    var selectedSubtitle: Int?
    var fileLoaded = false
    var endedNaturally = false
    var errorMessage: String?

    @ObservationIgnored nonisolated(unsafe) private var mpv: OpaquePointer?
    @ObservationIgnored nonisolated(unsafe) private var renderContext: OpaquePointer?
    @ObservationIgnored nonisolated private let renderLock = NSLock()
    @ObservationIgnored nonisolated private let eventQueue = DispatchQueue(label: "encore.mpv.events")
    /// Changes waiting for the main thread. mpv reports the position every frame; queueing
    /// each one separately let the main queue fall seconds behind (pause took ~10 s to
    /// show), so changes collect here and the main thread takes them all in one go.
    @ObservationIgnored nonisolated(unsafe) private var pending: [Change] = []
    @ObservationIgnored nonisolated(unsafe) private var flushScheduled = false
    @ObservationIgnored nonisolated private let pendingLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) weak var layer: MPVGLLayer?
    @ObservationIgnored nonisolated(unsafe) private var lastError: String?
    /// vo=libmpv drops the video track if a file starts before the render context
    /// exists, so loads wait for the layer to create it.
    @ObservationIgnored private var renderReady = false
    @ObservationIgnored private var pendingLoad: (() -> Void)?

    /// The live player, for the test hooks.
    @ObservationIgnored static weak var current: MPVController?

    init(settings: Settings) {
        defer { Self.current = self }
        guard let handle = mpv_create() else {
            errorMessage = "Could not start the mpv engine."
            return
        }
        mpv = handle

        func opt(_ name: String, _ value: String) { mpv_set_option_string(handle, name, value) }
        opt("vo", "libmpv")
        opt("hwdec", settings.hardwareDecoding ? "auto-safe" : "no")
        opt("keep-open", "yes")
        opt("idle", "yes")
        opt("terminal", "no")
        opt("input-default-bindings", "no")
        opt("input-vo-keyboard", "no")
        opt("ytdl", "no")
        opt("user-agent", "Encore/1.0")
        opt("network-timeout", "30")
        opt("cache", "yes")
        if settings.streamBuffer == .memory {
            opt("demuxer-max-bytes", "256MiB")
            opt("demuxer-max-back-bytes", "64MiB")
        } else {
            // Downloads ahead as fast as the connection allows, into a temporary file that
            // mpv deletes when playback stops; a quarter is kept behind for instant rewinds.
            let gb = settings.streamBuffer.rawValue
            opt("cache-on-disk", "yes")
            opt("demuxer-cache-dir", Self.diskCacheDir.path)
            opt("demuxer-max-bytes", "\(gb * 1024 * 3 / 4)MiB")
            opt("demuxer-max-back-bytes", "\(gb * 1024 / 4)MiB")
            opt("cache-secs", "86400")
            opt("demuxer-readahead-secs", "86400")
        }
        // mpv's built-in Lua scripts (on-screen controller, stats, console…) aren't used here;
        // each one is a thread doing work for nothing.
        opt("load-scripts", "no")
        opt("osc", "no")
        for script in ["load-stats-overlay", "load-console", "load-select", "load-positioning",
                       "load-commands", "load-context-menu", "load-auto-profiles", "load-osd-console"] {
            opt(script, "no")
        }
        opt("cache-pause-wait", "2")
        // Audio: the device decides the channel layout unless the user forces one.
        opt("audio-channels", settings.audioChannels.rawValue)
        opt("audio-spdif", settings.passthrough ? "ac3,eac3,dts,dts-hd,truehd" : "")
        opt("audio-exclusive", settings.exclusiveAudio ? "yes" : "no")
        opt("audio-normalize-downmix", settings.normalizeDownmix ? "yes" : "no")
        // Video
        opt("deband", settings.deband ? "yes" : "no")
        opt("interpolation", "no")
        // Tracks and subtitles
        if !settings.preferredAudioLanguages.isEmpty { opt("alang", settings.preferredAudioLanguages) }
        opt("slang", settings.preferredSubtitleLanguages)
        if !settings.subtitlesOnByDefault { opt("sid", "no") }
        // English subtitles even when the audio is English too.
        opt("subs-with-matching-audio", "yes")
        opt("subs-fallback", "default")
        opt("sub-scale", String(settings.subtitleSize.rawValue))
        opt("sub-font", "SF Pro Display")
        opt("sub-border-size", "2.5")
        opt("sub-shadow-offset", "1")
        opt("sub-ass-override", "scale")

        mpv_request_log_messages(handle, "error")
        guard mpv_initialize(handle) >= 0 else {
            errorMessage = "Could not initialize the mpv engine."
            return
        }

        let observed: [(String, mpv_format)] = [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG), ("paused-for-cache", MPV_FORMAT_FLAG),
            ("seeking", MPV_FORMAT_FLAG), ("demuxer-cache-duration", MPV_FORMAT_DOUBLE),
            ("volume", MPV_FORMAT_DOUBLE), ("mute", MPV_FORMAT_FLAG), ("speed", MPV_FORMAT_DOUBLE),
            ("eof-reached", MPV_FORMAT_FLAG), ("track-list", MPV_FORMAT_NONE),
            ("aid", MPV_FORMAT_NONE), ("sid", MPV_FORMAT_NONE),
        ]
        for (name, format) in observed { mpv_observe_property(handle, 0, name, format) }

        let me = Unmanaged.passUnretained(self).toOpaque()
        mpv_set_wakeup_callback(handle, { ctx in
            let c = Unmanaged<MPVController>.fromOpaque(ctx!).takeUnretainedValue()
            c.eventQueue.async { c.drainEvents() }
        }, me)
    }

    /// ~/Library/Caches/Encore/Stream: where the disk buffer lives (emptied when playback stops).
    static let diskCacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Encore/Stream", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: Commands

    func load(url: String, headers: [String: String], startAt: Double?, audioLanguages: String? = nil) {
        guard mpv != nil else { return }
        guard renderReady else {
            pendingLoad = { [weak self] in self?.load(url: url, headers: headers, startAt: startAt, audioLanguages: audioLanguages) }
            return
        }
        if let audioLanguages { set("alang", audioLanguages) }
        fileLoaded = false
        endedNaturally = false
        errorMessage = nil
        buffering = true
        set("start", startAt.map { String(Int($0)) } ?? "none")
        set("http-header-fields", headers.map { "\($0.key): \($0.value)" }.joined(separator: ","))
        command(["loadfile", url, "replace"])
    }

    func addSubtitle(url: String, title: String, lang: String) {
        commandAsync(["sub-add", url, "auto", title, lang])
    }

    func togglePause() { setPaused(!paused) }
    /// Updates the button at once and lets mpv catch up in the background; mpv's own
    /// report follows and confirms it.
    func setPaused(_ value: Bool) {
        paused = value
        setAsync("pause", value ? "yes" : "no")
    }
    func seek(to seconds: Double) { command(["seek", String(seconds), "absolute+keyframes"]) }
    /// To this exact time (used for a scrub preview's own frame time, which is a keyframe,
    /// so it's as quick as a keyframe seek).
    func seekExact(to seconds: Double) { command(["seek", String(seconds), "absolute+exact"]) }
    func seek(by seconds: Double) { command(["seek", String(seconds), "relative"]) }
    func setVolume(_ v: Double) { set("volume", String(Int(min(max(v, 0), 150)))) }
    func toggleMute() { set("mute", muted ? "no" : "yes") }
    func setSpeed(_ s: Double) { set("speed", String(s)) }
    func selectAudio(_ id: Int) { set("aid", String(id)) }
    func selectSubtitle(_ id: Int?) { set("sid", id.map(String.init) ?? "no") }
    func setSubtitleDelay(_ seconds: Double) { set("sub-delay", String(seconds)) }
    func setAudioDelay(_ seconds: Double) { set("audio-delay", String(seconds)) }

    /// A readable snapshot of what is actually playing, for the info panel.
    func mediaInfo() -> [(String, String)] {
        var rows: [(String, String)] = []
        func add(_ label: String, _ value: String?) { if let v = value, !v.isEmpty { rows.append((label, v)) } }

        let w = getString("video-params/w"), h = getString("video-params/h")
        add("Resolution", w.flatMap { w in h.map { "\(w) × \($0)" } })
        add("Video", getString("video-format").map { $0.uppercased() } ?? getString("video-codec"))
        switch getString("video-params/gamma") {
        case "pq": add("Dynamic range", "HDR10 (PQ)")
        case "hlg": add("Dynamic range", "HLG")
        case .some: add("Dynamic range", "SDR")
        case nil: break
        }
        add("Frame rate", getDouble("container-fps").map { String(format: "%.3f fps", $0) })
        add("Decoder", getString("hwdec-current").map { $0 == "no" ? "Software" : "Hardware (\($0))" })
        add("Video bitrate", getDouble("video-bitrate").map { String(format: "%.1f Mbps", $0 / 1_000_000) })
        if let a = audioTracks.first(where: { $0.id == selectedAudio }) {
            add("Audio track", [a.codecName, a.channelLayout].compactMap { $0 }.joined(separator: " "))
        }
        add("Decoded audio", getString("audio-params/hr-channels").map { layout in
            let rate = getDouble("audio-params/samplerate").map { String(format: " · %.1f kHz", $0 / 1000) } ?? ""
            return layout + rate
        })
        let outFormat = getString("audio-out-params/format") ?? ""
        add("Output", outFormat.hasPrefix("spdif")
            ? "Passthrough (\(outFormat.replacingOccurrences(of: "spdif-", with: "").uppercased()))"
            : getString("audio-out-params/hr-channels").map { "PCM \($0)" })
        add("Audio device", getString("audio-device"))
        add("Container", getString("file-format"))
        add("Buffered", getDouble("demuxer-cache-duration").map { String(format: "%.0f s", $0) })
        return rows
    }

    func debugProperty(_ name: String) -> String? { getString(name) }
    func debugCommand(_ args: [String]) { command(args) }

    /// Whether the video is HDR (PQ or HLG).
    var isHDRVideo: Bool { ["pq", "hlg"].contains(getString("video-params/gamma") ?? "") }

    private(set) var hdrOutput = false

    /// Real HDR on an HDR screen: mpv outputs PQ (BT.2020) into the half-float buffer and
    /// the layer is marked as extended-range PQ, so highlights go brighter than SDR white.
    /// `peakNits` is the screen's peak. Off: mpv tone-maps to SDR as before.
    func setHDROutput(_ on: Bool, peakNits: Double) {
        guard on != hdrOutput else { return }
        hdrOutput = on
        guard let layer else { applyHDR(on, peakNits: peakNits); return }
        // Fade the picture out, switch mpv's output and the layer's color mode while it's
        // dark (the two never line up on the same frame, which showed as a flash), then
        // fade back in once a frame in the new mode has been drawn.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        layer.opacity = 0
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.27) { [weak self, weak layer] in
            guard let self, let layer, self.hdrOutput == on else { return }
            self.applyHDR(on, peakNits: peakNits)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak layer] in
                guard let layer else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.45)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
                layer.opacity = 1
                CATransaction.commit()
            }
        }
    }

    private func applyHDR(_ on: Bool, peakNits: Double) {
        if on {
            set("target-prim", "bt.2020")
            set("target-trc", "pq")
            set("target-peak", String(Int(peakNits)))
        } else {
            set("target-prim", "auto")
            set("target-trc", "auto")
            set("target-peak", "auto")
        }
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.wantsExtendedDynamicRangeContent = on
        layer.colorspace = on ? CGColorSpace(name: CGColorSpace.itur_2100_PQ) : MPVGLLayer.sdrColorSpace
        CATransaction.commit()
        layer.setNeedsDisplay()
    }

    /// Short labels for what's actually playing, e.g. ["4K", "Dolby Vision", "5.1"].
    func qualityTags() -> [String] {
        var tags: [String] = []
        if let w = getInt("video-params/w"), let h = getInt("video-params/h"), w > 0 {
            // By width too, so scope films (3840×1600) still count as 4K.
            switch (w, h) {
            case _ where w >= 3200 || h >= 1800: tags.append("4K")
            case _ where w >= 1800 || h >= 1000: tags.append("1080p")
            case _ where w >= 1200 || h >= 700: tags.append("720p")
            default: tags.append("\(h)p")
            }
        }
        if dolbyVisionProfile() != nil {
            tags.append("Dolby Vision")
        } else {
            switch getString("video-params/gamma") {
            case "pq": tags.append("HDR10")
            case "hlg": tags.append("HLG")
            default: break
            }
        }
        if let a = audioTracks.first(where: { $0.id == selectedAudio }) {
            if (a.profile ?? "").localizedCaseInsensitiveContains("atmos") || (a.title ?? "").localizedCaseInsensitiveContains("atmos") {
                tags.append("Atmos")
            } else if let c = a.channels, c > 2, let layout = a.channelLayout {
                tags.append(layout)
            }
        }
        return tags
    }

    /// Display size of the video (aspect-corrected), once known.
    func videoDisplaySize() -> CGSize? {
        guard let w = getInt("video-params/dw"), let h = getInt("video-params/dh"), w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// The name of the file actually opened (after a season pack picked one).
    func openedFileName() -> String? {
        getString("filename/no-ext") ?? getString("media-title")
    }

    /// Dolby Vision profile of the video track, if the container says.
    func dolbyVisionProfile() -> Int? {
        for i in 0..<(getInt("track-list/count") ?? 0) where getString("track-list/\(i)/type") == "video" {
            if let p = getInt("track-list/\(i)/dolby-vision-profile") { return p }
        }
        return getString("video-params/colormatrix") == "dolbyvision" ? 5 : nil
    }

    func chapters() -> [(title: String, time: Double)] {
        (0..<(getInt("chapter-list/count") ?? 0)).compactMap { i in
            guard let t = getDouble("chapter-list/\(i)/time") else { return nil }
            return (getString("chapter-list/\(i)/title") ?? "", t)
        }
    }

    // MARK: Teardown

    func shutdown() {
        renderLock.lock()
        if let rc = renderContext, let ctx = layer?.glContext {
            CGLLockContext(ctx)
            CGLSetCurrentContext(ctx)
            mpv_render_context_free(rc)
            CGLUnlockContext(ctx)
        }
        renderContext = nil
        renderLock.unlock()
        guard let handle = mpv else { return }
        mpv_set_wakeup_callback(handle, nil, nil)
        mpv = nil
        eventQueue.async { mpv_terminate_destroy(handle) }
    }

    // MARK: libmpv plumbing

    private func set(_ name: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_property_string(mpv, name, value)
    }

    private func setAsync(_ name: String, _ value: String) {
        guard let mpv else { return }
        value.withCString { v in
            var p: UnsafePointer<CChar>? = v
            _ = mpv_set_property_async(mpv, 0, name, MPV_FORMAT_STRING, &p)
        }
    }

    private func command(_ args: [String]) {
        guard let mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { for p in cargs { free(UnsafeMutablePointer(mutating: p)) } }
        mpv_command(mpv, &cargs)
    }

    private func commandAsync(_ args: [String]) {
        guard let mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { for p in cargs { free(UnsafeMutablePointer(mutating: p)) } }
        mpv_command_async(mpv, 0, &cargs)
    }

    private func getString(_ name: String) -> String? {
        guard let mpv, let c = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    private func getDouble(_ name: String) -> Double? {
        guard let mpv else { return nil }
        var d: Double = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &d) >= 0 ? d : nil
    }

    private func getInt(_ name: String) -> Int? {
        guard let mpv else { return nil }
        var i: Int64 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_INT64, &i) >= 0 ? Int(i) : nil
    }

    private func getFlag(_ name: String) -> Bool {
        guard let mpv else { return false }
        var f: Int32 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &f) >= 0 && f != 0
    }

    private enum Change {
        case double(String, Double)
        case flag(String, Bool)
        case other(String)
        case fileLoaded
        case endFile(reason: mpv_end_file_reason, error: Int32)
    }

    nonisolated private func drainEvents() {
        while let handle = mpv {
            guard let event = mpv_wait_event(handle, 0) else { return }
            let e = event.pointee
            if e.event_id == MPV_EVENT_NONE { return }
            var change: Change?
            switch e.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                let p = e.data.assumingMemoryBound(to: mpv_event_property.self).pointee
                let name = String(cString: p.name)
                switch p.format {
                case MPV_FORMAT_DOUBLE: change = .double(name, p.data.assumingMemoryBound(to: Double.self).pointee)
                case MPV_FORMAT_FLAG: change = .flag(name, p.data.assumingMemoryBound(to: Int32.self).pointee != 0)
                default: change = .other(name)
                }
            case MPV_EVENT_FILE_LOADED:
                change = .fileLoaded
            case MPV_EVENT_END_FILE:
                let f = e.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                change = .endFile(reason: f.reason, error: f.error)
            case MPV_EVENT_LOG_MESSAGE:
                let m = e.data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                lastError = String(cString: m.text).trimmingCharacters(in: .whitespacesAndNewlines)
            case MPV_EVENT_SHUTDOWN:
                return
            default:
                break
            }
            if let change { enqueue(change) }
        }
    }

    nonisolated private func enqueue(_ change: Change) {
        pendingLock.lock()
        // A newer value of the same number replaces the waiting one (position, cache…).
        if case .double(let name, _) = change,
           let i = pending.lastIndex(where: { if case .double(name, _) = $0 { true } else { false } }) {
            pending[i] = change
        } else {
            pending.append(change)
        }
        let schedule = !flushScheduled
        flushScheduled = true
        pendingLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    private func flush() {
        pendingLock.lock()
        let changes = pending
        pending = []
        flushScheduled = false
        pendingLock.unlock()
        for change in changes { apply(change) }
    }

    private func apply(_ change: Change) {
        switch change {
        // Published at most ~4×/s: every change redraws the player, and nothing on screen
        // needs per-frame precision. Jumps (seeks) go through at once.
        case .double("time-pos", let v): if abs(v - position) >= 0.25 { position = v }
        case .double("duration", let v): duration = v
        case .double("demuxer-cache-duration", let v): if abs(v - cacheSeconds) >= 1 { cacheSeconds = v }
        case .double("volume", let v): volume = v
        case .double("speed", let v): speed = v
        case .flag("pause", let v): paused = v
        case .flag("paused-for-cache", let v): buffering = v
        case .flag("seeking", let v): seeking = v
        case .flag("mute", let v): muted = v
        case .flag("eof-reached", let v): if v && fileLoaded { endedNaturally = true }
        case .other("track-list"): refreshTracks()
        case .other("aid"): selectedAudio = getInt("aid")
        case .other("sid"): selectedSubtitle = getInt("sid")
        case .fileLoaded:
            fileLoaded = true
            buffering = false
            refreshTracks()
        case .endFile(let reason, let error):
            if reason == MPV_END_FILE_REASON_ERROR {
                let detail = lastError ?? String(cString: mpv_error_string(error))
                errorMessage = "Playback failed: \(detail)"
            }
        default: break
        }
    }

    private func refreshTracks() {
        var audio: [MediaTrack] = [], subs: [MediaTrack] = []
        for i in 0..<(getInt("track-list/count") ?? 0) {
            let p = "track-list/\(i)/"
            guard let type = getString(p + "type"), let id = getInt(p + "id") else { continue }
            let t = MediaTrack(
                id: id, type: type, title: getString(p + "title"), lang: getString(p + "lang"),
                codec: getString(p + "codec"), profile: getString(p + "codec-profile"),
                channels: getInt(p + "demux-channel-count"), isExternal: getFlag(p + "external"),
                isDefault: getFlag(p + "default"), isForced: getFlag(p + "forced")
            )
            if type == "audio" { audio.append(t) } else if type == "sub" { subs.append(t) }
        }
        audioTracks = audio
        subtitleTracks = subs
        selectedAudio = getInt("aid")
        selectedSubtitle = getInt("sid")
    }

    // MARK: Rendering (called by MPVGLLayer with its GL context current)

    nonisolated func createRenderContext() {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard renderContext == nil, let mpv else { return }
        let api = strdup("opengl")
        defer { free(api) }
        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
                let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
                return CFBundleGetFunctionPointerForName(bundle, symbol)
            },
            get_proc_address_ctx: nil
        )
        var rc: OpaquePointer?
        withUnsafeMutablePointer(to: &initParams) { ip in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(ip)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            mpv_render_context_create(&rc, mpv, &params)
        }
        guard let rc else { return }
        renderContext = rc
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderReady = true
            let load = self.pendingLoad
            self.pendingLoad = nil
            load?()
        }
    }

    /// Polled by the layer once per display refresh: does mpv have a frame due?
    nonisolated func wantsFrame() -> Bool {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let rc = renderContext else { return false }
        return mpv_render_context_update(rc) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0
    }

    nonisolated func render(fbo: GLint, width: GLint, height: GLint) {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let rc = renderContext else { return }
        // Tell mpv the target is half-float so it doesn't dither down to 8 bits.
        var fboParam = mpv_opengl_fbo(fbo: Int32(fbo), w: Int32(width), h: Int32(height), internal_format: 0x881A /* GL_RGBA16F */)
        var flip: Int32 = 1
        // Core Animation runs this on the main thread. By default mpv holds the call until
        // the frame's display time, which kept the whole app blocked ~80% of the time
        // during playback; Core Animation already draws in step with the display.
        var block: Int32 = 0
        withUnsafeMutablePointer(to: &fboParam) { f in
            withUnsafeMutablePointer(to: &flip) { fl in
                withUnsafeMutablePointer(to: &block) { b in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(f)),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(fl)),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(b)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    mpv_render_context_render(rc, &params)
                }
            }
        }
    }

    nonisolated func reportSwap() {
        renderLock.lock()
        if let rc = renderContext { mpv_render_context_report_swap(rc) }
        renderLock.unlock()
    }
}

/// Core Animation layer that mpv draws each frame into.
final class MPVGLLayer: CAOpenGLLayer {
    static let sdrColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    weak var controller: MPVController?
    private(set) var glContext: CGLContextObj?
    /// Set on resize so the current frame is redrawn at the new size.
    private var forceDraw = true

    override var bounds: CGRect {
        didSet { forceDraw = true }
    }

    override init() {
        super.init()
        // Core Animation calls canDraw on every display refresh; mpv decides.
        isAsynchronous = true
        needsDisplayOnBoundsChange = true
        // The buffer is half-float; without a color space macOS reads float values as
        // linear light, which crushed SDR video's mid-tones (harsh contrast). mpv's normal
        // output is gamma-encoded sRGB/BT.709.
        colorspace = Self.sdrColorSpace
        backgroundColor = NSColor.black.cgColor
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let l = layer as? MPVGLLayer { controller = l.controller }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let attrs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFADoubleBuffer, kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers,
            // Half-float buffer: room for HDR values above SDR white (and finer gradients in SDR).
            kCGLPFAColorFloat, kCGLPFAColorSize, CGLPixelFormatAttribute(64),
            CGLPixelFormatAttribute(0),
        ]
        var pf: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attrs, &pf, &count)
        return pf!
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        let ctx = super.copyCGLContext(forPixelFormat: pf)
        var swap: GLint = 1
        CGLSetParameter(ctx, kCGLCPSwapInterval, &swap)
        CGLSetCurrentContext(ctx)
        glContext = ctx
        controller?.createRenderContext()
        return ctx
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        let due = controller?.wantsFrame() ?? false
        if forceDraw { forceDraw = false; return true }
        return due
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        var viewport: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        if viewport[2] > 0, viewport[3] > 0 {
            controller?.render(fbo: fbo, width: viewport[2], height: viewport[3])
        } else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        }
        glFlush()
        controller?.reportSwap()
    }
}

/// NSView hosting the mpv layer, kept at the window's pixel density.
final class MPVVideoView: NSView {
    let glLayer = MPVGLLayer()

    init(controller: MPVController) {
        super.init(frame: .zero)
        glLayer.controller = controller
        controller.layer = glLayer
        // Layer-hosting: assign the layer before turning layers on, so AppKit leaves it alone.
        layer = glLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        glLayer.contentsScale = window?.backingScaleFactor ?? 2
        // Draw once right away: that is what makes Core Animation create the GL context.
        glLayer.setNeedsDisplay()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        glLayer.contentsScale = window?.backingScaleFactor ?? 2
    }
}
