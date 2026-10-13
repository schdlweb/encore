import AppKit
import SwiftUI

struct PickerTarget: Identifiable {
    let meta: Meta
    let video: Video?
    var id: String { video?.id ?? meta.id }
}

struct DetailView: View {
    let preview: Meta
    @Environment(AppState.self) private var app
    @State private var episodeDetails = DiscoveryService.EpisodeDetails()
    @State private var full: Meta?
    @State private var season: Int?
    @State private var related: [DiscoveryService.Section] = []
    @State private var relatedLoading = true
    @State private var originalLanguage: String?
    @State private var episodeAnchor: String?
    @State private var fallbackCast: [CastMember] = []

    /// The addon only sends cast for anime; other titles use the TVmaze/Wikidata fallback.
    private var castList: [CastMember] { meta.cast.isEmpty ? fallbackCast : meta.cast }

    private var meta: Meta { full ?? preview }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    header(height: max(520, geo.size.height * 0.82))
                    if meta.isSeriesLike, !meta.videos.isEmpty { episodes }
                    if !castList.isEmpty { cast }
                    ForEach(related) { DiscoveryRow(section: $0) }
                    if relatedLoading {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Finding related titles…").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, Theme.gutter)
                    }
                    about
                    Color.clear.frame(height: 30)
                }
            }
            .scrollIndicators(.never)
        }
        .background(Theme.base.opacity(0.35))
        .task(id: preview.id) {
            app.ambientImage = preview.background ?? preview.poster
            full = await app.fullMeta(preview)
            if season == nil {
                let resume = app.resumeTarget(for: meta).video
                season = resume?.season ?? meta.seasons.first
                episodeAnchor = resume?.id
            }
            let current = meta
            app.prewarm(meta: current, video: app.resumeTarget(for: current).video)
            async let rel = DiscoveryService.related(to: current)
            async let lang = DiscoveryService.originalLanguage(of: current)
            async let extraCast = current.cast.isEmpty ? DiscoveryService.cast(for: current) : []
            async let details = current.isSeriesLike ? DiscoveryService.episodeDetails(for: current) : DiscoveryService.EpisodeDetails()
            fallbackCast = await extraCast
            related = await rel
            relatedLoading = false
            originalLanguage = await lang
            episodeDetails = await details
        }
    }

    // MARK: Header

    private func header(height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .frame(height: height)
                .overlay { RemoteImage(url: meta.background ?? meta.poster, maxPixel: 2600) }
                .clipped()
                .overlay(LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0.2), .clear], startPoint: .leading, endPoint: .trailing))
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))

            VStack(alignment: .leading, spacing: 16) {
                if meta.logo != nil {
                    RemoteImage(url: meta.logo, contentMode: .fit, alignment: .bottomLeading, maxPixel: 900)
                        .frame(maxWidth: 420, maxHeight: 150, alignment: .bottomLeading)
                } else {
                    Text(meta.name).font(.system(size: 54, weight: .heavy)).lineLimit(2)
                }

                HStack(spacing: 8) {
                    if let r = meta.imdbRating {
                        Text("IMDb").font(.system(size: 11, weight: .heavy))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.yellow, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.black)
                        Text(r).fontWeight(.bold)
                    }
                    let parts = [meta.releaseInfo, meta.runtime, meta.certification, meta.genres.prefix(3).joined(separator: ", ")]
                        .compactMap { $0 }.filter { !$0.isEmpty }
                    ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                        if i > 0 || meta.imdbRating != nil { Text("·").foregroundStyle(Theme.textTertiary) }
                        Text(part)
                    }
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))

                if let d = meta.description {
                    Text(d)
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(4)
                        .frame(maxWidth: 640, alignment: .leading)
                }

                let target = app.resumeTarget(for: meta)
                HStack(spacing: 12) {
                    Button { play(target.video) } label: {
                        HStack(spacing: 8) {
                            if app.isStarting(target.video?.id ?? meta.id) {
                                ProgressView().controlSize(.small).tint(.black)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(target.label)
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .keyboardShortcut(.return, modifiers: [])

                    if let yt = meta.trailerYouTubeId {
                        Button { app.trailer = TrailerRequest(youTubeId: yt, title: meta.name) } label: {
                            Label("Trailer", systemImage: "play.rectangle")
                        }
                        .buttonStyle(PillButtonStyle())
                    }

                    Button { app.picker = PickerTarget(meta: meta, video: target.video) } label: {
                        Label("Streams", systemImage: "list.bullet")
                    }
                    .buttonStyle(PillButtonStyle())

                    Button { app.watch.toggleFavorite(meta) } label: {
                        Image(systemName: app.watch.isFavorite(meta.id) ? "checkmark" : "plus")
                            .frame(width: 18)
                    }
                    .buttonStyle(PillButtonStyle())
                    .help(app.watch.isFavorite(meta.id) ? "Remove from Library" : "Add to Library")

                    RatingButton(title: SavedTitle(meta))

                    Menu {
                        if meta.isSeriesLike, !meta.videos.isEmpty {
                            let regular = meta.videos.filter { ($0.season ?? 1) > 0 && ($0.released ?? .distantPast) <= .now }
                            Button("Mark Show as Watched") { app.setWatched(meta, videos: regular, watched: true) }
                            Button("Mark Show as Unwatched") { app.setWatched(meta, videos: meta.videos, watched: false) }
                            Divider()
                            DropButton(metaId: meta.id)
                        } else if app.watch.isWatched(meta.id) {
                            Button("Mark as Unwatched") { app.setWatched(meta, videos: [], watched: false) }
                        } else {
                            Button("Mark as Watched") { app.setWatched(meta, videos: [], watched: true) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    // Same look as the glass pill buttons beside it.
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75))
                    .contentShape(Capsule())
                    .help("More")
                }
                .padding(.top, 4)

            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 40)

            VStack {
                HStack {
                    Button { app.back() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 40, height: 40)
                            .glass()
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    Spacer()
                }
                Spacer()
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 44)
        }
        .frame(height: height)
    }

    // MARK: Episodes

    /// One continuous row across every season: scrolling past a season's last episode
    /// carries on into the next and moves the selected tab with it; tapping a tab glides
    /// the row to that season. Specials come last.
    private var episodes: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ForEach(meta.seasons, id: \.self) { s in
                    let seasonVideos = meta.videos.filter { ($0.season ?? 1) == s }
                    let allWatched = !seasonVideos.isEmpty && seasonVideos.allSatisfy { app.watch.isWatched($0.id) }
                    Button { jump(to: s) } label: {
                        Text(s == 0 ? (meta.isAnimeLike ? "Specials & OVAs" : "Specials") : "Season \(s)")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .foregroundStyle(season == s ? .black : .white)
                            .background {
                                if season == s { Capsule().fill(.white) }
                                else { Capsule().fill(Color.white.opacity(0.08)) }
                            }
                            .animation(.easeInOut(duration: 0.2), value: season)
                    }
                    .contextMenu {
                        if allWatched {
                            Button("Mark \(s == 0 ? "Specials" : "Season \(s)") as Unwatched") { app.setWatched(meta, videos: seasonVideos, watched: false) }
                        } else {
                            Button("Mark \(s == 0 ? "Specials" : "Season \(s)") as Watched") { app.setWatched(meta, videos: seasonVideos, watched: true) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.gutter)

            // scrollPosition (unlike ScrollViewReader) moves only this row, never the page.
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(allEpisodes) { v in
                        EpisodeCard(
                            video: v,
                            kicker: kicker(for: v),
                            runtime: episodeDetails.minutes(season: v.season, episode: v.episode),
                            summary: v.overview ?? episodeDetails.summary(season: v.season, episode: v.episode),
                            stillFallback: episodeDetails.image(season: v.season, episode: v.episode),
                            fallbackImage: meta.background,
                            progress: app.watch.progress(videoId: v.id),
                            isLoading: app.isStarting(v.id)
                        ) { play(v) }
                        .id(v.id)
                        .contextMenu {
                            Button("Choose Stream…") { app.picker = PickerTarget(meta: meta, video: v) }
                            Divider()
                            if app.watch.isWatched(v.id) {
                                Button("Mark as Unwatched") { app.setWatched(meta, videos: [v], watched: false) }
                            } else {
                                Button("Mark as Watched") { app.setWatched(meta, videos: [v], watched: true) }
                            }
                            if (v.season ?? 0) > 0 {
                                Button("Mark Watched Up to Here") { app.markWatched(upTo: v, in: meta, episodes: episodes(upTo: v)) }
                            }
                            if app.watch.progress(videoId: v.id) > 0 {
                                Divider()
                                Button("Remove Watch Progress") { app.watch.clearProgress(metaId: meta.id, videoId: v.id) }
                            }
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 12)
            }
            .contentMargins(.horizontal, Theme.gutter, for: .scrollContent)
            .scrollPosition(id: $episodeAnchor, anchor: .leading)
            .onChange(of: episodeAnchor) { _, id in
                // Follow the scroll: the tab is the season of the episode at the leading edge.
                guard let id, let s = allEpisodes.first(where: { $0.id == id })?.season, s != season else { return }
                season = s
            }
        }
    }

    private var allEpisodes: [Video] {
        let order = Dictionary(uniqueKeysWithValues: meta.seasons.enumerated().map { ($1, $0) })
        return meta.videos.sorted {
            let a = order[$0.season ?? 0] ?? .max, b = order[$1.season ?? 0] ?? .max
            return a != b ? a < b : ($0.episode ?? 0) < ($1.episode ?? 0)
        }
    }

    private func jump(to s: Int) {
        season = s
        guard let first = allEpisodes.first(where: { $0.season == s }) else { return }
        withAnimation(.smooth(duration: 0.6)) { episodeAnchor = first.id }
    }

    private func kicker(for v: Video) -> String {
        let n = v.episode.map(String.init) ?? ""
        if v.season == 0 { return "SPECIAL \(n)" }
        return meta.seasons.filter({ $0 > 0 }).count > 1 ? "SEASON \(v.season ?? 1) · EPISODE \(n)" : "EPISODE \(n)"
    }

    // MARK: Cast & About

    private var cast: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Cast & Crew")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(castList.prefix(30), id: \.self) { member in
                        Button { app.open(member, context: meta.imdbId) } label: { CastBubble(member: member) }
                            .buttonStyle(.plain)
                            .help("See \(member.name)'s other work")
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "About")
            HStack(alignment: .top, spacing: 60) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(meta.description ?? "No description.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        if let imdb = meta.imdbId { linkButton("IMDb", "https://www.imdb.com/title/\(imdb)/") }
                        if let mal = meta.malId { linkButton("MyAnimeList", "https://myanimelist.net/anime/\(mal)") }
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 9) {
                    infoRow("Genres", meta.genres.joined(separator: ", "))
                    infoRow("Released", meta.releaseInfo)
                    infoRow("Runtime", meta.runtime)
                    infoRow("Status", meta.status)
                    infoRow("Rated", meta.certification)
                    infoRow("Language", originalLanguage.flatMap { Locale.current.localizedString(forLanguageCode: $0) })
                    infoRow("Country", meta.country.map(countryName))
                    if meta.isSeriesLike {
                        let regular = meta.videos.filter { ($0.season ?? 1) > 0 }
                        infoRow("Episodes", regular.isEmpty ? nil : "\(regular.count) across \(Set(regular.compactMap(\.season)).count) season(s)")
                    }
                    peopleRow("Directors", meta.directors)
                    peopleRow("Writers", meta.writers)
                    infoRow("Rating", meta.imdbRating.map { "\($0) / 10" })
                }
                .font(.system(size: 13))
            }
            .padding(.horizontal, Theme.gutter)
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(Theme.textTertiary)
                Text(value).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// Directors/writers, each clickable through to their other work.
    @ViewBuilder
    private func peopleRow(_ label: String, _ names: [String]) -> some View {
        if !names.isEmpty {
            GridRow {
                Text(label).foregroundStyle(Theme.textTertiary)
                HStack(spacing: 6) {
                    ForEach(names.prefix(4), id: \.self) { name in
                        Button(name) { app.open(CastMember(name: name), context: meta.imdbId) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }

    private func linkButton(_ title: String, _ url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            Label(title, systemImage: "arrow.up.right.square")
        }
        .buttonStyle(PillButtonStyle())
        .controlSize(.small)
    }

    private func countryName(_ raw: String) -> String {
        if raw.count == 2, let n = Locale.current.localizedString(forRegionCode: raw.uppercased()) { return n }
        if raw.count == 3, let n = Locale.current.localizedString(forLanguageCode: raw) { return n } // AIOMetadata sometimes sends a language code
        return raw
    }

    // MARK: Actions

    /// Regular episodes up to and including this one, in order.
    private func episodes(upTo v: Video) -> [Video] {
        let key = (v.season ?? 0, v.episode ?? 0)
        return meta.videos.filter { ($0.season ?? 0) > 0 && (($0.season ?? 0), ($0.episode ?? 0)) <= key }
    }

    private func play(_ video: Video?) {
        app.requestPlay(meta: meta, video: video)
    }
}

struct StreamPicker: View {
    let target: PickerTarget
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var streams: [StreamItem] = []
    @State private var state: LoadState = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.meta.name).font(.system(size: 20, weight: .bold))
                    if let v = target.video {
                        Text([v.season.flatMap { s in v.episode.map { "S\(s) E\($0)" } }, v.title].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            switch state {
            case .loading:
                ProgressView("Asking your addon for streams…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle").padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                if streams.isEmpty {
                    Text("No streams found.").foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(streams) { s in
                                StreamRow(stream: s) { choose(s) }
                                    .contextMenu { StreamActions(stream: s, title: downloadTitle) }
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .frame(width: 720, height: 640)
        .task {
            do {
                streams = try await app.streams(for: target.meta, video: target.video)
                state = .loaded
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private var downloadTitle: String {
        guard let v = target.video, let s = v.season, let e = v.episode else { return target.meta.name }
        return String(format: "%@ S%02dE%02d", target.meta.name, s, e)
    }

    private func choose(_ s: StreamItem) {
        guard s.isPlayable else { return }
        app.requestPlay(meta: target.meta, video: target.video, stream: s, alternatives: streams)
        dismiss()
    }
}

struct StreamRow: View {
    let stream: StreamItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Text(stream.headline)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 170, alignment: .leading)
                    .multilineTextAlignment(.leading)
                Text(stream.details)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                if !stream.isPlayable {
                    Text(stream.infoHash != nil ? "Torrent" : "External")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(hovering && stream.isPlayable ? 0.12 : 0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(stream.isPlayable ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(stream.isPlayable ? "Play this stream" : "This stream has no direct link; it can't be played here")
    }
}

/// Right-click actions for a stream: copy its link, or download it.
struct StreamActions: View {
    let stream: StreamItem
    let title: String
    @Environment(AppState.self) private var app

    var body: some View {
        if let url = stream.url {
            Button("Copy Stream Link") { copy(url) }
            Button("Download") { app.downloads.download(stream, title: title) }
        }
        if let hash = stream.infoHash {
            Button("Copy Magnet Link") {
                copy("magnet:?xt=urn:btih:\(hash)&dn=" + (stream.filename ?? title).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).orEmpty)
            }
        }
        if let external = stream.externalUrl {
            Button("Open in Browser") { if let u = URL(string: external) { NSWorkspace.shared.open(u) } }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

/// Thumbs up/down/heart for a title, as a glass pill like its neighbours.
struct RatingButton: View {
    let title: SavedTitle
    @Environment(AppState.self) private var app

    var body: some View {
        let current = app.watch.rating(for: title.id)
        Menu {
            RatingItems(title: title)
        } label: {
            Image(systemName: current?.icon ?? "hand.thumbsup")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(current == .love ? Color.pink : .white)
                .frame(width: 18, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 22)
        .padding(.vertical, 11)
        .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75))
        .contentShape(Capsule())
        .help(current.map { "Rated: \($0.label)" } ?? "Rate this (shapes Recommended for You)")
    }
}

/// The rating choices, for a menu or a right-click menu.
struct RatingItems: View {
    let title: SavedTitle
    @Environment(AppState.self) private var app

    var body: some View {
        let current = app.watch.rating(for: title.id)
        ForEach([Rating.love, .like, .dislike], id: \.self) { r in
            Button { app.rate(title, current == r ? nil : r) } label: {
                Label(r.label + (current == r ? " ✓" : ""), systemImage: r.icon)
            }
        }
        if current != nil {
            Divider()
            Button("Clear Rating") { app.rate(title, nil) }
        }
    }
}
