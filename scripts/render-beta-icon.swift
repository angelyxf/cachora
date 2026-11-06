import AppKit
import Foundation

// Original geometric artwork for this fork: an open storage tray and return arc.
// No upstream logo or third-party bitmap is used.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
        let background = NSBezierPath(roundedRect: NSRect(x: 36, y: 36, width: 952, height: 952), xRadius: 218, yRadius: 218)
        NSGradient(starting: NSColor(srgbRed: 0.08, green: 0.32, blue: 0.39, alpha: 1),
                   ending: NSColor(srgbRed: 0.06, green: 0.62, blue: 0.62, alpha: 1))!
            .draw(in: background, angle: 52)
        let tray = NSBezierPath()
        tray.move(to: NSPoint(x: 260, y: 460)); tray.line(to: NSPoint(x: 260, y: 280))
        tray.curve(to: NSPoint(x: 316, y: 224), controlPoint1: NSPoint(x: 260, y: 244), controlPoint2: NSPoint(x: 280, y: 224))
        tray.line(to: NSPoint(x: 708, y: 224))
        tray.curve(to: NSPoint(x: 764, y: 280), controlPoint1: NSPoint(x: 744, y: 224), controlPoint2: NSPoint(x: 764, y: 244))
        tray.line(to: NSPoint(x: 764, y: 460))
        tray.lineWidth = 58; tray.lineCapStyle = .round; tray.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(0.94).setStroke(); tray.stroke()
        let arc = NSBezierPath()
        arc.move(to: NSPoint(x: 730, y: 620))
        arc.curve(to: NSPoint(x: 362, y: 688), controlPoint1: NSPoint(x: 700, y: 828), controlPoint2: NSPoint(x: 414, y: 838))
        arc.lineWidth = 60; arc.lineCapStyle = .round
        NSColor.white.setStroke(); arc.stroke()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 354, y: 794)); arrow.line(to: NSPoint(x: 352, y: 666)); arrow.line(to: NSPoint(x: 484, y: 681))
        arrow.lineWidth = 60; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
        NSColor.white.withAlphaComponent(0.4).setFill()
        NSBezierPath(roundedRect: NSRect(x: 388, y: 392, width: 248, height: 60), xRadius: 30, yRadius: 30).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = "beta_\(points)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "Cachora contributors", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: destination.appendingPathComponent("Contents.json"))
