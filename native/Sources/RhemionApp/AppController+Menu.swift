// AppController's menus: the app's main menu (shown while a window is up), the menu-bar menu's delegate, and
// the no-icons rule for every menu (moved out of main.swift unchanged).

import AppKit

extension AppController {
    /// ⌘Q: close every Rhemion window the normal way (performClose — a window mid-operation refuses, as it should);
    /// Rhemion itself keeps running in the menu bar.
    @objc private func closeAllWindows() {
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
            window.performClose(nil)
        }
    }

    /// The app's main menu. Rhemion is a menu-bar app, but its windows (Journal, Settings, Clear Data, Uninstall,
    /// Welcome) put up a Dock icon and the menu bar — without a main menu, ⌘Q / ⌘W / ⌘C / ⌘V do nothing there.
    /// Quit goes through NSApp.terminate, so applicationShouldTerminate still refuses mid-operation.
    func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu(title: "Rhemion")
        let about = NSMenuItem(title: "About Rhemion", action: #selector(openAbout), keyEquivalent: ""); about.target = self
        app.addItem(about)
        app.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","); settings.target = self
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide Rhemion", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        app.addItem(.separator())
        // ⌘Q only closes Rhemion's windows — Rhemion lives in the menu bar, and an accidental ⌘Q must not silently
        // stop dictation. Quitting for real is ⌥⌘Q here, or "Quit Rhemion" in the menu-bar menu.
        let closeAll = NSMenuItem(title: "Close Rhemion Windows", action: #selector(closeAllWindows), keyEquivalent: "q")
        closeAll.target = self
        app.addItem(closeAll)
        let quit = NSMenuItem(title: "Quit Rhemion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command, .option]
        app.addItem(quit)
        appItem.submenu = app
        app.delegate = self   // re-strips icons right before it opens (macOS 26 decorates "About" late)
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = window
        Self.withoutItemIcons(main)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
        Self.withoutItemIcons(main)   // again: setting the main menu can re-decorate the app menu
    }

    /// Menus without item icons: short menus scan faster without them, and the app
    /// looks the same on macOS 15, 26 and 27. macOS 26 adds its own icons to recognised commands (Settings,
    /// Quit, Close…); assigning an image and then nil opts an item out (AppKit engineer, Apple Developer
    /// Forums thread 800414). Recurses into submenus.
    static func withoutItemIcons(_ menu: NSMenu) {
        for item in menu.items {
            if !item.isSeparatorItem {
                item.image = NSImage(size: NSSize(width: 1, height: 1))
                item.image = nil
            }
            if let submenu = item.submenu { withoutItemIcons(submenu) }
        }
    }
}

// The app menu strips its icons again each time it is about to open (see withoutItemIcons).
extension AppController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { Self.withoutItemIcons(menu) }
}
