// Usage: swift Scripts/make-icons.swift <outDir>   → writes Slate.icns and Clay.icns
import AppKit

func render(size: Int, light: Bool) -> Data {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        let inset = s * 0.09
        let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let path = NSBezierPath(roundedRect: body, xRadius: s * 0.225, yRadius: s * 0.225)

        ctx.saveGState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = s * 0.03; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012); shadow.set()
        (light ? NSColor(srgbRed: 0.95, green: 0.92, blue: 0.85, alpha: 1) : NSColor(srgbRed: 0.10, green: 0.12, blue: 0.17, alpha: 1)).setFill()
        path.fill()
        ctx.restoreGState()

        path.addClip()
        let top = light ? NSColor(srgbRed: 0.99, green: 0.97, blue: 0.92, alpha: 1) : NSColor(srgbRed: 0.17, green: 0.20, blue: 0.28, alpha: 1)
        let bot = light ? NSColor(srgbRed: 0.90, green: 0.86, blue: 0.77, alpha: 1) : NSColor(srgbRed: 0.07, green: 0.08, blue: 0.12, alpha: 1)
        NSGradient(starting: top, ending: bot)!.draw(in: body, angle: -90)

        // the tegula screen: outer frame + 3×3 lattice, drawn as paper panes
        let screen = body.insetBy(dx: s * 0.17, dy: s * 0.17)
        let wood = light ? NSColor(srgbRed: 0.20, green: 0.16, blue: 0.13, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.88, blue: 0.78, alpha: 1)
        let pane = light ? NSColor(srgbRed: 1, green: 0.995, blue: 0.97, alpha: 0.9) : NSColor(srgbRed: 0.93, green: 0.88, blue: 0.78, alpha: 0.14)
        let bar = s * 0.028
        let cell = (screen.width - bar * 4) / 3
        for r in 0..<3 {
            for c in 0..<3 {
                let x = screen.minX + bar + CGFloat(c) * (cell + bar)
                let y = screen.minY + bar + CGFloat(r) * (cell + bar)
                // active pane glows warm
                let hot = (r == 2 && c == 0)
                (hot ? NSColor(srgbRed: 0.95, green: 0.56, blue: 0.25, alpha: light ? 0.95 : 0.9) : pane).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: cell, height: cell), xRadius: s * 0.012, yRadius: s * 0.012).fill()
            }
        }
        wood.setStroke()
        let frame = NSBezierPath(roundedRect: screen, xRadius: s * 0.03, yRadius: s * 0.03)
        frame.lineWidth = bar * 1.6; frame.stroke()
        let lattice = NSBezierPath()
        for i in 1...2 {
            let off = CGFloat(i) * (cell + bar) + bar / 2
            lattice.move(to: NSPoint(x: screen.minX + off, y: screen.minY)); lattice.line(to: NSPoint(x: screen.minX + off, y: screen.maxY))
            lattice.move(to: NSPoint(x: screen.minX, y: screen.minY + off)); lattice.line(to: NSPoint(x: screen.maxX, y: screen.minY + off))
        }
        lattice.lineWidth = bar; lattice.stroke()
        return true
    }
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let fm = FileManager.default
for (name, light) in [("Slate", false), ("Clay", true)] {
    let set = out.appendingPathComponent("\(name).iconset")
    try? fm.removeItem(at: set); try! fm.createDirectory(at: set, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try! render(size: base, light: light).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
        try! render(size: base * 2, light: light).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", set.path, "-o", out.appendingPathComponent("\(name).icns").path]
    try! p.run(); p.waitUntilExit()
    try? fm.removeItem(at: set)
}
