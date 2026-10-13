import SwiftUI

// MARK: Screen Time

/// Viewing stats, Trakt-style: a chart, then one tile per figure. The period (7 days,
/// 30 days, all time) and kind (everything, movies, shows) are switchable.
struct ScreenTimeSection: View {
    @Environment(AppState.self) private var app
    @AppStorage("screenTimePeriod") private var periodRaw = ScreenTime.Period.week.rawValue
    @AppStorage("screenTimeKind") private var kindRaw = ScreenTime.Kind.everything.rawValue

    private var period: ScreenTime.Period { ScreenTime.Period(rawValue: periodRaw) ?? .week }
    private var kind: ScreenTime.Kind { ScreenTime.Kind(rawValue: kindRaw) ?? .everything }

    var body: some View {
        let stats = app.watch.screenTime(period, kind)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Time").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.textSecondary)
                    Text(range(stats)).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Picker("Showing", selection: $kindRaw) {
                    ForEach(ScreenTime.Kind.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("Period", selection: $periodRaw) {
                    ForEach(ScreenTime.Period.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding(.horizontal, Theme.gutter)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    BreakdownTile(stats: stats)
                    figure("Daily Average", formatDuration(stats.dailyAverage), stats.dailyAverage, stats.previousDailyAverage, formatDuration)
                    PeakHoursTile(parts: stats.parts)
                    figure("Total", formatDuration(stats.total), stats.total, stats.previousTotal, formatDuration)
                    figure("Waking Hours", percent(stats.wakingShare), stats.wakingShare, stats.previousWakingShare, percent,
                           help: "Share of your waking time (16 hours a day) spent watching")
                    if kind == .everything {
                        figure("Movies", formatDuration(stats.movies), stats.movies, stats.previousMovies, formatDuration)
                        figure("Shows", formatDuration(stats.shows), stats.shows, stats.previousShows, formatDuration)
                    }
                    if kind != .shows {
                        figure("Movies Watched", "\(stats.moviesWatched)", Double(stats.moviesWatched),
                               stats.previousMoviesWatched.map(Double.init), { "\(Int($0))" })
                    }
                    if kind != .movies {
                        figure("Episodes Watched", "\(stats.episodesWatched)", Double(stats.episodesWatched),
                               stats.previousEpisodesWatched.map(Double.init), { "\(Int($0))" })
                    }
                    NoteTile(label: "Streak", value: "\(stats.currentStreak) day\(stats.currentStreak == 1 ? "" : "s")",
                             note: "Longest: \(stats.longestStreak) day\(stats.longestStreak == 1 ? "" : "s")",
                             help: "Days in a row with something watched")
                    if let busiest = stats.busiestDay {
                        NoteTile(label: "Busiest Day", value: formatDuration(busiest.seconds), note: dayName(busiest.date))
                    }
                    if kind != .movies, let top = stats.topShow {
                        NoteTile(label: "Most Watched", value: top.title.name,
                                 note: "\(top.episodes) episode\(top.episodes == 1 ? "" : "s")", width: 220, compact: true)
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 4)
            }
        }
    }

    private func figure(_ label: String, _ value: String, _ now: Double, _ before: Double?,
                        _ format: @escaping (Double) -> String, help: String? = nil) -> some View {
        FigureTile(label: label, value: value, change: before.map { now - $0 }, format: format,
                   comparedTo: period == .week ? "last week" : "the 30 days before", help: help)
    }

    private func range(_ s: ScreenTime) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        if s.period == .all { return "Since \(f.string(from: s.start))" }
        return "\(f.string(from: s.start)) – \(f.string(from: s.end))"
    }

    private func dayName(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f.string(from: d)
    }

    private func percent(_ x: Double) -> String {
        let p = x * 100
        return p > 0 && p < 1 ? "<1%" : "\(Int(p.rounded()))%"
    }
}

private struct StatTile<Content: View>: View {
    let label: String
    var width: CGFloat = 150
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            content.frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(16)
        .frame(width: width, height: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

/// A single figure with its change against the previous period (none for All Time).
/// The arrow carries the direction (no red/green: more or less viewing isn't good or bad).
private struct FigureTile: View {
    let label: String
    let value: String
    let change: Double?
    let format: (Double) -> String
    let comparedTo: String
    var help: String? = nil

    var body: some View {
        StatTile(label: label) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 18)
                Text(value).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Spacer()
                if let change {
                    HStack(spacing: 3) {
                        if abs(change) > 0.0001 {
                            Image(systemName: change > 0 ? "arrow.up" : "arrow.down").font(.system(size: 9, weight: .bold))
                            Text(format(abs(change)))
                        } else {
                            Text("Same as \(comparedTo)")
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .help("Compared with \(comparedTo)")
                }
            }
        }
        .help(help ?? "")
    }
}

/// A figure with a line of context instead of a comparison.
private struct NoteTile: View {
    let label: String
    let value: String
    let note: String
    var width: CGFloat = 150
    var compact = false
    var help: String? = nil

    var body: some View {
        StatTile(label: label, width: width) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 18)
                Text(value).font(.system(size: compact ? 17 : 26, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(compact ? 2 : 1).minimumScaleFactor(0.6)
                Spacer()
                Text(note).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
        .help(help ?? "")
    }
}

/// Thin bars: one per day (7 or 30), or one per month for All Time; hover for the exact time.
private struct BreakdownTile: View {
    let stats: ScreenTime
    @State private var hovered: Date?

    private var title: String { stats.monthly ? "Monthly Breakdown" : "Daily Breakdown" }
    private var many: Bool { stats.buckets.count > 12 }

    var body: some View {
        StatTile(label: title, width: many ? 440 : 300) {
            let peak = max(stats.buckets.map(\.seconds).max() ?? 0, 60)
            let busiest = stats.buckets.map(\.seconds).max() ?? 0
            HStack(alignment: .bottom, spacing: many ? 3 : 0) {
                ForEach(Array(stats.buckets.enumerated()), id: \.element.id) { i, bucket in
                    VStack(spacing: 6) {
                        Text(formatDuration(bucket.seconds))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize()
                            .opacity(hovered.map { $0 == bucket.date } ?? (bucket.seconds > 0 && bucket.seconds == busiest) ? 1 : 0)
                        GeometryReader { g in
                            ZStack(alignment: .bottom) {
                                Capsule().fill(Color.white.opacity(0.07))
                                Capsule()
                                    .fill(Theme.accent.opacity(hovered == nil || hovered == bucket.date ? 1 : 0.55))
                                    .frame(height: bucket.seconds > 0 ? max(4, g.size.height * bucket.seconds / peak) : 0)
                            }
                        }
                        .frame(width: many ? 8 : 14)
                        Text(label(bucket.date, index: i))
                            .font(.system(size: 10, weight: isCurrent(bucket.date) ? .semibold : .regular))
                            .foregroundStyle(isCurrent(bucket.date) ? Theme.textPrimary : Theme.textTertiary)
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { hovered = $0 ? bucket.date : (hovered == bucket.date ? nil : hovered) }
                    .help("\(fullLabel(bucket.date)): \(formatDuration(bucket.seconds))")
                }
            }
            .padding(.top, 8)
        }
    }

    private func isCurrent(_ d: Date) -> Bool {
        stats.monthly ? Calendar.current.isDate(d, equalTo: .now, toGranularity: .month) : Calendar.current.isDateInToday(d)
    }

    /// Every label for a week or a year of months; every 5th day (and today) for 30 days.
    private func label(_ d: Date, index: Int) -> String {
        let f = DateFormatter()
        if stats.monthly { f.dateFormat = "MMM"; return f.string(from: d) }
        if isCurrent(d) { return many ? "" : "Today" }
        if many { guard index % 5 == 0 else { return "" }; f.dateFormat = "d"; return f.string(from: d) }
        f.dateFormat = "EEE"
        return f.string(from: d)
    }

    private func fullLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = stats.monthly ? "MMMM yyyy" : "EEEE, MMM d"; return f.string(from: d)
    }
}

/// Morning / afternoon / evening / night, as bars sharing one scale.
private struct PeakHoursTile: View {
    let parts: [(ScreenTime.Part, Double)]

    var body: some View {
        StatTile(label: "Peak Hours", width: 290) {
            let peak = max(parts.map(\.1).max() ?? 0, 1)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(parts, id: \.0) { part, seconds in
                    HStack(spacing: 10) {
                        Text(part.rawValue).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 62, alignment: .leading)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.07))
                                Capsule().fill(Theme.accent).frame(width: seconds > 0 ? max(4, g.size.width * seconds / peak) : 0)
                            }
                        }
                        .frame(height: 5)
                        Text(formatDuration(seconds)).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    .help(hoursHelp(part))
                }
            }
            .padding(.top, 14)
        }
    }

    private func hoursHelp(_ p: ScreenTime.Part) -> String {
        switch p {
        case .morning: "5 AM – noon"
        case .afternoon: "Noon – 5 PM"
        case .evening: "5 PM – 10 PM"
        case .night: "10 PM – 5 AM"
        }
    }
}

// MARK: History

struct HistoryCard: View {
    let item: HistoryItem
    @Environment(AppState.self) private var app

    var body: some View {
        Button { app.open(item.title) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: item.thumbnail ?? item.title.background ?? item.title.poster, maxPixel: 600)
                        .frame(width: 260, height: 146)
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                    Text(when)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                }
                .frame(width: 260, height: 146)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .hoverLift(scale: 1.04)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(item.episodeLine).font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                .frame(width: 260, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu("Rate") { RatingItems(title: item.title) }
            Button("Remove from History") { app.watch.removeFromHistory(item.videoId) }
            if !item.isMovie {
                DropButton(metaId: item.title.id)
            }
        }
    }

    /// "Today", "Yesterday", or "October 3rd, 2026".
    private var when: String {
        let cal = Calendar.current
        if cal.isDateInToday(item.watchedAt) { return "Today" }
        if cal.isDateInYesterday(item.watchedAt) { return "Yesterday" }
        let day = cal.component(.day, from: item.watchedAt)
        let suffix = (11...13).contains(day % 100) ? "th" : ["th", "st", "nd", "rd"][min(day % 10, 4) < 4 ? day % 10 : 0]
        let month = DateFormatter(); month.dateFormat = "MMMM"
        return "\(month.string(from: item.watchedAt)) \(day)\(suffix), \(cal.component(.year, from: item.watchedAt))"
    }
}

/// "Drop Show" / "Resume Show" for a context menu.
struct DropButton: View {
    let metaId: String
    @Environment(AppState.self) private var app

    var body: some View {
        if app.watch.isDropped(metaId) {
            Button("Pick Show Back Up") { app.setDropped(metaId, false) }
        } else {
            Button("Drop Show") { app.setDropped(metaId, true) }
        }
    }
}
