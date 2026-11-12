import AppKit
import Carbon
import ServiceManagement

/// Click-to-record shortcut field with conflict detection.
final class ShortcutRecorder: NSButton {
    let actionID: String
    private var monitor: Any?
    var onChange: (() -> Void)?

    init(action: String) {
        actionID = action
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        bezelStyle = .rounded; target = self; self.action = #selector(begin)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        title = Settings.shared.shortcut(for: actionID)?.display ?? L10n.t(.notSet)
    }

    @objc private func begin() {
        title = L10n.t(.pressKeys)
        Hotkeys.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.capture(e); return nil
        }
    }

    private func finish() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        Hotkeys.shared.reload(); refresh(); onChange?()
    }

    private func capture(_ e: NSEvent) {
        if e.keyCode == 53 { finish(); return }                                   // esc
        if e.keyCode == 51 || e.keyCode == 117 { Settings.shared.setShortcut(nil, for: actionID); finish(); return }
        var mods: UInt32 = 0
        let f = e.modifierFlags
        if f.contains(.control) { mods |= UInt32(controlKey) }
        if f.contains(.option) { mods |= UInt32(optionKey) }
        if f.contains(.shift) { mods |= UInt32(shiftKey) }
        if f.contains(.command) { mods |= UInt32(cmdKey) }
        guard mods != 0 else { NSSound.beep(); title = L10n.t(.needMod); return }
        let arrows: [UInt16: String] = [123: "←", 124: "→", 125: "↓", 126: "↑", 49: "Space", 36: "↩", 48: "⇥"]
        let label = arrows[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "?").uppercased()
        var sc = Shortcut(keyCode: UInt32(e.keyCode), mods: mods, label: label)
        let mine = Settings.shared.shortcut(for: actionID)
        if sc != mine, Hotkeys.isTaken(sc) {
            let alts = Hotkeys.alternatives(for: sc)
            let alert = NSAlert()
            alert.messageText = L10n.t(.conflictTitle)
            alert.informativeText = String(format: L10n.t(.conflictBody), sc.display)
            for a in alts { alert.addButton(withTitle: String(format: L10n.t(.useInstead), a.display)) }
            alert.addButton(withTitle: L10n.t(.cancel))
            let r = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard r >= 0, r < alts.count else { finish(); return }
            sc = alts[r]
        }
        Settings.shared.setShortcut(sc, for: actionID)
        finish()
    }
}

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = SettingsWindowController()
    private var excludedTable = NSTableView()
    private var setupsTable = NSTableView()
    private var recorders: [ShortcutRecorder] = []

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.excludedTable.reloadData(); self?.setupsTable.reloadData()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        build()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private var tabs: NSTabViewController?

    func select(tab: Int) { tabs?.selectedTabViewItemIndex = max(0, min(tab, (tabs?.tabViewItems.count ?? 1) - 1)) }

    // MARK: building

    /// Native Settings structure: a toolbar whose items are the tabs (AppKit's `.toolbar` tab style). This is
    /// what gives the window the system chrome (large corners, Liquid Glass title bar and traffic lights).
    private func build() {
        guard let w = window else { return }
        let keep = tabs?.selectedTabViewItemIndex ?? 0
        let tvc = NSTabViewController()
        tvc.tabStyle = .toolbar
        let panes: [(String, String, NSView, CGFloat)] = [
            (L10n.t(.general), "gearshape", general(), 430),
            (L10n.t(.borders), "paintbrush", appearance(), 250),
            (L10n.t(.behavior), "slider.horizontal.3", behavior(), 420),
            (L10n.t(.shortcuts), "keyboard", shortcuts(), 520),
            (L10n.t(.setupsHint), "rectangle.3.group", setupsPane(), 440),
            (L10n.t(.about), "info.circle", about(), 300),
        ]
        for (title, symbol, view, height) in panes {
            let vc = NSViewController()
            view.frame = NSRect(x: 0, y: 0, width: 620, height: height)
            vc.view = view
            vc.preferredContentSize = NSSize(width: 620, height: height)
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tvc.addTabViewItem(item)
        }
        tabs = tvc
        w.contentViewController = tvc
        tvc.selectedTabViewItemIndex = keep
        w.setContentSize(NSSize(width: 620, height: panes[min(keep, panes.count - 1)].3))
    }

    private func grid(_ rows: [[NSView]]) -> NSView {
        let g = NSGridView(views: rows)
        g.rowSpacing = 12; g.columnSpacing = 14
        g.column(at: 0).xPlacement = .trailing
        let host = NSView()
        g.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(g)
        NSLayoutConstraint.activate([g.topAnchor.constraint(equalTo: host.topAnchor, constant: 22),
                                     g.centerXAnchor.constraint(equalTo: host.centerXAnchor)])
        return host
    }

    private func label(_ s: String, secondary: Bool = false) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        if secondary { t.textColor = .secondaryLabelColor; t.font = .systemFont(ofSize: 11) }
        return t
    }

    private func popup(_ items: [String], selected: Int, _ f: @escaping (Int) -> Void) -> NSPopUpButton {
        let p = ClosurePopUp(); p.addItems(withTitles: items); p.selectItem(at: selected); p.handler = f
        p.target = p; p.action = #selector(ClosurePopUp.fire); return p
    }

    private func check(_ title: String, _ on: Bool, _ f: @escaping (Bool) -> Void) -> NSButton {
        let b = ClosureButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = on ? .on : .off; b.handler = { f($0.state == .on) }
        b.target = b; b.action = #selector(ClosureButton.fire); return b
    }

    private func general() -> NSView {
        let s = Settings.shared
        let ratios = [0.5, 0.6, 2.0 / 3.0]
        let main = popup([L10n.t(.half), L10n.t(.sixty), L10n.t(.twoThirds)],
                         selected: ratios.enumerated().min { abs($0.1 - s.mainRatio) < abs($1.1 - s.mainRatio) ? true : false }!.0) { s.mainRatio = ratios[$0] }
        let gap = ClosureSlider(value: s.gap, minValue: 0, maxValue: 32, target: nil, action: nil)
        let gapLabel = label("\(Int(s.gap)) pt")
        gap.handler = { v in s.gap = v.rounded(); gapLabel.stringValue = "\(Int(v.rounded())) pt" }
        gap.target = gap; gap.action = #selector(ClosureSlider.fire); gap.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let gapRow = NSStackView(views: [gap, gapLabel]); gapRow.spacing = 8

        func edge(_ name: S, _ get: Double, _ set: @escaping (Double) -> Void) -> NSStackView {
            let f = ClosureField(); f.stringValue = "\(Int(get))"; f.widthAnchor.constraint(equalToConstant: 44).isActive = true
            f.handler = { set(max(0, min(400, Double($0) ?? 0))) }
            f.target = f; f.action = #selector(ClosureField.fire)
            let v = NSStackView(views: [label(L10n.t(name), secondary: true), f]); v.orientation = .vertical; v.spacing = 3; v.alignment = .centerX
            return v
        }
        let edges = NSStackView(views: [edge(.top, s.edgeTop) { s.edgeTop = $0 }, edge(.bottom, s.edgeBottom) { s.edgeBottom = $0 },
                                        edge(.left, s.edgeLeft) { s.edgeLeft = $0 }, edge(.right, s.edgeRight) { s.edgeRight = $0 }])
        edges.spacing = 12

        let themes = ThemeMode.allCases
        let theme = popup([L10n.t(.themeSystem), L10n.t(.themeLight), L10n.t(.themeDark)], selected: themes.firstIndex(of: s.theme)!) {
            s.theme = themes[$0]; AppDelegate.applyTheme()
        }
        let langCodes = ["system"] + L10n.langs.map { $0.code }
        let lang = popup([L10n.t(.languageSystem)] + L10n.langs.map { $0.name }, selected: langCodes.firstIndex(of: s.language) ?? 0) { [weak self] in
            s.language = langCodes[$0]; DispatchQueue.main.async { self?.build() }
        }
        let icons = IconChoice.allCases
        let icon = popup([L10n.t(.slateIcon), L10n.t(.clayIcon)], selected: icons.firstIndex(of: s.icon)!) {
            s.icon = icons[$0]; Icons.applyAppIcon()
        }
        let login = check(L10n.t(.launchAtLogin), SMAppService.mainApp.status == .enabled) { on in
            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { NSSound.beep() }
        }
        return grid([
            [label(L10n.t(.mainSize)), main],
            [label(L10n.t(.spacing)), gapRow],
            [label(L10n.t(.edgeSpace)), edges],
            [label(L10n.t(.theme)), theme],
            [label(L10n.t(.language)), lang],
            [label(L10n.t(.appIcon)), icon],
            [NSView(), login],
        ])
    }

    private func appearance() -> NSView {
        let s = Settings.shared
        let modes = BorderMode.allCases
        let names: [BorderMode: S] = [.none: .borderNone, .active: .borderActive, .all: .borderAll, .glow: .borderGlow]
        let mode = popup(modes.map { L10n.t(names[$0]!) }, selected: modes.firstIndex(of: s.borderMode)!) { s.borderMode = modes[$0] }
        let color = ClosureColorWell(); color.color = s.borderColor
        color.handler = { s.borderColor = $0 }; color.target = color; color.action = #selector(ClosureColorWell.fire)
        color.widthAnchor.constraint(equalToConstant: 50).isActive = true
        let fm = FocusMode.allCases
        let fnames: [FocusMode: S] = [.off: .focusOff, .dim: .focusDim, .noPeek: .focusNoPeek]
        let focus = popup(fm.map { L10n.t(fnames[$0]!) }, selected: fm.firstIndex(of: s.focusMode)!) { s.focusMode = fm[$0] }
        return grid([[label(L10n.t(.borderStyle)), mode], [label(L10n.t(.borderColor)), color], [label(L10n.t(.focus)), focus]])
    }

    private func behavior() -> NSView {
        let s = Settings.shared
        excludedTable = NSTableView()
        let col = NSTableColumn(identifier: .init("app")); col.width = 300
        excludedTable.addTableColumn(col); excludedTable.headerView = nil
        excludedTable.dataSource = self; excludedTable.delegate = self
        let scroll = NSScrollView(); scroll.documentView = excludedTable; scroll.hasVerticalScroller = true
        scroll.widthAnchor.constraint(equalToConstant: 330).isActive = true; scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let rm = ClosureButton(title: L10n.t(.remove), target: nil, action: nil)
        rm.handler = { [weak self] _ in
            guard let self = self, self.excludedTable.selectedRow >= 0 else { return }
            var ex = s.excluded; ex.remove(at: self.excludedTable.selectedRow); s.excluded = ex; Tiler.shared.resyncAll()
        }
        rm.target = rm; rm.action = #selector(ClosureButton.fire)
        let add = ClosureButton(title: L10n.t(.addApp), target: nil, action: nil)
        add.handler = { _ in
            let p = NSOpenPanel(); p.allowedContentTypes = [.application]; p.directoryURL = URL(fileURLWithPath: "/Applications")
            if p.runModal() == .OK, let u = p.url, let b = Bundle(url: u)?.bundleIdentifier, !s.excluded.contains(b) {
                s.excluded = s.excluded + [b]; Tiler.shared.resyncAll()
            }
        }
        add.target = add; add.action = #selector(ClosureButton.fire)
        let buttons = NSStackView(views: [add, rm]); buttons.spacing = 8
        let box = NSStackView(views: [scroll, buttons]); box.orientation = .vertical; box.alignment = .leading; box.spacing = 8
        return grid([
            [NSView(), check(L10n.t(.animate), s.animate) { s.animate = $0 }],
            [NSView(), check(L10n.t(.tabView), s.tabView) { s.tabView = $0 }],
            [NSView(), check(L10n.t(.hoverActivate), s.hoverActivate) { s.hoverActivate = $0 }],
            [NSView(), check(L10n.t(.quickActions), s.quickActions) { s.quickActions = $0 }],
            [NSView(), check(L10n.t(.smallMonitor), s.smallMonitor) { s.smallMonitor = $0 }],
            [label(L10n.t(.excludedApps)), box],
        ])
    }

    private func shortcuts() -> NSView {
        recorders.removeAll()
        let names: [Action: S] = [.layoutGrid: .grid, .layoutColumns: .columns, .layoutRows: .rows, .layoutSide: .side, .pause: .pause,
                                  .swapLeft: .swapLeft, .swapRight: .swapRight, .swapUp: .swapUp, .swapDown: .swapDown,
                                  .cleanSpace: .cleanSpace, .focusToggle: .focus, .retile: .retile, .tileApp: .tileApp, .makeMain: .makeMain, .maximize: .maximize]
        var rows: [[NSView]] = []
        for a in Action.allCases {
            let r = ShortcutRecorder(action: a.rawValue)
            let name = String(format: L10n.t(names[a] ?? .grid), "")
            let reset = ClosureButton(title: L10n.t(.reset), target: nil, action: nil)
            reset.controlSize = .small; reset.bezelStyle = .inline
            reset.handler = { _ in Settings.shared.resetShortcut(a.rawValue); Hotkeys.shared.reload(); r.refresh() }
            reset.target = reset; reset.action = #selector(ClosureButton.fire)
            rows.append([label(name.trimmingCharacters(in: .whitespaces)), r, reset])
        }
        return grid(rows)
    }

    private func setupsPane() -> NSView {
        setupsTable = NSTableView()
        for (id, w, t) in [("name", 220.0, L10n.t(.setupName)), ("keys", 140.0, L10n.t(.shortcuts))] {
            let c = NSTableColumn(identifier: .init(id)); c.width = w; c.title = t; setupsTable.addTableColumn(c)
        }
        setupsTable.dataSource = self; setupsTable.delegate = self; setupsTable.rowHeight = 28
        let scroll = NSScrollView(); scroll.documentView = setupsTable; scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let save = ClosureButton(title: L10n.t(.saveSetup), target: nil, action: nil)
        save.handler = { [weak self] _ in MenuController.promptSaveSetup(); self?.setupsTable.reloadData(); self?.window?.makeKeyAndOrderFront(nil) }
        save.target = save; save.action = #selector(ClosureButton.fire)
        let del = ClosureButton(title: L10n.t(.deleteSetup), target: nil, action: nil)
        del.handler = { [weak self] _ in
            guard let self = self, self.setupsTable.selectedRow >= 0 else { return }
            var all = Settings.shared.setups; all.remove(at: self.setupsTable.selectedRow); Settings.shared.setups = all
            Hotkeys.shared.reload(); self.setupsTable.reloadData()
        }
        del.target = del; del.action = #selector(ClosureButton.fire)
        let note = label(L10n.t(.setupSaved), secondary: true); note.lineBreakMode = .byWordWrapping; note.preferredMaxLayoutWidth = 520
        let row = NSStackView(views: [save, del]); row.spacing = 8
        let stack = NSStackView(views: [scroll, row, note]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView(); host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 18), stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(equalToConstant: 230)])
        return host
    }

    private func about() -> NSView {
        let icon = NSImageView(image: Icons.appIcon(Settings.shared.icon) ?? NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true; icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let title = NSTextField(labelWithString: "Tegula 1.0.0"); title.font = .systemFont(ofSize: 20, weight: .semibold)
        let body = label(L10n.t(.aboutText), secondary: true); body.alignment = .center; body.preferredMaxLayoutWidth = 440; body.lineBreakMode = .byWordWrapping
        let stack = NSStackView(views: [icon, title, body]); stack.orientation = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView(); host.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: host.centerXAnchor), stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 40)])
        return host
    }

    // MARK: tables

    func numberOfRows(in t: NSTableView) -> Int { t === excludedTable ? Settings.shared.excluded.count : Settings.shared.setups.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        if t === excludedTable {
            let b = Settings.shared.excluded[row]
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b).map { FileManager.default.displayName(atPath: $0.path) } ?? b
            return NSTextField(labelWithString: name)
        }
        let s = Settings.shared.setups[row]
        if col?.identifier.rawValue == "keys" {
            let r = ShortcutRecorder(action: "setup." + s.id); r.controlSize = .small
            r.onChange = {}
            return r
        }
        let f = ClosureField(); f.stringValue = s.name; f.isBordered = false; f.drawsBackground = false
        f.handler = { new in
            var all = Settings.shared.setups
            if row < all.count, !new.isEmpty { all[row].name = new; Settings.shared.setups = all }
        }
        f.target = f; f.action = #selector(ClosureField.fire)
        return f
    }
}

// MARK: closure-based controls (keeps the UI code compact without SwiftUI)

final class ClosurePopUp: NSPopUpButton {
    var handler: ((Int) -> Void)?
    @objc func fire() { handler?(indexOfSelectedItem) }
}
final class ClosureButton: NSButton {
    var handler: ((NSButton) -> Void)?
    @objc func fire() { handler?(self) }
}
final class ClosureSlider: NSSlider {
    var handler: ((Double) -> Void)?
    @objc func fire() { handler?(doubleValue) }
}
final class ClosureField: NSTextField {
    var handler: ((String) -> Void)?
    @objc func fire() { handler?(stringValue) }
}
final class ClosureColorWell: NSColorWell {
    var handler: ((NSColor) -> Void)?
    @objc func fire() { handler?(color) }
}
