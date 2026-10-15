import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 34) {
                    if !app.heroes.isEmpty {
                        HeroCarousel(items: app.heroes, height: max(480, geo.size.height * 0.74))
                    } else {
                        Color.clear.frame(height: 110)
                    }

                    let continuing = app.continueRow
                    if !continuing.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Continue Watching")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .glass(cornerRadius: 10)
                                .padding(.horizontal, Theme.gutter)
                            PagedRow(items: continuing, itemWidth: Theme.landscapeWidth, spacing: 22) { ContinueCard(entry: $0) }
                        }
                    }

                    if !app.upcoming.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Upcoming")
                            PagedRow(items: app.upcoming, itemWidth: 260, verticalPadding: 12) { UpcomingCard(item: $0) }
                        }
                    }

                    // Netflix-style: Top Picks, then two rows named after titles you watched.
                    if app.settings.showRecommendations {
                        ForEach(recommendationRows, id: \.title) { group in
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeader(title: group.title)
                                PagedRow(items: group.items, itemWidth: Theme.posterWidth) { rec in
                                    PosterCard(meta: rec.meta, onNotInterested: { app.notInterested(in: rec) })
                                }
                            }
                        }
                    }

                    ForEach(app.rows) { row in
                        CatalogRowView(row: row)
                    }
                    BrokenCatalogsNote()
                    Color.clear.frame(height: 40)
                }
            }
            .scrollIndicators(.never)
        }
        .task {
            await app.loadUpcoming()
            if app.settings.showRecommendations { await app.loadRecommendations() }
        }
    }
}

/// An unaired episode: when it airs, and which one.
extension HomeView {
    /// Recommendations grouped by the watched title behind them, strongest first; at most
    /// 3 rows, and only titles with a few picks get a row of their own.
    /// "Top Picks for You" (the 15 strongest overall), then up to two "Because You
    /// Watched …" rows from the rest, so posters don't repeat. If the rest is too thin
    /// for a row, that row may reuse top picks.
    var recommendationRows: [(title: String, items: [Recommendation])] {
        let all = app.recommendations
        guard !all.isEmpty else { return [] }
        let top = Array(all.prefix(15))
        let rest = Array(all.dropFirst(15))
        func groups(_ recs: [Recommendation]) -> [(String, [Recommendation])] {
            var order: [String] = []
            var byBecause: [String: [Recommendation]] = [:]
            for r in recs {
                if byBecause[r.because] == nil { order.append(r.because) }
                byBecause[r.because, default: []].append(r)
            }
            return order.compactMap { k in byBecause[k].map { (k, $0) } }.filter { $0.1.count >= 3 }
        }
        var because = groups(rest)
        if because.count < 2 {
            for g in groups(all) where !because.contains(where: { $0.0 == g.0 }) { because.append(g) }
        }
        return [("Top Picks for You", top)] + because.prefix(2).map { ("Because You Watched \($0.0)", $0.1) }
    }
}

struct UpcomingCard: View {
    let item: UpcomingEpisode
    @Environment(AppState.self) private var app

    var body: some View {
        Button { app.open(item.meta) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: item.meta.background ?? item.video.thumbnail ?? item.meta.poster, maxPixel: 600)
                        .frame(width: 260, height: 146)
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                    Text([airs, item.runtime.map { $0 >= 60 ? "\($0 / 60)h \($0 % 60)m" : "\($0)m" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                }
                .frame(width: 260, height: 146)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .hoverLift(scale: 1.04)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.meta.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(episodeLine).font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                .frame(width: 260, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { DropButton(metaId: item.meta.id) }
    }

    private var episodeLine: String {
        let v = item.video
        let label = v.season.flatMap { s in v.episode.map { "S\(s) • E\($0)" } } ?? ""
        return [label, v.title.isEmpty ? nil : v.title].compactMap { $0 }.joined(separator: " - ")
    }

    /// "Today", "Tomorrow", "Friday" within a week, else "Oct 24".
    private var airs: String {
        guard let date = item.video.released else { return "Upcoming" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: date)).day ?? 99
        let f = DateFormatter()
        f.dateFormat = days < 7 ? "EEEE" : "MMM d"
        return f.string(from: date) + " · " + daysUntil(date)
    }
}

struct HeroCarousel: View {
    let items: [Meta]
    let height: CGFloat
    @Environment(AppState.self) private var app
    @State private var index = 0
    @State private var hovering = false
    @State private var onScreen = true

    private let timer = Timer.publish(every: 9, on: .main, in: .common).autoconnect()

    var body: some View {
        let meta = items[min(index, items.count - 1)]
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .frame(height: height)
                .overlay { RemoteImage(url: meta.background, maxPixel: 2600) }
                .clipped()
                .overlay(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .leading, endPoint: .init(x: 0.6, y: 0.5)))
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .id(meta.id)
                .transition(.opacity)

            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if meta.logo != nil {
                        RemoteImage(url: meta.logo, contentMode: .fit, alignment: .bottomLeading, maxPixel: 900)
                            .frame(maxWidth: 380, maxHeight: 130, alignment: .bottomLeading)
                    } else {
                        Text(meta.name)
                            .font(.system(size: 52, weight: .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                }
                .shadow(color: .black.opacity(0.4), radius: 10)

                HStack(spacing: 8) {
                    if let r = meta.imdbRating { Text(r).foregroundStyle(Theme.rating).fontWeight(.bold) }
                    ForEach([meta.year, meta.genres.first, meta.runtime].compactMap { $0 }, id: \.self) { part in
                        Text("·").foregroundStyle(Theme.textTertiary)
                        Text(part)
                    }
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))

                if let d = meta.description {
                    Text(d)
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(2)
                        .frame(maxWidth: 560, alignment: .leading)
                }

                if !meta.cast.isEmpty {
                    HStack(spacing: 10) {
                        HStack(spacing: -10) {
                            ForEach(meta.cast.prefix(3), id: \.self) { m in
                                ZStack {
                                    Circle().fill(Color.white.opacity(0.15))
                                    if m.photo != nil { RemoteImage(url: m.photo, maxPixel: 90) }
                                    else { Image(systemName: "person.fill").foregroundStyle(.white.opacity(0.6)) }
                                }
                                .frame(width: 30, height: 30)
                                .clipShape(Circle())
                                .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1.5))
                            }
                        }
                        Text(meta.cast.prefix(3).map(\.name).joined(separator: ", "))
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }

                Button { app.open(meta) } label: {
                    Text(meta.type == "movie" ? "Go to Movie" : "Go to Show")
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .padding(.top, 6)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 64)
            // Swapped, not cross-faded: SwiftUI redrew fading text on the CPU every frame,
            // which stalled the page at each slide change.
            .animation(nil, value: meta.id)

            // Page dots and arrows.
            HStack(spacing: 6) {
                ForEach(items.indices, id: \.self) { i in
                    Capsule()
                        .fill(.white.opacity(i == index ? 0.95 : 0.35))
                        .frame(width: i == index ? 20 : 6, height: 6)
                        .onTapGesture { withAnimation { index = i } }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 26)

            if hovering {
                HStack {
                    arrow("chevron.left") { step(-1) }
                    Spacer()
                    arrow("chevron.right") { step(1) }
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hovering = h } }
        // Only rotates while on screen: changing slides off screen still cross-faded the
        // window's whole background mid-scroll.
        .onReceive(timer) { _ in if !hovering, onScreen { step(1) } }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: index) { app.ambientImage = items[index].background }
    }

    private func step(_ d: Int) {
        withAnimation(.easeInOut(duration: 0.6)) {
            index = (index + d + items.count) % items.count
        }
    }

    private func arrow(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 44, height: 44)
                .glass()
        }
        .buttonStyle(.plain)
    }
}

struct CatalogRowView: View {
    let row: CatalogRowModel
    @Environment(AppState.self) private var app

    private var ranked: Bool {
        let n = row.def.name.lowercased()
        return n.contains("top 10") || n.contains("trending") || n.contains("popular")
    }

    /// Failed or empty: the row steps aside (it's listed at the bottom of Home instead).
    private var broken: Bool {
        switch row.state {
        case .failed: true
        case .loaded: row.items.isEmpty
        default: false
        }
    }

    var body: some View {
        if broken {
            Color.clear.frame(height: 0)
                .task { app.prefetchRows(after: row) }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: row.def.name) { app.open(row.def) }
            switch row.state {
            case .failed(let message):
                HStack(spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                    Button("Retry") { row.retry(app.client) }
                        .buttonStyle(PillButtonStyle())
                        .controlSize(.small)
                }
                .padding(.horizontal, Theme.gutter)
                .frame(height: Theme.posterRowHeight, alignment: .leading)
            case .loaded where row.items.isEmpty:
                Text("Nothing here right now.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.gutter)
                    .frame(height: Theme.posterRowHeight, alignment: .leading)
            case _ where !row.items.isEmpty:
                let items = Array(row.items.prefix(40))
                PagedRow(items: items, itemWidth: Theme.posterWidth) { meta in
                    let i = items.firstIndex { $0.id == meta.id } ?? 99
                    PosterCard(meta: meta, rank: ranked && i < 10 ? i + 1 : nil)
                }
            default:
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        if row.items.isEmpty {
                            // Same size as real cards (caption space included), so a row
                            // filling in doesn't change height and shift the page mid-scroll.
                            ForEach(0..<8, id: \.self) { _ in
                                VStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.white.opacity(0.06))
                                        .frame(width: Theme.posterWidth, height: Theme.posterHeight)
                                    Color.clear.frame(width: Theme.posterWidth, height: Theme.posterCaptionHeight)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.vertical, 14)
                }
            }
        }
        .task {
            // Start the next few rows too, so they've usually arrived before they scroll in.
            app.prefetchRows(after: row)
            await row.loadIfNeeded(app.client)
        }
    }
}

/// "See All": every item in one catalog, paging further as you scroll.
struct CatalogGridView: View {
    let def: CatalogDef
    @Environment(AppState.self) private var app

    var body: some View {
        let row = app.row(for: def)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BackBar(title: def.name, subtitle: def.displayType)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.posterWidth, maximum: Theme.posterWidth + 10), spacing: 22, alignment: .top)],
                          alignment: .leading, spacing: 26) {
                    ForEach(row.items) { meta in
                        PosterCard(meta: meta)
                            .onAppear {
                                if meta.id == row.items.last?.id { Task { await row.loadMore(app.client) } }
                            }
                    }
                }
                .padding(.horizontal, Theme.gutter)
                if row.state == .loading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            .padding(.bottom, 40)
        }
        .task { await row.loadIfNeeded(app.client) }
    }
}

struct BackBar: View {
    let title: String
    var subtitle: String? = nil
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 16) {
            Button { app.back() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 40, height: 40)
                    .glass()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 28, weight: .bold))
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.textTertiary) }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 90)
    }
}

/// The catalogs that failed to load or came back empty, listed once at the bottom of
/// Home instead of as broken rows, with a way to try them again.
struct BrokenCatalogsNote: View {
    @Environment(AppState.self) private var app

    private var broken: [CatalogRowModel] {
        app.rows.filter { row in
            switch row.state {
            case .failed: true
            case .loaded: row.items.isEmpty
            default: false
            }
        }
    }

    var body: some View {
        let rows = broken
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(rows.count == 1 ? "1 catalog couldn't be loaded" : "\(rows.count) catalogs couldn't be loaded")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Retry") { for row in rows { row.retry(app.client, force: true) } }
                        .buttonStyle(PillButtonStyle())
                        .controlSize(.small)
                }
                Text(rows.map { row in
                    if case .failed(let why) = row.state { return "\(row.def.name) (\(why))" }
                    return "\(row.def.name) (came back empty)"
                }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(4)
                Text("They're hidden from Home. You can turn catalogs off in Settings → Home Screen.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)
            .glass(cornerRadius: 14, tint: .black.opacity(0.3))
            .padding(.horizontal, Theme.gutter)
        }
    }
}
