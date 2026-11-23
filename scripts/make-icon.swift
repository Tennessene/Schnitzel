//
//  make-icon.swift
//  Draws Schnitzel's placeholder app icon and writes Resources/AppIcon.icns.
//
//  This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
//
//  Usage (from the repository root):
//      swift scripts/make-icon.swift
//
//  Original design: a cast-iron pan seen from above with a golden, breaded schnitzel
//  and a lemon slice, on a warm background. Fully drawn in code, no outside artwork.
//

import AppKit
import Foundation

let canvas: CGFloat = 1024

/// Deterministic random numbers, so the icon is the same on every run.
struct SeededRandom {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 1_000_000) / 1_000_000
    }
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [])
}

func radialGradient(_ ctx: CGContext, _ colors: [CGColor], center: CGPoint, radius: CGFloat) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
}

/// A wobbly closed blob around `center`, used for the schnitzel's outline.
func blobPath(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, rotation: CGFloat,
              wobble: CGFloat, seed: UInt64) -> CGPath {
    var random = SeededRandom(state: seed)
    let count = 14
    var offsets: [CGFloat] = []
    for _ in 0..<count { offsets.append(1 + (random.next() - 0.5) * wobble) }
    var points: [CGPoint] = []
    for index in 0..<count {
        let angle = CGFloat(index) / CGFloat(count) * 2 * .pi
        let x = cos(angle) * radiusX * offsets[index]
        let y = sin(angle) * radiusY * offsets[index]
        points.append(CGPoint(
            x: center.x + x * cos(rotation) - y * sin(rotation),
            y: center.y + x * sin(rotation) + y * cos(rotation)))
    }
    // Smooth closed curve through the points (Catmull-Rom converted to Bézier).
    let path = CGMutablePath()
    path.move(to: points[0])
    for index in 0..<count {
        let p0 = points[(index - 1 + count) % count]
        let p1 = points[index]
        let p2 = points[(index + 1) % count]
        let p3 = points[(index + 2) % count]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: c1, control2: c2)
    }
    path.closeSubpath()
    return path
}

func drawIcon(_ ctx: CGContext) {
    // Background tile, following the macOS icon grid (824 pt tile on a 1024 pt canvas).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0xF2C46B))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    linearGradient(ctx, [color(0xFBE3A6), color(0xE9963E)],
                   from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))

    // Pan handle, toward the lower right, drawn first so the pan covers its end.
    let handleAngle: CGFloat = -.pi / 4
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 540)
    ctx.rotate(by: handleAngle)
    let handle = CGPath(roundedRect: CGRect(x: 250, y: -38, width: 240, height: 76),
                        cornerWidth: 38, cornerHeight: 38, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: color(0x000000, 0.35))
    ctx.addPath(handle)
    ctx.setFillColor(color(0x2B2724))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Hanging hole in the handle.
    ctx.addEllipse(in: CGRect(x: 432, y: -16, width: 32, height: 32))
    ctx.setFillColor(color(0xE9963E))
    ctx.fillPath()
    ctx.restoreGState()

    // Pan body.
    let panCenter = CGPoint(x: 500, y: 552)
    let panRadius: CGFloat = 300
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.4))
    ctx.addEllipse(in: CGRect(x: panCenter.x - panRadius, y: panCenter.y - panRadius,
                              width: panRadius * 2, height: panRadius * 2))
    ctx.setFillColor(color(0x34302C))
    ctx.fillPath()
    ctx.restoreGState()

    // Rim highlight.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: panCenter.x - panRadius, y: panCenter.y - panRadius,
                              width: panRadius * 2, height: panRadius * 2))
    ctx.clip()
    linearGradient(ctx, [color(0x5A544E), color(0x22201E)],
                   from: CGPoint(x: panCenter.x - 200, y: panCenter.y + 260),
                   to: CGPoint(x: panCenter.x + 200, y: panCenter.y - 260))
    ctx.restoreGState()

    // Cooking surface.
    let innerRadius: CGFloat = 256
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: panCenter.x - innerRadius, y: panCenter.y - innerRadius,
                              width: innerRadius * 2, height: innerRadius * 2))
    ctx.clip()
    radialGradient(ctx, [color(0x3D3833), color(0x1C1A18)],
                   center: CGPoint(x: panCenter.x - 60, y: panCenter.y + 70), radius: innerRadius * 1.2)
    ctx.restoreGState()

    // Schnitzel.
    let schnitzelCenter = CGPoint(x: panCenter.x - 10, y: panCenter.y + 6)
    let schnitzel = blobPath(center: schnitzelCenter, radiusX: 205, radiusY: 150,
                             rotation: 0.35, wobble: 0.16, seed: 7)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x000000, 0.45))
    ctx.addPath(schnitzel)
    ctx.setFillColor(color(0xC9781F))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(schnitzel)
    ctx.clip()
    radialGradient(ctx, [color(0xF6C35A), color(0xE59A2E), color(0xB8661A)],
                   center: CGPoint(x: schnitzelCenter.x - 40, y: schnitzelCenter.y + 50), radius: 240)
    // Breadcrumb texture.
    var random = SeededRandom(state: 42)
    for _ in 0..<260 {
        let x = schnitzelCenter.x + (random.next() - 0.5) * 440
        let y = schnitzelCenter.y + (random.next() - 0.5) * 360
        let size = 5 + random.next() * 11
        let light = random.next() > 0.5
        ctx.setFillColor(light ? color(0xFFE29A, 0.55) : color(0x9C5414, 0.45))
        ctx.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size * 0.8))
    }
    ctx.restoreGState()

    // Golden edge.
    ctx.addPath(schnitzel)
    ctx.setStrokeColor(color(0xA65A15, 0.8))
    ctx.setLineWidth(6)
    ctx.strokePath()

    // Lemon slice.
    let lemonCenter = CGPoint(x: panCenter.x + 120, y: panCenter.y + 110)
    let lemonRadius: CGFloat = 62
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: color(0x000000, 0.4))
    ctx.setFillColor(color(0xF7D83A))
    ctx.fillEllipse(in: CGRect(x: lemonCenter.x - lemonRadius, y: lemonCenter.y - lemonRadius,
                               width: lemonRadius * 2, height: lemonRadius * 2))
    ctx.restoreGState()
    let flesh = lemonRadius - 10
    ctx.setFillColor(color(0xFFF3A8))
    ctx.fillEllipse(in: CGRect(x: lemonCenter.x - flesh, y: lemonCenter.y - flesh,
                               width: flesh * 2, height: flesh * 2))
    ctx.setStrokeColor(color(0xF2CF2E))
    ctx.setLineWidth(5)
    for segment in 0..<8 {
        let angle = CGFloat(segment) / 8 * 2 * .pi
        ctx.move(to: lemonCenter)
        ctx.addLine(to: CGPoint(x: lemonCenter.x + cos(angle) * flesh,
                                y: lemonCenter.y + sin(angle) * flesh))
    }
    ctx.strokePath()

    ctx.restoreGState()
}

func renderPNG(size: Int, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory
    .appending(path: "Schnitzel-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    try renderPNG(size: base, to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try renderPNG(size: base * 2, to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
try renderPNG(size: 1024, to: root.appending(path: "Resources/AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}
print("Wrote Resources/AppIcon.icns and Resources/AppIcon-1024.png")
