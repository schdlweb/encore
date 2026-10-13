import AppKit
import ImageIO
import SwiftUI

/// Fetches artwork and decodes it at display size, off the main thread.
///
/// AsyncImage decodes full-size images (posters are often 1000–3000 px) on the main
/// thread and forgets them when a row scrolls away, which is what made Home stutter.
/// Here each image is downsampled once with ImageIO and kept in memory; URLCache
/// keeps the original bytes on disk.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, NSImage>()
    private let session: URLSession
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let lock = NSLock()

    private init() {
        memory.totalCostLimit = 400 << 20
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache.shared
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: cfg)
    }

    private func key(_ url: URL, _ maxPixel: Int) -> String { "\(maxPixel)|\(url.absoluteString)" }

    /// Fetches and prepares images in the background so they're ready before they're shown.
    func prefetch(_ urls: [String], maxPixel: Int) {
        for raw in urls {
            guard let url = URL(string: raw), cached(url, maxPixel: maxPixel) == nil else { continue }
            Task.detached(priority: .utility) { _ = await self.image(url, maxPixel: maxPixel) }
        }
    }

    /// Memory-cache hit only; lets a view show its image on the first frame.
    func cached(_ url: URL, maxPixel: Int) -> NSImage? {
        memory.object(forKey: key(url, maxPixel) as NSString)
    }

    func image(_ url: URL, maxPixel: Int) async -> NSImage? {
        let k = key(url, maxPixel)
        if let hit = memory.object(forKey: k as NSString) { return hit }

        lock.lock()
        if let running = inFlight[k] {
            lock.unlock()
            return await running.value
        }
        let task = Task.detached(priority: .userInitiated) { [session] () -> NSImage? in
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        inFlight[k] = task
        lock.unlock()

        let img = await task.value
        lock.lock()
        inFlight[k] = nil
        lock.unlock()
        if let img {
            let cost = Int(img.size.width * img.size.height * 4)
            memory.setObject(img, forKey: k as NSString, cost: cost)
        }
        return img
    }

    private static func downsample(_ data: Data, maxPixel: Int) -> NSImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true, // decode now, not on the main thread at draw time
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts) else { return nil }
        // Redraw into the display's native format (sRGB, premultiplied BGRA) here, off the
        // main thread. Otherwise Core Animation converts each image's colors on the main
        // thread the first time it's shown, which is what made the first scroll stutter.
        let cg = displayReady(decoded) ?? decoded
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func displayReady(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}

/// Artwork view backed by ImagePipeline. `maxPixel` is the longest side to decode;
/// pick roughly 2x the on-screen size for Retina.
struct RemoteImage: View {
    let url: String?
    var contentMode: ContentMode = .fill
    /// Where a `.fit` image sits inside its frame (logos hug the bottom-left).
    var alignment: Alignment = .center
    var maxPixel: Int = 600
    /// Tried when `url` fails to load (dead link, 404).
    var fallbackURL: String? = nil
    /// Whether to draw a grey box while there's no image (off when something sits underneath).
    var showsEmpty = true

    @State private var image: NSImage?

    init(url: String?, contentMode: ContentMode = .fill, alignment: Alignment = .center, maxPixel: Int = 600,
         fallbackURL: String? = nil, showsEmpty: Bool = true) {
        self.url = url
        self.contentMode = contentMode
        self.alignment = alignment
        self.maxPixel = maxPixel
        self.fallbackURL = fallbackURL
        self.showsEmpty = showsEmpty
        _image = State(initialValue: url.flatMap(URL.init(string:)).flatMap { ImagePipeline.shared.cached($0, maxPixel: maxPixel) })
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .transition(.opacity)
            } else if contentMode == .fill, showsEmpty {
                Rectangle().fill(Color.white.opacity(0.06))
            }
        }
        .task(id: [url, fallbackURL].map { $0 ?? "" }.joined(separator: "|")) {
            guard let url, let u = URL(string: url) else { image = nil; return }
            if let hit = ImagePipeline.shared.cached(u, maxPixel: maxPixel) {
                image = hit
                return
            }
            var loaded = await ImagePipeline.shared.image(u, maxPixel: maxPixel)
            if loaded == nil, let f = fallbackURL.flatMap(URL.init(string:)) {
                loaded = await ImagePipeline.shared.image(f, maxPixel: maxPixel)
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}
