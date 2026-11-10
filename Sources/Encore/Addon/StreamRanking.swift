import Foundation

/// The order Play tries a title's streams in. No state of its own: everything it needs is
/// passed in, so the ranking can be checked by itself (see Tests/).
enum StreamRanking {
    /// Playable streams in the order to try them: the exact stream last played for this
    /// episode, then the same release group (the last episode's, else the one last used for
    /// this title), then AIOStreams' own order, with last resorts (worst last): files from
    /// another season/entry, OVAs/specials when a regular episode was asked for, and Dolby
    /// Vision-only files (wrong colors here).
    static func order(_ streams: [StreamItem], matcher: EpisodeMatcher, video: Video?, videoId: String,
                      remembered: StreamChoice?, preferBingeGroup: String?) -> [StreamItem] {
        let group = preferBingeGroup ?? remembered?.bingeGroup
        var seen = Set<String>()
        let playable = streams.filter { $0.isPlayable && seen.insert($0.url!).inserted }
        let grouped = playable.filter { group != nil && $0.bingeGroup == group }
            + playable.filter { group == nil || $0.bingeGroup != group }
        let wantsRegularEpisode = (video?.season ?? 1) > 0 && !StreamItem.isExtraName(video?.title ?? "")
        // Series packs: no episode in the name and far bigger than the real episodes (a 33 GB
        // "Kusuriya no Hitorigoto" folder among 1.5 GB episodes). The debrid service picks
        // some file inside, often from another season, so they're tried last.
        let episodeSizes = playable.filter { matcher.identifiesEpisode($0) }.compactMap(\.videoSize).sorted()
        let typicalSize = episodeSizes.isEmpty ? nil : episodeSizes[episodeSizes.count / 2]
        func looksLikePack(_ s: StreamItem) -> Bool {
            guard video?.season != nil, !matcher.identifiesEpisode(s), let size = s.videoSize else { return false }
            return size > max(8_000_000_000, (typicalSize ?? 0) * 4)
        }
        func penalty(_ s: StreamItem) -> Int {
            (matcher.isMismatch(s) ? 4 : 0) + (looksLikePack(s) ? 3 : 0)
                + (wantsRegularEpisode && s.looksLikeExtra ? 2 : 0) + (s.isDolbyVisionOnly ? 1 : 0)
        }
        var ordered = grouped.enumerated()
            .sorted { (penalty($0.element), $0.offset) < (penalty($1.element), $1.offset) }
            .map(\.element)
        // The user's own pick (or what last played fine) beats the heuristics.
        // (Unless it's from another season/entry, so a wrong file played once can't stick.)
        if let remembered, remembered.videoId == videoId,
           let i = ordered.firstIndex(where: { remembered.matches($0) && !matcher.isMismatch($0) }) {
            ordered.insert(ordered.remove(at: i), at: 0)
        }
        return ordered
    }
}
