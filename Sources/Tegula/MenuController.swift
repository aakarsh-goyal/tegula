import AppKit

// MARK: - panel building blocks (hover is handled by tracking areas, so the highlight is instant)

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

private class HoverRow: NSView {
    var onClick: (() -> Void)?
    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func mouseDown(with e: NSEvent) {}
    override func mouseUp(with e: NSEvent) {
        if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() }
    }
    override func hitTest(_ p: NSPoint) -> NSView? {
        guard let v = super.hitTest(p) else { return nil }
        return (v is NSControl && !(v is NSTextField)) ? v : self
    }
    override func draw(_ r: NSRect) {
        guard hovering || selected else { return }
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.20) : NSColor.labelColor.withAlphaComponent(0.09)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

private final class LayoutCard: HoverRow {
    let kind: LayoutKind
    let title: String
    init(kind: LayoutKind, title: String, frame: NSRect) { self.kind = kind; self.title = title; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) {
        super.draw(r)
        let c: NSColor = selected ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(0.7)
        Icons.drawLayout(kind, in: NSRect(x: bounds.midX - 15, y: 9, width: 30, height: 22.5), color: c)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        (title as NSString).draw(in: NSRect(x: 0, y: 38, width: bounds.width, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular),
            .foregroundColor: selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor, .paragraphStyle: para])
    }
}

private final class ClickSwitch: NSSwitch {
    var handler: ((Bool) -> Void)?
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    @objc func fire() { handler?(state == .on) }
}

private final class ClickSegmented: NSSegmentedControl {
    var handler: ((Int) -> Void)?
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    @objc func fire() { handler?(selectedSegment) }
}

private final class PanelWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        level = .popUpMenu; isReleasedWhenClosed = false; hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
}

// MARK: - controller

final class MenuController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var panel: PanelWindow?
    private var clickMonitor: Any?
    private var activateObserver: NSObjectProtocol?
    private var panelTopLeft = NSPoint.zero
    private var displayKey: String?
    private var frontBundle: (id: String, name: String)?
    var onOpenSettings: (() -> Void)?
    var onGrantAccess: (() -> Void)?

    private let width: CGFloat = 292

    override init() {
        super.init()
        if let b = item.button {
            b.image = Icons.statusGlyph(paused: Settings.shared.paused)
            b.target = self; b.action = #selector(toggle)
            b.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.item.button?.image = Icons.statusGlyph(paused: Settings.shared.paused || Tiler.shared.stageManagerOn)
            if self.panel != nil { DispatchQueue.main.async { self.render() } }
        }
    }

    func debugOpen() { open() }

    @objc private func toggle() { panel == nil ? open() : close() }

    private func open() {
        guard panel == nil, let bw = item.button?.window else { return }
        let p = PanelWindow()
        panel = p
        displayKey = bw.screen.map { Geo.key($0) } ?? Tiler.shared.currentDisplay()
        let bf = bw.frame
        panelTopLeft = NSPoint(x: bf.midX - width / 2, y: bf.minY - 6)
        if let vis = (bw.screen ?? NSScreen.main)?.visibleFrame {
            panelTopLeft.x = min(max(panelTopLeft.x, vis.minX + 8), vis.maxX - width - 8)
        }
        render()
        Log.d("panel open button=\(bf) panel=\(p.frame) screen=\(bw.screen?.frame ?? .zero)")
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; p.animator().alphaValue = 1 }
        // Dismiss when the user clicks anywhere else (installed only while the panel is open).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.close() }
        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.processIdentifier != getpid() { self?.close() }
            }
    }

    private func close() {
        Log.d("panel close")
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let o = activateObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); activateObserver = nil }
        panel?.orderOut(nil)
        panel = nil
    }

    private func then(_ f: @escaping () -> Void) -> () -> Void { { [weak self] in self?.close(); f() } }

    // MARK: rendering

    private func row(_ symbol: String?, _ title: String, trailing: String? = nil, h: CGFloat = 28, action: @escaping () -> Void) -> HoverRow {
        let r = HoverRow(frame: NSRect(x: 0, y: 0, width: width - 12, height: h))
        r.onClick = action
        var x: CGFloat = 12
        if let s = symbol, let img = NSImage(systemSymbolName: s, accessibilityDescription: nil) {
            let iv = NSImageView(image: img)
            iv.frame = NSRect(x: 10, y: (h - 16) / 2, width: 18, height: 16)
            iv.contentTintColor = .secondaryLabelColor; iv.imageScaling = .scaleProportionallyDown
            r.addSubview(iv); x = 36
        }
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13); t.lineBreakMode = .byTruncatingTail
        t.frame = NSRect(x: x, y: (h - 17) / 2, width: r.bounds.width - x - (trailing == nil ? 12 : 92), height: 17)
        r.addSubview(t)
        if let tr = trailing {
            let l = NSTextField(labelWithString: tr)
            l.font = .systemFont(ofSize: 12); l.textColor = .tertiaryLabelColor; l.alignment = .right
            l.frame = NSRect(x: r.bounds.width - 92, y: (h - 16) / 2, width: 80, height: 16)
            r.addSubview(l)
        }
        return r
    }

    private func switchRow(_ symbol: String, _ title: String, trailing: String? = nil, on: Bool, _ change: @escaping (Bool) -> Void) -> HoverRow {
        let r = row(symbol, title, trailing: nil) {}
        let sw = ClickSwitch()
        sw.controlSize = .small; sw.state = on ? .on : .off; sw.handler = change
        sw.target = sw; sw.action = #selector(ClickSwitch.fire)
        sw.sizeToFit()
        sw.frame.origin = NSPoint(x: r.bounds.width - sw.frame.width - 10, y: (r.bounds.height - sw.frame.height) / 2)
        r.addSubview(sw)
        r.onClick = { sw.state = sw.state == .on ? .off : .on; change(sw.state == .on) }
        return r
    }

    private func separator() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width - 12, height: 1))
        v.wantsLayer = true; v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return v
    }

    private func sectionLabel(_ s: String) -> NSView {
        let t = NSTextField(labelWithString: s.uppercased())
        t.font = .systemFont(ofSize: 10, weight: .semibold); t.textColor = .tertiaryLabelColor
        t.frame = NSRect(x: 12, y: 0, width: width - 36, height: 14)
        return t
    }

    private func render() {
        guard let p = panel else { return }
        let set = Settings.shared
        let content = FlippedView()
        var y: CGFloat = 8
        func add(_ v: NSView, gap: CGFloat = 2) {
            v.frame.origin = NSPoint(x: 6, y: y)
            content.addSubview(v)
            y += v.frame.height + gap
        }

        if !Tiler.shared.trusted {
            add(row("exclamationmark.triangle.fill", L10n.t(.grantAccess), action: then { [weak self] in self?.onGrantAccess?() }), gap: 6)
        }

        // layouts
        let current = displayKey.map { set.layout(for: $0) } ?? .grid
        let kinds: [(LayoutKind, S)] = [(.grid, .grid), (.columns, .columns), (.rows, .rows), (.side, .side)]
        let cw = (width - 12 - 6) / 4
        let cards = NSView(frame: NSRect(x: 0, y: 0, width: width - 12, height: 58))
        for (i, (k, s)) in kinds.enumerated() {
            let c = LayoutCard(kind: k, title: L10n.t(s), frame: NSRect(x: CGFloat(i) * (cw + 2), y: 0, width: cw, height: 58))
            c.selected = k == current
            c.onClick = { [weak self] in Tiler.shared.setLayout(k, display: self?.displayKey) }
            cards.addSubview(c)
        }
        add(cards, gap: 6)
        add(separator(), gap: 6)

        add(switchRow("pause.circle", L10n.t(.pause), on: set.paused) { _ in Tiler.shared.togglePause() })
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
           app.activationPolicy == .regular, let b = app.bundleIdentifier {
            frontBundle = (b, app.localizedName ?? b)
            let name = app.localizedName ?? b
            add(switchRow("macwindow", String(format: L10n.t(.tileApp), name), on: !set.excluded.contains(b)) { _ in
                Tiler.shared.toggleTile(bundle: b)
            })
        }
        // Apps switched off for tiling stay listed here so a skipped app is never a mystery.
        for b in set.excluded where b != frontBundle?.id {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? b
            add(switchRow("macwindow", String(format: L10n.t(.tileApp), name), on: false) { _ in Tiler.shared.toggleTile(bundle: b) })
        }
        add(separator(), gap: 8)

        // focus
        let focusRow = NSView(frame: NSRect(x: 0, y: 0, width: width - 12, height: 30))
        let fl = NSTextField(labelWithString: L10n.t(.focus)); fl.font = .systemFont(ofSize: 13)
        fl.frame = NSRect(x: 12, y: 6, width: 60, height: 17); focusRow.addSubview(fl)
        let modes = FocusMode.allCases
        let seg = ClickSegmented(labels: [L10n.t(.focusOff), L10n.t(.focusDim), L10n.t(.focusNoPeek)], trackingMode: .selectOne, target: nil, action: nil)
        seg.selectedSegment = modes.firstIndex(of: set.focusMode) ?? 0
        seg.controlSize = .small; seg.handler = { Settings.shared.focusMode = modes[$0] }
        seg.target = seg; seg.action = #selector(ClickSegmented.fire)
        seg.frame = NSRect(x: 76, y: 3, width: width - 12 - 76 - 8, height: 22)
        focusRow.addSubview(seg)
        add(focusRow, gap: 2)

        add(row("sparkles", L10n.t(.cleanSpace), trailing: set.shortcut(for: Action.cleanSpace.rawValue)?.display, action: then { Tiler.shared.cleanSpace() }))
        add(row("arrow.triangle.2.circlepath", L10n.t(.retile), trailing: set.shortcut(for: Action.retile.rawValue)?.display, action: then { Tiler.shared.resyncAll(reset: true) }))
        add(separator(), gap: 8)

        // setups
        add(sectionLabel(L10n.t(.setupsHint)), gap: 4)
        for s in set.setups {
            add(row("rectangle.3.group", s.name, trailing: s.shortcut?.display, action: then { Tiler.shared.launchSetup(s) }))
        }
        add(row("plus.circle", L10n.t(.saveSetup), action: then { MenuController.promptSaveSetup() }))
        add(separator(), gap: 8)

        add(row("gearshape", L10n.t(.settings), trailing: "⌘,", action: then { [weak self] in self?.onOpenSettings?() }))
        add(row("power", L10n.t(.quit), trailing: "⌘Q", action: then { NSApp.terminate(nil) }), gap: 6)

        let fx = NSVisualEffectView()
        fx.material = .menu; fx.state = .active; fx.blendingMode = .behindWindow
        fx.wantsLayer = true; fx.layer?.cornerRadius = 14; fx.layer?.masksToBounds = true
        content.frame = NSRect(x: 0, y: 0, width: width, height: y)
        fx.addSubview(content)
        p.contentView = fx
        p.setFrame(NSRect(x: panelTopLeft.x, y: panelTopLeft.y - y, width: width, height: y), display: true)
    }

    static func promptSaveSetup() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.t(.setupName)
        alert.informativeText = L10n.t(.setupSaved)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = "Setup \(Settings.shared.setups.count + 1)"
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t(.save)); alert.addButton(withTitle: L10n.t(.cancel))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        let s = Tiler.shared.captureSetup(name: name.isEmpty ? "Setup" : name)
        Settings.shared.setups = Settings.shared.setups + [s]
        Hotkeys.shared.reload()
    }
}

