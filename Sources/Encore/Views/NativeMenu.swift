import AppKit
import SwiftUI

/// A real AppKit menu, built at the moment it's clicked and shown at the pointer.
///
/// The player's menus used SwiftUI's Menu, which SwiftUI may rebuild while it's open
/// whenever the player redraws (it does several times a second). How well that's
/// contained differs between macOS versions, so on some Macs the menus flickered, lost
/// their highlight or closed submenus. An NSMenu built on click is never touched again
/// until it closes, on every macOS version.
enum MenuEntry {
    case item(String, checked: Bool = false, enabled: Bool = true, action: () -> Void)
    case submenu(String, [MenuEntry])
    case header(String)
    case separator
}

@MainActor
enum NativeMenu {
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func runAction() { run() }
    }

    static func show(_ entries: [MenuEntry]) {
        var actions: [Action] = []
        let menu = build(entries, actions: &actions)
        // AppKit lays a submenu out the first time the pointer reaches it, which made moving
        // between Speed and Source lag at first. Lay them all out now, before showing.
        func prepare(_ m: NSMenu) {
            m.update()
            _ = m.size
            for item in m.items { if let sub = item.submenu { prepare(sub) } }
        }
        prepare(menu)
        // popUp blocks until the menu closes, so `actions` (the item targets) stay alive.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        _ = actions
    }

    /// The menu as text, for checking its contents in tests.
    static func describe(_ entries: [MenuEntry]) -> String {
        var actions: [Action] = []
        func walk(_ m: NSMenu, _ depth: Int) -> [String] {
            m.items.flatMap { i -> [String] in
                let line = String(repeating: "  ", count: depth) + (i.isSeparatorItem ? "—" : (i.state == .on ? "✓ " : "") + i.title)
                return [line] + (i.submenu.map { walk($0, depth + 1) } ?? [])
            }
        }
        return walk(build(entries, actions: &actions), 0).joined(separator: "\n")
    }

    private static func build(_ entries: [MenuEntry], actions: inout [Action]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .item(let title, let checked, let enabled, let run):
                let action = Action(run)
                actions.append(action)
                let item = NSMenuItem(title: title, action: #selector(Action.runAction), keyEquivalent: "")
                item.target = action
                item.state = checked ? NSControl.StateValue.on : NSControl.StateValue.off
                item.isEnabled = enabled
                menu.addItem(item)
            case .submenu(let title, let children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = build(children, actions: &actions)
                menu.addItem(item)
            case .header(let title):
                menu.addItem(NSMenuItem.sectionHeader(title: title))
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
    }
}

/// The player's icon buttons that open a native menu.
struct NativeMenuButton: View {
    let icon: String
    let help: String
    let entries: () -> [MenuEntry]

    var body: some View {
        Button { NativeMenu.show(entries()) } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
