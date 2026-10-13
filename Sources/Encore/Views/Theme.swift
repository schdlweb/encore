import CoreImage
import SwiftUI

enum Theme {
    static let base = Color(red: 0.035, green: 0.05, blue: 0.075)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.42)
    static let accent = Color(red: 0.62, green: 0.84, blue: 0.98)
    static let rating = Color(red: 0.35, green: 0.85, blue: 0.45)
    static let gutter: CGFloat = 48
    static let posterWidth: CGFloat = 150
    static var posterHeight: CGFloat { posterWidth * 1.5 }
    /// Title and year lines under a poster.
    static let posterCaptionHeight: CGFloat = 36
    /// A Home row's content: poster, gap, caption, and the scroll padding around them.
    static var posterRowHeight: CGFloat { posterHeight + 8 + posterCaptionHeight + 28 }
    static let landscapeWidth: CGFloat = 300
    static var landscapeHeight: CGFloat { landscapeWidth * 9 / 16 }
}

/// Frosted glass capsule/rounded background used by chips, the nav bar and buttons.
struct Glass: ViewModifier {
    var cornerRadius: CGFloat? = nil
    var tint: Color = .white.opacity(0.08)

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                shape.fill(tint)
                shape.stroke(Color.white.opacity(0.14), lineWidth: 0.75)
            }
            .clipShape(shape)
    }

    private var shape: AnyShape {
        if let cornerRadius { AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)) }
        else { AnyShape(Capsule()) }
    }
}

extension View {
    func glass(cornerRadius: CGFloat? = nil, tint: Color = .white.opacity(0.08)) -> some View {
        modifier(Glass(cornerRadius: cornerRadius, tint: tint))
    }
}

/// Lift-on-hover, the Mac stand-in for Apple TV's focus effect.
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.07
    var cornerRadius: CGFloat = 12
    /// Runs when the card lifts (e.g. to preload its page), sharing the one hover tracker
    /// rather than adding another: every tracker is updated by AppKit as the page scrolls.
    var onLift: (() -> Void)? = nil
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovering ? 0.55 : 0), lineWidth: 1.5)
            }
            // The shadow exists only while lifted: a zero-size shadow on every poster still
            // cost a shadow pass per card per frame while scrolling.
            .background {
                if hovering {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black)
                        .shadow(color: .black.opacity(0.55), radius: 22, y: 14)
                        .transition(.opacity)
                }
            }
            .scaleEffect(hovering ? scale : 1)
            .zIndex(hovering ? 1 : 0)
            // Quick: a slow spring made the lifted card trail a fast-moving pointer by a card
            // or two. Lifting takes 0.12 s, dropping 0.08 s.
            .animation(hovering ? .easeOut(duration: 0.12) : .easeIn(duration: 0.08), value: hovering)
            // Movement over the card (not just entering it), so the card that ends up under
            // the pointer after a scroll lifts on the next nudge of the mouse.
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    // Cards sliding under a still pointer during a scroll don't lift.
                    if !hovering, !ScrollActivity.isScrolling { hovering = true; onLift?() }
                case .ended:
                    if hovering { hovering = false }
                }
            }
            // When a scroll (or a row's ‹ › paging) settles, drop any lift: the card that
            // was lifted has usually moved out from under the pointer without being told.
            .onReceive(NotificationCenter.default.publisher(for: ScrollActivity.settled)) { _ in
                if hovering { hovering = false }
            }
    }
}

/// Whether the user is scrolling right now (trackpad, momentum or mouse wheel), so hover
/// effects can sit it out. Plain static state: nothing redraws when it changes.
@MainActor
enum ScrollActivity {
    private(set) static var isScrolling = false
    /// Posted when a scroll comes to rest.
    static let settled = Notification.Name("EncoreScrollSettled")
    private static var monitor: Any?
    private static var settle: DispatchWorkItem?

    /// For scrolls that aren't wheel/trackpad gestures (the rows' ‹ › buttons).
    static func scrolled(for seconds: Double) {
        isScrolling = true
        settle?.cancel()
        let work = DispatchWorkItem {
            isScrolling = false
            NotificationCenter.default.post(name: settled, object: nil)
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            isScrolling = true
            settle?.cancel()
            let work = DispatchWorkItem {
                isScrolling = false
                NotificationCenter.default.post(name: settled, object: nil)
            }
            settle = work
            // Momentum events keep arriving until the scroll stops; settle shortly after.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            return event
        }
    }
}

extension View {
    func hoverLift(scale: CGFloat = 1.07, cornerRadius: CGFloat = 12, onLift: (() -> Void)? = nil) -> some View {
        modifier(HoverLift(scale: scale, cornerRadius: cornerRadius, onLift: onLift))
    }
}

/// Pressable capsule button in the Apple TV style.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, glass, accent }
    var kind: Kind = .glass

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .foregroundStyle(kind == .primary ? Color.black : Color.white)
            .background {
                switch kind {
                case .primary: Capsule().fill(Color.white)
                case .accent: Capsule().fill(Theme.accent.opacity(0.85))
                case .glass: Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                }
            }
            .overlay { Capsule().strokeBorder(Color.white.opacity(kind == .glass ? 0.16 : 0), lineWidth: 0.75) }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct SectionHeader: View {
    let title: String
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let action {
                Button(action: action) {
                    HStack(spacing: 6) {
                        Text(title)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(title)
            }
        }
        .font(.system(size: 22, weight: .bold))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, Theme.gutter)
    }
}

struct RatingLabel: View {
    let rating: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill").font(.system(size: 9))
            Text(rating)
        }
    }
}

/// Blurred, dimmed artwork filling the window behind everything. The blur is baked
/// with Core Image from a small copy of the art, which is cheap and looks the same
/// everywhere (SwiftUI's blur filter at this radius is costly on every frame).
struct AmbientBackground: View {
    let image: String?
    @State private var blurred: NSImage?

    var body: some View {
        ZStack {
            Theme.base
            if let blurred {
                // Overlay on a clear view so the fill image can't widen the window's layout.
                Color.clear.overlay {
                    Image(nsImage: blurred)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .clipped()
                .opacity(0.6)
                .id(ObjectIdentifier(blurred))
                .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 1.2), value: blurred.map(ObjectIdentifier.init))
        .ignoresSafeArea()
        .task(id: image) {
            guard let image, let url = URL(string: image) else { return }
            if let img = await BlurCache.shared.image(for: url) { blurred = img }
        }
    }
}

actor BlurCache {
    static let shared = BlurCache()
    private var cache: [URL: NSImage] = [:]
    private let context = CIContext()

    func image(for url: URL) async -> NSImage? {
        if let hit = cache[url] { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let input = CIImage(data: data) else { return nil }
        // Shrink first: blurring 300px wide is plenty for a backdrop and very cheap.
        let scale = 300 / max(input.extent.width, 1)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Saturation baked in here rather than as a SwiftUI filter, which the GPU
        // re-applied to the whole window on every scrolled frame.
        let blurred = small.clampedToExtent()
            .applyingGaussianBlur(sigma: 18)
            .cropped(to: small.extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3])
        guard let cg = context.createCGImage(blurred, from: small.extent) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[url] = img
        return img
    }
}
