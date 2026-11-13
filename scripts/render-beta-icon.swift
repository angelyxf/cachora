import AppKit

// Cachora's glass recovery loop. Draw at the final pixel size so the rim and
// rounded arrow remain legible in small Finder and Dock representations.
private let canvas: CGFloat = 1024
private let space = CGColorSpace(name: CGColorSpace.sRGB)!

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255,
            alpha: alpha)
}

private func fillGradient(
    _ context: CGContext, path: CGPath, colors: [CGColor], stops: [CGFloat],
    from start: CGPoint, to end: CGPoint
) {
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops)!
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gradient, start: start, end: end,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

private func glow(
    _ context: CGContext, inside path: CGPath, at center: CGPoint,
    radius: CGFloat, color: CGColor
) {
    let gradient = CGGradient(colorsSpace: space,
                              colors: [color, color.copy(alpha: 0)!] as CFArray,
                              locations: [0, 1])!
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])
    context.restoreGState()
}

private func recoveryLoop() -> CGPath {
    let center = CGPoint(x: 512, y: 510)
    let outerRadius: CGFloat = 278
    let innerRadius: CGFloat = 156
    let top = -CGFloat.pi * 0.24
    let bottom = -CGFloat.pi * 1.73

    func point(radius: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    let path = CGMutablePath()
    let innerTop = point(radius: innerRadius, angle: top)
    let outerTop = point(radius: outerRadius, angle: top)
    path.move(to: innerTop)
    path.addArc(center: center, radius: innerRadius, startAngle: top, endAngle: bottom, clockwise: true)
    // The arrowhead grows out of the lower terminal. Its rounded outline
    // shares the two edges of the ring instead of sitting above them.
    path.addLine(to: CGPoint(x: 595, y: 610))
    path.addQuadCurve(to: CGPoint(x: 600, y: 596), control: CGPoint(x: 587, y: 597))
    path.addLine(to: CGPoint(x: 743, y: 601))
    path.addQuadCurve(to: CGPoint(x: 758, y: 620), control: CGPoint(x: 767, y: 603))
    path.addLine(to: CGPoint(x: 727, y: 756))
    path.addQuadCurve(to: CGPoint(x: 711, y: 760), control: CGPoint(x: 723, y: 770))
    path.addLine(to: point(radius: outerRadius, angle: bottom))
    path.addArc(center: center, radius: outerRadius, startAngle: bottom, endAngle: top, clockwise: false)
    path.addCurve(to: innerTop,
                  control1: CGPoint(x: outerTop.x + 58, y: outerTop.y + 62),
                  control2: CGPoint(x: innerTop.x + 54, y: innerTop.y + 59))
    path.closeSubpath()
    return path
}

private func render(pixels: Int) -> Data {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / canvas
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)

    let tile = CGPath(roundedRect: CGRect(x: 82, y: 73, width: 860, height: 860),
                      cornerWidth: 208, cornerHeight: 208, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -17 * scale), blur: 24 * scale,
                      color: color(0x1A285A, alpha: 0.30))
    context.setFillColor(color(0x245ED6))
    context.addPath(tile)
    context.fillPath()
    context.restoreGState()
    fillGradient(context, path: tile,
                 colors: [color(0x6CC5FA), color(0x397DED), color(0x2857D2), color(0x222C98)],
                 stops: [0, 0.34, 0.69, 1],
                 from: CGPoint(x: 168, y: 82), to: CGPoint(x: 881, y: 927))
    glow(context, inside: tile, at: CGPoint(x: 215, y: 92), radius: 544,
         color: color(0xE4F8FF, alpha: 0.55))
    glow(context, inside: tile, at: CGPoint(x: 787, y: 843), radius: 464,
         color: color(0x263AFF, alpha: 0.40))
    let rim = tile.copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 1)
    fillGradient(context, path: rim,
                 colors: [color(0xFFFFFF, alpha: 0.80), color(0xBDDEFF, alpha: 0.14),
                          color(0x161F7A, alpha: 0.65)],
                 stops: [0, 0.46, 1],
                 from: CGPoint(x: 188, y: 72), to: CGPoint(x: 807, y: 918))

    let loop = recoveryLoop()
    var offset = CGAffineTransform(translationX: 0, y: 17)
    let depth = loop.copy(using: &offset)!
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 30 * scale,
                      color: color(0x102A77, alpha: 0.62))
    context.setFillColor(color(0x82B6F6))
    context.addPath(depth)
    context.fillPath()
    context.restoreGState()
    fillGradient(context, path: depth,
                 colors: [color(0xB8E8FF), color(0x6D9DF3), color(0x466CD5)],
                 stops: [0, 0.52, 1],
                 from: CGPoint(x: 360, y: 245), to: CGPoint(x: 713, y: 815))
    fillGradient(context, path: loop,
                 colors: [color(0xFFFFFF), color(0xDDF4FF), color(0xBBD7FF), color(0xF0F6FF)],
                 stops: [0, 0.29, 0.72, 1],
                 from: CGPoint(x: 353, y: 226), to: CGPoint(x: 688, y: 805))
    glow(context, inside: loop, at: CGPoint(x: 363, y: 324), radius: 276,
         color: color(0xFFFFFF, alpha: 0.74))
    let bevel = loop.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 1)
    fillGradient(context, path: bevel,
                 colors: [color(0xFFFFFF), color(0xEDF9FF, alpha: 0.28), color(0xFFFFFF, alpha: 0.72)],
                 stops: [0, 0.55, 1],
                 from: CGPoint(x: 353, y: 225), to: CGPoint(x: 632, y: 813))

    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "beta_\(points)@\(scale)x.png"
        try render(pixels: points * scale).write(to: destination.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "Cachora contributors", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: destination.appendingPathComponent("Contents.json"))
