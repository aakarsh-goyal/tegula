import AppKit
import QuartzCore

struct TileInfo {
    let key: String
    let index: Int
    let rect: CGRect          // AX coords, full tile (including tab strip area)
    let ids: [CGWindowID]     // stack, last = top
    var top: CGWindowID { ids.last! }
}

enum TabStripLayout { static let height: CGFloat = 26 }

/// Click-through, non-activating panel used for borders and the focus dimmer.
class OverlayPanel: NSPanel {
    init(interactive: Bool = false) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = .normal; ignoresMouseEvents = !interactive
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false; hidesOnDeactivate = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Glide to `r` in step with the windows (same curve and duration), or jump.
    func move(to r: NSRect, animated: Bool) {
        if animated && isVisible && frame != r {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.duration; ctx.timingFunction = Motion.curve
                self.animator().setFrame(r, display: true)
            }
        } else {
            setFrame(r, display: false)
        }
    }

    func fadeIn(_ d: TimeInterval = 0.25) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = d; ctx.timingFunction = Motion.curve
            self.animator().alphaValue = 1
        }
    }
}

private final class BorderView: NSView {
    let ring = CALayer()
    private var margin: CGFloat = 20
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.addSublayer(ring)
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(width: CGFloat, color: NSColor, glow: Bool, margin: CGFloat) {
        self.margin = margin
        ring.cornerRadius = 16
        ring.borderWidth = width
        ring.borderColor = color.cgColor
        ring.shadowColor = color.cgColor
        ring.shadowOpacity = glow ? 0.95 : 0
        ring.shadowRadius = glow ? 10 : 0
        ring.shadowOffset = .zero
        needsLayout = true
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.frame = bounds.insetBy(dx: margin, dy: margin)
        CATransaction.commit()
    }
}

final class BorderPanel: OverlayPanel {
    fileprivate let view = BorderView(frame: .zero)
    override init(interactive: Bool = false) { super.init(); contentView = view }
}

/// Focus cover ordered directly beneath the active window: a dark tint, with optional behind-window blur.
private final class DimPanel: OverlayPanel {
    let host = NSView()
    let fx = NSVisualEffectView()
    let tint = NSView()
    override init(interactive: Bool = false) {
        super.init()
        fx.material = .hudWindow; fx.blendingMode = .behindWindow; fx.state = .active
        fx.appearance = NSAppearance(named: .vibrantDark)
        tint.wantsLayer = true; tint.layer?.backgroundColor = NSColor.black.cgColor
        fx.autoresizingMask = [.width, .height]; tint.autoresizingMask = [.width, .height]
        host.addSubview(fx); host.addSubview(tint)
        contentView = host
        alphaValue = 0
    }
    func fit(_ size: NSSize) {
        let r = NSRect(origin: .zero, size: size)
        host.frame = r; fx.frame = r; tint.frame = r
    }
}

private final class ClickFirstButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class TabBar: NSVisualEffectView {
    var items: [(id: CGWindowID, title: String, icon: NSImage?)] = []
    var active: CGWindowID = 0
    var onSelect: ((CGWindowID) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    override func draw(_ r: NSRect) {
        super.draw(r)
        guard !items.isEmpty else { return }
        let w = bounds.width / CGFloat(items.count)
        for (i, it) in items.enumerated() {
            let seg = NSRect(x: CGFloat(i) * w + 2, y: 2, width: w - 4, height: bounds.height - 4)
            let sel = it.id == active
            (sel ? NSColor.controlAccentColor.withAlphaComponent(0.28) : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
            NSBezierPath(roundedRect: seg, xRadius: 7, yRadius: 7).fill()
            var x = seg.minX + 8
            if let icon = it.icon { icon.draw(in: NSRect(x: x, y: seg.minY + 3, width: 14, height: 14)); x += 19 }
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: sel ? .semibold : .regular),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(sel ? 1 : 0.7), .paragraphStyle: para]
            (it.title as NSString).draw(in: NSRect(x: x, y: seg.minY + 3.5, width: seg.maxX - x - 6, height: 15), withAttributes: attrs)
        }
    }
    override func mouseDown(with e: NSEvent) {
        guard !items.isEmpty else { return }
        let x = convert(e.locationInWindow, from: nil).x
        let i = min(items.count - 1, max(0, Int(x / (bounds.width / CGFloat(items.count)))))
        onSelect?(items[i].id)
    }
}

private final class TabPanel: OverlayPanel {
    let bar = TabBar()
    init() {
        super.init(interactive: true)
        bar.material = .headerView; bar.blendingMode = .behindWindow; bar.state = .active
        bar.wantsLayer = true; bar.layer?.cornerRadius = 9; bar.layer?.masksToBounds = true
        contentView = bar
        level = .floating
    }
}

private final class QuickPanel: OverlayPanel {
    var onAction: ((Int) -> Void)?
    init() {
        super.init(interactive: true)
        let fx = NSVisualEffectView(); fx.material = .hudWindow; fx.state = .active; fx.blendingMode = .behindWindow
        fx.wantsLayer = true; fx.layer?.cornerRadius = 9; fx.layer?.masksToBounds = true
        let stack = NSStackView(); stack.spacing = 2; stack.edgeInsets = NSEdgeInsets(top: 1, left: 4, bottom: 1, right: 4)
        let symbols = ["rectangle.on.rectangle.angled", "arrow.up.left.and.arrow.down.right", "xmark"]
        for (i, s) in symbols.enumerated() {
            let b = ClickFirstButton(); b.isBordered = false; b.tag = i
            b.image = NSImage(systemSymbolName: s, accessibilityDescription: nil)
            b.contentTintColor = .labelColor; b.target = self; b.action = #selector(tap(_:))
            b.toolTip = [L10n.t(.makeMain), L10n.t(.floatWin), L10n.t(.closeWin)][i]
            stack.addArrangedSubview(b)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 92, height: 22); fx.addSubview(stack)
        contentView = fx; level = .floating
    }
    @objc func tap(_ b: NSButton) { onAction?(b.tag) }
}

/// Everything drawn on top of / beneath other apps' windows. Rebuilt from a snapshot of the tiler state.
final class Overlays {
    static let shared = Overlays()

    private var borders: [BorderPanel] = []
    private var dims: [DimPanel] = []
    private var tabs: [TabPanel] = []
    private let quick = QuickPanel()
    private var dimHideWork: DispatchWorkItem?

    init() {
        quick.onAction = { i in
            guard let id = Tiler.shared.activeID else { return }
            switch i {
            case 0: Tiler.shared.makeMain(id)
            case 1: Tiler.shared.floatWindow(id)
            default: Tiler.shared.closeWindow(id)
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.dims.forEach { $0.orderOut(nil) }; self?.dims.removeAll()
        }
    }

    func hideAll() {
        dimHideWork?.cancel()
        (borders as [NSWindow] + dims as [NSWindow] + tabs as [NSWindow] + [quick]).forEach { $0.orderOut(nil) }
    }

    func refresh(tiles: [TileInfo], active: CGWindowID?, focused: CGWindowID?, animated: Bool) {
        let s = Settings.shared
        let glide = animated && Motion.enabled
        updateBorders(tiles, active, s, glide)
        updateTabs(tiles, active, s, glide)
        updateDim(focused, s)
        updateQuick(tiles, active, s)
    }

    // MARK: borders

    private func updateBorders(_ tiles: [TileInfo], _ active: CGWindowID?, _ s: Settings, _ glide: Bool) {
        var want: [(TileInfo, Bool)] = []
        switch s.borderMode {
        case .none: break
        case .active, .glow: if let a = active, let t = tiles.first(where: { $0.ids.contains(a) }) { want = [(t, true)] }
        case .all: want = tiles.map { ($0, active != nil && $0.ids.contains(active!)) }
        }
        while borders.count < want.count { borders.append(BorderPanel()) }
        let width = CGFloat(min(3.0, max(1.5, s.gap / 2)))
        let margin: CGFloat = 20
        for (i, p) in borders.enumerated() {
            guard i < want.count else { p.orderOut(nil); continue }
            let (t, isActive) = want[i]
            let r = Geo.flip(t.rect).insetBy(dx: -width - margin, dy: -width - margin).integral
            let c = s.borderColor.withAlphaComponent(isActive ? 1 : 0.35)
            let fresh = !p.isVisible
            if fresh { p.alphaValue = 0; p.setFrame(r, display: false) } else { p.move(to: r, animated: glide) }
            p.view.configure(width: width, color: c, glow: s.borderMode == .glow && isActive, margin: margin)
            p.order(.above, relativeTo: Int(t.top))
            if fresh { p.fadeIn() }
        }
    }

    // MARK: tab strips

    private func updateTabs(_ tiles: [TileInfo], _ active: CGWindowID?, _ s: Settings, _ glide: Bool) {
        let stacked = s.tabView ? tiles.filter { $0.ids.count > 1 } : []
        while tabs.count < stacked.count {
            let p = TabPanel()
            p.bar.onSelect = { Tiler.shared.focus($0) }
            tabs.append(p)
        }
        for (i, p) in tabs.enumerated() {
            guard i < stacked.count else { p.orderOut(nil); continue }
            let t = stacked[i]
            var r = t.rect; r.size.height = TabStripLayout.height - 2
            let fresh = !p.isVisible
            if fresh { p.alphaValue = 0; p.setFrame(Geo.flip(r), display: false) } else { p.move(to: Geo.flip(r), animated: glide) }
            p.bar.items = t.ids.map { id in
                let tw = Tiler.shared.wins[id]
                let app = tw.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
                let icon = app?.icon; icon?.size = NSSize(width: 14, height: 14)
                return (id, tw?.el.string(kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? app?.localizedName ?? "—", icon)
            }
            p.bar.active = active.flatMap { t.ids.contains($0) ? $0 : nil } ?? t.top
            p.bar.needsDisplay = true
            p.orderFront(nil)
            if fresh { p.fadeIn() }
        }
    }

    // MARK: focus dim (blur + darken, eased in and out)

    private func updateDim(_ focused: CGWindowID?, _ s: Settings) {
        guard s.focusMode != .off else { dimHideWork?.cancel(); fadeOutDims(0.3); return }
        guard let f = focused else {
            // Focus is momentarily nil while switching apps: wait a beat so the dim doesn't flicker.
            if dimHideWork == nil {
                let w = DispatchWorkItem { [weak self] in self?.dimHideWork = nil; self?.fadeOutDims(0.35) }
                dimHideWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
            }
            return
        }
        dimHideWork?.cancel(); dimHideWork = nil
        let screens = NSScreen.screens
        while dims.count < screens.count { dims.append(DimPanel()) }
        // Dim Others: darker only, no blur. No Peek: blurred and darkened.
        let blur: CGFloat = s.focusMode == .noPeek ? 1 : 0
        let tint: CGFloat = s.focusMode == .noPeek ? 0.30 : 0.58
        for (i, p) in dims.enumerated() {
            guard i < screens.count else { p.orderOut(nil); continue }
            if p.frame != screens[i].frame {
                p.setFrame(screens[i].frame, display: false)
                p.fit(screens[i].frame.size)
            }
            let fresh = !p.isVisible
            if fresh { p.alphaValue = 0; p.tint.alphaValue = tint; p.fx.alphaValue = blur }
            p.order(.below, relativeTo: Int(f))
            if p.alphaValue < 1 || p.tint.alphaValue != tint || p.fx.alphaValue != blur {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = fresh ? 0.55 : 0.3; ctx.timingFunction = Motion.curve
                    p.animator().alphaValue = 1
                    p.tint.animator().alphaValue = tint
                    p.fx.animator().alphaValue = blur
                }
            }
        }
    }

    private func fadeOutDims(_ d: TimeInterval) {
        for p in dims where p.isVisible && p.alphaValue > 0 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = d; ctx.timingFunction = Motion.curve
                p.animator().alphaValue = 0
            }, completionHandler: { if p.alphaValue == 0 { p.orderOut(nil) } })
        }
    }

    // MARK: quick actions

    private func updateQuick(_ tiles: [TileInfo], _ active: CGWindowID?, _ s: Settings) {
        guard s.quickActions, let a = active, let t = tiles.first(where: { $0.ids.contains(a) }) else { quick.orderOut(nil); return }
        let strip = (s.tabView && t.ids.count > 1) ? TabStripLayout.height : 0
        let ax = CGRect(x: t.rect.maxX - 104, y: t.rect.minY + strip + 5, width: 92, height: 22)
        quick.setFrame(Geo.flip(ax), display: false)
        quick.order(.above, relativeTo: Int(a))
    }
}
