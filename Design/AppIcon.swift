// Draws Velvet's app icon: dark brushed velvet with a crimson play button.
// Regenerate: swiftc -O Design/AppIcon.swift -o /tmp/appicon && /tmp/appicon <out-dir>,
// then copy <out-dir>/Velvet-1024.png to Velvet/AppIcon.icon/Assets/Velvet.png.
//
// The icon is an Icon Composer file (Velvet/AppIcon.icon) with this image as its only layer,
// full bleed: macOS 26 and later give it the system's shape and shadow. For macOS 15, Xcode
// draws rounded fallback images from it. (A plain icon set can't serve both: a full-bleed
// square shows unrounded on macOS 15, and a pre-rounded one showed a blank placeholder on
// macOS 27.)

import AppKit
import CoreGraphics

let size: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)   // the design's coordinate space


func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Fine fabric grain: tiny random light/dark specks, very faint.
func grain(_ ctx: CGContext, in rect: CGRect, strength: CGFloat) {
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<90000 {
        let x = CGFloat.random(in: rect.minX...rect.maxX, using: &rng)
        let y = CGFloat.random(in: rect.minY...rect.maxY, using: &rng)
        let light = Bool.random(using: &rng)
        ctx.setFillColor(light ? CGColor(gray: 1, alpha: strength) : CGColor(gray: 0, alpha: strength * 1.4))
        ctx.fill(CGRect(x: x, y: y, width: 1.6, height: 1.6))
    }
}

/// A play triangle with rounded corners, centred optically (shifted right a little).
func playPath(center: CGPoint, size s: CGFloat, corner: CGFloat) -> CGPath {
    let h = s, w = s * 0.94
    let a = CGPoint(x: center.x - w * 0.42, y: center.y + h / 2)
    let b = CGPoint(x: center.x - w * 0.42, y: center.y - h / 2)
    let c = CGPoint(x: center.x + w * 0.58, y: center.y)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
    p.addArc(tangent1End: b, tangent2End: c, radius: corner)
    p.addArc(tangent1End: c, tangent2End: a, radius: corner)
    p.addArc(tangent1End: a, tangent2End: b, radius: corner)
    p.closeSubpath()
    return p
}

func render(_ name: String, draw: (CGContext) -> Void) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Full-bleed and opaque: the design's 824 pt body is scaled to fill the canvas, and macOS
    // applies its own rounded mask and shadow. An icon with transparent, pre-rounded corners
    // shows as the blank placeholder in the Dock and About panel on macOS 27.
    ctx.scaleBy(x: size / body.width, y: size / body.height)
    ctx.translateBy(x: -body.minX, y: -body.minY)
    draw(ctx)
    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/\(name).png"))
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.drawLinearGradient(CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func radial(_ ctx: CGContext, _ colors: [CGColor], center: CGPoint, radius: CGFloat) {
    ctx.drawRadialGradient(CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
}


/// Directional nap: faint parallel strokes, like brushed velvet.
func nap(_ ctx: CGContext, in rect: CGRect, angle: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: rect.midX, y: rect.midY); ctx.rotate(by: angle)
    var rng = SystemRandomNumberGenerator()
    for i in stride(from: -700, to: 700, by: 3) {
        ctx.setStrokeColor(CGColor(gray: Bool.random(using: &rng) ? 1 : 0, alpha: alpha * CGFloat.random(in: 0.3...1, using: &rng)))
        ctx.setLineWidth(1.2)
        ctx.move(to: CGPoint(x: -700, y: CGFloat(i))); ctx.addLine(to: CGPoint(x: 700, y: CGFloat(i))); ctx.strokePath()
    }
    ctx.restoreGState()
}

func darkVelvet(_ ctx: CGContext, top: UInt32, bottom: UInt32, sheen: UInt32) {
    linear(ctx, [color(top), color(bottom)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    ctx.saveGState(); ctx.setBlendMode(.screen)
    radial(ctx, [color(sheen, 0.5), color(sheen, 0)], center: CGPoint(x: 330, y: 820), radius: 520)
    ctx.restoreGState()
    grain(ctx, in: body, strength: 0.03)
}

func crimsonPlay(_ ctx: CGContext, center: CGPoint, size: CGFloat, glow: CGFloat, light: UInt32 = 0xFF4D63, dark: UInt32 = 0xA30A24) {
    let play = playPath(center: center, size: size, corner: size * 0.145)
    if glow > 0 {
        ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 44, color: color(0xE0103A, glow))
        ctx.addPath(play); ctx.setFillColor(color(dark)); ctx.fillPath(); ctx.restoreGState()
    }
    ctx.saveGState(); ctx.addPath(play); ctx.clip()
    linear(ctx, [color(light), color(dark)], from: CGPoint(x: center.x - size * 0.3, y: center.y + size * 0.55), to: CGPoint(x: center.x + size * 0.3, y: center.y - size * 0.55))
    grain(ctx, in: CGRect(x: center.x - size, y: center.y - size, width: size * 2, height: size * 2), strength: 0.04)
    ctx.restoreGState()
}

// B4: brushed nap background, crimson play with a thin bright rim and no glow
render("Velvet-1024") { ctx in
    linear(ctx, [color(0x2C2528), color(0x0C0A0B)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    nap(ctx, in: body, angle: -0.6, alpha: 0.045)
    ctx.saveGState(); ctx.setBlendMode(.screen)
    radial(ctx, [color(0x6B5A60, 0.4), color(0x6B5A60, 0)], center: CGPoint(x: 330, y: 820), radius: 500)
    ctx.restoreGState()
    let c = CGPoint(x: 532, y: 512)
    crimsonPlay(ctx, center: c, size: 360, glow: 0)
    ctx.addPath(playPath(center: c, size: 360, corner: 52)); ctx.setStrokeColor(color(0xFF8A98, 0.55)); ctx.setLineWidth(5); ctx.strokePath()
}


// Every size the app icon set needs, scaled from the master.
let master = NSImage(contentsOfFile: CommandLine.arguments[1] + "/Velvet-1024.png")!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/icon_\(px).png"))
}
