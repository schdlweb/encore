import AppKit
import SwiftUI

extension PlayerView {
    /// Sizes the player window to the video's shape, keeping its width where it fits the screen.
    func fitWindow(_ w: NSWindow, to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        videoShape = size
        guard !w.styleMask.contains(.fullScreen) else { return }
        let screen = (w.screen ?? NSScreen.main)?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        var width = min(max(w.frame.width, 960), screen.width * 0.9)
        var height = width * size.height / size.width
        if height > screen.height * 0.9 {
            height = screen.height * 0.9
            width = height * size.width / size.height
        }
        let center = CGPoint(x: w.frame.midX, y: w.frame.midY)
        var frame = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height))
        frame.origin = CGPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2)
        w.setFrame(w.constrainFrameRect(frame, to: w.screen), display: true, animate: true)
    }

    /// After a manual resize: keep the width the user chose, fix the height to the video's shape.
    func snap(_ w: NSWindow, to size: CGSize) {
        let content = w.contentRect(forFrameRect: w.frame)
        let height = content.width * size.height / size.width
        guard abs(height - content.height) > 1 else { return }
        var frame = w.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - height, width: content.width, height: height))
        frame = w.constrainFrameRect(frame, to: w.screen)
        w.setFrame(frame, display: true, animate: true)
    }

    func endFullScreenTransition() {
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            fullScreenTransition = false
        }
    }

    func toggleFullScreen() {
        guard let w = hostWindow ?? NSApp.keyWindow else { return }
        w.collectionBehavior.remove(.fullScreenAuxiliary)
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.makeKeyAndOrderFront(nil)
        w.toggleFullScreen(nil)
    }

    func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard let p = player else { return .ignored }
        let arrows: [KeyEquivalent] = [.leftArrow, .rightArrow, .upArrow, .downArrow]
        if press.phase == .repeat, !arrows.contains(press.key) { return .handled }
        let skip = Double(app.settings.skipInterval)
        // Skips show only the timeline (unless the playbar is already up); other keys bring up the playbar.
        if press.key == .leftArrow || press.key == .rightArrow {
            p.seek(by: (press.modifiers.contains(.shift) ? 60 : skip) * (press.key == .leftArrow ? -1 : 1))
            if controlsVisible { poke() } else { flashTimeline() }
            return .handled
        }
        poke()
        switch press.key {
        case .space: p.togglePause()
        case .upArrow: p.setVolume(p.volume + 5)
        case .downArrow: p.setVolume(p.volume - 5)
        case .escape:
            if let w = hostWindow ?? NSApp.keyWindow, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) } else { close() }
        default:
            switch press.characters.lowercased() {
            case "f": toggleFullScreen()
            case "m": p.toggleMute()
            case "i": withAnimation { showInfo.toggle() }
            case "k": p.togglePause()
            case "n": if let n = nextVideo { playNext(n) }
            default: return .ignored
            }
        }
        return .handled
    }
}
