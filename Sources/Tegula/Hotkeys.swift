import AppKit
import Carbon

/// Global shortcuts via Carbon RegisterEventHotKey: the OS delivers an event only when one of
/// our exact combinations is pressed. No event tap, no key logging, no Input Monitoring prompt.
final class Hotkeys {
    static let shared = Hotkeys()
    var onAction: ((String) -> Void)?

    private var refs: [String: EventHotKeyRef] = [:]
    private var idToAction: [UInt32: String] = [:]
    private var installed = false
    private var counter: UInt32 = 0

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            Hotkeys.shared.fire(hk.id)
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(_ id: UInt32) {
        if let a = idToAction[id] { DispatchQueue.main.async { self.onAction?(a) } }
    }

    // Shortcuts that exist only while the menu-bar panel is open. The panel never activates Tegula, so
    // without these, keys like ⌘Q would go to whichever app is in front.
    private var tempRefs: [EventHotKeyRef] = []
    var hasTemporary: Bool { !tempRefs.isEmpty }

    func pushTemporary(_ shortcuts: [String: Shortcut]) {
        installHandler()
        popTemporary()
        for (action, sc) in shortcuts {
            counter += 1
            var ref: EventHotKeyRef?
            let hid = EventHotKeyID(signature: OSType(0x54474C41), id: counter)
            if RegisterEventHotKey(sc.keyCode, sc.mods, hid, GetApplicationEventTarget(), 0, &ref) == noErr, let ref = ref {
                tempRefs.append(ref); idToAction[counter] = action
            }
        }
    }

    func popTemporary() {
        for r in tempRefs { UnregisterEventHotKey(r) }
        tempRefs.removeAll()
        idToAction = idToAction.filter { !$0.value.hasPrefix("panel.") }
    }

    func unregisterAll() {
        for (_, r) in refs { UnregisterEventHotKey(r) }
        refs.removeAll(); idToAction = idToAction.filter { $0.value.hasPrefix("panel.") }
    }

    func reload() {
        installHandler()
        unregisterAll()
        for (action, sc) in Settings.shared.allShortcuts() {
            counter += 1
            var ref: EventHotKeyRef?
            let hid = EventHotKeyID(signature: OSType(0x54474C41), id: counter)   // 'TGLA'
            let st = RegisterEventHotKey(sc.keyCode, sc.mods, hid, GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref = ref {
                refs[action] = ref; idToAction[counter] = action
            } else {
                Log.d("hotkey REGISTER FAILED \(action) \(sc.display) status=\(st)")   // -9878 = already taken by another app
            }
        }
    }

    // MARK: conflict detection

    /// True if macOS (symbolic hotkeys) or another app already owns this combination.
    /// Call with our own hotkeys unregistered (see ShortcutRecorder).
    static func isTaken(_ sc: Shortcut) -> Bool {
        if systemTaken(sc) { return true }
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(sc.keyCode, sc.mods, EventHotKeyID(signature: OSType(0x50524F42), id: 1),
                                     GetApplicationEventTarget(), 0, &ref)
        if st == noErr, let r = ref { UnregisterEventHotKey(r); return false }
        return true
    }

    private static func systemTaken(_ sc: Shortcut) -> Bool {
        var out: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&out) == noErr, let arr = out?.takeRetainedValue() as? [[String: Any]] else { return false }
        for d in arr {
            guard (d[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = d[kHISymbolicHotKeyCode as String] as? Int,
                  let mods = d[kHISymbolicHotKeyModifiers as String] as? Int else { continue }
            if UInt32(code) == sc.keyCode && UInt32(mods) & 0xFF00 == sc.mods & 0xFF00 { return true }
        }
        return false
    }

    static func alternatives(for sc: Shortcut) -> [Shortcut] {
        let c = UInt32(controlKey), o = UInt32(optionKey), s = UInt32(shiftKey), m = UInt32(cmdKey)
        let variants = [sc.mods | s, c | o | m, c | o | s, c | m | s, o | m | s]
        var out: [Shortcut] = []
        for v in variants where v != sc.mods {
            let cand = Shortcut(keyCode: sc.keyCode, mods: v, label: sc.label)
            if !isTaken(cand) { out.append(cand); if out.count == 2 { break } }
        }
        return out
    }
}
