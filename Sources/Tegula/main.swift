import AppKit

let args = CommandLine.arguments
if args.contains("--selftest-layout") { exit(LayoutSelfTest.run() ? 0 : 1) }
if args.contains("--dump-windows") { Tiler.shared.dump(); exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
