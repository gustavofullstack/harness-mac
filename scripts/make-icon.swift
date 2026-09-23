// Renders an .icns app icon.
//   swift scripts/make-icon.swift <out.icns> [logo.svg]
// With a logo (the harness's own favicon, read from the local dsh install at build time and never
// committed), draws it in DeepSeek blue on a white squircle. Without one, draws a neutral prompt glyph.
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: make-icon.swift <out.icns> [logo.svg]"); exit(2) }
let output = args[1]

let logo: NSImage? = args.count > 2 ? {
    guard var svg = try? String(contentsOfFile: args[2], encoding: .utf8) else { return nil }
    // The favicon is black with a dark-mode override; pin it to the brand blue.
    if let style = svg.range(of: "<style>[\\s\\S]*?</style>", options: .regularExpression) { svg.removeSubrange(style) }
    svg = svg.replacingOccurrences(of: "fill=\"#000\"", with: "fill=\"#4D6BFE\"")
    return NSImage(data: Data(svg.utf8))
}() : nil

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.09
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    if let logo {
        NSColor.white.setFill()
        shape.fill()
        let side = rect.width * 0.66
        logo.draw(in: NSRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side))
    } else {
        NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.36, alpha: 1),
                   ending: NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 1))!.draw(in: shape, angle: -90)
        let glyph = NSAttributedString(string: "›_", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size * 0.34, weight: .bold),
            .foregroundColor: NSColor(calibratedRed: 0.55, green: 0.70, blue: 1.0, alpha: 1),
        ])
        let g = glyph.size()
        glyph.draw(at: NSPoint(x: (size - g.width) / 2, y: (size - g.height) / 2))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", output]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print(p.terminationStatus == 0 ? output : "iconutil failed")
exit(p.terminationStatus)
