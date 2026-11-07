import AppKit
import ApplicationServices

// Private but long-stable: maps an AX window element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ el: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    func value(_ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success ? v : nil
    }
    func string(_ n: String) -> String? { value(n) as? String }
    func bool(_ n: String) -> Bool? { (value(n) as? NSNumber)?.boolValue }
    func element(_ n: String) -> AXUIElement? {
        guard let v = value(n), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    func elements(_ n: String) -> [AXUIElement] { (value(n) as? [AXUIElement]) ?? [] }

    var pid: pid_t { var p: pid_t = 0; AXUIElementGetPid(self, &p); return p }
    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    private func axValue(_ n: String, _ type: AXValueType, _ into: UnsafeMutableRawPointer) -> Bool {
        guard let v = value(n), CFGetTypeID(v) == AXValueGetTypeID() else { return false }
        return AXValueGetValue(v as! AXValue, type, into)
    }
    var frame: CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard axValue(kAXPositionAttribute, .cgPoint, &p), axValue(kAXSizeAttribute, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
    @discardableResult func setPosition(_ p: CGPoint) -> Bool {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, v) == .success
    }
    @discardableResult func setSize(_ s: CGSize) -> Bool {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, v) == .success
    }
    /// position → size → (position again if the OS clamped it while growing)
    func setFrame(_ r: CGRect) {
        setPosition(r.origin)
        setSize(r.size)
        if let f = frame, abs(f.minX - r.minX) > 1 || abs(f.minY - r.minY) > 1 { setPosition(r.origin) }
    }
    func isSettable(_ n: String) -> Bool {
        var s: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, n as CFString, &s) == .success && s.boolValue
    }
    func raise() { AXUIElementPerformAction(self, kAXRaiseAction as CFString) }
    func press(_ attr: String) { element(attr).map { _ = AXUIElementPerformAction($0, kAXPressAction as CFString) } }
}

/// Coordinate helpers. AX space: origin top-left of the primary display, y down.
enum Geo {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    static func axMouse() -> CGPoint {
        let m = NSEvent.mouseLocation
        return CGPoint(x: m.x, y: primaryHeight - m.y)
    }
    static func displayID(_ s: NSScreen) -> CGDirectDisplayID? {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
    static func key(_ s: NSScreen) -> String {
        if let id = displayID(s), let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let str = CFUUIDCreateString(nil, u) as String? { return str }
        return "screen-\(Int(s.frame.minX))-\(Int(s.frame.minY))"
    }
}

struct ScreenInfo {
    let key: String
    let screen: NSScreen
    let full: CGRect      // AX coords
    let usable: CGRect    // AX coords, minus menu bar/dock/user edge space
    var ultrawide: Bool { full.width / full.height >= 2.0 }
    var vertical: Bool { full.height > full.width }
    var capacity: Int { LayoutEngine.capacity(ultrawide: ultrawide) }

    static func all() -> [ScreenInfo] {
        let s = Settings.shared
        return NSScreen.screens.map { scr in
            var u = Geo.flip(scr.visibleFrame)
            u.origin.x += s.edgeLeft; u.size.width -= s.edgeLeft + s.edgeRight
            u.origin.y += s.edgeTop;  u.size.height -= s.edgeTop + s.edgeBottom
            return ScreenInfo(key: Geo.key(scr), screen: scr, full: Geo.flip(scr.frame), usable: u)
        }
    }
}
