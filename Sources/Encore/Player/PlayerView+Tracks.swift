import AppKit
import SwiftUI

extension PlayerView {
    // MARK: Remembered languages

    /// mpv `alang` for this title: a language picked for it before, then its original.
    var audioLanguages: String? {
        guard let saved = app.watch.trackChoice(for: request.meta.id)?.audio else { return request.audioLanguages }
        return (languageCodes(saved) + [request.audioLanguages].compactMap { $0 }).joined(separator: ",")
    }

    var subtitlePrefs: [String] {
        app.settings.preferredSubtitleLanguages.split(separator: ",")
            .map { normalizeLang(String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// The subtitle language picked for this title, if one was (not "off").
    var savedSubtitleLanguage: String? {
        guard let s = app.watch.trackChoice(for: request.meta.id)?.subtitles, s != TrackChoice.off else { return nil }
        return s
    }

    /// Signs & Songs, forced or commentary subtitles rather than the full dialogue.
    static func isPartialSubtitle(_ t: MediaTrack) -> Bool {
        t.isForced || (t.title ?? "").range(of: #"(?i)sign|song|forced|commentary"#, options: .regularExpression) != nil
    }

    /// Audio in a language other than the title's original is remembered for this movie or
    /// show; going back to the original forgets it.
    func rememberAudio(_ id: Int, _ p: MPVController) {
        guard let lang = p.audioTracks.first(where: { $0.id == id })?.lang else { return }
        let code = normalizeLang(lang)
        var original = Set((request.audioLanguages ?? "").split(separator: ",").map { normalizeLang(String($0)) })
        // Original unknown: the file's default track stands in for it.
        if original.isEmpty, let def = p.audioTracks.first(where: \.isDefault)?.lang ?? p.audioTracks.first?.lang {
            original = [normalizeLang(def)]
        }
        app.watch.setAudioChoice(original.contains(code) ? nil : code, metaId: request.meta.id)
    }

    /// Subtitles other than the usual (another language, or off when they're normally on)
    /// are remembered for this movie or show; going back to the usual forgets it.
    func rememberSubtitles(_ id: Int?, _ p: MPVController) {
        let usual = app.settings.subtitlesOnByDefault ? subtitlePrefs.first : nil
        let value: String?
        if let id {
            guard let lang = p.subtitleTracks.first(where: { $0.id == id })?.lang else { return }
            let code = normalizeLang(lang)
            value = code == usual ? nil : code
        } else {
            value = usual == nil ? nil : TrackChoice.off
        }
        app.watch.setSubtitleChoice(value, metaId: request.meta.id)
    }

    /// Anime releases often flag a "Signs & Songs" track as the English default; prefer
    /// the full-dialogue English track when there is one.
    func refineSubtitleChoice(_ p: MPVController) {
        // Subtitles picked for this title before win over the settings.
        if app.trackChoiceSubtitlesOff(request.meta.id) {
            p.selectSubtitle(nil)
            return
        }
        if let saved = savedSubtitleLanguage {
            let matches = p.subtitleTracks.filter { $0.lang.map(normalizeLang) == saved }
            // Not in the file: the addon's subtitles are tried once they're added.
            if let pick = matches.first(where: { !Self.isPartialSubtitle($0) }) ?? matches.first {
                p.selectSubtitle(pick.id)
            }
            return
        }
        guard app.settings.subtitlesOnByDefault else { return }
        let prefs = subtitlePrefs
        let partial = Self.isPartialSubtitle
        let wanted = p.subtitleTracks.filter { t in t.lang.map { prefs.contains(normalizeLang($0)) } ?? false }
        let current = p.subtitleTracks.first { $0.id == p.selectedSubtitle }
        if let full = wanted.first(where: { !partial($0) }), current == nil || partial(current!) {
            p.selectSubtitle(full.id)
        }
    }
}
