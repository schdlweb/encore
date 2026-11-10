import Foundation

/// Why playback can't continue, in the words the error screen uses.
struct PlaybackProblem: Equatable {
    var title: String
    var detail: String
    var canRetry = true

    static func streamStopped(at seconds: Double) -> PlaybackProblem {
        PlaybackProblem(title: "Playback stopped at \(formatClock(seconds))",
                        detail: "The connection to this stream kept dropping.")
    }

    static func sourceFailed(_ reason: String) -> PlaybackProblem {
        let sentence = reason.hasSuffix(".") ? reason : reason + "."
        return PlaybackProblem(title: "That source didn't work", detail: sentence)
    }

    static let couldNotPlay = PlaybackProblem(title: "This video couldn't play",
                                              detail: "The link may have expired, or the file may be damaged.")

    static let engineFailed = PlaybackProblem(title: "The player couldn't start",
                                              detail: "Quit and reopen Encore.", canRetry: false)
}
