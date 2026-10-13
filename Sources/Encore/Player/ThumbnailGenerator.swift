import AppKit
import CFFmpeg

/// Scrubbing previews, like Infuse's, read straight from the stream with FFmpeg: seek to
/// the keyframe at or before the hovered time, decode that one frame, scale it down.
///
/// (This used a second, hidden mpv. mpv is a playback pipeline: after a seek it reports
/// ready slightly before the new frame reaches its output, so a preview could show the
/// previous spot's frame and only "catch up" over later redraws.) Here every preview is
/// exactly the frame decoded for it, and its real timestamp is kept so a click on the
/// timeline can land on that very frame.
///
/// All FFmpeg calls happen on one serial queue. Requests coalesce: while a frame is being
/// made only the latest hover is kept. Between requests it fills the timeline in the
/// background, coarse to fine, so a hover can show a close frame at once.
final class ThumbnailGenerator: @unchecked Sendable {
    static let width = 480 // 240 pt on a Retina screen

    private let queue = DispatchQueue(label: "encore.thumbnails", qos: .userInitiated)
    private var format: UnsafeMutablePointer<AVFormatContext>?
    private var decoder: UnsafeMutablePointer<AVCodecContext>?
    private var scaler: UnsafeMutablePointer<SwsContext>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var decoded: UnsafeMutablePointer<AVFrame>?
    private var streamIndex: Int32 = -1
    private var ready = false
    private var failed = false
    private var busy = false
    private var pending: Double?
    /// Read from the main thread while the queue may be busy, so it has its own lock.
    private var cache: [Int: (image: CGImage, frameTime: Double)] = [:]
    private let cacheLock = NSLock()
    private let bucket: Double
    private let duration: Double
    private var sweep: [Double] = []
    /// Spots just ahead of the pointer in the direction it's moving: after the hovered
    /// spot itself, before the background fill.
    private var ahead: [Double] = []
    private var lastRequest: Double?
    private var sweeping = false
    private let deliver: @MainActor (Double, CGImage) -> Void

    /// `deliver` receives (bucketed time, image) on the main actor.
    init(url: String, headers: [String: String], duration: Double, deliver: @escaping @MainActor (Double, CGImage) -> Void) {
        // One preview per 2 s (3 s past 2 hours).
        bucket = duration > 7200 ? 3 : 2
        self.duration = duration
        self.deliver = deliver
        queue.async { self.open(url: url, headers: headers) }
    }

    func bucketed(_ t: Double) -> Double { (t / bucket).rounded() * bucket }

    /// Cached frame for this time, if one was already made.
    func cached(_ t: Double) -> CGImage? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[Int(bucketed(t) * 10)]?.image
    }

    /// Where the preview for this time really is (its keyframe), once it's been made.
    func frameTime(_ t: Double) -> Double? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[Int(bucketed(t) * 10)]?.frameTime
    }

    /// The closest frame made so far within `window` seconds: (its bucket, its real time, image).
    func nearestFrame(_ t: Double, within window: Double) -> (key: Double, frameTime: Double, image: CGImage)? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let best = cache.min { abs($0.value.frameTime - t) < abs($1.value.frameTime - t) }
        guard let best, abs(best.value.frameTime - t) <= window else { return nil }
        return (Double(best.key) / 10, best.value.frameTime, best.value.image)
    }

    /// The closest frame made so far, if it's from (nearly) the same moment.
    func nearest(_ t: Double) -> (time: Double, image: CGImage)? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let target = Int(bucketed(t) * 10)
        let limit = Int(bucket * 10 * 1.5)
        return cache.min { abs($0.key - target) < abs($1.key - target) }
            .flatMap { abs($0.key - target) <= limit ? (Double($0.key) / 10, $0.value.image) : nil }
    }

    /// Fills the timeline in the background, coarse to fine (quarters, eighths, …) down to
    /// one frame every ~12 s, so a ready frame is almost always next to the pointer.
    func prefetch() {
        queue.async {
            guard !self.sweeping, self.duration > 0 else { return }
            self.sweeping = true
            var seen = Set<Int>()
            var divs: [Int] = []
            var d = 4
            while true { divs.append(d); if self.duration / Double(d) <= 12 || d >= 1024 { break }; d *= 2 }
            for div in divs {
                for i in stride(from: 1, to: div, by: 1) {
                    let t = self.bucketed(self.duration * Double(i) / Double(div))
                    if seen.insert(Int(t * 10)).inserted { self.sweep.append(t) }
                }
            }
            self.pump()
        }
    }

    func request(_ t: Double) {
        let t = bucketed(t)
        queue.async {
            // Look ahead in the direction of travel (a few frames, spaced like the fill).
            if let last = self.lastRequest, last != t {
                let step = max(self.bucket, self.duration / 400) * (t > last ? 1 : -1)
                self.ahead = (1...4).map { self.bucketed(t + step * Double($0)) }
                    .filter { $0 >= 0 && $0 <= self.duration && self.cached($0) == nil }
            }
            self.lastRequest = t
            if let hit = self.cached(t) {
                self.send(t, hit)
                self.pump()
                return
            }
            self.pending = t
            self.pump()
        }
    }

    func shutdown() {
        queue.async {
            self.failed = true
            self.close()
        }
    }

    deinit { close() }

    // MARK: Queue-only

    private func open(url: String, headers: [String: String]) {
        var opts: OpaquePointer?
        if !headers.isEmpty {
            av_dict_set(&opts, "headers", headers.map { "\($0.key): \($0.value)\r\n" }.joined(), 0)
        }
        av_dict_set(&opts, "user_agent", "Encore/1.0", 0)
        av_dict_set(&opts, "rw_timeout", "20000000", 0) // µs
        av_dict_set(&opts, "reconnect", "1", 0)
        // Reuse one keep-alive connection for every jump instead of a new HTTPS handshake
        // with the debrid server each time.
        av_dict_set(&opts, "multiple_requests", "1", 0)
        defer { av_dict_free(&opts) }

        var ctx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&ctx, url, nil, &opts) >= 0, let ctx else { failed = true; return }
        format = ctx
        guard avformat_find_stream_info(ctx, nil) >= 0 else { failed = true; return }
        streamIndex = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard streamIndex >= 0, let stream = ctx.pointee.streams[Int(streamIndex)],
              let codec = avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id),
              let dec = avcodec_alloc_context3(codec) else { failed = true; return }
        decoder = dec
        guard avcodec_parameters_to_context(dec, stream.pointee.codecpar) >= 0 else { failed = true; return }
        dec.pointee.thread_count = 0 // automatic
        // Hardware decoding (VideoToolbox), as the player uses: a 4K HEVC keyframe takes
        // a few ms instead of a few hundred. Falls back to software if unavailable.
        var hw: UnsafeMutablePointer<AVBufferRef>?
        if av_hwdevice_ctx_create(&hw, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 {
            dec.pointee.hw_device_ctx = hw
        }
        dec.pointee.skip_loop_filter = AVDISCARD_ALL // a little softer, a lot faster; it's a thumbnail
        guard avcodec_open2(dec, codec, nil) >= 0 else { failed = true; return }
        // Only the video track is read.
        for i in 0..<Int(ctx.pointee.nb_streams) where i != Int(streamIndex) {
            ctx.pointee.streams[i]?.pointee.discard = AVDISCARD_ALL
        }
        packet = av_packet_alloc()
        decoded = av_frame_alloc()
        scaler = sws_alloc_context()
        ready = true
        pump()
    }

    private func close() {
        if scaler != nil { sws_free_context(&scaler) }
        scaler = nil
        if decoded != nil { av_frame_free(&decoded) }
        if packet != nil { av_packet_free(&packet) }
        if decoder != nil { avcodec_free_context(&decoder) }
        if format != nil { avformat_close_input(&format) }
    }

    private func pump() {
        guard ready, !failed, !busy else { return }
        // Hover requests first; otherwise the next uncached background position.
        let t: Double
        if let p = pending {
            t = p
            pending = nil
        } else if let next = nextAhead() {
            t = next
        } else if let next = nextSweep() {
            t = next
        } else {
            return
        }
        busy = true
        defer { busy = false }
        if let (img, at) = frame(at: t) {
            cacheLock.lock()
            cache[Int(t * 10)] = (img, at)
            cacheLock.unlock()
            send(t, img)
        }
        if pending != nil || !ahead.isEmpty || !sweep.isEmpty { queue.async { self.pump() } }
    }

    private func nextAhead() -> Double? {
        while !ahead.isEmpty {
            let t = ahead.removeFirst()
            if cached(t) == nil { return t }
        }
        return nil
    }

    private func nextSweep() -> Double? {
        while !sweep.isEmpty {
            let t = sweep.removeFirst()
            if cached(t) == nil { return t }
        }
        return nil
    }

    private func send(_ t: Double, _ img: CGImage) {
        let deliver = self.deliver
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(t, img) } }
    }

    /// The keyframe at or before `t`, decoded and scaled; with its real time in seconds.
    private func frame(at t: Double) -> (CGImage, Double)? {
        guard let fmt = format, let dec = decoder, let pkt = packet, let frm = decoded,
              let stream = fmt.pointee.streams[Int(streamIndex)] else { return nil }
        let tb = stream.pointee.time_base
        let secondsPerTick = Double(tb.num) / Double(tb.den)
        let start = stream.pointee.start_time == Int64.min ? 0 : stream.pointee.start_time
        let target = start + Int64(t / secondsPerTick)
        guard av_seek_frame(fmt, streamIndex, target, AVSEEK_FLAG_BACKWARD) >= 0 else { return nil }
        avcodec_flush_buffers(dec)

        var got = false
        var reads = 0
        while !got, reads < 2000, av_read_frame(fmt, pkt) >= 0 {
            reads += 1
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.stream_index == streamIndex, avcodec_send_packet(dec, pkt) >= 0 else { continue }
            if avcodec_receive_frame(dec, frm) == 0 { got = true }
        }
        if !got {
            // End of stream: drain whatever the decoder still holds.
            avcodec_send_packet(dec, nil)
            got = avcodec_receive_frame(dec, frm) == 0
        }
        guard got else { return nil }
        defer { av_frame_unref(frm) }
        // A hardware frame lives on the GPU: copy it into memory for scaling.
        var source = frm
        var cpuFrame: UnsafeMutablePointer<AVFrame>?
        defer { if cpuFrame != nil { av_frame_free(&cpuFrame) } }
        if frm.pointee.hw_frames_ctx != nil {
            cpuFrame = av_frame_alloc()
            guard let cpu = cpuFrame, av_hwframe_transfer_data(cpu, frm, 0) >= 0 else { return nil }
            cpu.pointee.sample_aspect_ratio = frm.pointee.sample_aspect_ratio
            cpu.pointee.color_primaries = frm.pointee.color_primaries
            cpu.pointee.color_trc = frm.pointee.color_trc
            cpu.pointee.colorspace = frm.pointee.colorspace
            cpu.pointee.color_range = frm.pointee.color_range
            source = cpu
        }

        let pts = frm.pointee.best_effort_timestamp == Int64.min ? target : frm.pointee.best_effort_timestamp
        let at = Double(pts - start) * secondsPerTick

        // Display shape (honours anamorphic pixels), scaled to the preview width.
        let sar = source.pointee.sample_aspect_ratio
        let pixelAspect = sar.num > 0 && sar.den > 0 ? Double(sar.num) / Double(sar.den) : 1
        let displayW = Double(source.pointee.width) * pixelAspect
        let w = Self.width
        let h = max(2, Int(Double(w) * Double(source.pointee.height) / max(displayW, 1)) & ~1)

        guard let out = av_frame_alloc() else { return nil }
        var outPtr: UnsafeMutablePointer<AVFrame>? = out
        defer { av_frame_free(&outPtr) }
        out.pointee.width = Int32(w)
        out.pointee.height = Int32(h)
        out.pointee.format = AV_PIX_FMT_BGRA.rawValue
        guard av_frame_get_buffer(out, 0) >= 0, sws_scale_frame(scaler, out, source) >= 0,
              let base = out.pointee.data.0 else { return nil }
        let stride = Int(out.pointee.linesize.0)
        let data = Data(bytes: base, count: stride * h) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }
        return (image, at)
    }
}
