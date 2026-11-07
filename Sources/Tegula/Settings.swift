import AppKit
import Carbon

enum BorderMode: String, CaseIterable { case none, active, all, glow }
enum FocusMode: String, CaseIterable { case off, dim, noPeek }
enum ThemeMode: String, CaseIterable { case system, light, dark }
enum IconChoice: String, CaseIterable { case slate, clay }

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var mods: UInt32          // Carbon modifier mask
    var label: String         // key glyph for display
    var display: String { Shortcut.modGlyphs(mods) + label }

    static func modGlyphs(_ m: UInt32) -> String {
        var s = ""
        if m & UInt32(controlKey) != 0 { s += "⌃" }
        if m & UInt32(optionKey) != 0 { s += "⌥" }
        if m & UInt32(shiftKey) != 0 { s += "⇧" }
        if m & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }
}

struct DisplaySetup: Codable { var display: String; var layout: String; var tiles: [[String]] }
struct Setup: Codable {
    var id: String
    var name: String
    var displays: [DisplaySetup]
    var shortcut: Shortcut?
}

/// Everything user-configurable. UserDefaults-backed; every write posts `Settings.changed`.
final class Settings {
    static let shared = Settings()
    static let changed = Notification.Name("TegulaSettingsChanged")
    private let d = UserDefaults.standard
    private func post() { NotificationCenter.default.post(name: Settings.changed, object: nil) }

    private func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
    private func flag(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
    private func put(_ v: Any?, _ k: String) { d.set(v, forKey: k); post() }

    var paused: Bool { get { flag("paused", false) } set { put(newValue, "paused") } }
    var mainRatio: Double { get { dbl("mainRatio", 0.5) } set { put(newValue, "mainRatio") } }
    var gap: Double { get { dbl("gap", 8) } set { put(newValue, "gap") } }
    var edgeTop: Double { get { dbl("edgeTop", 0) } set { put(newValue, "edgeTop") } }
    var edgeBottom: Double { get { dbl("edgeBottom", 0) } set { put(newValue, "edgeBottom") } }
    var edgeLeft: Double { get { dbl("edgeLeft", 0) } set { put(newValue, "edgeLeft") } }
    var edgeRight: Double { get { dbl("edgeRight", 0) } set { put(newValue, "edgeRight") } }

    var borderMode: BorderMode { get { BorderMode(rawValue: d.string(forKey: "borderMode") ?? "") ?? .active } set { put(newValue.rawValue, "borderMode") } }
    var borderColor: NSColor {
        get {
            if let s = d.string(forKey: "borderColor"), let c = NSColor(hexString: s) { return c }
            return NSColor(srgbRed: 0.93, green: 0.55, blue: 0.25, alpha: 1)
        }
        set { put(newValue.hexString, "borderColor") }
    }
    var focusMode: FocusMode { get { FocusMode(rawValue: d.string(forKey: "focusMode") ?? "") ?? .off } set { put(newValue.rawValue, "focusMode") } }
    var animate: Bool { get { flag("animate", true) } set { put(newValue, "animate") } }
    var tabView: Bool { get { flag("tabView", true) } set { put(newValue, "tabView") } }
    var hoverActivate: Bool { get { flag("hoverActivate", false) } set { put(newValue, "hoverActivate") } }
    var quickActions: Bool { get { flag("quickActions", false) } set { put(newValue, "quickActions") } }
    var theme: ThemeMode { get { ThemeMode(rawValue: d.string(forKey: "theme") ?? "") ?? .system } set { put(newValue.rawValue, "theme") } }
    var language: String { get { d.string(forKey: "language") ?? "system" } set { put(newValue, "language") } }
    var icon: IconChoice { get { IconChoice(rawValue: d.string(forKey: "icon") ?? "") ?? .slate } set { put(newValue.rawValue, "icon") } }
    var excluded: [String] { get { d.stringArray(forKey: "excluded") ?? [] } set { put(newValue, "excluded") } }

    func layout(for display: String) -> LayoutKind {
        let m = d.dictionary(forKey: "layouts") as? [String: String] ?? [:]
        return LayoutKind(rawValue: m[display] ?? "") ?? .grid
    }
    func setLayout(_ k: LayoutKind, for display: String) {
        var m = d.dictionary(forKey: "layouts") as? [String: String] ?? [:]
        m[display] = k.rawValue
        put(m, "layouts")
    }

    // MARK: shortcuts
    private func decode<T: Decodable>(_ k: String, _ t: T.Type) -> T? { d.data(forKey: k).flatMap { try? JSONDecoder().decode(t, from: $0) } }
    private func encode<T: Encodable>(_ v: T, _ k: String) { put(try? JSONEncoder().encode(v), k) }

    private var shortcutOverrides: [String: Shortcut] { decode("shortcutOverrides", [String: Shortcut].self) ?? [:] }
    var disabledShortcuts: Set<String> { Set(d.stringArray(forKey: "shortcutsOff") ?? []) }

    func shortcut(for action: String) -> Shortcut? {
        if disabledShortcuts.contains(action) { return nil }
        if let o = shortcutOverrides[action] { return o }
        if action.hasPrefix("setup.") { return setups.first { "setup." + $0.id == action }?.shortcut }
        return Action(rawValue: action)?.defaultShortcut
    }
    func setShortcut(_ s: Shortcut?, for action: String) {
        if action.hasPrefix("setup.") {
            var all = setups
            if let i = all.firstIndex(where: { "setup." + $0.id == action }) { all[i].shortcut = s; setups = all }
            return
        }
        var o = shortcutOverrides, off = disabledShortcuts
        if let s = s { o[action] = s; off.remove(action) } else { o[action] = nil; off.insert(action) }
        encode(o, "shortcutOverrides")
        put(Array(off), "shortcutsOff")
    }
    func resetShortcut(_ action: String) {
        var o = shortcutOverrides, off = disabledShortcuts
        o[action] = nil; off.remove(action)
        encode(o, "shortcutOverrides"); put(Array(off), "shortcutsOff")
    }
    func allShortcuts() -> [String: Shortcut] {
        var out: [String: Shortcut] = [:]
        for a in Action.allCases { if let s = shortcut(for: a.rawValue) { out[a.rawValue] = s } }
        for st in setups { if let s = st.shortcut, !disabledShortcuts.contains("setup." + st.id) { out["setup." + st.id] = s } }
        return out
    }

    var setups: [Setup] {
        get { decode("setups", [Setup].self) ?? [] }
        set { encode(newValue, "setups") }
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        var h = hexString; if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

/// Everything a shortcut can trigger (setups add dynamic "setup.<id>" actions).
enum Action: String, CaseIterable {
    case layoutGrid, layoutColumns, layoutRows, layoutSide
    case pause, swapLeft, swapRight, swapUp, swapDown
    case cleanSpace, focusToggle, retile, tileApp, makeMain

    var defaultShortcut: Shortcut? {
        let cac = UInt32(controlKey | optionKey | cmdKey), ca = UInt32(controlKey | optionKey)
        switch self {
        case .layoutGrid:    return Shortcut(keyCode: 18, mods: cac, label: "1")
        case .layoutColumns: return Shortcut(keyCode: 19, mods: cac, label: "2")
        case .layoutRows:    return Shortcut(keyCode: 20, mods: cac, label: "3")
        case .layoutSide:    return Shortcut(keyCode: 21, mods: cac, label: "4")
        case .pause:         return Shortcut(keyCode: 17, mods: ca, label: "T")
        case .swapLeft:      return Shortcut(keyCode: 123, mods: ca, label: "←")
        case .swapRight:     return Shortcut(keyCode: 124, mods: ca, label: "→")
        case .swapDown:      return Shortcut(keyCode: 125, mods: ca, label: "↓")
        case .swapUp:        return Shortcut(keyCode: 126, mods: ca, label: "↑")
        case .cleanSpace:    return Shortcut(keyCode: 8, mods: cac, label: "C")
        case .focusToggle:   return Shortcut(keyCode: 3, mods: cac, label: "F")
        case .retile:        return Shortcut(keyCode: 15, mods: cac, label: "R")
        case .tileApp:       return Shortcut(keyCode: 17, mods: cac, label: "T")
        case .makeMain:      return Shortcut(keyCode: 46, mods: cac, label: "M")
        }
    }
}
