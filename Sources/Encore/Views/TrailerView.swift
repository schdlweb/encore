import AppKit
import SwiftUI
import WebKit

/// Full-window YouTube trailer, played through YouTube's embed player.
struct TrailerOverlay: View {
    let youTubeId: String
    let title: String
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
                .onTapGesture { app.trailer = nil }
            VStack(spacing: 16) {
                HStack {
                    Text("\(title) · Trailer").font(.system(size: 18, weight: .bold))
                    Spacer()
                    Button("Open in YouTube") {
                        if let u = URL(string: "https://www.youtube.com/watch?v=\(youTubeId)") { NSWorkspace.shared.open(u) }
                    }
                    .buttonStyle(PillButtonStyle())
                    Button { app.trailer = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 36, height: 36).glass()
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                GeometryReader { g in
                    let w = min(g.size.width, g.size.height * 16 / 9)
                    YouTubeEmbed(videoId: youTubeId)
                        .frame(width: w, height: w * 9 / 16)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(50)
        }
    }
}

struct YouTubeEmbed: NSViewRepresentable {
    let videoId: String

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.isElementFullscreenEnabled = true
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        load(web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    static func dismantleNSView(_ web: WKWebView, coordinator: ()) {
        web.loadHTMLString("", baseURL: nil) // stops audio immediately
    }

    private func load(_ web: WKWebView) {
        // YouTube's embed refuses to play without a referring origin, so the page is
        // given an https base URL.
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width">
        <style>html,body{margin:0;height:100%;background:#000}iframe{border:0;width:100%;height:100%}</style>
        </head><body>
        <iframe src="https://www.youtube-nocookie.com/embed/\(videoId)?autoplay=1&rel=0&modestbranding=1&playsinline=1"
          allow="autoplay; encrypted-media; fullscreen; picture-in-picture" allowfullscreen></iframe>
        </body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://encore.app"))
    }
}
