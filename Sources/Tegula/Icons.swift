import AppKit

enum Icons {
    /// Menu-bar glyph: a tegula lattice (rounded frame + cross).
    static func statusGlyph(paused: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            let frame = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 14, height: 14), xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.5; frame.stroke()
            if paused {
                NSBezierPath(rect: NSRect(x: 6, y: 5.5, width: 2, height: 7)).fill()
                NSBezierPath(rect: NSRect(x: 10, y: 5.5, width: 2, height: 7)).fill()
            } else {
                let cross = NSBezierPath()
                cross.move(to: NSPoint(x: 9, y: 2)); cross.line(to: NSPoint(x: 9, y: 16))
                cross.move(to: NSPoint(x: 2, y: 9)); cross.line(to: NSPoint(x: 16, y: 9))
                cross.lineWidth = 1.2; cross.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Small layout diagram for menu items.
    static func layoutGlyph(_ k: LayoutKind) -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 12), flipped: false) { _ in
            NSColor.black.setFill()
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: 1, yRadius: 1).fill()
            }
            switch k {
            case .grid:    box(0, 6.5, 7.5, 5.5); box(8.5, 6.5, 7.5, 5.5); box(0, 0, 7.5, 5.5); box(8.5, 0, 7.5, 5.5)
            case .columns: box(0, 0, 4.5, 12); box(5.75, 0, 4.5, 12); box(11.5, 0, 4.5, 12)
            case .rows:    box(0, 8.2, 16, 3.8); box(0, 4.1, 16, 3.8); box(0, 0, 16, 3.8)
            case .side:    box(0, 0, 9, 12); box(10, 6.5, 6, 5.5); box(10, 0, 6, 5.5)
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Draws the layout glyph scaled into `r` with an arbitrary colour (used by the panel cards).
    static func drawLayout(_ k: LayoutKind, in r: NSRect, color: NSColor) {
        let sx = r.width / 16, sy = r.height / 12
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            NSBezierPath(roundedRect: NSRect(x: r.minX + x * sx, y: r.minY + y * sy, width: w * sx, height: h * sy), xRadius: 1.5, yRadius: 1.5).fill()
        }
        color.setFill()
        switch k {
        case .grid:    box(0, 6.5, 7.5, 5.5); box(8.5, 6.5, 7.5, 5.5); box(0, 0, 7.5, 5.5); box(8.5, 0, 7.5, 5.5)
        case .columns: box(0, 0, 4.5, 12); box(5.75, 0, 4.5, 12); box(11.5, 0, 4.5, 12)
        case .rows:    box(0, 8.2, 16, 3.8); box(0, 4.1, 16, 3.8); box(0, 0, 16, 3.8)
        case .side:    box(0, 0, 9, 12); box(10, 6.5, 6, 5.5); box(10, 0, 6, 5.5)
        }
    }

    /// Full-colour app icon, bundled as Resources/<Name>.icns.
    static func appIcon(_ c: IconChoice) -> NSImage? {
        let name = c == .slate ? "Slate" : "Clay"
        guard let url = Bundle.main.url(forResource: name, withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    static func applyAppIcon() {
        guard let img = appIcon(Settings.shared.icon) else { return }
        NSApp.applicationIconImage = img
    }
}
