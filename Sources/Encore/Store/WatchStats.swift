import Foundation

/// One video watched, for the History row (newest first; one item per video).
struct HistoryItem: Codable, Hashable, Identifiable {
    var title: SavedTitle
    var videoId: String
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    var thumbnail: String?
    var watchedAt: Date
    var id: String { videoId }
    var isMovie: Bool { season == nil }

    var episodeLine: String {
        guard let s = season, let e = episode else { return "Movie" }
        return "S\(s) • E\(e)" + (episodeTitle.map { $0.isEmpty ? "" : " - \($0)" } ?? "")
    }
}

/// How much you liked a title.
enum Rating: Int, Codable, CaseIterable {
    case dislike = -1, like = 1, love = 2

    var label: String { self == .dislike ? "Not for Me" : self == .like ? "Like This" : "Love This!" }
    var icon: String { self == .dislike ? "hand.thumbsdown.fill" : self == .like ? "hand.thumbsup.fill" : "heart.fill" }
    /// How much titles related to this one count in recommendations.
    var weight: Double { self == .dislike ? -1 : self == .like ? 1.5 : 2.2 }
}

struct RatedTitle: Codable, Hashable {
    var title: SavedTitle
    var rating: Rating
    var ratedAt: Date
}

/// Watch-time bookkeeping, kept apart from the library so views that show progress
/// don't redraw every time a few seconds of viewing are logged. Saved in stats.json.
struct StatsDisk: Codable {
    /// Seconds watched per local hour ("2026-10-12T21"), split into movies and shows.
    var movieHours: [String: Double] = [:]
    var showHours: [String: Double] = [:]
    var history: [HistoryItem] = []
    var dropped: [String] = []
    /// Titles hidden from Recommended for You.
    var notInterested: [String] = []
    /// Your ratings, by title id.
    var ratings: [String: RatedTitle] = [:]
    var seeded = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        movieHours = try c.decodeIfPresent([String: Double].self, forKey: .movieHours) ?? [:]
        showHours = try c.decodeIfPresent([String: Double].self, forKey: .showHours) ?? [:]
        history = (try? c.decodeIfPresent([HistoryItem].self, forKey: .history)) ?? []
        dropped = try c.decodeIfPresent([String].self, forKey: .dropped) ?? []
        notInterested = try c.decodeIfPresent([String].self, forKey: .notInterested) ?? []
        ratings = (try? c.decodeIfPresent([String: RatedTitle].self, forKey: .ratings)) ?? [:]
        seeded = try c.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
    }

    static let hourFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH"
        return f
    }()
}

/// Screen-time figures for a period (7 days, 30 days, or everything), optionally only
/// movies or only shows, compared with the period just before it.
struct ScreenTime {
    enum Period: String, CaseIterable, Identifiable {
        case week = "7 Days", month = "30 Days", all = "All Time"
        var id: String { rawValue }
        var days: Int? { self == .week ? 7 : self == .month ? 30 : nil }
    }
    enum Kind: String, CaseIterable, Identifiable {
        case everything = "Everything", movies = "Movies", shows = "Shows"
        var id: String { rawValue }
    }
    /// One chart bar: a day, or a month for All Time.
    struct Bucket: Identifiable { let date: Date; let seconds: Double; var id: Date { date } }
    enum Part: String, CaseIterable { case morning = "Morning", afternoon = "Afternoon", evening = "Evening", night = "Night" }

    let period: Period
    let kind: Kind
    let start: Date
    let end: Date
    let buckets: [Bucket]
    let monthly: Bool
    let parts: [(Part, Double)]
    let total: Double
    let previousTotal: Double?
    let movies, shows: Double
    let previousMovies, previousShows: Double?
    let dayCount: Int
    let moviesWatched, episodesWatched: Int
    let previousMoviesWatched, previousEpisodesWatched: Int?
    let currentStreak, longestStreak: Int
    let busiestDay: (date: Date, seconds: Double)?
    let topShow: (title: SavedTitle, episodes: Int)?

    var dailyAverage: Double { total / Double(max(dayCount, 1)) }
    var previousDailyAverage: Double? { previousTotal.map { $0 / Double(max(dayCount, 1)) } }
    /// Share of waking time (16 h a day) spent watching.
    var wakingShare: Double { total / (Double(max(dayCount, 1)) * 16 * 3600) }
    var previousWakingShare: Double? { previousTotal.map { $0 / (Double(max(dayCount, 1)) * 16 * 3600) } }

    init(stats: StatsDisk, period: Period, kind: Kind, now: Date = .now) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        self.period = period
        self.kind = kind

        // Every hour logged, as (day start, hour, seconds, isMovie), filtered to the kind.
        var samples: [(day: Date, hour: Int, seconds: Double, movie: Bool)] = []
        for (hours, movie) in [(stats.movieHours, true), (stats.showHours, false)] {
            if kind == .movies && !movie || kind == .shows && movie { continue }
            for (key, seconds) in hours {
                guard let at = StatsDisk.hourFormat.date(from: key), seconds > 0 else { continue }
                samples.append((cal.startOfDay(for: at), cal.component(.hour, from: at), seconds, movie))
            }
        }
        let history = stats.history.filter { kind == .everything || (kind == .movies) == $0.isMovie }
        let firstDay = (samples.map(\.day) + history.map { cal.startOfDay(for: $0.watchedAt) }).min() ?? today

        let first: Date
        let prevStart: Date?
        if let n = period.days {
            first = cal.date(byAdding: .day, value: -(n - 1), to: today)!
            prevStart = cal.date(byAdding: .day, value: -n, to: first)!
        } else {
            first = min(firstDay, today)
            prevStart = nil
        }
        start = first
        end = today
        dayCount = (cal.dateComponents([.day], from: first, to: today).day ?? 0) + 1

        var perDay: [Date: Double] = [:]
        var partTotals: [Part: Double] = [:]
        var total = 0.0, movies = 0.0, shows = 0.0
        var prev = 0.0, prevMovies = 0.0, prevShows = 0.0
        for s in samples {
            if s.day >= first, s.day <= today {
                total += s.seconds
                if s.movie { movies += s.seconds } else { shows += s.seconds }
                perDay[s.day, default: 0] += s.seconds
                let part: Part = (5..<12).contains(s.hour) ? .morning : (12..<17).contains(s.hour) ? .afternoon
                    : (17..<22).contains(s.hour) ? .evening : .night
                partTotals[part, default: 0] += s.seconds
            } else if let prevStart, s.day >= prevStart, s.day < first {
                prev += s.seconds
                if s.movie { prevMovies += s.seconds } else { prevShows += s.seconds }
            }
        }
        self.total = total
        self.movies = movies
        self.shows = shows
        previousTotal = prevStart == nil ? nil : prev
        previousMovies = prevStart == nil ? nil : prevMovies
        previousShows = prevStart == nil ? nil : prevShows
        parts = Part.allCases.map { ($0, partTotals[$0] ?? 0) }

        // Bars: one per day, or one per month (last 12) for All Time.
        if period == .all {
            monthly = true
            let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: today))!
            let firstMonth = cal.date(from: cal.dateComponents([.year, .month], from: first))!
            let span = min(11, max(0, cal.dateComponents([.month], from: firstMonth, to: thisMonth).month ?? 0))
            var perMonth: [Date: Double] = [:]
            for (day, secs) in perDay { perMonth[cal.date(from: cal.dateComponents([.year, .month], from: day))!, default: 0] += secs }
            buckets = (0...span).reversed().map { back in
                let m = cal.date(byAdding: .month, value: -back, to: thisMonth)!
                return Bucket(date: m, seconds: perMonth[m] ?? 0)
            }
        } else {
            monthly = false
            buckets = (0..<dayCount).map { i in
                let d = cal.date(byAdding: .day, value: i, to: first)!
                return Bucket(date: d, seconds: perDay[d] ?? 0)
            }
        }

        // Counts from history (one item per video, at the last time it was watched).
        func counts(_ from: Date, _ to: Date) -> (Int, Int) {
            let items = history.filter { let d = cal.startOfDay(for: $0.watchedAt); return d >= from && d <= to }
            return (items.filter(\.isMovie).count, items.filter { !$0.isMovie }.count)
        }
        (moviesWatched, episodesWatched) = counts(first, today)
        if let prevStart {
            let c = counts(prevStart, cal.date(byAdding: .day, value: -1, to: first)!)
            previousMoviesWatched = c.0
            previousEpisodesWatched = c.1
        } else {
            previousMoviesWatched = nil
            previousEpisodesWatched = nil
        }

        // Streaks count days with any viewing (of this kind), at any time.
        var allDays: Set<Date> = Set(samples.map(\.day))
        allDays.formUnion(history.map { cal.startOfDay(for: $0.watchedAt) })
        var streak = 0
        var day = allDays.contains(today) ? today : cal.date(byAdding: .day, value: -1, to: today)!
        while allDays.contains(day) { streak += 1; day = cal.date(byAdding: .day, value: -1, to: day)! }
        currentStreak = streak
        var longest = 0, run = 0
        var previous: Date?
        for d in allDays.sorted() {
            run = previous.map { cal.dateComponents([.day], from: $0, to: d).day == 1 } == true ? run + 1 : 1
            longest = max(longest, run)
            previous = d
        }
        longestStreak = longest

        busiestDay = perDay.max { $0.value < $1.value }.map { ($0.key, $0.value) }

        // The show with the most episodes watched in the period.
        var perShow: [String: (SavedTitle, Int)] = [:]
        for item in history where !item.isMovie {
            let d = cal.startOfDay(for: item.watchedAt)
            guard d >= first, d <= today else { continue }
            perShow[item.title.id] = (item.title, (perShow[item.title.id]?.1 ?? 0) + 1)
        }
        topShow = perShow.values.max { $0.1 < $1.1 }.map { ($0.0, $0.1) }
    }
}

/// "2h 25m", "48m", "0m".
func formatDuration(_ seconds: Double) -> String {
    let m = Int((seconds / 60).rounded())
    if m >= 60 { return "\(m / 60)h \(m % 60)m" }
    return "\(m)m"
}
