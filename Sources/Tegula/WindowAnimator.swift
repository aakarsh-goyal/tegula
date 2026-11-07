import AppKit
import ApplicationServices
import QuartzCore

enum Motion {
    static let duration: CFTimeInterval = 0.26
    /// cubic-bezier(.215,.61,.355,1) == ease-out-cubic, the same curve the window glide uses.
    static let curve = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
    static func ease(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    static var enabled: Bool { Settings.shared.animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Background AX writer. Latest frame wins per window, so a slow app never builds a backlog and the
/// main thread never waits on another process.
private final class FrameWriter {
    private final class Slot { var pending: (CGRect, Bool)?; var busy = false }
    private var applied: [CGWindowID: Int] = [:]
    private let lock = NSLock()
    private var slots: [CGWindowID: Slot] = [:]
    private let queue = DispatchQueue(label: "tegula.ax-writer", qos: .userInteractive, attributes: .concurrent)
    var onFinal: ((CGWindowID, Int) -> Void)?

    func push(_ id: CGWindowID, _ el: AXUIElement, _ r: CGRect, final: Bool) {
        lock.lock()
        let s: Slot
        if let e = slots[id] { s = e } else { s = Slot(); slots[id] = s }
        s.pending = (r, final)
        let start = !s.busy
        s.busy = true
        lock.unlock()
        if start { queue.async { self.drain(id, el, s) } }
    }

    private func drain(_ id: CGWindowID, _ el: AXUIElement, _ s: Slot) {
        while true {
            lock.lock()
            guard let (r, final) = s.pending else { s.busy = false; slots[id] = nil; lock.unlock(); return }
            s.pending = nil
            lock.unlock()
            lock.lock(); applied[id, default: 0] += 1; let count = applied[id]!; lock.unlock()
            if final {
                el.setFrame(r)
                lock.lock(); applied[id] = nil; lock.unlock()
                DispatchQueue.main.async { self.onFinal?(id, count) }
            } else {
                el.setSize(r.size); el.setPosition(r.origin)
            }
        }
    }
}

/// Glides windows to their tiles. The display link exists only while something is moving, so an idle
/// Tegula has no per-frame work at all.
final class WindowAnimator {
    static let shared = WindowAnimator()

    private var tickCounts: [CGWindowID: Int] = [:]
    private struct Job { let el: AXUIElement; let pid: pid_t; var from: CGRect; var to: CGRect; var start: CFTimeInterval; var ticks = 0 }
    private var jobs: [CGWindowID: Job] = [:]
    private var finishing = Set<CGWindowID>()
    private var link: CADisplayLink?
    private let writer = FrameWriter()
    private var enhanced: [pid_t: Bool] = [:]
    var onFinish: ((CGWindowID) -> Void)?
    var touch: ((CGWindowID) -> Void)?

    init() { writer.onFinal = { [weak self] id, applied in self?.finalDone(id, applied: applied) } }

    private func frame(_ j: Job, _ now: CFTimeInterval) -> CGRect {
        let t = Motion.ease(min(1, max(0, (now - j.start) / Motion.duration)))
        func l(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * CGFloat(t)).rounded() }
        return CGRect(x: l(j.from.minX, j.to.minX), y: l(j.from.minY, j.to.minY), width: l(j.from.width, j.to.width), height: l(j.from.height, j.to.height))
    }

    func current(_ id: CGWindowID) -> CGRect? { jobs[id].map { frame($0, CACurrentMediaTime()) } }
    func target(_ id: CGWindowID) -> CGRect? { jobs[id]?.to }

    func move(_ id: CGWindowID, el: AXUIElement, pid: pid_t, from: CGRect, to: CGRect) {
        jobs[id] = Job(el: el, pid: pid, from: current(id) ?? from, to: to, start: CACurrentMediaTime())
        quietEnhancedUI(pid)
        if link == nil {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let l = screen.displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    func cancel(_ id: CGWindowID) { jobs[id] = nil; stopIfIdle() }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        for (id, j) in jobs {
            touch?(id)
            tickCounts[id, default: 0] += 1
            if now - j.start >= Motion.duration {
                jobs[id] = nil; finishing.insert(id)
                writer.push(id, j.el, j.to, final: true)
            } else {
                writer.push(id, j.el, frame(j, now), final: false)
            }
        }
        stopIfIdle()
    }

    private func stopIfIdle() {
        if jobs.isEmpty { link?.invalidate(); link = nil }
    }

    private func finalDone(_ id: CGWindowID, applied: Int) {
        Log.d("glide win=\(id) ticks=\(tickCounts[id] ?? 0) framesApplied=\(applied)")
        tickCounts[id] = nil
        finishing.remove(id)
        touch?(id)
        if jobs.isEmpty && finishing.isEmpty { restoreEnhancedUI() }
        onFinish?(id)
    }

    // Apps with "Enhanced User Interface" on animate AX resizes themselves, which fights our glide.
    private func quietEnhancedUI(_ pid: pid_t) {
        guard enhanced[pid] == nil else { return }
        let app = AXUIElementCreateApplication(pid)
        let was = app.bool("AXEnhancedUserInterface") ?? false
        enhanced[pid] = was
        if was { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
    }

    private func restoreEnhancedUI() {
        for (pid, was) in enhanced where was {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        enhanced.removeAll()
    }
}
