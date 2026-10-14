import SwiftUI

/// Portrait poster with the genre · rating strip inside and title/year beneath.
struct PosterCard: View {
    let meta: Meta
    var rank: Int? = nil
    var width: CGFloat = Theme.posterWidth
    /// Replaces the year under the title, e.g. "as Frieren" or "Sequel".
    var caption: String? = nil
    /// Adds "Not Interested" to the right-click menu (Recommended for You).
    var onNotInterested: (() -> Void)? = nil
    @Environment(AppState.self) private var app

    private var height: CGFloat { width * 1.5 }

    private var badge: String? {
        if app.watch.inProgressIds.contains(meta.id) { return "In Progress" }
        let year = Calendar.current.component(.year, from: .now)
        if let y = meta.year.flatMap(Int.init), y >= year {
            return "New"
        }
        return nil
    }

    private var strip: String? {
        let parts = [meta.genres.first, meta.imdbRating.map { "★ \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        Button { app.open(meta) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    // The title shows if no poster loads at all.
                    PosterFallback(name: meta.name)
                    RemoteImage(url: meta.poster ?? backupPoster(meta.imdbId), maxPixel: 450,
                                fallbackURL: meta.poster == nil ? nil : backupPoster(meta.imdbId), showsEmpty: false)
                        .frame(width: width, height: height)
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                    VStack {
                        HStack(alignment: .top) {
                            if let rank {
                                Text("\(rank)")
                                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .shadow(color: .black.opacity(0.6), radius: 6)
                                    .padding(.leading, 10)
                                    .padding(.top, 2)
                            }
                            Spacer(minLength: 0)
                        }
                        Spacer()
                        if let strip {
                            Text(strip)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.bottom, 9)
                        }
                    }
                    if let badge {
                        VStack {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        .padding(.top, 6)
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .hoverLift(onLift: { app.warmDetail(meta) })

                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text([meta.year, caption].compactMap { $0 }.joined(separator: " · ").ifEmpty(" "))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(width: width, height: Theme.posterCaptionHeight, alignment: .topLeading)
            }
        }
        .buttonStyle(.plain)
        .modifier(PosterMenu(meta: meta, onNotInterested: onNotInterested))
    }
}

/// Landscape card with a progress bar, for Continue Watching.
struct ContinueCard: View {
    let entry: WatchEntry
    @Environment(AppState.self) private var app

    var body: some View {
        Button { resume() } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: entry.episodeThumbnail ?? entry.title.background ?? entry.title.poster, maxPixel: 700)
                        .frame(width: Theme.landscapeWidth, height: Theme.landscapeHeight)
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                    HStack(spacing: 10) {
                        Capsule().fill(.white.opacity(0.3))
                            .frame(height: 4)
                            .overlay(alignment: .leading) {
                                GeometryReader { g in
                                    Capsule().fill(.white).frame(width: g.size.width * entry.progress)
                                }
                            }
                        Text([entry.episodeLabel, formatRemaining(entry.remaining)].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .fixedSize()
                    }
                    .padding(12)
                    if app.isStarting(entry.videoId) { LoadingVeil() }
                }
                .frame(width: Theme.landscapeWidth, height: Theme.landscapeHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .hoverLift(scale: 1.05, cornerRadius: 14, onLift: { app.prewarm(entry) })

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(entry.episodeTitle ?? entry.title.releaseInfo.map { String($0.prefix(4)) } ?? " ")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                .frame(width: Theme.landscapeWidth, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Go to \(entry.title.type == "movie" ? "Movie" : "Show")") { app.open(entry.title) }
            Menu("Rate") { RatingItems(title: entry.title) }
            Button("Remove from Continue Watching") { app.watch.removeFromContinue(entry.title.id) }
            if entry.season != nil { DropButton(metaId: entry.title.id) }
        }
    }

    private func resume() {
        Task {
            guard let meta = await app.fullMeta(type: entry.title.type, id: entry.title.id) else {
                app.open(entry.title)
                return
            }
            app.requestPlay(meta: meta, video: meta.videos.first { $0.id == entry.videoId })
        }
    }
}

/// Episode tile: thumbnail, number, title, watched progress.
struct EpisodeCard: View {
    let video: Video
    var kicker: String? = nil
    /// Length in minutes, when known.
    var runtime: Int? = nil
    /// The episode's description (the addon's, else TVmaze's).
    var summary: String? = nil
    /// A still to use when the addon has none (or its link is dead), e.g. TVmaze's.
    var stillFallback: String? = nil
    let fallbackImage: String?
    let progress: Double
    let isLoading: Bool
    let action: () -> Void

    private var placeholderLabel: String {
        guard let e = video.episode else { return "" }
        return video.season == 0 ? "SP \(e)" : "E\(e)"
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    // Placeholder underneath: the show's art, dimmed, with the episode number.
                    // The still covers it once (and if) it loads.
                    EpisodePlaceholder(art: fallbackImage, label: placeholderLabel, upcoming: (video.released ?? .distantPast) > .now)
                    RemoteImage(url: video.thumbnail ?? stillFallback, maxPixel: 640, fallbackURL: video.thumbnail == nil ? nil : stillFallback, showsEmpty: false)
                        .frame(width: 280, height: 158)
                    if progress > 0 {
                        LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                        Capsule().fill(.white.opacity(0.3)).frame(height: 4)
                            .overlay(alignment: .leading) {
                                GeometryReader { g in Capsule().fill(.white).frame(width: g.size.width * progress) }
                            }
                            .padding(12)
                    }
                    if progress > 0.92 {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white, .black.opacity(0.4))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(10)
                    }
                    if isLoading { LoadingVeil() }
                }
                .frame(width: 280, height: 158)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .hoverLift(scale: 1.05)

                VStack(alignment: .leading, spacing: 3) {
                    Text(kicker ?? video.episode.map { "EPISODE \($0)" } ?? "")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(video.title.isEmpty ? "Episode \(video.episode ?? 0)" : video.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let facts = episodeFacts(video, runtime: runtime) {
                        Text(facts)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    if let o = summary, !o.isEmpty {
                        Text(o)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(o)
                    }
                }
                .frame(width: 280, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

struct CastBubble: View {
    let member: CastMember

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.white.opacity(0.08))
                if member.photo != nil {
                    RemoteImage(url: member.photo, maxPixel: 240)
                } else {
                    Text(initials).font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(Circle())
            Text(member.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if let c = member.character {
                Text(c).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
        .frame(width: 110)
    }

    private var initials: String {
        member.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

/// Dimmed overlay with a spinner, laid over a card whose stream is being started.
struct LoadingVeil: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 8) {
                ProgressView().controlSize(.regular).tint(.white)
                Text("Loading…").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .transition(.opacity)
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// "24m · Jan 17, 2018", or "24m · Airs Fri, Oct 17" for an episode that hasn't aired.
func episodeFacts(_ video: Video, runtime: Int?) -> String? {
    var parts: [String] = []
    if let runtime, runtime > 0 { parts.append(runtime >= 60 ? "\(runtime / 60)h \(runtime % 60)m" : "\(runtime)m") }
    if let date = video.released {
        let f = DateFormatter()
        if date > .now {
            f.dateFormat = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) ? "EEE, MMM d" : "MMM d, yyyy"
            parts.append("Airs " + f.string(from: date) + " · " + daysUntil(date))
        } else {
            f.dateFormat = "MMM d, yyyy"
            parts.append(f.string(from: date))
        }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

/// "today", "tomorrow", "in 5 days" (calendar days, local time).
func daysUntil(_ date: Date) -> String {
    let cal = Calendar.current
    let n = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: date)).day ?? 0
    switch n {
    case ...0: return "today"
    case 1: return "tomorrow"
    default: return "in \(n) days"
    }
}

/// Stand-in for a missing episode still: the show's art blurred and dimmed, with the
/// episode number, and "Coming soon" for one that hasn't aired.
struct EpisodePlaceholder: View {
    let art: String?
    let label: String
    var upcoming = false

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            RemoteImage(url: art, maxPixel: 400, showsEmpty: false)
                .blur(radius: 14)
                .opacity(0.45)
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                if upcoming {
                    Text("Coming soon").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: 280, height: 158)
        .clipped()
    }
}

/// A poster's right-click menu (My List, Not Interested).
struct PosterMenu: ViewModifier {
    let meta: Meta
    var onNotInterested: (() -> Void)?
    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        content.contextMenu {
            Button(app.watch.favoriteIds.contains(meta.id) ? "Remove from Library" : "Add to Library") {
                app.watch.toggleFavorite(meta)
            }
            if let onNotInterested { Button("Not Interested") { onNotInterested() } }
        }
    }
}

/// Stremio's poster for an IMDb title: the backup when a catalog's own poster link is
/// dead or blocked (some sites refuse images to other apps).
func backupPoster(_ imdb: String?) -> String? {
    imdb.map { "https://images.metahub.space/poster/medium/\($0)/img" }
}

/// What a poster card shows when no image could be loaded: the title on a soft gradient.
struct PosterFallback: View {
    let name: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom)
            Text(name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(12)
        }
    }
}
