import AppKit
import SwiftUI

/// "en" and "eng" both become "eng" so addon and file languages compare.
func normalizeLang(_ code: String) -> String {
    let c = code.lowercased()
    return Locale.LanguageCode(c).identifier(.alpha3) ?? c
}

/// Seek bar with buffered range, intro/credits marks, and a hover preview bubble
/// showing a thumbnail of that point (when previews are on) and its time.
struct Scrubber: View {
    let position: Double
    let duration: Double
    let buffered: Double
    var segments: [SkipSegment] = []
    var preview: CGImage?
    var previewsEnabled = true
    /// The exact frame is still being made: a small spinner on whatever's shown.
    var previewLoading = false
    /// The real time of the frame shown (the bubble's label); nil uses the pointer's time.
    var previewLabel: Double? = nil
    let onSeek: (Double, Bool) -> Void
    var onHover: (Double?) -> Void = { _ in }
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let frac = duration > 0 ? min(1, max(0, position / duration)) : 0
            let buf = duration > 0 ? min(1, max(0, buffered / duration)) : 0
            let active = hoverX != nil
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(0.35)).frame(width: w * buf)
                // Marks clamped to the timeline: segment times can run past a shorter cut.
                ForEach(segments.filter { duration > 0 && $0.start < duration }) { seg in
                    Rectangle()
                        .fill(Theme.accent.opacity(0.55))
                        .frame(width: max(2, w * (min(seg.end, duration) - seg.start) / duration))
                        .offset(x: w * seg.start / duration)
                }
                Capsule().fill(.white).frame(width: w * frac)
                Circle()
                    .fill(.white)
                    .frame(width: active ? 14 : 0, height: active ? 14 : 0)
                    .offset(x: w * frac - (active ? 7 : 0))
                    .shadow(radius: 3)
            }
            .frame(width: w, height: active ? 8 : 5, alignment: .leading)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .bottomLeading) {
                // Infuse-style: the frame sits on the playbar just above the timeline,
                // following the pointer, kept within the panel (which reaches past the
                // timeline by about the width of the time labels).
                if let x = hoverX, duration > 0 {
                    bubble(time: previewsEnabled ? (previewLabel ?? value(at: x, width: w)) : value(at: x, width: w))
                        .offset(x: min(max(-62, x - bubbleWidth / 2), w + 62 - bubbleWidth), y: -16)
                        .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        hoverX = v.location.x
                        let t = value(at: v.location.x, width: w)
                        onSeek(t, false)
                        onHover(t)
                    }
                    .onEnded { v in onSeek(value(at: v.location.x, width: w), true) }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    hoverX = loc.x
                    onHover(value(at: loc.x, width: w))
                case .ended:
                    hoverX = nil
                    onHover(nil)
                }
            }
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .frame(height: 20)
    }

    private var bubbleWidth: CGFloat { previewsEnabled ? 240 : 80 }

    /// The frame's own shape (2.39:1 films stay wide), 16:9 until the first frame arrives.
    private var previewAspect: CGFloat {
        guard let preview, preview.height > 0 else { return 16 / 9 }
        return CGFloat(preview.width) / CGFloat(preview.height)
    }

    private func bubble(time: Double) -> some View {
        VStack(spacing: 5) {
            Text(formatClock(time))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 3)
            if previewsEnabled {
                ZStack {
                    Color.black
                    if let preview {
                        Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        if previewLoading {
                            // A stand-in is showing: quiet spinner in the corner.
                            ProgressView().controlSize(.mini).tint(.white)
                                .padding(6)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        }
                    } else {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                .frame(width: bubbleWidth, height: bubbleWidth / previewAspect)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.55), radius: 14, y: 6)
            }
        }
        .frame(width: bubbleWidth)
    }

    private func value(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(0, x / width), 1)) * duration
    }
}

// MARK: Menus

// The menus are separate views compared only on what they show. Inside the player's
// panel they would be rebuilt with every time update during playback, and rebuilding an
// open menu shifts its highlight away from the cursor and closes its submenus.


extension View {
    /// The floating glass panel the playbar (and the arrow-key timeline) sit in.
    func playerPanel(onHover: ((Bool) -> Void)? = nil) -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(width: 520)
            // Drawn as a background (not a clip) so the scrub preview can rise above the panel.
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.3))
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
            .onHover { onHover?($0) }
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity)
    }

}

/// Speed, source and media info live behind one gear, as in Infuse.
struct GearMenu: View, Equatable {
    let speed: Double
    let sources: [StreamItem]
    let current: StreamItem
    let showInfo: Bool
    let setSpeed: (Double) -> Void
    let switchTo: (StreamItem) -> Void
    let toggleInfo: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.speed == b.speed && a.sources == b.sources && a.current == b.current && a.showInfo == b.showInfo
    }

    var body: some View {
        NativeMenuButton(icon: "gearshape.fill", help: "Speed, source, media info", entries: entries)
            .onAppear {
                if ProcessInfo.processInfo.environment["ENCORE_DUMP_MENUS"] != nil { print("[menu]\n" + NativeMenu.describe(entries())); fflush(stdout) }
            }
    }

    private func entries() -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .submenu("Speed (\(String(format: "%gx", speed)))", [0.5, 0.75, 1, 1.25, 1.5, 2].map { s in
                .item(s == 1 ? "Normal" : String(format: "%gx", s), checked: abs(speed - s) < 0.01) { setSpeed(s) }
            }),
        ]
        if sources.count > 1 {
            entries.append(.submenu("Source", sources.prefix(25).map { s in
                .item(String(s.oneLine.prefix(90)), checked: s.url == current.url) { switchTo(s) }
            }))
        }
        entries += [.separator, .item(showInfo ? "Hide Media Info" : "Media Info") { toggleInfo() }]
        return entries
    }
}

struct AudioMenu: View, Equatable {
    let tracks: [MediaTrack]
    let selected: Int?
    let select: (Int) -> Void
    let setDelay: (Double) -> Void

    static func == (a: Self, b: Self) -> Bool { a.tracks == b.tracks && a.selected == b.selected }

    var body: some View {
        NativeMenuButton(icon: "waveform", help: "Audio tracks") {
            [.header("Audio")]
                + tracks.map { t in
                    .item(t.label + (t.detail.isEmpty ? "" : "  —  \(t.detail)"), checked: selected == t.id) { select(t.id) }
                }
                + [.separator,
                   .submenu("Audio Offset", [-0.5, -0.25, -0.1, 0, 0.1, 0.25, 0.5].map { d in
                       .item(d == 0 ? "None" : String(format: "%+.2f s", d)) { setDelay(d) }
                   })]
        }
    }
}

struct SubtitleMenu: View, Equatable {
    let tracks: [MediaTrack]
    let selected: Int?
    let select: (Int?) -> Void
    let setDelay: (Double) -> Void

    static func == (a: Self, b: Self) -> Bool { a.tracks == b.tracks && a.selected == b.selected }

    var body: some View {
        NativeMenuButton(icon: "captions.bubble", help: "Subtitles") {
            [.header("Subtitles"), .item("Off", checked: selected == nil) { select(nil) }]
                + tracks.map { t in
                    .item(t.label + (t.detail.isEmpty ? "" : "  —  \(t.detail)"), checked: selected == t.id) { select(t.id) }
                }
                + [.separator,
                   .submenu("Subtitle Offset", [-2.0, -1, -0.5, 0, 0.5, 1, 2].map { d in
                       .item(d == 0 ? "None" : String(format: "%+.1f s", d)) { setDelay(d) }
                   })]
        }
    }
}
