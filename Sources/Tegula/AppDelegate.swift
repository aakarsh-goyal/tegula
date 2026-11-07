import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menu: MenuController!

    static func applyTheme() {
        switch Settings.shared.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
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
