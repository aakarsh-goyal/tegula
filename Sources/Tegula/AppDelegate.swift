import AppKit

/// Debug hooks: with `debugLog` on, `notifyutil -p com.aakarsh.tegula.dump` logs the tiler's state and
/// `notifyutil -p com.aakarsh.tegula.do.<action>` runs a shortcut action, so behaviour can be tested headlessly.
private var debugHandlers: [String: () -> Void] = [:]
private let darwinCallback: CFNotificationCallback = { _, _, name, _, _ in
    guard let n = name?.rawValue as String? else { return }
    DispatchQueue.main.async { debugHandlers[n]?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menu: MenuController!

    static func applyTheme() {
        switch Settings.shared.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// An accessory app has no visible menu bar, but its key equivalents (⌘W, ⌘Q, ⌘, ⌘C/⌘V…) still need a
    /// main menu to exist, otherwise the Settings window can't be closed from the keyboard.
    private func installMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); main.addItem(item)
            let m = NSMenu(title: title); item.submenu = m
            return m
        }
        let app = submenu("Tegula")
        app.addItem(withTitle: L10n.t(.settings), action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: L10n.t(.quit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = submenu(L10n.t(.editMenu))
        edit.addItem(withTitle: L10n.t(.cut), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.t(.copy), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.t(.paste), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.t(.selectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let win = submenu(L10n.t(.windowMenu))
        win.addItem(withTitle: L10n.t(.close), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: L10n.t(.minimize), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    @objc private func openSettingsFromMenu() { SettingsWindowController.shared.show() }

    func applicationDidFinishLaunching(_ n: Notification) {
        installMainMenu()
        AppDelegate.applyTheme()
        Icons.applyAppIcon()
        menu = MenuController()
        menu.onOpenSettings = { SettingsWindowController.shared.show() }
        menu.onGrantAccess = { [weak self] in self?.requestAccess() }

        Hotkeys.shared.onAction = { [weak self] in self?.perform($0) }
        Hotkeys.shared.reload()
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { _ in
            AppDelegate.applyTheme()
        }

        if Log.on {
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            func listen(_ name: String, _ f: @escaping () -> Void) {
                debugHandlers[name] = f
                CFNotificationCenterAddObserver(center, nil, darwinCallback, name as CFString, nil, .deliverImmediately)
            }
            listen("com.aakarsh.tegula.dump") { Tiler.shared.debugDump() }
            // Posts ⌘W, but ONLY when one of our own windows is key, so it can never close another app's window.
            listen("com.aakarsh.tegula.cmdw") {
                guard NSApp.isActive, NSApp.keyWindow != nil else { Log.d("cmdw skipped: Tegula window not key"); return }
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 13, keyDown: down)
                    e?.flags = .maskCommand; e?.post(tap: .cghidEventTap)
                }
                Log.d("cmdw posted")
            }
            // Synthesises a real keystroke at the HID level so the full Carbon hotkey path is exercised.
            for a in Action.allCases {
                listen("com.aakarsh.tegula.key.\(a.rawValue)") {
                    guard let sc = Settings.shared.shortcut(for: a.rawValue) else { Log.d("key \(a.rawValue): no shortcut"); return }
                    var f: CGEventFlags = []
                    if sc.mods & 4096 != 0 { f.insert(.maskControl) }
                    if sc.mods & 2048 != 0 { f.insert(.maskAlternate) }
                    if sc.mods & 512 != 0 { f.insert(.maskShift) }
                    if sc.mods & 256 != 0 { f.insert(.maskCommand) }
                    if (123...126).contains(sc.keyCode) { f.insert(.maskSecondaryFn); f.insert(.maskNumericPad) }   // real arrow keys carry these
                    Log.d("synth key \(sc.display) for \(a.rawValue); frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
                    for down in [true, false] {
                        let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: CGKeyCode(sc.keyCode), keyDown: down)
                        e?.flags = f
                        e?.post(tap: .cghidEventTap)
                    }
                }
            }
            for a in Action.allCases { listen("com.aakarsh.tegula.do.\(a.rawValue)") { [weak self] in Log.d("debug action \(a.rawValue)"); self?.perform(a.rawValue) } }
        }

        // Accessibility trust changes are announced by the OS, so no polling is needed.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Tiler.shared.start() }
        }
        if Tiler.shared.trusted { Tiler.shared.start() } else { requestAccess() }
        if CommandLine.arguments.contains("--open-menu") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.menu.debugOpen() } }
        if CommandLine.arguments.contains("--cycle-layout") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let cur = Tiler.shared.currentDisplay().map { Settings.shared.layout(for: $0) } ?? .grid
                Tiler.shared.setLayout(cur == .grid ? .columns : .grid)
            }
        }
        if CommandLine.arguments.contains("--clean-space") { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Tiler.shared.cleanSpace() } }
        // Dev aid: `Tegula --settings [tab]` opens Settings straight away.
        if let i = CommandLine.arguments.firstIndex(of: "--settings") {
            SettingsWindowController.shared.show()
            if let t = CommandLine.arguments[safe: i + 1].flatMap({ Int($0) }) { SettingsWindowController.shared.select(tab: t) }
        }
    }

    private func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = L10n.t(.accessTitle); a.informativeText = L10n.t(.accessText)
            a.addButton(withTitle: "System Settings…"); a.addButton(withTitle: L10n.t(.cancel))
            if a.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }

    func perform(_ id: String) {
        let t = Tiler.shared
        if id.hasPrefix("setup.") {
            if let s = Settings.shared.setups.first(where: { "setup." + $0.id == id }) { t.launchSetup(s) }
            return
        }
        switch Action(rawValue: id) {
        case .layoutGrid: t.setLayout(.grid)
        case .layoutColumns: t.setLayout(.columns)
        case .layoutRows: t.setLayout(.rows)
        case .layoutSide: t.setLayout(.side)
        case .pause: t.togglePause()
        case .swapLeft: t.swapInDirection(-1, 0)
        case .swapRight: t.swapInDirection(1, 0)
        case .swapUp: t.swapInDirection(0, -1)
        case .swapDown: t.swapInDirection(0, 1)
        case .cleanSpace: t.cleanSpace()
        case .focusToggle: t.cycleFocusMode()
        case .retile: t.resyncAll(reset: true)
        case .tileApp:
            if let app = NSWorkspace.shared.frontmostApplication, let b = app.bundleIdentifier { t.toggleTile(bundle: b) }
        case .makeMain: t.makeMain()
        case nil: break
        }
    }
}
