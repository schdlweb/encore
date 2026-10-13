import SwiftUI

/// A horizontal row with ‹ › buttons for mouse users: they show while the pointer is over
/// the row, scroll it a screenful at a time, and hide at either end. Trackpad scrolling
/// works as before.
struct PagedRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    /// Width of one card, to know how many fit on screen.
    let itemWidth: CGFloat
    var spacing: CGFloat = 18
    var verticalPadding: CGFloat = 14
    @ViewBuilder let content: (Item) -> Content

    @State private var leading: Item.ID?
    @State private var hovering = false
    /// The row's width, read only when a button is clicked: a plain reference, so
    /// measuring it never redraws or re-lays-out the row.
    @State private var size = SizeBox()

    final class SizeBox { var width: CGFloat = 1200 }

    private var leadingIndex: Int { leading.flatMap { id in items.firstIndex { $0.id == id } } ?? 0 }
    private var perPage: Int { max(1, Int((size.width - Theme.gutter * 2 + spacing) / (itemWidth + spacing))) }
    private var canGoBack: Bool { leadingIndex > 0 }
    private var canGoForward: Bool { leadingIndex + perPage < items.count }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: spacing) {
                ForEach(items) { item in content(item).id(item.id) }
            }
            .scrollTargetLayout()
            .padding(.vertical, verticalPadding)
        }
        .contentMargins(.horizontal, Theme.gutter, for: .scrollContent)
        .scrollPosition(id: $leading, anchor: .leading)
        .background(GeometryReader { g in
            let _ = { size.width = g.size.width }()
            Color.clear
        })
        // Built only while the pointer is over this row.
        .overlay(alignment: .leading) { if showArrows { arrow("chevron.left", visible: canGoBack) { page(-1) } } }
        .overlay(alignment: .trailing) { if showArrows { arrow("chevron.right", visible: canGoForward) { page(1) } } }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    private var showArrows: Bool { hovering || ProcessInfo.processInfo.environment["ENCORE_SHOW_ARROWS"] != nil }

    private func page(_ direction: Int) {
        let target = min(max(0, leadingIndex + direction * perPage), max(0, items.count - perPage))
        guard items.indices.contains(target) else { return }
        ScrollActivity.scrolled(for: 0.5)
        withAnimation(.easeInOut(duration: 0.45)) { leading = items[target].id }
    }

    private func arrow(_ icon: String, visible: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.4), radius: 8)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.bottom, 24) // centred on the artwork, not the captions under it
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .transition(.opacity)
    }
}
