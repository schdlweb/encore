// Checks for Encore's pure logic and its on-disk stores. Built and run by
// scripts/test.sh: every source file except the app's entry point, plus this file.
// Nothing here touches the network, the real library, or the user's settings.
import Foundation

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("  FAIL \(what)  (\(file):\(line))")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ what: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if a != b {
        failures += 1
        print("  FAIL \(what): got \(a), expected \(b)  (\(file):\(line))")
    }
}

func section(_ name: String, _ body: () throws -> Void) {
    print(name)
    do { try body() } catch { failures += 1; print("  FAIL threw \(error)") }
}

func decode<T: Decodable>(_ json: String, as: T.Type = T.self) -> T {
    try! JSONDecoder().decode(T.self, from: Data(json.utf8))
}

func stream(_ filename: String, url: String? = nil, group: String? = nil, size: Int64? = nil, name: String? = nil) -> StreamItem {
    var hints: [String: Any] = ["filename": filename]
    if let group { hints["bingeGroup"] = group }
    if let size { hints["videoSize"] = size }
    var obj: [String: Any] = ["url": url ?? "https://example.invalid/\(filename)", "behaviorHints": hints]
    if let name { obj["name"] = name }
    return try! JSONDecoder().decode(StreamItem.self, from: JSONSerialization.data(withJSONObject: obj))
}

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("encore-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func files(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

// MARK: Versions and checksums

section("Updater.isNewer") {
    expect(Updater.isNewer("1.10.0", than: "1.9.2"), "1.10.0 > 1.9.2")
    expect(!Updater.isNewer("1.9.2", than: "1.10.0"), "1.9.2 < 1.10.0")
    expect(!Updater.isNewer("1.0.10", than: "1.0.10"), "same version isn't newer")
    expect(Updater.isNewer("2", than: "1.9.9"), "short version")
    expect(!Updater.isNewer("1.0", than: "1.0.0"), "1.0 == 1.0.0")
    expect(Updater.isNewer("1.0.1", than: "1.0"), "1.0.1 > 1.0")
}

section("Updater.sha256") {
    let dir = tempDir()
    let file = dir.appendingPathComponent("abc.bin")
    try Data("abc".utf8).write(to: file)
    expectEqual(try Updater.sha256(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of \"abc\"")
    let big = dir.appendingPathComponent("big.bin")
    try Data(repeating: 0x61, count: 3_000_000).write(to: big) // spans several read chunks
    let again = try Updater.sha256(of: big)
    expectEqual(again.count, 64, "hex length")
    expectEqual(again, try Updater.sha256(of: big), "stable across reads")
    let small = try Updater.sha256(of: file)
    expect(again != small, "different files differ")
}

// MARK: Stream checks

section("StreamProbe.errorVideoReason") {
    func reason(_ s: String) -> String? { StreamProbe.errorVideoReason(URL(string: s)!) }
    expectEqual(reason("https://aio.example/static/download_failed.mp4"), "Debrid download failed", "AIOStreams failure clip")
    expectEqual(reason("https://aio.example/static/downloading.mp4"), "Not cached yet (debrid is still downloading it)", "still downloading")
    expectEqual(reason("https://torrentio.example/videos/failed_rar_v2.mp4"), "Release is a RAR archive", "Torrentio clip")
    expect(reason("https://aio.example/static/something_new.mp4")?.contains("something_new") == true, "unknown clip is still an error")
    expect(reason("https://aio.example/static/200.mp4") == nil, "200.mp4 is not an error")
    expect(reason("https://cdn.example/files/Show.S01E01.mp4") == nil, "an ordinary mp4")
    expect(reason("https://cdn.example/static/Show.S01E01.mkv") == nil, "an mkv in /static")
}

// MARK: Reading file names

section("EpisodeMatcher.markers") {
    func m(_ s: String) -> (Int?, Int?, ClosedRange<Int>?) {
        let x = EpisodeMatcher.markers(in: s)
        return (x.season, x.episode, x.seasonRange)
    }
    expect(m("Show.S01E05.1080p.mkv") == (1, 5, nil), "S01E05")
    expect(m("Show S3 - 01 [1080p]") == (3, 1, nil), "S3 - 01")
    expect(m("Kaguya 2 - 01.mkv") == (2, 1, nil), "trailing season number")
    expect(m("[Group] Show - 05v2 [1080p].mkv") == (nil, 5, nil), "bare episode with version")
    expect(m("Show.S01-S03.Complete") == (nil, nil, 1...3), "season range")
    expect(m("Show Seasons 1 to 3") == (nil, nil, 1...3), "season range in words")
    expect(m("Show Season 2 Batch") == (2, nil, nil), "Season 2")
    expect(m("Show 2nd Season") == (2, nil, nil), "2nd Season")
    expect(m("Just A Movie 2019 1080p") == (nil, nil, nil), "no markers")
}

section("EpisodeMatcher.isMismatch") {
    let s1e1 = EpisodeMatcher(season: 1, episode: 1, foreignPhrases: ["the first kiss that never ends"])
    expect(!s1e1.isMismatch("Show.S01E01.mkv"), "the episode itself")
    expect(s1e1.isMismatch("Show.S02E01.mkv"), "another season")
    expect(s1e1.isMismatch("Show.S01E02.mkv"), "another episode")
    expect(s1e1.isMismatch("Kaguya 2 - 01.mkv"), "season 2 numbered in the name")
    expect(s1e1.isMismatch("Kaguya-sama - The First Kiss Never Ends - S01E01.mkv"), "another entry by its title")
    expect(!s1e1.isMismatch("Show.S01-S03.Complete"), "a pack covering the season")
    expect(s1e1.isMismatch("Show.S02-S03.Complete"), "a pack not covering it")
    expect(!s1e1.isMismatch("Show 1080p BluRay"), "nothing to go on")
    let s3e1 = EpisodeMatcher(season: 3, episode: 1, foreignPhrases: [], absoluteEpisode: 49)
    expect(!s3e1.isMismatch("Show - 49 [1080p].mkv"), "absolute numbering")
    expect(s3e1.isMismatch("Show - 48 [1080p].mkv"), "wrong absolute number")
    expect(!EpisodeMatcher.none.isMismatch("Show.S09E09.mkv"), "movies never mismatch")
}

section("StreamItem name checks") {
    expect(StreamItem.isExtraName("Show - OVA 1 [BD].mkv"), "OVA")
    expect(StreamItem.isExtraName("Show NCED 01"), "creditless ending")
    expect(StreamItem.isExtraName("Show.S01E00.Special.mkv"), "a special")
    expect(!StreamItem.isExtraName("Show.S01E01.1080p.mkv"), "regular episode")
    expect(stream("Movie.2160p.DV.WEB-DL.mkv").isDolbyVisionOnly, "DV without HDR")
    expect(!stream("Movie.2160p.DV.HDR10.WEB-DL.mkv").isDolbyVisionOnly, "DV with an HDR10 layer")
    expectEqual(stream("Movie.2160p.BluRay.REMUX.mkv").sourceTag, "Remux", "source tag prefers Remux")
    expectEqual(stream("Movie.1080p.WEB-DL.mkv").sourceTag, "WEB-DL", "WEB-DL")
}

// MARK: Ranking

section("StreamRanking.order") {
    let ep: Video = decode(#"{"id":"tt1:1:1","season":1,"episode":1,"title":"Pilot"}"#)
    let matcher = EpisodeMatcher(season: 1, episode: 1, foreignPhrases: [])
    func names(_ s: [StreamItem]) -> [String] { s.map { $0.filename ?? "?" } }
    func rank(_ s: [StreamItem], remembered: StreamChoice? = nil, group: String? = nil) -> [String] {
        names(StreamRanking.order(s, matcher: matcher, video: ep, videoId: ep.id, remembered: remembered, preferBingeGroup: group))
    }

    let a = stream("Show.S01E01.A.mkv", group: "A", size: 1_500_000_000)
    let b = stream("Show.S01E01.B.mkv", group: "B", size: 1_400_000_000)
    let wrongSeason = stream("Show.S02E01.mkv", size: 1_500_000_000)
    let ova = stream("Show.OVA.01.mkv", size: 700_000_000)
    let dv = stream("Show.S01E01.DV.mkv", size: 4_000_000_000)
    let pack = stream("Show.Complete.BluRay", size: 33_000_000_000)
    var torrentOnly = stream("Show.S01E01.torrent.mkv")
    torrentOnly.url = nil

    expectEqual(rank([a, b]), ["Show.S01E01.A.mkv", "Show.S01E01.B.mkv"], "the addon's order is kept")
    expectEqual(rank([wrongSeason, ova, dv, pack, a]),
                ["Show.S01E01.A.mkv", "Show.S01E01.DV.mkv", "Show.OVA.01.mkv", "Show.Complete.BluRay", "Show.S02E01.mkv"],
                "last resorts go last, worst last")
    expectEqual(rank([a, b], group: "B"), ["Show.S01E01.B.mkv", "Show.S01E01.A.mkv"], "the last episode's release group first")
    expectEqual(rank([a, b], remembered: StreamChoice(videoId: "tt1:1:9", url: nil, filename: nil, bingeGroup: "B")),
                ["Show.S01E01.B.mkv", "Show.S01E01.A.mkv"], "the group last used for the title")
    expectEqual(rank([a, b], remembered: StreamChoice(videoId: ep.id, url: b.url, filename: nil, bingeGroup: nil)),
                ["Show.S01E01.B.mkv", "Show.S01E01.A.mkv"], "the exact stream last played for this episode")
    expectEqual(rank([a, wrongSeason], remembered: StreamChoice(videoId: ep.id, url: wrongSeason.url, filename: nil, bingeGroup: nil)),
                ["Show.S01E01.A.mkv", "Show.S02E01.mkv"], "a remembered wrong file doesn't stick")
    expectEqual(rank([a, a, torrentOnly, b]), ["Show.S01E01.A.mkv", "Show.S01E01.B.mkv"], "duplicates and unplayable streams dropped")
    expectEqual(rank([]), [], "nothing in, nothing out")
}

section("CutoffRecovery") {
    func ending(_ p: Double, _ d: Double) -> Bool { CutoffRecovery.isRealEnding(position: p, duration: d) }
    expect(!ending(18, 90), "stopping at 18 of 90 s is a cutoff")
    expect(!ending(700, 1440), "mid-episode is a cutoff")
    expect(ending(1439, 1440), "the last second is the ending")
    expect(ending(1420, 1440), "within the last 2% is the ending")
    expect(!ending(1380, 1440), "a minute short of an episode's end is a cutoff")
    expect(ending(7100, 7200), "a film's credits stretch")
    expect(ending(12, 0), "no known duration can't be judged a cutoff")

    let first = CutoffRecovery.after(nil, position: 600)
    expectEqual(first.action, .retrySameStream, "the first cutoff retries the same stream")
    let second = CutoffRecovery.after(first, position: 601)
    expectEqual(second.action, .tryAnotherStream, "dying at the same spot moves on")
    let third = CutoffRecovery.after(second, position: 602)
    expectEqual(third.action, .tryAnotherStream, "a second other source")
    expectEqual(CutoffRecovery.after(third, position: 603).action, .giveUp, "then it stops trying")
    expectEqual(third.position, 600, "small gains don't reset the count")
    expectEqual(CutoffRecovery.after(third, position: 900), CutoffRecovery(position: 900, attempts: 1),
                "playing on for a while starts over")
}

// MARK: Ids, languages, formatting

section("JellyfinSync item ids") {
    let id = JellyfinSync.itemId(imdb: "tt0903747", type: "series", season: 2, episode: 13)
    expect(id != nil, "an id is made")
    if let id, let back = JellyfinSync.decode(id) {
        expectEqual(back.imdb, "tt0903747", "IMDb id round-trips")
        expectEqual(back.season, 2, "season")
        expectEqual(back.episode, 13, "episode")
    } else { expect(false, "decodes its own id") }
    if let movie = JellyfinSync.itemId(imdb: "tt0111161", type: "movie"), let back = JellyfinSync.decode(movie) {
        expect(back.season == nil && back.episode == nil, "a movie has no season or episode")
    } else { expect(false, "movie id") }
    expect(JellyfinSync.itemId(imdb: "mal:5114", type: "anime") == nil, "non-IMDb ids are refused")
    expect(JellyfinSync.decode("not-an-id") == nil, "junk doesn't decode")
}

section("Languages and clocks") {
    expectEqual(normalizeLang("en"), "eng", "en → eng")
    expectEqual(normalizeLang("ENG"), "eng", "case")
    expectEqual(normalizeLang("ja"), "jpn", "ja → jpn")
    expect(languageCodes("jpn").contains("ja"), "jpn also matches ja")
    expect(Set(languageCodes("chi")).isSuperset(of: ["chi", "zho", "zh"]), "Chinese spellings")
    expectEqual(languageCodes("fre").count, Set(languageCodes("fre")).count, "no duplicates")
    expectEqual(formatClock(59), "0:59", "under a minute")
    expectEqual(formatClock(3725), "1:02:05", "over an hour")
    expectEqual(formatClock(-1), "--:--", "negative")
    expectEqual(formatRemaining(20), "1m", "at least a minute")
    expectEqual(formatRemaining(5400), "1h 30m", "hours and minutes")
}

section("AddonClient manifest URLs") {
    expectEqual(try AddonClient(manifestURL: " https://a.example/x/manifest.json \n").base.absoluteString, "https://a.example/x", "https manifest")
    expectEqual(try AddonClient(manifestURL: "stremio://a.example/x/manifest.json").base.absoluteString, "https://a.example/x", "stremio:// link")
    expectEqual(try AddonClient(manifestURL: "https://a.example/x///").base.absoluteString, "https://a.example/x", "trailing slashes")
    expect((try? AddonClient(manifestURL: "ftp://a.example")) == nil, "other schemes are refused")
    expect((try? AddonClient(manifestURL: "not a url")) == nil, "junk is refused")
}

// MARK: Disk

struct Sample: Codable, Equatable, Sendable {
    var n: Int
    var items: [String: Int] = [:]

    init(n: Int, items: [String: Int] = [:]) { self.n = n; self.items = items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        n = c.lenientValue(.n, default: 0)
        items = c.lenientDictionary(.items)
    }
}

section("DiskStore") {
    let dir = tempDir()
    let store = DiskStore(file: dir.appendingPathComponent("sample.json"))
    expect(store.load(Sample.self) == nil, "no file yet")
    expectEqual(files(in: dir), [], "nothing set aside for a missing file")

    // Many writes in a row: the last one handed over is the one on disk.
    for i in 1...300 { store.write(Sample(n: i)) }
    store.writeNow(Sample(n: 301, items: ["a": 1]))
    expectEqual(store.load(Sample.self), Sample(n: 301, items: ["a": 1]), "writes land in order")
    expectEqual(files(in: dir), ["sample.json"], "a clean read sets nothing aside")

    // One damaged entry: the rest still loads, and the original is kept.
    try Data(#"{"n": 7, "items": {"good": 1, "bad": "oops", "also": 3}}"#.utf8).write(to: store.file)
    expectEqual(store.load(Sample.self), Sample(n: 7, items: ["good": 1, "also": 3]), "only the damaged entry is dropped")
    let afterPartial = files(in: dir)
    expectEqual(afterPartial.filter { $0.hasPrefix("sample.unreadable-") }.count, 1, "the file with the damaged entry is set aside")

    // Not JSON at all: nothing loads, the file is kept, and saving doesn't destroy the copy.
    let junk = Data("{ this is not json".utf8)
    try junk.write(to: store.file)
    Thread.sleep(forTimeInterval: 1.1) // copies are named to the second
    expect(store.load(Sample.self) == nil, "an unreadable file loads as nothing")
    let copies = files(in: dir).filter { $0.hasPrefix("sample.unreadable-") }
    expectEqual(copies.count, 2, "the unreadable file is set aside too")
    store.writeNow(Sample(n: 1))
    let kept = copies.contains { (try? Data(contentsOf: dir.appendingPathComponent($0))) == junk }
    expect(kept, "its contents survive the next save")
}

@MainActor func watchStoreChecks() {
    section("WatchStore on disk") {
        let dir = tempDir()
        let title: SavedTitle = decode(#"{"id":"tt1","type":"series","name":"Show"}"#)
        func entry(_ video: String, position: Double) -> WatchEntry {
            WatchEntry(title: title, videoId: video, season: 1, episode: 1, episodeTitle: nil, episodeThumbnail: nil,
                       position: position, duration: 1000, updatedAt: .now)
        }

        let first = WatchStore(directory: dir)
        for p in stride(from: 100.0, through: 500, by: 100) { first.record(entry("tt1:1:1", position: p)) }
        first.setDropped("tt9", true)
        first.flushNow()

        let second = WatchStore(directory: dir)
        expectEqual(second.entry(for: "tt1")?.position, 500, "the latest position is the one saved")
        expectEqual(second.progress(videoId: "tt1:1:1"), 0.5, "progress")
        expect(second.isDropped("tt9"), "stats saved too")
        expectEqual(second.continueWatching.count, 1, "Continue Watching")
        expectEqual(second.watchHistory.count, 1, "history logged once per video")

        // A library that can't be read: Encore starts empty, but the file isn't lost.
        let library = dir.appendingPathComponent("library.json")
        let original = try Data(contentsOf: library)
        var damaged = original
        damaged.removeLast(original.count / 2) // cut off mid-write
        try damaged.write(to: library)
        let third = WatchStore(directory: dir)
        expect(third.entry(for: "tt1") == nil, "nothing loads from a cut-off file")
        third.record(entry("tt2:1:1", position: 50))
        third.flushNow()
        let copies = files(in: dir).filter { $0.hasPrefix("library.unreadable-") }
        expectEqual(copies.count, 1, "the cut-off library is set aside before anything is saved")
        expect(copies.first.map { (try? Data(contentsOf: dir.appendingPathComponent($0))) == damaged } == true, "untouched")

        // One entry of the wrong shape among good ones.
        try Data(#"""
        {"entries": {"tt1": {"title": {"id":"tt1","type":"series","name":"Show"}, "videoId": "tt1:1:2",
                             "position": 40, "duration": 100, "updatedAt": 700000000},
                     "tt5": {"videoId": 12}},
         "progress": {"tt1:1:2": 0.4, "tt5:1:1": "half"},
         "favorites": [{"id":"tt1","type":"series","name":"Show"}, 17]}
        """#.utf8).write(to: library)
        let fourth = WatchStore(directory: dir)
        expectEqual(fourth.entry(for: "tt1")?.videoId, "tt1:1:2", "good entries survive a bad neighbour")
        expect(fourth.entry(for: "tt5") == nil, "the bad one is dropped")
        expectEqual(fourth.progress(videoId: "tt1:1:2"), 0.4, "good progress survives")
        expectEqual(fourth.favorites.count, 1, "good favourites survive")
    }
}

MainActor.assumeIsolated { watchStoreChecks() }

print(failures == 0 ? "\nAll \(checks) checks passed." : "\n\(failures) of \(checks) checks failed.")
exit(failures == 0 ? 0 : 1)
