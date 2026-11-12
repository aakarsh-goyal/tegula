import AppKit
import ApplicationServices

final class TWin {
    let id: CGWindowID
    let el: AXUIElement
    let pid: pid_t
    let bundle: String
    var display: String
    var lastApplied = Date.distantPast
    var expected = CGRect.zero
    var snapCount = 0
    var snapStamp = Date.distantPast
    var anchorRight = false, anchorBottom = false     // tile touches the screen's right/bottom edge
    var settledTarget: CGRect?, settledFrame: CGRect?  // where an increment-snapping window ended up for a target
    init(id: CGWindowID, el: AXUIElement, pid: pid_t, bundle: String, display: String) {
        self.id = id; self.el = el; self.pid = pid; self.bundle = bundle; self.display = display
    }
}

private let axCallback: AXObserverCallback = { _, el, note, _ in
    Tiler.shared.axEvent(el, note as String)
}

/// KVO shim so we hear about Stage Manager being toggled without polling.
private final class DefaultsKVO: NSObject {
    let defaults: UserDefaults, key: String, cb: () -> Void
    init(_ d: UserDefaults, _ key: String, _ cb: @escaping () -> Void) {
        defaults = d; self.key = key; self.cb = cb
        super.init()
        d.addObserver(self, forKeyPath: key, options: [.new], context: nil)
    }
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) { cb() }
}

/// Owns window state and drives the layout engine. Entirely event-driven: AX observer callbacks,
/// workspace notifications, hotkeys and one-shot debounce blocks. There are no repeating timers.
final class Tiler {
    static let shared = Tiler()

    private(set) var wins: [CGWindowID: TWin] = [:]
    private var tiles: [String: [[CGWindowID]]] = [:]       // per display: tiles, each a stack (last = top)
    private var tileRects: [String: [CGRect]] = [:]         // full tile rects (AX coords)
    private var observers: [pid_t: AXObserver] = [:]
    private var observed: [CGWindowID: pid_t] = [:]
    private var minSizes: [CGWindowID: CGSize] = [:]
    private var userFloating = Set<CGWindowID>()
    private(set) var activeID: CGWindowID?                  // focused AND tiled
    private(set) var focusedRaw: CGWindowID?                // focused window, tiled or not
    private var focusedFullScreen = false                    // that window is in native full screen (its own Space)
    private var fullScreenIDs = Set<CGWindowID>()          // tiled windows currently in native full screen: they keep their tile
    private var maximized: [String: CGWindowID] = [:]      // per display: the tiled window currently filling the screen
    private var freeMax: [CGWindowID: CGRect] = [:]         // restore frames for maximized windows we don't tile
    private var mru: [CGWindowID] = []                       // window ids, most recently active first
    private var lastActive: [pid_t: CGWindowID] = [:]       // per app: last tiled window that was active

    private var started = false
    private var pendingPIDs = Set<pid_t>()
    private var syncWork: DispatchWorkItem?
    private var dirty = Set<String>()
    private var retileWork: DispatchWorkItem?
    private var stageKVO: DefaultsKVO?
    private let stageDefaults = UserDefaults(suiteName: "com.apple.WindowManager")

    private var dragID: CGWindowID?
    private var dragCmd = false
    private var mouseUpMonitor: Any?
    private var hoverMonitor: Any?
    private var hoverTile: (String, Int)?
    private var hoverWork: DispatchWorkItem?
    private var pendingSetup: (setup: Setup, deadline: Date)?

    var trusted: Bool { AXIsProcessTrusted() }
    var stageManagerOn: Bool { stageDefaults?.bool(forKey: "GloballyEnabled") ?? false }
    var running: Bool { started && trusted && !Settings.shared.paused && !stageManagerOn }

    // MARK: lifecycle

    func start() {
        guard !started, trusted else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        func on(_ n: Notification.Name, _ f: @escaping (Notification) -> Void) {
            ws.addObserver(forName: n, object: nil, queue: .main, using: f)
        }
        func pidOf(_ n: Notification) -> pid_t? {
            (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [self] n in
            guard running, let p = pidOf(n) else { return }
            ensureObserver(p); scheduleSync(p)
        }
        on(NSWorkspace.didTerminateApplicationNotification) { [self] n in
            guard let p = pidOf(n) else { return }
            observers[p] = nil; scheduleSync(p)
        }
        on(NSWorkspace.didHideApplicationNotification) { [self] n in pidOf(n).map { scheduleSync($0) } }
        on(NSWorkspace.didUnhideApplicationNotification) { [self] n in pidOf(n).map { scheduleSync($0) } }
        on(NSWorkspace.didActivateApplicationNotification) { [self] _ in refreshActive() }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [self] _ in
            // macOS reshuffles window order while a Space transition settles: keep the dimmer under the focused
            // window for that short stretch (one-shot burst, ~0.6s, not a standing timer).
            func burst(_ n: Int) {
                Overlays.shared.reassertDimOrder(below: focusedRaw)
                if n > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { burst(n - 1) } }
            }
            refreshActive(draw: false)   // learn right now whether we are in / left full screen
            // The slide is over: bring the dimmer back once the window has settled into its tile (gently).
            if !focusedFullScreen && Overlays.shared.dimsSuppressed { scheduleDimResume(after: 0.15) }
            burst(75)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.resyncAll() }
        }
        on(NSWorkspace.didWakeNotification) { [self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.resyncAll() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [self] _ in screensChanged() }
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [self] _ in settingsChanged() }
        stageKVO = DefaultsKVO(stageDefaults ?? .standard, "GloballyEnabled") { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.stageManagerOn { Overlays.shared.hideAll() } else { self.resyncAll() }
                NotificationCenter.default.post(name: Settings.changed, object: nil)
            }
        }
        Overlays.shared.frameProvider = { [weak self] id in self?.wins[id].flatMap { $0.expected == .zero ? nil : $0.expected } }   // no AX call on the hot path
        WindowAnimator.shared.touch = { [weak self] id in self?.wins[id]?.lastApplied = Date() }
        WindowAnimator.shared.onFinish = { [weak self] id in
            guard let self = self, let tw = self.wins[id], let f = tw.el.frame else { return }
            let r = tw.expected
            if f.width > r.width + 2 || f.height > r.height + 2 { self.verify.append((id, r, tw.display)); self.scheduleVerify() }
            self.settle(tw)
        }
        updateHoverMonitor(); updateClickMonitor()
        resyncAll(initial: true)
    }

    // MARK: AX observers

    private func ensureObserver(_ pid: pid_t) {
        guard observers[pid] == nil, pid != getpid() else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let o = obs else { return }
        let app = AXUIElementCreateApplication(pid)
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                  kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            AXObserverAddNotification(o, app, n as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        observers[pid] = o
    }

    private func observeWindow(_ w: AXUIElement, _ id: CGWindowID, _ pid: pid_t) {
        guard observed[id] == nil, let o = observers[pid] else { return }
        observed[id] = pid
        for n in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                  kAXWindowMovedNotification, kAXWindowResizedNotification] {
            AXObserverAddNotification(o, w, n as CFString, nil)
        }
    }

    fileprivate func axEvent(_ el: AXUIElement, _ note: String) {
        guard started, !Settings.shared.paused else { return }
        Log.d("ax \(note) pid=\(el.pid)")
        switch note {
        case kAXFocusedWindowChangedNotification: refreshActive()
        case kAXWindowMovedNotification, kAXWindowResizedNotification: geometryChanged(el)
        default:
            Overlays.shared.reassertDimOrder(below: focusedRaw)
            scheduleSync(el.pid)
        }
    }

    // MARK: sync

    private func scheduleSync(_ pid: pid_t) {
        pendingPIDs.insert(pid)
        guard syncWork == nil else { return }
        let w = DispatchWorkItem { [self] in
            syncWork = nil
            let pids = pendingPIDs; pendingPIDs.removeAll()
            for p in pids { syncApp(p) }
            flush()
        }
        syncWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: w)
    }

    func resyncAll(initial: Bool = false, reset: Bool = false) {
        Log.d("resyncAll initial=\(initial) reset=\(reset)")
        guard started else { return }
        if reset { userFloating.removeAll(); minSizes.removeAll() }
        guard running else { Overlays.shared.hideAll(); return }
        let order = initial ? zOrder() : []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            ensureObserver(app.processIdentifier)
        }
        // Drop everything we think we know, then rediscover (keeps order when not resetting).
        let pids = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { $0.processIdentifier })
        for p in pids { syncApp(p) }
        for w in wins.values where !pids.contains(w.pid) { remove(w.id) }
        if initial { reorder(by: order); mru = order.filter { wins[$0] != nil } }
        if reset { for key in tiles.keys { tiles[key] = tiles[key]?.filter { !$0.isEmpty } } }
        refreshActive(draw: false)
        flushAll(animated: reset)
    }

    /// Front-to-back window ids, used once at startup so the frontmost windows get the biggest tiles.
    private func zOrder() -> [CGWindowID] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    private func reorder(by z: [CGWindowID]) {
        let rank = Dictionary(uniqueKeysWithValues: z.enumerated().map { ($1, $0) })
        for key in tiles.keys {
            let flat = (tiles[key] ?? []).flatMap { $0 }.sorted { (rank[$0] ?? 9999) < (rank[$1] ?? 9999) }
            var fresh: [[CGWindowID]] = []
            let cap = capacity(key)
            for id in flat {
                if fresh.count < cap { fresh.append([id]) } else { fresh[cap - 1].insert(id, at: 0) }
            }
            tiles[key] = fresh
        }
    }

    private func eligible(_ w: AXUIElement, id: CGWindowID, bundle: String, hidden: Bool) -> Bool {
        if hidden || userFloating.contains(id) || Settings.shared.excluded.contains(bundle) { return false }
        guard w.string(kAXRoleAttribute) == kAXWindowRole, w.string(kAXSubroleAttribute) == kAXStandardWindowSubrole else { return false }
        if w.bool(kAXMinimizedAttribute) == true || w.bool("AXFullScreen") == true { return false }
        return w.isSettable(kAXPositionAttribute) && w.isSettable(kAXSizeAttribute)
    }

    private func syncApp(_ pid: pid_t) {
        guard running else { return }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.activationPolicy == .regular, pid != getpid() else {
            for w in wins.values where w.pid == pid { remove(w.id) }
            for (id, p) in observed where p == pid { observed[id] = nil }
            return
        }
        let bundle = app.bundleIdentifier ?? "pid.\(pid)"
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        // A failed/timed-out read is NOT "no windows": keep what we know and try again on the next event.
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success else { return }
        let list = (raw as? [AXUIElement]) ?? []
        var present = Set<CGWindowID>()
        let screens = ScreenInfo.all()
        for w in list {
            guard let id = w.windowID else { continue }
            observeWindow(w, id, pid)
            if wins[id] != nil {
                // Already tiled: only a positive signal removes it (don't re-probe attributes that can time out).
                if app.isHidden || userFloating.contains(id) || Settings.shared.excluded.contains(bundle)
                    || w.bool(kAXMinimizedAttribute) == true { continue }
                // Native full screen is temporary: keep the window's slot in the layout so it returns to it.
                if w.bool("AXFullScreen") == true { fullScreenIDs.insert(id) }
                else if fullScreenIDs.remove(id) != nil { dirty.insert(wins[id]?.display ?? "") }
                present.insert(id); continue
            }
            guard eligible(w, id: id, bundle: bundle, hidden: app.isHidden) else { continue }
            present.insert(id)
            if wins[id] == nil {
                let f = w.frame ?? .zero
                let c = CGPoint(x: f.midX, y: f.midY)
                let key = (screens.first { $0.full.contains(c) } ?? screens.first { $0.full.contains(Geo.axMouse()) } ?? screens.first)?.key ?? ""
                let tw = TWin(id: id, el: w, pid: pid, bundle: bundle, display: key)
                wins[id] = tw
                place(tw)
            }
        }
        // AX only lists the windows of the Space you are looking at. A tracked window that is merely on another
        // Space (e.g. while an app is in native full screen) is still alive: keep its slot in the layout.
        let missing = wins.values.filter { $0.pid == pid && !present.contains($0.id) }
        let alive = missing.contains { w in !list.contains { $0.windowID == w.id } } ? allWindowIDs() : []
        for w in missing {
            if !list.contains(where: { $0.windowID == w.id }) && alive.contains(w.id) { present.insert(w.id); continue }
            remove(w.id)
        }
        for (id, p) in observed where p == pid && !list.contains(where: { $0.windowID == id }) { observed[id] = nil; minSizes[id] = nil }
        if pendingSetup != nil { applyPendingSetup() }
    }

    /// Every existing window on every Space (a closed window drops out of this list).
    private func allWindowIDs() -> Set<CGWindowID> {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    /// Small monitor mode only: Columns and Rows hold at most two windows; anything beyond that stacks behind a tile.
    private func twoWindowLimit(_ key: String) -> Bool {
        Settings.shared.smallMonitor && [.columns, .rows].contains(Settings.shared.layout(for: key))
    }

    private func capacity(_ key: String) -> Int {
        if twoWindowLimit(key) { return 2 }
        return ScreenInfo.all().first { $0.key == key }?.capacity ?? 4
    }

    /// Rank of a tile = its most recently used window (lower = more recent).
    private func tileRank(_ t: [CGWindowID]) -> Int { t.map(rank).min() ?? Int.max }

    private func place(_ tw: TWin) {
        var t = tiles[tw.display] ?? []
        if t.count < capacity(tw.display) {
            t.append([tw.id])
        } else if twoWindowLimit(tw.display) {
            // Two-window layouts: the new window takes the tile of the least recently used window,
            // which stacks behind it. The most recently used window keeps its place.
            let idx = t.indices.max { tileRank(t[$0]) < tileRank(t[$1]) } ?? t.count - 1
            t[idx].append(tw.id)
        } else {
            let idx = activeID.flatMap { a in t.firstIndex { $0.contains(a) } } ?? t.count - 1
            t[idx].append(tw.id)
        }
        tiles[tw.display] = t
        dirty.insert(tw.display)
    }

    private func remove(_ id: CGWindowID) {
        guard let tw = wins.removeValue(forKey: id) else { return }
        for key in tiles.keys {
            tiles[key] = tiles[key]?.map { $0.filter { $0 != id } }.filter { !$0.isEmpty }
        }
        minSizes[id] = nil
        mru.removeAll { $0 == id }
        fullScreenIDs.remove(id)
        for k in maximized.keys where maximized[k] == id { maximized[k] = nil }
        dirty.insert(tw.display)
    }

    private func rebalance(_ t: inout [[CGWindowID]], cap: Int) {
        while t.count > cap, t.count > 1 {
            // stack the least recently used tile behind the next-least-recent one
            let order = t.indices.sorted { a, b in
                let ra = tileRank(t[a]), rb = tileRank(t[b])
                return ra != rb ? ra > rb : a > b
            }
            let victim = order[0], host = order[1]
            t[host] = (t[host] + t[victim]).sorted { rank($0) > rank($1) }
            t.remove(at: victim)
        }
        while t.count < cap, let i = t.firstIndex(where: { $0.count > 1 }) {
            t.append([t[i].removeFirst()])
        }
    }

    // MARK: retile

    private func flush(animated: Bool = true) {
        let keys = dirty; dirty.removeAll()
        for k in keys { retile(k, animated: animated) }
        refreshActive(draw: false); publish(animated: animated)
    }
    private func flushAll(animated: Bool = true) { for s in ScreenInfo.all() { dirty.insert(s.key) }; flush(animated: animated) }

    func scheduleRetileAll() {
        guard retileWork == nil else { return }
        let w = DispatchWorkItem { [self] in retileWork = nil; flushAll() }
        retileWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: w)
    }

    private func rank(_ id: CGWindowID) -> Int { mru.firstIndex(of: id) ?? mru.count + 1000 }

    private func tileMin(_ ids: [CGWindowID]) -> CGSize {
        var s = CGSize.zero
        for id in ids { if let m = minSizes[id] { s.width = max(s.width, m.width); s.height = max(s.height, m.height) } }
        return s
    }

    private func retile(_ key: String, animated: Bool = true) {
        guard running, let scr = ScreenInfo.all().first(where: { $0.key == key }) else { return }
        let set = Settings.shared
        var work = (tiles[key] ?? []).map { $0.filter { wins[$0] != nil } }.filter { !$0.isEmpty }
        // Self-heal: a window we track on this display that sits in no tile (and isn't deliberately floated)
        // would never be tiled again. Adopt it.
        let tiled = Set(tiles.values.flatMap { $0.flatMap { $0 } })
        for tw in wins.values.sorted(by: { $0.id < $1.id }) where tw.display == key && !tiled.contains(tw.id) && !userFloating.contains(tw.id) {
            Log.d("retile adopts orphan win=\(tw.id) bundle=\(tw.bundle)")
            work.append([tw.id])
        }
        rebalance(&work, cap: capacity(key))
        if let m = maximized[key], !work.contains(where: { $0.contains(m) }) { maximized[key] = nil }
        guard !work.isEmpty else { tiles[key] = []; tileRects[key] = []; return }

        let gap = set.gap
        let avail = scr.usable.insetBy(dx: gap, dy: gap)
        let kind = set.layout(for: key)
        var rects: [CGRect] = []
        var floated: [CGWindowID] = []
        while true {
            let mins = work.map { tileMin($0) }
            let tree = LayoutEngine.tree(kind: kind, count: work.count, ratio: set.mainRatio, ultrawide: scr.ultrawide, vertical: scr.vertical)
            rects = LayoutEngine.solve(tree, in: avail, gap: gap, mins: mins, count: work.count)
            let needW = LayoutEngine.minExtent(tree, .horizontal, gap: gap, mins: mins)
            let needH = LayoutEngine.minExtent(tree, .vertical, gap: gap, mins: mins)
            if work.count == 1 && work[0].count == 1 { break }
            if needW <= Double(avail.width) + 0.5 && needH <= Double(avail.height) + 0.5 { break }
            // Won't fit. Rather than float a window over its neighbours, stack the least recently used tile
            // behind another one: the windows you used last keep their own, fully visible tiles.
            if work.count > 1 {
                let order = work.indices.sorted { tileRank(work[$0]) > tileRank(work[$1]) }   // oldest first
                let victim = order[0], host = order[1]
                Log.d("retile stacks stale tile \(work[victim]) behind \(work[host])")
                work[host] = (work[host] + work[victim]).sorted { rank($0) > rank($1) }      // most recent on top (last)
                work.remove(at: victim)
                continue
            }
            // A single tile that still won't fit: float the hungriest window (never a whole stack).
            func area(_ id: CGWindowID) -> CGFloat { (minSizes[id]?.width ?? 0) * (minSizes[id]?.height ?? 0) }
            let worst = mins.indices.max { mins[$0].width * mins[$0].height < mins[$1].width * mins[$1].height }!
            guard let victim = work[worst].max(by: { area($0) < area($1) }) else { break }
            floated.append(victim)
            work[worst].removeAll { $0 == victim }
            if work[worst].isEmpty { work.remove(at: worst) }
            if work.isEmpty { break }
        }
        tiles[key] = work
        tileRects[key] = rects
        // Windows that cannot fit any tile float, centred.
        for id in floated {
            userFloating.insert(id)   // stays out of the layout until "Retile All" (even if the frame read below fails)
            guard let tw = wins[id], let f = tw.el.frame else { continue }
            let size = CGSize(width: min(f.width, avail.width), height: min(f.height, avail.height))
            tw.lastApplied = Date()
            tw.el.setPosition(CGPoint(x: avail.midX - size.width / 2, y: avail.midY - size.height / 2))
        }
        let strip = set.tabView ? TabStripLayout.height : 0
        for (i, ids) in work.enumerated() {
            var r = rects[i]
            if ids.count > 1 && strip > 0 { r.origin.y += strip; r.size.height -= strip }
            let right = rects[i].maxX >= avail.maxX - 0.5, bottom = rects[i].maxY >= avail.maxY - 0.5
            for id in ids {
                if fullScreenIDs.contains(id) { continue }
                if id == maximized[key] {   // fills the screen; the rest stay arranged in the layout behind it
                    wins[id]?.anchorRight = true; wins[id]?.anchorBottom = true
                    apply(id, avail, display: key, animated: animated)
                    continue
                }
                wins[id]?.anchorRight = right; wins[id]?.anchorBottom = bottom
                apply(id, r, display: key, animated: animated)
            }
        }
        Log.d("retile \(key) \(kind.rawValue) ultra=\(scr.ultrawide) tiles=\(work.map { $0.count }) floated=\(floated.count) rects=\(rects.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" })")
        scheduleVerify()
    }

    private var verify: [(id: CGWindowID, want: CGRect, display: String)] = []
    private var verifyWork: DispatchWorkItem?

    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1.5 && abs(a.minY - b.minY) < 1.5 && abs(a.width - b.width) < 1.5 && abs(a.height - b.height) < 1.5
    }

    /// Moves (or glides) a window to `r`. Windows that didn't reach `r` are re-checked once, shortly after:
    /// apps like Electron resize asynchronously, so an immediate read-back would teach a false minimum.
    private func apply(_ id: CGWindowID, _ r: CGRect, display: String, animated: Bool) {
        guard let tw = wins[id] else { return }
        tw.expected = r
        let anim = WindowAnimator.shared
        if let t = anim.target(id), near(t, r) { return }                 // already gliding there
        let running = anim.current(id)
        guard let cur = running ?? tw.el.frame else { return }
        if running == nil, var m = minSizes[id] {   // a learned minimum the window has since undercut was wrong
            if cur.width < m.width - 2 { m.width = cur.width }
            if cur.height < m.height - 2 { m.height = cur.height }
            minSizes[id] = (m.width <= 0 && m.height <= 0) ? nil : m
        }
        if running == nil && near(cur, r) { return }
        // A window that snaps to a size grid (Terminal's character cells) can't reach `r` exactly; once it
        // has settled for this target, don't keep re-moving it.
        if running == nil, let t = tw.settledTarget, t == r, let f = tw.settledFrame, near(cur, f) { return }
        tw.lastApplied = Date()
        if animated && Motion.enabled {
            anim.move(id, el: tw.el, pid: tw.pid, from: cur, to: r)
            return
        }
        anim.cancel(id)
        tw.el.setFrame(r)
        if let f = tw.el.frame, f.width > r.width + 2 || f.height > r.height + 2 { verify.append((id, r, display)) }
        settle(tw)
    }

    /// If the window ended up a little smaller than its tile (size increments / rounding), push it flush
    /// against the screen edge it shares, so the slack falls between tiles instead of at the screen edge.
    private func settle(_ tw: TWin) {
        let r = tw.expected
        guard var f = tw.el.frame else { return }
        let dw = r.width - f.width, dh = r.height - f.height
        guard (dw > 0.5 || dh > 0.5), dw < 64, dh < 64 else { tw.settledTarget = nil; return }
        let x = tw.anchorRight ? r.maxX - f.width : r.minX
        let y = tw.anchorBottom ? r.maxY - f.height : r.minY
        if abs(f.minX - x) > 0.5 || abs(f.minY - y) > 0.5 {
            tw.lastApplied = Date()
            tw.el.setPosition(CGPoint(x: x, y: y))
            f = tw.el.frame ?? f
        }
        tw.settledTarget = r; tw.settledFrame = f
        Log.d("settle win=\(tw.id) target=\(Int(r.width))x\(Int(r.height)) got=\(Int(f.width))x\(Int(f.height)) at \(Int(f.minX)),\(Int(f.minY)) right=\(tw.anchorRight) bottom=\(tw.anchorBottom)")
    }

    private func scheduleVerify() {
        guard !verify.isEmpty, verifyWork == nil else { return }
        let w = DispatchWorkItem { [self] in
            verifyWork = nil
            let items = verify; verify.removeAll()
            // First read now, second read shortly after: a size is only a real minimum if it holds still.
            // Apps that resize asynchronously (WhatsApp/Catalyst, Electron) otherwise report a stale,
            // larger frame that gets mistaken for a minimum and floats the window for good.
            var first: [CGWindowID: CGRect] = [:]
            for it in items { if let f = wins[it.id]?.el.frame { first[it.id] = f } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                var changed = Set<String>()
                for it in items {
                    guard let tw = wins[it.id], let f = tw.el.frame, let f0 = first[it.id] else { continue }
                    // Stale item (a newer target exists or a glide is running) or a size that is still moving.
                    guard tw.expected == it.want, WindowAnimator.shared.target(it.id) == nil, near(f, f0) else { continue }
                    // A few points of overshoot is size-grid rounding (Terminal's character cells), not a minimum.
                    let wOver = f.width > it.want.width + 12, hOver = f.height > it.want.height + 20
                    guard wOver || hOver else { continue }
                    let old = minSizes[it.id] ?? .zero
                    let new = CGSize(width: wOver ? max(old.width, f.width) : old.width, height: hOver ? max(old.height, f.height) : old.height)
                    if new != old { minSizes[it.id] = new; changed.insert(it.display) }
                }
                for k in changed { dirty.insert(k) }
                if !changed.isEmpty { flush() }
            }
        }
        verifyWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    // MARK: overlays

    private func publish(animated: Bool = false) {
        var infos: [TileInfo] = []
        for (key, list) in tiles {
            if let m = maximized[key], wins[m] != nil, let scr = ScreenInfo.all().first(where: { $0.key == key }) {
                infos.append(TileInfo(key: key, index: 0, rect: scr.usable.insetBy(dx: Settings.shared.gap, dy: Settings.shared.gap), ids: [m]))
                continue
            }
            let rects = tileRects[key] ?? []
            for (i, all) in list.enumerated() where i < rects.count {
                let ids = all.filter { !fullScreenIDs.contains($0) }   // no borders/tabs over a full-screen Space
                if ids.isEmpty { continue }
                infos.append(TileInfo(key: key, index: i, rect: rects[i], ids: ids))
            }
        }
        Overlays.shared.refresh(tiles: infos, active: activeID, focused: focusedRaw, animated: animated)
    }

    private var dimResumeWork: DispatchWorkItem?
    private func scheduleDimResume(after d: TimeInterval) {
        dimResumeWork?.cancel()
        let w = DispatchWorkItem { [self] in
            refreshActive(draw: false)
            dimResumeWork = nil
            guard !focusedFullScreen, Overlays.shared.dimsSuppressed else { return }
            Overlays.shared.suppressDims(false)
            publish()
        }
        dimResumeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: w)
    }

    func refreshActive(draw: Bool = true) {
        Log.d("refreshActive draw=\(draw)")
        var raw: CGWindowID?
        var candidate: CGWindowID?
        var fullScreen = false
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            let pid = app.processIdentifier
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.2)
            let fw = ax.element(kAXFocusedWindowAttribute)
            raw = fw?.windowID
            fullScreen = (fw ?? ax.element(kAXMainWindowAttribute))?.bool("AXFullScreen") == true
            candidate = raw.flatMap { wins[$0] != nil ? $0 : nil }
            // Focus can sit on a panel that isn't tiled (Picture-in-Picture, a popover, a sheet), or be
            // missing for a moment. The app's own tiled window is still what shortcuts should act on.
            if candidate == nil, let m = ax.element(kAXMainWindowAttribute)?.windowID, wins[m] != nil { candidate = m }
            if candidate == nil, let l = lastActive[pid], wins[l] != nil { candidate = l }
            if candidate == nil { candidate = wins.values.filter { $0.pid == pid }.map { $0.id }.min() }
            if let c = candidate { lastActive[pid] = c }
        } else if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            return
        }
        focusedRaw = raw
        focusedFullScreen = fullScreen
        if fullScreen { dimResumeWork?.cancel(); dimResumeWork = nil; Overlays.shared.suppressDims(true) }
        else if Overlays.shared.dimsSuppressed && dimResumeWork == nil { scheduleDimResume(after: 1.5) }   // fallback
        activeID = candidate
        if let a = candidate, mru.first != a { mru.removeAll { $0 == a }; mru.insert(a, at: 0) }
        // Focusing any other window on a display ends its maximized state.
        if let a = candidate, let d = wins[a]?.display, let m = maximized[d], m != a {
            maximized[d] = nil; dirty.insert(d); scheduleRetileAll()
        }
        if let a = activeID {   // keep the focused window on top of its stack
            for key in tiles.keys {
                guard var t = tiles[key], let i = t.firstIndex(where: { $0.contains(a) }) else { continue }
                if t[i].last != a { t[i].removeAll { $0 == a }; t[i].append(a); tiles[key] = t }
            }
        }
        if draw { publish() }
    }

    // MARK: user-driven moves

    private func geometryChanged(_ el: AXUIElement) {
        guard running, let id = el.windowID, let tw = wins[id] else { return }
        if el.bool("AXFullScreen") == true { fullScreenIDs.insert(id); return }   // the OS owns its frame
        if fullScreenIDs.remove(id) != nil {
            dirty.insert(tw.display); scheduleRetileAll()
            refreshActive()   // right now: brings the dimmer back instantly (no 30ms retile debounce)
            return
        }
        if Date().timeIntervalSince(tw.lastApplied) < 0.35 { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            dragID = id
            if NSEvent.modifierFlags.contains(.command) { dragCmd = true }
            if mouseUpMonitor == nil {
                mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.finishDrag() }
            }
            return
        }
        // The app moved/resized itself (or something else did): snap back, but not in a fight loop.
        guard let f = el.frame else { return }
        let e = tw.expected
        if abs(f.minX - e.minX) < 3, abs(f.minY - e.minY) < 3, abs(f.width - e.width) < 3, abs(f.height - e.height) < 3 { return }
        if Date().timeIntervalSince(tw.snapStamp) > 1.5 { tw.snapCount = 0 }
        tw.snapStamp = Date(); tw.snapCount += 1
        if tw.snapCount <= 3 { dirty.insert(tw.display); scheduleRetileAll() }
    }

    private func finishDrag() {
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m); mouseUpMonitor = nil }
        let cmd = dragCmd || NSEvent.modifierFlags.contains(.command)
        dragCmd = false
        defer { scheduleRetileAll() }
        guard let id = dragID, let tw = wins[id] else { dragID = nil; return }
        dragID = nil
        let p = Geo.axMouse()
        let screens = ScreenInfo.all()
        guard let target = screens.first(where: { $0.full.contains(p) }) else { return }
        dirty.insert(tw.display); dirty.insert(target.key)
        if cmd, let (key, idx) = tileAt(p), let other = tiles[key]?[idx].last, other != id {
            swap(id, other)
        } else if target.key != tw.display {
            move(id, toDisplay: target.key)
        }
    }

    private func tileAt(_ p: CGPoint) -> (String, Int)? {
        for (key, rs) in tileRects { for (i, r) in rs.enumerated() where r.contains(p) { return (key, i) } }
        return nil
    }

    private func locate(_ id: CGWindowID) -> (key: String, tile: Int, slot: Int)? {
        for (key, t) in tiles { for (i, stack) in t.enumerated() { if let s = stack.firstIndex(of: id) { return (key, i, s) } } }
        return nil
    }

    private func swap(_ a: CGWindowID, _ b: CGWindowID) {
        guard let la = locate(a), let lb = locate(b) else { return }
        tiles[la.key]![la.tile][la.slot] = b
        tiles[lb.key]![lb.tile][lb.slot] = a
        wins[a]?.display = lb.key; wins[b]?.display = la.key
        dirty.insert(la.key); dirty.insert(lb.key)
    }

    private func move(_ id: CGWindowID, toDisplay key: String) {
        guard let tw = wins[id] else { return }
        let old = tw.display
        for k in tiles.keys { tiles[k] = tiles[k]?.map { $0.filter { $0 != id } }.filter { !$0.isEmpty } }
        tw.display = key
        place(tw)
        dirty.insert(old); dirty.insert(key)
    }

    // MARK: actions

    func focus(_ id: CGWindowID) {
        guard let tw = wins[id] else { return }
        let app = AXUIElementCreateApplication(tw.pid)
        tw.el.raise()
        AXUIElementSetAttributeValue(tw.el, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, tw.el)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: tw.pid)?.activate()
    }

    /// Display the user is working on: focused window's, else the mouse's.
    func currentDisplay() -> String? {
        if let id = activeID, let w = wins[id] { return w.display }
        let screens = ScreenInfo.all()
        return (screens.first { $0.full.contains(Geo.axMouse()) } ?? screens.first)?.key
    }

    func setLayout(_ k: LayoutKind, display: String? = nil) {
        guard let key = display ?? currentDisplay() else { return }
        Settings.shared.setLayout(k, for: key)   // settingsChanged() retiles
    }

    func togglePause() {
        Settings.shared.paused.toggle()
        if !Settings.shared.paused { resyncAll() }
    }

    func swapInDirection(_ dx: Int, _ dy: Int) {
        var (dx, dy) = (dx, dy)
        // In Rows there is no left or right: ← / → move the window up / down instead.
        if dx != 0, let a = activeID, let l = locate(a), Settings.shared.layout(for: l.key) == .rows, (tiles[l.key]?.count ?? 0) > 1 { dy = dx; dx = 0 }
        guard running, let id = activeID, let loc = locate(id), let rects = tileRects[loc.key], loc.tile < rects.count else {
            Log.d("swap(\(dx),\(dy)) ignored: running=\(running) active=\(String(describing: activeID)) located=\(activeID.flatMap { locate($0) } != nil)")
            return
        }
        Log.d("swap(\(dx),\(dy)) win=\(id) tile=\(loc.tile) of \(rects.count) on \(loc.key.prefix(8))")
        // A maximized window: the arrow returns it to the layout, moving toward that side if there's a tile there.
        let wasMaximized = maximized[loc.key] == id
        if wasMaximized { maximized[loc.key] = nil; dirty.insert(loc.key) }
        let me = rects[loc.tile]
        let c = CGPoint(x: me.midX, y: me.midY)
        var best: (Int, CGFloat)?
        for (i, r) in rects.enumerated() where i != loc.tile {
            let d = CGPoint(x: r.midX - c.x, y: r.midY - c.y)
            let along = CGFloat(dx) * d.x + CGFloat(dy) * d.y
            let across = abs(CGFloat(dy) * d.x) + abs(CGFloat(dx) * d.y)
            guard along > 4 else { continue }
            let score = along + 2 * across
            if best == nil || score < best!.1 { best = (i, score) }
        }
        if let (i, _) = best, let other = tiles[loc.key]?[i].last {
            swap(id, other)
        } else if wasMaximized {
            // already on that side: restoring is all that was asked
        } else {
            // past the screen edge: hop to the neighbouring display
            let screens = ScreenInfo.all()
            guard let cur = screens.first(where: { $0.key == loc.key }) else { return }
            let cc = CGPoint(x: cur.full.midX, y: cur.full.midY)
            let next = screens.filter { $0.key != loc.key }.compactMap { s -> (ScreenInfo, CGFloat)? in
                let d = CGPoint(x: s.full.midX - cc.x, y: s.full.midY - cc.y)
                let along = CGFloat(dx) * d.x + CGFloat(dy) * d.y
                return along > 0 ? (s, along + 2 * (abs(CGFloat(dy) * d.x) + abs(CGFloat(dx) * d.y))) : nil
            }.min { $0.1 < $1.1 }
            guard let target = next?.0 else { return }
            move(id, toDisplay: target.key)
        }
        flush()
        focus(id)
    }

    func makeMain(_ id: CGWindowID? = nil) {
        guard let id = id ?? activeID, let loc = locate(id), let main = tiles[loc.key]?.first?.last, main != id else { return }
        swap(id, main); flush(); focus(id)
    }

    /// ⌃⌥↩: fills the screen with the active window, whether or not tiling is running. While tiling runs, the
    /// other windows keep their places in the active layout behind it; press again (or focus another window) to restore.
    func toggleMaximize() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.3)
        let el = ax.element(kAXFocusedWindowAttribute) ?? ax.element(kAXMainWindowAttribute)
        let raw = el?.windowID
        if running, let id = [raw, activeID].compactMap({ $0 }).first(where: { wins[$0] != nil }), let tw = wins[id] {
            maximized[tw.display] = maximized[tw.display] == id ? nil : id
            dirty.insert(tw.display); flush()
            return
        }
        // Not tiled (paused, excluded app, Stage Manager…): plain maximize / restore.
        guard let el = el, let id = raw, el.bool("AXFullScreen") != true else { return }
        if let prev = freeMax.removeValue(forKey: id) { el.setFrame(prev); return }
        guard let f = el.frame else { return }
        let screens = ScreenInfo.all()
        let c = CGPoint(x: f.midX, y: f.midY)
        guard let scr = screens.first(where: { $0.full.contains(c) }) ?? screens.first else { return }
        freeMax[id] = f
        el.setFrame(scr.usable.insetBy(dx: Settings.shared.gap, dy: Settings.shared.gap))
    }

    func floatWindow(_ id: CGWindowID) {
        userFloating.insert(id)
        if let tw = wins[id] { remove(id); dirty.insert(tw.display) }
        flush()
    }

    func closeWindow(_ id: CGWindowID) { wins[id]?.el.press(kAXCloseButtonAttribute) }

    func toggleTile(bundle: String) {
        var ex = Settings.shared.excluded
        if let i = ex.firstIndex(of: bundle) { ex.remove(at: i) } else { ex.append(bundle) }
        Settings.shared.excluded = ex
        resyncAll()
    }

    func cleanSpace() {
        let tiled = Set(wins.values.map { $0.pid })
        var hidden: [String] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != getpid() && !tiled.contains(app.processIdentifier)
            && !app.isHidden && app.bundleIdentifier != "com.apple.finder" {
            hidden.append("\(app.bundleIdentifier ?? "?"):\(app.hide())")
        }
        Log.d("cleanSpace tiledPIDs=\(tiled.count) hid=\(hidden)")
    }

    func cycleFocusMode() {
        let all = FocusMode.allCases
        let next = all[(all.firstIndex(of: Settings.shared.focusMode)! + 1) % all.count]
        Settings.shared.focusMode = next
    }

    // MARK: settings / screens

    private func settingsChanged() {
        guard started else { return }
        updateHoverMonitor(); updateClickMonitor()
        if running { scheduleRetileAll() } else { Overlays.shared.hideAll() }
    }

    private func screensChanged() {
        let keys = Set(ScreenInfo.all().map { $0.key })
        let home = ScreenInfo.all().first?.key ?? ""
        for tw in wins.values where !keys.contains(tw.display) { tw.display = home }
        for k in tiles.keys where !keys.contains(k) {
            for stack in tiles[k] ?? [] { for id in stack { if let tw = wins[id] { place(tw) } } }
            tiles[k] = nil; tileRects[k] = nil
        }
        scheduleRetileAll()
    }

    // MARK: focus-dim click pre-cover (installed only while Dim Others / No Peek is on)

    private var clickMonitor: Any?
    private func updateClickMonitor() {
        let want = Settings.shared.focusMode != .off && running
        if want, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.clickDown() }
        } else if !want, let m = clickMonitor {
            NSEvent.removeMonitor(m); clickMonitor = nil
        }
    }

    private func clickDown() {
        guard let (k, i) = tileAt(Geo.axMouse()), let top = tiles[k]?[safe: i]?.last, top != focusedRaw else { return }
        Overlays.shared.precover(new: top, old: focusedRaw)
    }

    // MARK: hover-to-activate (installed only while the option is on)

    private func updateHoverMonitor() {
        let want = Settings.shared.hoverActivate && running
        if want, hoverMonitor == nil {
            hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.hoverMoved() }
        } else if !want, let m = hoverMonitor {
            NSEvent.removeMonitor(m); hoverMonitor = nil; hoverTile = nil
        }
    }

    private func hoverMoved() {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let p = Geo.axMouse()
        guard let t = tileAt(p) else { return }
        if let h = hoverTile, h == t { return }
        hoverTile = t
        hoverWork?.cancel()
        let w = DispatchWorkItem { [self] in
            guard let top = tiles[t.0]?[safe: t.1]?.last, top != activeID, tileAt(Geo.axMouse()).map({ $0 == t }) == true else { return }
            focus(top)
        }
        hoverWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    // MARK: setups

    func captureSetup(name: String) -> Setup {
        var ds: [DisplaySetup] = []
        for (key, list) in tiles where !list.isEmpty {
            let tilesB = list.map { stack -> [String] in
                var seen: [String] = []
                for id in stack { if let b = wins[id]?.bundle, !seen.contains(b) { seen.append(b) } }
                return seen
            }
            ds.append(DisplaySetup(display: key, layout: Settings.shared.layout(for: key).rawValue, tiles: tilesB))
        }
        return Setup(id: UUID().uuidString, name: name, displays: ds, shortcut: nil)
    }

    func launchSetup(_ s: Setup) {
        guard running else { return }
        let wanted = Set(s.displays.flatMap { $0.tiles.flatMap { $0 } })
        for d in s.displays { if let k = LayoutKind(rawValue: d.layout) { Settings.shared.setLayout(k, for: d.display) } }
        for b in wanted {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == b }) {
                if app.isHidden { app.unhide() }
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
                let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            }
        }
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != getpid() && !app.isHidden
            && app.bundleIdentifier != "com.apple.finder" && !wanted.contains(app.bundleIdentifier ?? "") { app.hide() }
        pendingSetup = (s, Date().addingTimeInterval(15))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            resyncAll()
            applyPendingSetup()
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [self] in
                if let p = pendingSetup, p.deadline <= Date() { pendingSetup = nil }
            }
        }
    }

    private func applyPendingSetup() {
        guard let (s, deadline) = pendingSetup else { return }
        if Date() > deadline { pendingSetup = nil; return }
        let screens = Set(ScreenInfo.all().map { $0.key })
        var used = Set<CGWindowID>()
        var satisfied = true
        for d in s.displays where screens.contains(d.display) {
            var result: [[CGWindowID]] = []
            for bundles in d.tiles {
                var ids: [CGWindowID] = []
                for b in bundles {
                    let mine = wins.values.filter { $0.bundle == b && !used.contains($0.id) }.map { $0.id }.sorted()
                    if mine.isEmpty { satisfied = false }
                    ids += mine
                }
                used.formUnion(ids)
                if !ids.isEmpty { result.append(ids) }
            }
            for id in result.flatMap({ $0 }) { wins[id]?.display = d.display }
            for old in tiles.keys where old != d.display { tiles[old] = tiles[old]?.map { $0.filter { !result.flatMap { $0 }.contains($0) } }.filter { !$0.isEmpty } }
            tiles[d.display] = result
            dirty.insert(d.display)
        }
        if satisfied { pendingSetup = nil }
        flush()
    }

    // MARK: diagnostics

    func dump() {
        print("trusted:", trusted, " stageManager:", stageManagerOn)
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            for w in ax.elements(kAXWindowsAttribute) {
                let ok = eligible(w, id: w.windowID ?? 0, bundle: app.bundleIdentifier ?? "", hidden: app.isHidden)
                print(ok ? "TILE " : "skip ", app.bundleIdentifier ?? "?", w.windowID ?? 0, w.frame.map { "\($0)" } ?? "-")
            }
        }
    }

    /// Debug-only (needs `debugLog`): writes what the tiler believes, per app, to the log.
    func debugDump() {
        Log.d("DUMP sdk=0x\(String(dyld_get_program_sdk_version(), radix: 16)) minos-check os=\(ProcessInfo.processInfo.operatingSystemVersionString) reduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)")
        Log.d("DUMP running=\(running) trusted=\(trusted) stage=\(stageManagerOn) paused=\(Settings.shared.paused) active=\(String(describing: activeID)) focusedRaw=\(String(describing: focusedRaw)) userFloating=\(userFloating.count)")
        for scr in ScreenInfo.all() {
            Log.d("DUMP display \(scr.key.prefix(8)) full=\(scr.full) usable=\(scr.usable) capacity=\(scr.capacity) layout=\(Settings.shared.layout(for: scr.key).rawValue)")
        }
        for (k, t) in tiles {
            Log.d("DUMP tiles[\(k.prefix(8))]=\(t) rects=\(tileRects[k]?.count ?? 0) rectList=\((tileRects[k] ?? []).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" })")
        }
        for (id, m) in minSizes { Log.d("DUMP learnedMin win=\(id) bundle=\(wins[id]?.bundle ?? "-") display=\(wins[id]?.display.prefix(8) ?? "-") min=\(Int(m.width))x\(Int(m.height))") }
        for id in userFloating { Log.d("DUMP floated win=\(id) bundle=\(wins[id]?.bundle ?? "-") frame=\(String(describing: wins[id]?.el.frame))") }
        let front = NSWorkspace.shared.frontmostApplication
        Log.d("DUMP frontmost=\(front?.bundleIdentifier ?? "-")")
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            let pid = app.processIdentifier, b = app.bundleIdentifier ?? "?"
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.3)
            var raw: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &raw)
            let list = (raw as? [AXUIElement]) ?? []
            var fw: CFTypeRef?
            let ferr = AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &fw)
            Log.d("DUMP app \(b) pid=\(pid) hidden=\(app.isHidden) observer=\(observers[pid] != nil) windowsErr=\(err.rawValue) n=\(list.count) focusedErr=\(ferr.rawValue) front=\(app == front)")
            for w in list {
                let id = w.windowID
                Log.d("DUMP   win=\(String(describing: id)) role=\(w.string(kAXRoleAttribute) ?? "-") sub=\(w.string(kAXSubroleAttribute) ?? "-") min=\(String(describing: w.bool(kAXMinimizedAttribute))) fs=\(String(describing: w.bool("AXFullScreen"))) posSet=\(w.isSettable(kAXPositionAttribute)) sizeSet=\(w.isSettable(kAXSizeAttribute)) tracked=\(id.map { wins[$0] != nil } ?? false) floatedByUs=\(id.map { userFloating.contains($0) } ?? false) eligible=\(id.map { eligible(w, id: $0, bundle: b, hidden: app.isHidden) } ?? false) frame=\(w.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-") expected=\(id.flatMap { wins[$0] }.map { "\(Int($0.expected.minX)),\(Int($0.expected.minY)) \(Int($0.expected.width))x\(Int($0.expected.height))" } ?? "-")")
            }
        }
    }
}

@_silgen_name("dyld_get_program_sdk_version") func dyld_get_program_sdk_version() -> UInt32

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

/// Opt-in diagnostics: `defaults write com.aakarsh.tegula debugLog -bool true` → ~/Library/Logs/Tegula.log
enum Log {
    static let on = UserDefaults.standard.bool(forKey: "debugLog")
    static func d(_ s: @autoclosure () -> String) {
        guard on else { return }
        let path = NSHomeDirectory() + "/Library/Logs/Tegula.log"
        let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(s())\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
