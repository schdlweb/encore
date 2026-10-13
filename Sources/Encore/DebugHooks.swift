import AppKit
import WebKit
import MediaPlayer
import SwiftUI

/// Test hooks, inert unless their environment variables are set:
///   ENCORE_SNAPSHOT_DIR=/path  writes the window as PNG every 3 s (shot-N.png)
///   ENCORE_ROUTE=tab:search | detail:<type>:<id> | play:<type>:<id>[:<videoId>]
@MainActor
enum DebugHooks {
    static func install(app: AppState) {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["ENCORE_SNAPSHOT_DIR"] {
            var n = 0
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                Task { @MainActor in
                    n += 1
                    snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("shot-\(n).png"))
                }
            }
        }
        if env["ENCORE_LOG_PLAYER"] != nil {
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                Task { @MainActor in
                    if MPVController.current == nil, let st = app.playStatus {
                        print("[status] \(st.message) | \(st.detail ?? "") | failures=\(st.failures)")
                    }
                    guard let p = MPVController.current else { return }
                    print("[playing] \(app.playback?.videoId ?? "nothing") status=\(app.playStatus.map { "\($0.message) | \($0.detail ?? "") | failures=\($0.failures.count)" } ?? "none")")
                    var line = String(format: "[player] pos=%.1f dur=%.1f paused=%d loaded=%d buffering=%d ended=%d",
                                      p.position, p.duration, p.paused ? 1 : 0, p.fileLoaded ? 1 : 0, p.buffering ? 1 : 0, p.endedNaturally ? 1 : 0)
                    line += " hdrOut=\(p.hdrOutput) gamma=\(p.debugProperty("video-params/gamma") ?? "-") trc=\(p.debugProperty("target-trc") ?? "-") screenEDR=\(NSApp.windows.first { $0.isVisible && $0.title == "Player" }?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 0)"
                    line += " aid=\(p.selectedAudio.map(String.init) ?? "-") sid=\(p.selectedSubtitle.map(String.init) ?? "-")"
                    if let e = p.errorMessage { line += " error=\(e)" }
                    let visible = NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
                    line += " windowVisible=\(visible) display-fps=\(p.debugProperty("display-fps") ?? "nil") decoder-drops=\(p.debugProperty("decoder-frame-drop-count") ?? "nil") delayed=\(p.debugProperty("vo-delayed-frame-count") ?? "nil")"
                    let np = MPNowPlayingInfoCenter.default()
                    line += " nowPlaying=\(np.playbackState.rawValue)/\(np.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String ?? "-")"
                    print(line)
                    print("  audio: " + p.audioTracks.map { "\($0.id) \($0.label) [\($0.detail)]" }.joined(separator: " | "))
                    print("  subs:  " + p.subtitleTracks.map { "\($0.id) \($0.label) [\($0.detail)]" }.joined(separator: " | "))
                    print("  video: " + ["vid", "current-vo", "video-codec", "video-params/w", "video-params/h", "hwdec-current", "estimated-vf-fps", "frame-drop-count"]
                        .map { "\($0)=\(p.debugProperty($0) ?? "nil")" }.joined(separator: " "))
                    print("  info:  " + p.mediaInfo().map { "\($0.0)=\($0.1)" }.joined(separator: "; "))
                    fflush(stdout)
                }
            }
        }
        if let route = env["ENCORE_ROUTE"] {
            Task {
                while app.connection != .loaded { try? await Task.sleep(for: .milliseconds(200)) }
                try? await Task.sleep(for: .seconds(2))
                for (i, step) in route.split(separator: "|").enumerated() {
                    if i > 0 { try? await Task.sleep(for: .seconds(3)) }
                    await go(String(step), app: app)
                }
            }
        }
    }

    private static func go(_ route: String, app: AppState) async {
        let parts = route.split(separator: ":", maxSplits: 3).map(String.init)
        switch parts.first {
        case "tab":
            if let t = Tab.allCases.first(where: { $0.rawValue.lowercased() == parts[1] }) { app.tab = t }
        case "detail" where parts.count >= 3:
            let (type, metaId, _) = splitIds(route)
            if let m = await app.fullMeta(type: type, id: metaId) { app.open(m) }
        case "play" where parts.count >= 3:
            // play:<type>:<metaId>[:<videoId>] — ids may contain colons (mal:5114, tt1:1:2).
            let (type, metaId, videoId) = splitIds(route)
            guard let m = await app.fullMeta(type: type, id: metaId) else { print("[play] no meta"); return }
            let start = Date()
            app.requestPlay(meta: m, video: m.videos.first { $0.id == videoId })
            while app.playback == nil, app.playStatus?.phase != .failed, Date().timeIntervalSince(start) < 60 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            print(String(format: "[play] %@ ready after %.2fs", videoId ?? metaId, Date().timeIntervalSince(start)))
            fflush(stdout)
        case "checkboxes":
            // Clicks the first few checkboxes in the frontmost window and reports what got hidden.
            try? await Task.sleep(for: .seconds(2))
            func all(_ v: NSView) -> [NSButton] {
                var out = (v as? NSButton).map { [$0] } ?? []
                for sub in v.subviews { out += all(sub) }
                return out
            }
            guard let root = NSApp.windows.first(where: \.isVisible)?.contentView else { return }
            let boxes = all(root)
            print("[check] \(boxes.count) buttons: " + boxes.prefix(6).map { "'\($0.title)' state=\($0.state.rawValue)" }.joined(separator: ", "))
            for b in boxes.prefix(3) { b.performClick(nil) }
            try? await Task.sleep(for: .seconds(1))
            print("[check] hidden=\(app.settings.hiddenCatalogs.sorted()) rows=\(app.rows.count)")
            fflush(stdout)
        case "thumbreal":
            // Previews against the stream that's playing: time each hover to its frame.
            guard let pb = app.playback, let p = MPVController.current, p.duration > 0 else { print("[thumb] not playing"); return }
            let start = Date()
            var asked: [Int: Date] = [:]
            let gen = ThumbnailGenerator(url: pb.url.absoluteString, headers: pb.stream.requestHeaders, duration: p.duration) { t, img in
                let since = asked[Int(t)].map { Date().timeIntervalSince($0) } ?? -1
                // Fingerprint: average of a few sampled pixels, to spot identical (stale) frames.
                var fp = 0
                if let data = img.dataProvider?.data, let ptr = CFDataGetBytePtr(data) {
                    let n = CFDataGetLength(data)
                    for k in stride(from: 0, to: n, by: max(4, n / 97)) { fp = (fp &* 31 &+ Int(ptr[k])) & 0xFFFFFF }
                }
                let out = ProcessInfo.processInfo.environment["ENCORE_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/thumb-\(Int(t)).png"))
                print(String(format: "[thumb] t=%.0f latency=%.2fs (at %.1fs) fp=%06x", t, since, Date().timeIntervalSince(start), fp))
                fflush(stdout)
            }
            try? await Task.sleep(for: .seconds(3))
            for frac in [0.1, 0.5, 0.52, 0.8, 0.3, 0.31, 0.32, 0.9] {
                let t = gen.bucketed(p.duration * frac)
                asked[Int(t)] = Date()
                gen.request(t)
                try? await Task.sleep(for: .milliseconds(1500))
            }
            try? await Task.sleep(for: .seconds(5))
            gen.shutdown()
        case "scrollbench":
            // Scrolls the page like a steady trackpad swipe and counts display frames that
            // were missed (an interval over 1.5× the screen's refresh), via a display link.
            guard let window = NSApp.windows.first(where: \.isVisible), let root = window.contentView else { return }
            var found: [NSScrollView] = []
            func walk(_ v: NSView) { if let s = v as? NSScrollView { found.append(s) }; v.subviews.forEach(walk) }
            walk(root)
            guard let page = found.max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else { return }
            let counter = FrameCounter()
            let link = root.displayLink(target: counter, selector: #selector(FrameCounter.tick(_:)))
            link.add(to: .main, forMode: .common)
            page.contentView.scroll(to: .zero)
            let start = Date()
            // ~1500 pt/s for 6 s, driven by the display link's own rhythm.
            while Date().timeIntervalSince(start) < 6 {
                let y = Date().timeIntervalSince(start) * 1500
                page.contentView.scroll(to: NSPoint(x: 0, y: y))
                page.reflectScrolledClipView(page.contentView)
                try? await Task.sleep(for: .milliseconds(4))
            }
            link.invalidate()
            print("[scroll] " + counter.report)
            fflush(stdout)
        case "revealbench":
            // Jumps down a screen at a time and records how long the main thread stalls
            // building the newly revealed rows (the cost of seeing them for the first time).
            guard let window = NSApp.windows.first(where: \.isVisible), let root = window.contentView else { return }
            var found: [NSScrollView] = []
            func walk(_ v: NSView) { if let s = v as? NSScrollView { found.append(s) }; v.subviews.forEach(walk) }
            walk(root)
            guard let page = found.max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else { return }
            let counter = FrameCounter()
            let link = root.displayLink(target: counter, selector: #selector(FrameCounter.tick(_:)))
            link.add(to: .main, forMode: .common)
            let busy = MainBusyMeter()
            busy.start()
            var stalls: [Double] = []
            for i in 1...14 {
                counter.reset()
                page.contentView.scroll(to: NSPoint(x: 0, y: Double(i) * 700))
                page.reflectScrolledClipView(page.contentView)
                try? await Task.sleep(for: .milliseconds(600))
                stalls.append(counter.worstGap * 1000)
            }
            link.invalidate()
            page.contentView.scroll(to: .zero)
            busy.stop()
            print(String(format: "[reveal] busy=%.0fms avg-worst-frame=%.0fms worst=%.0fms", busy.total * 1000, stalls.reduce(0, +) / Double(stalls.count), stalls.max() ?? 0))
            fflush(stdout)
        case "downloadtest" where parts.count >= 3:
            // downloadtest:<type>:<id> — downloads the first playable stream for a few seconds.
            let (type, metaId, _) = splitIds(route)
            guard let m = await app.fullMeta(type: type, id: metaId),
                  let s = (try? await app.streams(for: m, video: nil))?.first(where: \.isPlayable) else { print("[dl] no stream"); return }
            app.downloads.download(s, title: m.name)
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(2))
                if let i = app.downloads.items.first { print("[dl] \(i.name) state=\(i.state) \(i.received)/\(i.total)"); fflush(stdout) }
            }
            if let i = app.downloads.items.first { app.downloads.dismiss(i.id) }
            print("[dl] cancelled"); fflush(stdout)
        case "upcoming":
            await app.loadUpcoming()
            for u in app.upcoming { print("[upcoming] \(u.meta.name) S\(u.video.season ?? 0)E\(u.video.episode ?? 0) \(u.video.released.map { "\($0)" } ?? "?")") }
            print("[upcoming] \(app.upcoming.count) total"); fflush(stdout)
        case "recs":
            let t0 = Date()
            await app.loadRecommendations(force: true)
            for r in app.recommendations.prefix(15) { print("[recs] \(r.meta.name) (\(r.meta.id)) ← \(r.because)") }
            print(String(format: "[recs] %d total in %.1fs", app.recommendations.count, Date().timeIntervalSince(t0))); fflush(stdout)
        case "playmatch" where parts.count >= 4:
            // playmatch:<type>:<metaId>:<text> — plays the first stream whose description has <text>.
            let rest = route.split(separator: ":", maxSplits: 3).map(String.init)
            guard let m = await app.fullMeta(type: rest[1], id: rest[2]),
                  let all = try? await app.streams(for: m, video: nil) else { print("[play] no streams"); return }
            let pick = all.first { $0.isPlayable && !$0.isDolbyVisionOnly && ($0.headline + " " + $0.details + " " + ($0.filename ?? "")).localizedCaseInsensitiveContains(rest[3]) }
            guard let pick else { print("[play] nothing matching \(rest[3])"); fflush(stdout); return }
            print("[play] picked \(pick.oneLine)"); fflush(stdout)
            app.requestPlay(meta: m, video: nil, stream: pick, alternatives: all)
        case "tohdrscreen":
            // Moves the player window onto a screen that can show HDR.
            guard let screen = NSScreen.screens.first(where: { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.5 }),
                  let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "Player" }) else { print("[hdr] no screen/window"); fflush(stdout); return }
            let f = screen.visibleFrame
            w.setFrame(NSRect(x: f.midX - 640, y: f.midY - 270, width: 1280, height: 540), display: true)
            print("[hdr] target \(screen.localizedName) frame=\(f)"); fflush(stdout)
            try? await Task.sleep(for: .seconds(2))
            print("[hdr] window now on \(w.screen?.localizedName ?? "?") frame=\(w.frame) hdrOut=\(MPVController.current?.hdrOutput ?? false)"); fflush(stdout)
        case "playerwin":
            // Pauses and prints the player window's number (for `screencapture -l`) and saves
            // mpv's own render of the same frame as a reference.
            guard let p = MPVController.current, let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "Player" }) else { return }
            p.setPaused(true)
            try? await Task.sleep(for: .seconds(1))
            let out = ProcessInfo.processInfo.environment["ENCORE_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
            p.debugCommand(["screenshot-to-file", out + "/mpv-ref.png", "video"])
            print("[win] \(w.windowNumber) screen=\(w.screen?.localizedName ?? "?") hdrOut=\(p.hdrOutput)"); fflush(stdout)
        case "thumbcheck":
            // Same time from a generator that has jumped around vs a fresh one: must match.
            guard let pb = app.playback, let p = MPVController.current, p.duration > 0 else { print("[check] not playing"); return }
            func fingerprint(_ img: CGImage) -> Int {
                var fp = 0
                if let data = img.dataProvider?.data, let ptr = CFDataGetBytePtr(data) {
                    let n = CFDataGetLength(data)
                    for k in stride(from: 0, to: n, by: max(4, n / 97)) { fp = (fp &* 31 &+ Int(ptr[k])) & 0xFFFFFF }
                }
                return fp
            }
            var seen: [String: Int] = [:]
            let t0 = Date()
            let a = ThumbnailGenerator(url: pb.url.absoluteString, headers: pb.stream.requestHeaders, duration: p.duration) { t, img in
                seen["a\(Int(t))"] = fingerprint(img)
                print(String(format: "[check] A t=%.0f fp=%06x at %.1fs", t, fingerprint(img), Date().timeIntervalSince(t0))); fflush(stdout)
            }
            for f in [0.2, 0.7, 0.4, 0.61] { a.request(p.duration * f); try? await Task.sleep(for: .milliseconds(1200)) }
            let b = ThumbnailGenerator(url: pb.url.absoluteString, headers: pb.stream.requestHeaders, duration: p.duration) { t, img in
                print(String(format: "[check] B t=%.0f fp=%06x frameTime=%.2f", t, fingerprint(img), 0.0)); fflush(stdout)
            }
            try? await Task.sleep(for: .seconds(4))
            b.request(p.duration * 0.61)
            try? await Task.sleep(for: .seconds(4))
            print("[check] A frameTime(0.61)=\(a.frameTime(p.duration * 0.61) ?? -1) B=\(b.frameTime(p.duration * 0.61) ?? -1)"); fflush(stdout)
            a.shutdown(); b.shutdown()
        case "ranked" where parts.count >= 3:
            let (type, metaId, videoId) = splitIds(route)
            guard let m = await app.fullMeta(type: type, id: metaId) else { return }
            let v = m.videos.first { $0.id == videoId }
            for (i, s) in await app.rankedStreams(meta: m, video: v).prefix(6).enumerated() {
                let gb = s.videoSize.map { String(format: "%.1f GB", Double($0) / 1e9) } ?? "?"
                print("[ranked] \(i + 1). \(s.filename ?? s.oneLine) (\(gb))")
            }
            fflush(stdout)
        case "updatedl":
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("encore-dl-test.zip")
            do {
                try await app.updater.download(URL(string: "http://127.0.0.1:8799/Encore.zip")!, to: dest)
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? -1
                print("[update] downloaded \(size) bytes state=\(app.updater.state)")
            } catch { print("[update] failed \(error)") }
            fflush(stdout)
        case "updateinstall":
            // Installs the zip served at 127.0.0.1:8799 over this copy of the app.
            print("[update] installing over \(Bundle.main.bundleURL.path)"); fflush(stdout)
            await app.updater.install(.init(version: "9.9.9", notes: "", zip: URL(string: "http://127.0.0.1:8799/Encore.zip")!))
            print("[update] state=\(app.updater.state)"); fflush(stdout)
        case "updatecheck":
            await app.updater.check(userInitiated: true)
            print("[update] current=\(app.updater.currentVersion) state=\(app.updater.state)"); fflush(stdout)
        case "seekend":
            guard let p = MPVController.current, p.duration > 0 else { return }
            p.seekExact(to: p.duration - 40)
            print("[seekend] at \(Date())"); fflush(stdout)
        case "jfids":
            let a = JellyfinSync.itemId(imdb: "tt9522300", type: "series") ?? "-"
            let b = JellyfinSync.itemId(imdb: "tt9522300", type: "series", season: 1, episode: 3) ?? "-"
            let c = JellyfinSync.itemId(imdb: "tt0816692", type: "movie") ?? "-"
            print("[jf] \(a) \(b) \(c) decode=\(String(describing: JellyfinSync.decode(b)))"); fflush(stdout)
        case "pausetest":
            // Toggles pause a few times, timing the call itself and until the UI state flips.
            for _ in 0..<4 {
                guard let p = MPVController.current else { print("[pause] no player"); return }
                let was = p.paused, t0 = Date()
                p.togglePause()
                let call = Date().timeIntervalSince(t0)
                while p.paused == was, Date().timeIntervalSince(t0) < 10 { try? await Task.sleep(for: .milliseconds(5)) }
                print(String(format: "[pause] -> %@ call=%.0fms state=%.0fms", p.paused ? "paused" : "playing", call * 1000, Date().timeIntervalSince(t0) * 1000))
                fflush(stdout)
                try? await Task.sleep(for: .seconds(2))
            }
        case "wait" where parts.count >= 2:
            try? await Task.sleep(for: .seconds(Double(parts[1]) ?? 1))
        case "order" where parts.count >= 3:
            // order:<type>:<metaId>:<videoId> — prints how streams rank after the sanity checks.
            let (type, metaId, videoId) = splitIds(route)
            guard let m = await app.fullMeta(type: type, id: metaId), let v = m.videos.first(where: { $0.id == videoId }) else { return }
            let matcher = await EpisodeMatcher.make(meta: m, video: v)
            print("[order] phrases=\(matcher.foreignPhrases)")
            let streams = (try? await app.streams(for: m, video: v)) ?? []
            for s in streams.filter(\.isPlayable).prefix(12) {
                let flags = [matcher.isMismatch(s) ? "WRONG-ENTRY" : nil, s.looksLikeExtra ? "EXTRA" : nil, s.isDolbyVisionOnly ? "DV" : nil]
                    .compactMap { $0 }.joined(separator: ",")
                print("  [\(flags.isEmpty ? "ok" : flags)] \(s.filename ?? s.oneLine)")
            }
            fflush(stdout)
        case "person" where parts.count >= 2:
            app.open(CastMember(name: parts[1...].joined(separator: ":")))
        case "scroll":
            // scroll:<points> scrolls the frontmost scroll view, for snapshotting lower sections.
            if let y = Double(parts.count > 1 ? parts[1] : "800") {
                try? await Task.sleep(for: .seconds(4))
                scrollFrontmost(by: y)
            }
        case "trailer" where parts.count >= 2:
            app.trailer = TrailerRequest(youTubeId: parts[1], title: "Test")
            try? await Task.sleep(for: .seconds(9))
            let out = ProcessInfo.processInfo.environment["ENCORE_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
            func find(_ v: NSView) -> WKWebView? { (v as? WKWebView) ?? v.subviews.lazy.compactMap(find).first }
            if let root = NSApp.windows.first(where: \.isVisible)?.contentView, let web = find(root) {
                web.takeSnapshot(with: nil) { img, err in
                    if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent("web.png"))
                    }
                    print("[trailer] snapshot \(img != nil) err=\(String(describing: err))"); fflush(stdout)
                }
            } else { print("[trailer] no web view"); fflush(stdout) }
        case "rowstates":
            let failed = app.rows.filter { if case .failed = $0.state { return true }; return false }
            let loaded = app.rows.filter { $0.state == .loaded }.count
            print("[rows] total=\(app.rows.count) loaded=\(loaded) failed=\(failed.count): " +
                  failed.map { r -> String in if case .failed(let m) = r.state { return "\(r.def.name)=\(m)" }; return "" }.joined(separator: "; "))
            fflush(stdout)
        case "cast" where parts.count >= 3:
            let (type, metaId, _) = splitIds(route)
            guard let m = await app.fullMeta(type: type, id: metaId) else { return }
            let c = m.cast.isEmpty ? await DiscoveryService.cast(for: m) : m.cast
            print("[cast] \(m.name) (addon had \(m.cast.count)): " + c.prefix(5).map { "\($0.name) as \($0.character ?? "?") photo=\($0.photo != nil)" }.joined(separator: " | "))
            fflush(stdout)
        case "winfo":
            for w in NSApp.windows where w.isVisible {
                let cb = w.collectionBehavior
                print("[winfo] \(w.title) behavior=\(cb.rawValue) primary=\(cb.contains(.fullScreenPrimary)) aux=\(cb.contains(.fullScreenAuxiliary)) none=\(cb.contains(.fullScreenNone)) mask=\(w.styleMask.rawValue) class=\(type(of: w))")
            }
            fflush(stdout)
        case "fullscreen":
            guard let w = NSApp.windows.first(where: { $0.title == "Player" && $0.isVisible }) else { print("[fs] no player window"); return }
            w.toggleFullScreen(nil)
            try? await Task.sleep(for: .seconds(3))
            let screen = w.screen?.frame ?? .zero
            print("[fs] fullscreen=\(w.styleMask.contains(.fullScreen)) window=\(Int(w.frame.width))x\(Int(w.frame.height)) screen=\(Int(screen.width))x\(Int(screen.height)) key=\(w.isKeyWindow) resizable=\(w.styleMask.contains(.resizable)) zoomEnabled=\(w.standardWindowButton(.zoomButton)?.isEnabled ?? false) aspect=\(w.contentAspectRatio)")
            fflush(stdout)
        case "search" where parts.count >= 2:
            let start = Date()
            let sections = await SearchService.search(parts[1...].joined(separator: ":"))
            print(String(format: "[search] %.2fs", Date().timeIntervalSince(start)))
            for sec in sections {
                print("  \(sec.title): " + sec.items.prefix(5).map { "\($0.name) (\($0.id), \($0.type))" }.joined(separator: " | "))
            }
            fflush(stdout)
        case "segments" where parts.count >= 3:
            // segments:<type>:<metaId>[:<videoId>] — videoId may itself contain colons.
            let (type, metaId, videoId) = splitIds(route)
            guard let m = await app.fullMeta(type: type, id: metaId) else { print("[segments] no meta"); return }
            let video = m.videos.first { $0.id == videoId }
            let segs = await SegmentService.fetch(meta: m, video: video, duration: 1420)
            print("[segments] \(m.name) \(videoId): " + segs.map { "\($0.kind) \(Int($0.start))-\(Int($0.end)) [\($0.source)]" }.joined(separator: ", "))
            fflush(stdout)
        case "thumb" where parts.count >= 2:
            let url = route.dropFirst("thumb:".count)
            let out = ProcessInfo.processInfo.environment["ENCORE_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
            let start = Date()
            var gen: ThumbnailGenerator?
            gen = ThumbnailGenerator(url: String(url), headers: [:], duration: 30) { t, img in
                let rep = NSBitmapImageRep(cgImage: img)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: out).appendingPathComponent("thumb-\(Int(t)).png"))
                print(String(format: "[thumb] t=%.0f %dx%d after %.2fs", t, img.width, img.height, Date().timeIntervalSince(start)))
                fflush(stdout)
            }
            for t in [5.0, 15.0, 25.0] {
                gen?.request(t)
                try? await Task.sleep(for: .seconds(2))
            }
            _ = gen
        default: break
        }
    }

    private static func scrollFrontmost(by y: Double) {
        guard let root = NSApp.windows.first(where: \.isVisible)?.contentView else { return }
        var found: [NSScrollView] = []
        func walk(_ v: NSView) { if let s = v as? NSScrollView, s.hasVerticalScroller || s.verticalScrollElasticity != .none { found.append(s) }; v.subviews.forEach(walk) }
        walk(root)
        // The tallest vertical scroll view is the page.
        guard let page = found.filter({ ($0.documentView?.frame.height ?? 0) > $0.frame.height + 100 })
            .max(by: { $0.frame.height < $1.frame.height }) else { return }
        let clip = page.contentView
        clip.scroll(to: NSPoint(x: 0, y: min(y, (page.documentView?.frame.height ?? 0) - clip.bounds.height)))
        page.reflectScrolledClipView(clip)
    }

    private static func splitIds(_ route: String) -> (type: String, metaId: String, videoId: String) {
        let rest = route.split(separator: ":", maxSplits: 2).map(String.init)
        let tail = rest.count > 2 ? rest[2] : ""
        let prefixed = ["mal:", "kitsu:", "anilist:", "tmdb:"].contains { tail.hasPrefix($0) }
        let metaId = prefixed ? tail.split(separator: ":").prefix(2).joined(separator: ":")
                              : String(tail.split(separator: ":").first ?? "")
        let videoId = String(String(tail.dropFirst(metaId.count)).drop(while: { $0 == ":" }))
        return (rest[1], metaId, videoId)
    }

    /// Writes each visible window: shot-N.png for the first, shot-N-w2.png for the next…
    private static func snapshot(to url: URL) {
        for (i, w) in NSApp.windows.filter(\.isVisible).enumerated() {
            guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let target = i == 0 ? url : url.deletingPathExtension().appendingPathExtension("w\(i + 1).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: target)
            if i > 0 || NSApp.windows.filter(\.isVisible).count > 1 {
                print("[window] \(w.title.isEmpty ? "-" : w.title) frame=\(Int(w.frame.width))x\(Int(w.frame.height)) content=\(Int(view.bounds.width))x\(Int(view.bounds.height))")
                fflush(stdout)
            }
        }
    }
}


/// Records display-link timestamps for the scroll benchmark.
final class FrameCounter: NSObject {
    private var stamps: [CFTimeInterval] = []
    private var period: CFTimeInterval = 1.0 / 60
    @objc func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        if link.duration > 0 { period = link.duration }
    }
    func reset() { stamps = [] }
    var worstGap: CFTimeInterval { zip(stamps.dropFirst(), stamps).map { $0 - $1 }.max() ?? 0 }
    var report: String {
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let missed = gaps.reduce(0) { $0 + max(0, Int(($1 / period).rounded()) - 1) }
        let worst = (gaps.max() ?? 0) * 1000
        return String(format: "frames=%d missed=%d (%.1f%%) worst=%.0fms refresh=%.0fHz",
                      stamps.count, missed, Double(missed) / Double(max(1, stamps.count + missed)) * 100, worst, 1 / period)
    }
}

/// Sums the time the main run loop spends working (awake) rather than waiting.
final class MainBusyMeter {
    private var observer: CFRunLoopObserver?
    private var wokeAt: CFTimeInterval?
    private(set) var total: CFTimeInterval = 0
    func start() {
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, activity in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if activity == .afterWaiting { self.wokeAt = now }
            else if let w = self.wokeAt { self.total += now - w; self.wokeAt = nil }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
    func stop() { if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) } }
}
