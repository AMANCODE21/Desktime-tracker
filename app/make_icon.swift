// App icon banata hai: dark navy squircle + teal→green progress ring + clock ki suiyan.  Usage: swift make_icon.swift <out.iconset>
import Cocoa

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
/// 12 baje se clockwise angle (0...1) -> point
func pt(_ c: NSPoint, _ r: CGFloat, _ f: CGFloat) -> NSPoint {
    let a = .pi / 2 - f * 2 * .pi
    return NSPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), small = px < 64

    // macOS grid: 1024 me 824 ka body, halki shadow ke saath
    let inset = s * 100 / 1024, box = NSRect(x: inset, y: inset * 1.1, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: box, xRadius: box.width * 0.2237, yRadius: box.width * 0.2237)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.35)
    sh.shadowBlurRadius = s * 0.025; sh.shadowOffset = NSSize(width: 0, height: -s * 0.012); sh.set()
    rgb(0x0F172A).setFill(); bg.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [rgb(0x2A3550), rgb(0x161E33), rgb(0x0B1120)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: bg, angle: -90)
    // upar se halki roshni + patli border
    NSGraphicsContext.saveGraphicsState(); bg.addClip()
    NSGradient(colors: [NSColor(white: 1, alpha: 0.08), NSColor(white: 1, alpha: 0)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(x: box.minX, y: box.midY, width: box.width, height: box.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 1, alpha: 0.10).setStroke(); bg.lineWidth = max(1, s * 0.004); bg.stroke()

    let c = NSPoint(x: box.midX, y: box.midY), R = box.width * 0.30, w = box.width * (small ? 0.11 : 0.085)
    // ring ka track
    let track = NSBezierPath(); track.appendOval(in: NSRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
    NSColor(white: 1, alpha: 0.09).setStroke(); track.lineWidth = w; track.stroke()

    // progress ring: teal -> green, chhote tukdon me gradient
    let done: CGFloat = 0.72, steps = 120
    let c0 = rgb(0x22D3EE).usingColorSpace(.sRGB)!, c1 = rgb(0x34D399).usingColorSpace(.sRGB)!, c2 = rgb(0x84CC16).usingColorSpace(.sRGB)!
    for i in 0..<steps {
        let f0 = done * CGFloat(i) / CGFloat(steps), f1 = done * CGFloat(i + 1) / CGFloat(steps) + 0.002
        let t = CGFloat(i) / CGFloat(steps - 1)
        let col = t < 0.5 ? c0.blended(withFraction: t * 2, of: c1)! : c1.blended(withFraction: (t - 0.5) * 2, of: c2)!
        let seg = NSBezierPath()
        seg.appendArc(withCenter: c, radius: R, startAngle: 90 - f0 * 360, endAngle: 90 - f1 * 360, clockwise: true)
        seg.lineWidth = w; seg.lineCapStyle = (i == 0 || i == steps - 1) ? .round : .butt
        col.setStroke(); seg.stroke()
    }
    // ring ke end pe chamakta dot
    if !small {
        let e = pt(c, R, done), d = w * 0.42
        NSColor(white: 1, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: e.x - d, y: e.y - d, width: 2 * d, height: 2 * d)).fill()
    }

    // ghante ke nishaan (bade size pe hi)
    if !small {
        for h in 0..<12 {
            let big = h % 3 == 0, r1 = R - w * 0.95, r0 = r1 - (big ? w * 0.55 : w * 0.3)
            let p = NSBezierPath(); p.move(to: pt(c, r0, CGFloat(h) / 12)); p.line(to: pt(c, r1, CGFloat(h) / 12))
            p.lineWidth = big ? s * 0.012 : s * 0.007; p.lineCapStyle = .round
            NSColor(white: 1, alpha: big ? 0.55 : 0.28).setStroke(); p.stroke()
        }
    }

    // suiyan: minute wali ring ke end ki taraf, ghante wali ~2 baje
    func hand(_ f: CGFloat, _ len: CGFloat, _ lw: CGFloat, _ col: NSColor) {
        let p = NSBezierPath(); p.move(to: pt(c, -len * 0.12, f)); p.line(to: pt(c, len, f))
        p.lineWidth = lw; p.lineCapStyle = .round; col.setStroke(); p.stroke()
    }
    NSGraphicsContext.saveGraphicsState()
    let hs = NSShadow(); hs.shadowColor = NSColor(white: 0, alpha: 0.4); hs.shadowBlurRadius = s * 0.01; hs.set()
    hand(0.16, R * 0.45, s * (small ? 0.06 : 0.034), .white)
    hand(done, R * 0.68, s * (small ? 0.045 : 0.024), .white)
    NSGraphicsContext.restoreGraphicsState()
    let cd = s * (small ? 0.045 : 0.03)
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - cd, y: c.y - cd, width: 2 * cd, height: 2 * cd)).fill()
    rgb(0x34D399).setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - cd * 0.45, y: c.y - cd * 0.45, width: cd * 0.9, height: cd * 0.9)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
