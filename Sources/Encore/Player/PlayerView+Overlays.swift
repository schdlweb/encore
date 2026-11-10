import AppKit
import SwiftUI

extension PlayerView {
    // MARK: Overlays

    @ViewBuilder
    func overlays(_ p: MPVController) -> some View {
        if (!p.fileLoaded || p.buffering || p.seeking || checkingStream != nil) && p.errorMessage == nil {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.white)
                if let s = checkingStream {
                    Text("Checking stream…").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text(s.oneLine).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                } else if !p.fileLoaded {
                    Text(stream.headline.components(separatedBy: "\n").first ?? "")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if p.fileLoaded, p.buffering {
                    Text("Buffering…").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .allowsHitTesting(false)
        }

        if let error = p.errorMessage {
            errorCard(error)
        }

        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomBar(p)
        }
        .opacity(controlsVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .allowsHitTesting(controlsVisible)

        // Up Next (which also stands in for Skip Credits): shown when the credits start,
        // fades after a few seconds, and comes back with the controls when you move.
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                Spacer()
                upNextCard(p)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, controlsVisible ? 120 : 40)
        }
        .opacity(upNextFresh || controlsVisible ? 1 : 0)
        .allowsHitTesting(upNextFresh || controlsVisible)
        .animation(.easeInOut(duration: 0.4), value: upNextFresh)
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .onChange(of: upNextDue) { _, due in
            upNextTask?.cancel()
            guard due else { upNextFresh = false; return }
            upNextFresh = true
            upNextTask = Task {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { upNextFresh = false }
            }
        }

        VStack {
            Spacer()
            seekFlash(p)
        }
        .opacity(seekFlashVisible && !controlsVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: seekFlashVisible)
        .allowsHitTesting(false)

        VStack {
            Spacer()
            HStack {
                Spacer()
                skipButton
            }
            .padding(.horizontal, 40)
            .padding(.bottom, controlsVisible ? 110 : 40)
        }
        // Shown for a few seconds when an intro/credits starts, then only with the controls
        // (moving the mouse brings it back).
        .opacity(skipPromptFresh || controlsVisible ? 1 : 0)
        .allowsHitTesting(skipPromptFresh || controlsVisible)
        .animation(.easeInOut(duration: 0.4), value: skipPromptFresh)
        .onChange(of: activeSegment?.id) { _, id in
            skipPromptTask?.cancel()
            guard id != nil else { skipPromptFresh = false; return }
            skipPromptFresh = true
            skipPromptTask = Task {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { skipPromptFresh = false }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: activeSegment?.id)

        if dolbyVisionWarning {
            HStack(spacing: 12) {
                Image(systemName: "paintpalette").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dolby Vision–only video").font(.system(size: 13, weight: .semibold))
                    Text("This file has no HDR10/SDR layer, so colors may look green or purple on Mac.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                }
                if let alt = request.alternatives.first(where: { $0.isPlayable && !$0.isDolbyVisionOnly && !triedURLs.contains($0.url ?? "") }),
                   let p = player {
                    Button("Switch Version") {
                        dolbyVisionWarning = false
                        switchStream(to: alt, player: p)
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                }
                Button { withAnimation { dolbyVisionWarning = false } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .padding(14)
            .glass(cornerRadius: 16, tint: .black.opacity(0.45))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 100)
            .transition(.opacity)
        }

        if let toast {
            Text(toast)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .glass(tint: .black.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 50)
                .transition(.opacity)
                .allowsHitTesting(false)
        }

        if showInfo {
            infoPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 90)
                .padding(.trailing, 40)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    var topBar: some View {
        if inWindow {
            // "✕ Close" under the traffic lights, the show's name and episode below it,
            // and the info button on the right.
            ZStack(alignment: .top) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Button { close() } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                                Text("Close").font(.system(size: 13, weight: .medium))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(request.title).font(.system(size: 22, weight: .bold))
                            subtitleLine(opacity: 0.75)
                        }
                        .padding(.leading, 8)
                        .shadow(color: .black.opacity(0.5), radius: 6)
                    }
                    Spacer()
                    circleButton("info.circle", help: "Media info (I)") { withAnimation { showInfo.toggle() } }
                        .padding(.top, 2)
                }
                .padding(.horizontal, 12)
                .padding(.trailing, 8)
                .padding(.top, 38)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 50)
            .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
        } else {
            HStack(alignment: .center, spacing: 16) {
                circleButton("chevron.left", help: "Close") { close() }
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title).font(.system(size: 20, weight: .bold))
                    subtitleLine(opacity: 0.7)
                }
                Spacer()
                circleButton("info.circle", help: "Media info (I)") { withAnimation { showInfo.toggle() } }
            }
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .padding(.bottom, 50)
            .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
        }
    }

    /// Compact floating panel like Infuse's: volume left, transport centred, track menus,
    /// a gear menu and full screen right; timeline with times on either side below.
    func bottomBar(_ p: MPVController) -> some View {
        let skip = app.settings.skipInterval
        return VStack(spacing: 8) {
            ZStack {
                HStack(spacing: 6) {
                    controlIcon(p.muted || p.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 13, help: "Mute (M)") { p.toggleMute() }
                    Slider(value: Binding(get: { p.volume }, set: { p.setVolume($0) }), in: 0...130)
                        .frame(width: 84)
                        .controlSize(.mini)
                        .tint(.white)
                    Spacer()
                }
                HStack(spacing: 20) {
                    controlIcon("gobackward", size: 16, help: "Back \(skip)s (←)") { p.seek(by: -Double(skip)) }
                    controlIcon(p.paused ? "play.fill" : "pause.fill", size: 22, help: "Play/Pause (Space)") { p.togglePause() }
                        .frame(width: 26)
                    controlIcon("goforward", size: 16, help: "Forward \(skip)s (→)") { p.seek(by: Double(skip)) }
                    if let next = nextVideo {
                        controlIcon("forward.end.fill", size: 14, help: "Next episode (N)") { playNext(next) }
                    }
                }
                HStack(spacing: 12) {
                    Spacer()
                    SubtitleMenu(tracks: p.subtitleTracks, selected: p.selectedSubtitle,
                                 select: { p.selectSubtitle($0); rememberSubtitles($0, p) }, setDelay: { p.setSubtitleDelay($0) })
                        .equatable()
                    AudioMenu(tracks: p.audioTracks, selected: p.selectedAudio,
                              select: { p.selectAudio($0); rememberAudio($0, p) }, setDelay: { p.setAudioDelay($0) })
                        .equatable()
                    GearMenu(speed: p.speed, sources: request.alternatives.filter(\.isPlayable), current: stream,
                             showInfo: showInfo, setSpeed: { p.setSpeed($0) },
                             switchTo: { switchStream(to: $0, player: p) },
                             toggleInfo: { withAnimation { showInfo.toggle() } })
                        .equatable()
                    controlIcon(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                size: 13, help: "Full screen (F)") { toggleFullScreen() }
                }
            }
            .frame(height: 26)

            timeline(p)
        }
        .playerPanel(onHover: { pointerOnBar = $0 })
    }

    /// Elapsed | seek bar | remaining.
    func timeline(_ p: MPVController) -> some View {
        HStack(spacing: 10) {
            Text(formatClock(scrubbing ?? p.position))
                .frame(width: 50, alignment: .leading)
            Scrubber(
                position: scrubbing ?? p.position, duration: p.duration, buffered: p.position + p.cacheSeconds,
                segments: segments, preview: preview, previewsEnabled: app.settings.scrubPreviews,
                previewLoading: previewIsStale,
                previewLabel: preview != nil ? previewFrameTime : nil,
                onSeek: { value, done in
                    scrubbing = done ? nil : value
                    // Seek to the same moment the preview was made from, so the click
                    // lands on the scene the preview showed.
                    if done {
                        // Land on the frame the bubble is showing (what you see is where
                        // you go); without one, on the keyframe for that spot.
                        if let frame = previewFrameTime, preview != nil, abs(frame - value) <= snapWindow {
                            p.seekExact(to: frame)
                        } else if let frame = thumbs?.frameTime(value) {
                            p.seekExact(to: frame)
                        } else {
                            p.seek(to: thumbs?.bucketed(value) ?? value)
                        }
                    }
                    poke()
                },
                onHover: { t in hoverPreview(t, player: p) }
            )
            Text("-" + formatClock(max(0, p.duration - (scrubbing ?? p.position))))
                .frame(width: 56, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.85))
    }

    /// Just the timeline, flashed briefly when skipping with the arrow keys so you can see
    /// where you landed without the whole playbar covering the picture.
    func seekFlash(_ p: MPVController) -> some View {
        timeline(p)
            .allowsHitTesting(false)
            .playerPanel()
    }

    var isFullScreen: Bool { hostWindow?.styleMask.contains(.fullScreen) ?? false }

    // MARK: Panels

    var infoPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Now Playing").font(.system(size: 15, weight: .bold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                ForEach(info, id: \.0) { row in
                    GridRow {
                        Text(row.0).foregroundStyle(.white.opacity(0.55))
                        Text(row.1).foregroundStyle(.white)
                    }
                }
            }
            .font(.system(size: 12))
            Divider().overlay(Color.white.opacity(0.2))
            Text(stream.headline + "\n" + stream.details)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(8)
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        .glass(cornerRadius: 18, tint: .black.opacity(0.35))
    }

    /// At the credits (or the last 45 s): the next episode is up.
    var upNextDue: Bool {
        guard let p = player, nextVideo != nil, !upNextDismissed, p.duration > 120 else { return false }
        return p.duration - p.position < 45 || activeSegment?.kind == .outro
    }

    /// One card for the credits: what's next, Play Next, or keep watching the credits.
    @ViewBuilder
    func upNextCard(_ p: MPVController) -> some View {
        if let next = nextVideo, upNextDue {
            HStack(spacing: 12) {
                // The thumbnail is itself a play button.
                Button { playNext(next) } label: {
                    ZStack {
                        RemoteImage(url: next.thumbnail ?? request.meta.background, maxPixel: 240)
                        Color.black.opacity(0.25)
                        Image(systemName: advancing ? "hourglass" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 3)
                    }
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(advancing)

                VStack(alignment: .leading, spacing: 3) {
                    Text("UP NEXT" + (next.episode.map { " · E\($0)" } ?? ""))
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.55))
                    Text(next.title.isEmpty ? "Episode \(next.episode ?? 0)" : next.title)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 10) {
                        Button { playNext(next) } label: {
                            Label(advancing ? "Loading…" : "Play", systemImage: "play.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(.white))
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                        .disabled(advancing)
                        Button("Watch Credits") { withAnimation { upNextDismissed = true } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .fixedSize()
                    .padding(.top, 2)
                }
            }
            .padding(10)
            .frame(width: 330, alignment: .leading)
            .glass(cornerRadius: 14, tint: .black.opacity(0.4))
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    func errorCard(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack {
                if let alt = nextUntriedStream, let p = player {
                    Button("Try Next Stream") { switchStream(to: alt, player: p) }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                }
                Button("Close") { close() }.buttonStyle(PillButtonStyle())
            }
        }
        .padding(30)
        .glass(cornerRadius: 22, tint: .black.opacity(0.5))
    }

    func circleButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 40, height: 40)
                .glass()
        }
        .buttonStyle(.plain)
        .help(help)
    }

    func controlIcon(_ icon: String, size: CGFloat = 19, help: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); poke() }) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The year (or episode) with the quality tags beside it on the same line.
    func subtitleLine(opacity: Double) -> some View {
        HStack(spacing: 8) {
            if let s = request.subtitle, !s.isEmpty {
                Text(s).font(.system(size: 13)).foregroundStyle(.white.opacity(opacity)).lineLimit(1)
            }
            ForEach(qualityTags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.45), lineWidth: 0.75))
                    .fixedSize()
            }
        }
        .animation(.easeOut(duration: 0.2), value: qualityTags)
    }

    @ViewBuilder
    var skipButton: some View {
        if let seg = activeSegment, let p = player {
            if seg.kind == .outro, nextVideo != nil {
                // The Up Next card covers the credits (Play Next skips them).
                EmptyView()
            } else {
                Button { skip(seg, player: p) } label: {
                    Label(seg.buttonTitle, systemImage: "forward.fill")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .help("Times from \(seg.source)")
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
    }
}
