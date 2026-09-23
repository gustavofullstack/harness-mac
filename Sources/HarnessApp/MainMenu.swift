import AppKit

/// Standard macOS menu bar. The Edit menu is required for ⌘C/⌘V/⌘A to reach the web view.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let bar = NSMenu()
        let name = ProcessInfo.processInfo.processName

        bar.addSubmenu(name, [
            item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        bar.addSubmenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        bar.addSubmenu("View", [
            item("Reload", #selector(AppDelegate.reloadHarness(_:)), "r"),
            item("Restart Harness", #selector(AppDelegate.restartHarness(_:)), "r", [.command, .shift]),
            item("Open in Browser", #selector(AppDelegate.openInBrowser(_:)), "o", [.command, .shift]),
            keepAwakeItem(),
            .separator(),
            item("Actual Size", #selector(AppDelegate.actualSize(_:)), "0"),
            item("Zoom In", #selector(AppDelegate.zoomIn(_:)), "="),
            item("Zoom Out", #selector(AppDelegate.zoomOut(_:)), "-"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let window = bar.addSubmenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.windowsMenu = window
        bar.addSubmenu("Help", [item("DeepSeek Harness Quickstart", #selector(AppDelegate.openDocs(_:)))])
        return bar
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func keepAwakeItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Keep Mac Awake While DSH Runs",
                              action: #selector(AppDelegate.toggleKeepAwake(_:)), keyEquivalent: "")
        item.target = NSApp.delegate
        item.state = Preferences.keepAwake ? .on : .off
        return item
    }
}

private extension NSMenu {
    @discardableResult
    func addSubmenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        addItem(holder)
        return menu
    }
}
