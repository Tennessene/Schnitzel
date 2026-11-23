//
//  make-icon.swift
//  Draws Schnitzel's app icon and writes Resources/AppIcon.icns plus
//  Resources/AppIcon-1024.png (used in the README).
//
//  This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
//
//  Usage (from the repository root):
//      swift scripts/make-icon.swift
//
//  Original illustration, drawn entirely in code: two breaded schnitzels, a grilled
//  lemon slice, parsley and capers in a dark blue pan, on the standard macOS icon grid
//  (an 824 pt rounded tile on a 1024 pt canvas).
//

import AppKit
import Foundation

let canvas: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// MARK: - Helpers

/// Deterministic random numbers, so the icon is identical on every run.
struct SeededRandom {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 1_000_000) / 1_000_000
    }
    mutating func next(_ range: ClosedRange<CGFloat>) -> CGFloat {
        range.lowerBound + next() * (range.upperBound - range.lowerBound)
    }
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: colors as CFArray, locations: locations)!
}

func fillRadial(_ ctx: CGContext, _ colors: [CGColor], _ locations: [CGFloat]? = nil,
                center: CGPoint, radius: CGFloat) {
    ctx.drawRadialGradient(gradient(colors, locations), startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
}

func fillLinear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.drawLinearGradient(gradient(colors), start: from, end: to,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
}

/// A smooth, slightly irregular closed outline around `center`.
func blobPath(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, rotation: CGFloat,
              wobble: CGFloat, seed: UInt64, points count: Int = 16) -> CGPath {
    var random = SeededRandom(state: seed)
    var points: [CGPoint] = []
    for index in 0..<count {
        let angle = CGFloat(index) / CGFloat(count) * 2 * .pi
        let scale = 1 + (random.next() - 0.5) * wobble
        let x = cos(angle) * radiusX * scale
        let y = sin(angle) * radiusY * scale
        points.append(CGPoint(x: center.x + x * cos(rotation) - y * sin(rotation),
                              y: center.y + x * sin(rotation) + y * cos(rotation)))
    }
    // Closed Catmull-Rom curve through the points, converted to Bézier segments.
    let path = CGMutablePath()
    path.move(to: points[0])
    for index in 0..<count {
        let p0 = points[(index - 1 + count) % count]
        let p1 = points[index]
        let p2 = points[(index + 1) % count]
        let p3 = points[(index + 2) % count]
        path.addCurve(to: p2,
                      control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                      control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }
    path.closeSubpath()
    return path
}

// MARK: - Pan

func drawPan(_ ctx: CGContext) {
    // Rim: the raised edge of the pan, visible in the upper left corner.
    fillLinear(ctx, [color(0x3A4F86), color(0x1B2547)],
               from: CGPoint(x: 120, y: 900), to: CGPoint(x: 520, y: 500))

    // Cooking surface: a large circle whose centre lies to the lower right.
    let center = CGPoint(x: 700, y: 440)
    let radius: CGFloat = 640
    ctx.saveGState()
    ctx.addEllipse(in: circle(center, radius))
    ctx.clip()
    fillRadial(ctx, [color(0x1E2A52), color(0x141C3A), color(0x0C1128)], [0, 0.6, 1],
               center: CGPoint(x: 560, y: 560), radius: radius)
    ctx.restoreGState()

    // Soft highlight where the rim meets the surface.
    ctx.saveGState()
    ctx.addEllipse(in: circle(center, radius + 6))
    ctx.setStrokeColor(color(0x6D86C8, 0.55))
    ctx.setLineWidth(10)
    ctx.strokePath()
    ctx.addEllipse(in: circle(center, radius - 10))
    ctx.setStrokeColor(color(0x05081A, 0.6))
    ctx.setLineWidth(14)
    ctx.strokePath()
    ctx.restoreGState()

    // A sprinkle of salt on the pan.
    var random = SeededRandom(state: 99)
    for _ in 0..<70 {
        let point = CGPoint(x: random.next(140...900), y: random.next(140...880))
        let size = random.next(2...5)
        ctx.setFillColor(color(0xC9D4F2, random.next(0.25...0.6)))
        ctx.fillEllipse(in: circle(point, size))
    }
}

// MARK: - Schnitzel

func drawSchnitzel(_ ctx: CGContext, path: CGPath, light: CGPoint, seed: UInt64) {
    let bounds = path.boundingBox

    // Shadow on the pan.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 6, height: -16), blur: 26, color: color(0x000000, 0.6))
    ctx.addPath(path)
    ctx.setFillColor(color(0xB8640F))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Golden body, brighter toward the light.
    fillRadial(ctx, [color(0xFFC75A), color(0xF29A22), color(0xC8680D)], [0, 0.55, 1],
               center: light, radius: max(bounds.width, bounds.height) * 0.75)

    // A few deeper-browned patches, as from uneven frying.
    var random = SeededRandom(state: seed)
    for _ in 0..<5 {
        let point = CGPoint(x: random.next(bounds.minX...bounds.maxX),
                            y: random.next(bounds.minY...bounds.maxY))
        fillRadial(ctx, [color(0xB55A0C, 0.45), color(0xB55A0C, 0)],
                   center: point, radius: random.next(50...95))
    }

    // Breadcrumb texture: many small light and dark flecks.
    let area = bounds.width * bounds.height
    let flecks = Int(area / 260)
    for _ in 0..<flecks {
        let point = CGPoint(x: random.next(bounds.minX...bounds.maxX),
                            y: random.next(bounds.minY...bounds.maxY))
        let size = random.next(3...9)
        let roll = random.next()
        if roll < 0.45 {
            ctx.setFillColor(color(0xFFE39A, random.next(0.35...0.75)))
        } else if roll < 0.85 {
            ctx.setFillColor(color(0xA9520A, random.next(0.3...0.6)))
        } else {
            ctx.setFillColor(color(0x3A2008, random.next(0.35...0.6))) // black pepper
            ctx.fillEllipse(in: circle(point, size * 0.35))
            continue
        }
        ctx.fillEllipse(in: CGRect(x: point.x, y: point.y, width: size, height: size * 0.75))
    }

    // Darker, crisper edge all around.
    ctx.addPath(path)
    ctx.setStrokeColor(color(0x9A4C08, 0.75))
    ctx.setLineWidth(22)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.addPath(path)
    ctx.setStrokeColor(color(0x7E3D06, 0.9))
    ctx.setLineWidth(4)
    ctx.strokePath()
}

// MARK: - Lemon

func drawLemon(_ ctx: CGContext, center: CGPoint, radius: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 4, height: -12), blur: 20, color: color(0x000000, 0.6))
    ctx.setFillColor(color(0xE7B526))
    ctx.fillEllipse(in: circle(center, radius))
    ctx.restoreGState()

    // Pulp.
    let pulp = radius - 12
    ctx.saveGState()
    ctx.addEllipse(in: circle(center, pulp))
    ctx.clip()
    fillRadial(ctx, [color(0xFFF1A6), color(0xFBD35A), color(0xE9A92A)], [0, 0.6, 1],
               center: CGPoint(x: center.x - 20, y: center.y + 20), radius: pulp)

    // Segment lines.
    ctx.setStrokeColor(color(0xFFF7CC, 0.75))
    ctx.setLineWidth(5)
    for segment in 0..<9 {
        let angle = CGFloat(segment) / 9 * 2 * .pi + 0.2
        ctx.move(to: CGPoint(x: center.x + cos(angle) * 10, y: center.y + sin(angle) * 10))
        ctx.addLine(to: CGPoint(x: center.x + cos(angle) * pulp * 0.92,
                                y: center.y + sin(angle) * pulp * 0.92))
    }
    ctx.strokePath()

    // Grill marks: dark diagonal stripes, slightly uneven.
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: -0.55)
    var random = SeededRandom(state: 5)
    for offset in [-radius * 0.5, 0, radius * 0.5] {
        let width = random.next(9...13)
        let wobble = random.next(-8...8)
        let mark = CGPath(roundedRect: CGRect(x: -radius * 0.85, y: offset + wobble - width / 2,
                                              width: radius * 1.7, height: width),
                          cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 10, color: color(0x8A4210, 0.8))
        ctx.addPath(mark)
        ctx.setFillColor(color(0x5A2A0A, 0.6))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // Rind highlight.
    ctx.addEllipse(in: circle(center, radius - 3))
    ctx.setStrokeColor(color(0xFFE27A, 0.8))
    ctx.setLineWidth(4)
    ctx.strokePath()
}

// MARK: - Garnish

func drawCaper(_ ctx: CGContext, at center: CGPoint, radius: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 2, height: -5), blur: 8, color: color(0x000000, 0.55))
    ctx.setFillColor(color(0x6F7A4A))
    ctx.fillEllipse(in: circle(center, radius))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: circle(center, radius))
    ctx.clip()
    fillRadial(ctx, [color(0xB3BE86), color(0x6E7A48), color(0x3E4627)], [0, 0.5, 1],
               center: CGPoint(x: center.x - radius * 0.35, y: center.y + radius * 0.35),
               radius: radius * 1.3)
    ctx.restoreGState()
}

/// A flat-leaf parsley sprig: a short stem with three lobed leaflets.
func drawParsley(_ ctx: CGContext, at base: CGPoint, angle: CGFloat, scale: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: base.x, y: base.y)
    ctx.rotate(by: angle)
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShadow(offset: CGSize(width: 2, height: -6), blur: 10, color: color(0x000000, 0.5))

    // Stem.
    ctx.setStrokeColor(color(0x4E9A3A))
    ctx.setLineWidth(7)
    ctx.setLineCap(.round)
    ctx.move(to: .zero)
    ctx.addQuadCurve(to: CGPoint(x: 0, y: 70), control: CGPoint(x: 12, y: 35))
    ctx.strokePath()

    // Leaflets.
    let leaflets: [(CGPoint, CGFloat)] = [
        (CGPoint(x: 0, y: 112), 0), (CGPoint(x: -42, y: 78), 0.9), (CGPoint(x: 42, y: 80), -0.9)
    ]
    for (index, leaflet) in leaflets.enumerated() {
        let leaf = blobPath(center: leaflet.0, radiusX: 26, radiusY: 44, rotation: leaflet.1,
                            wobble: 0.55, seed: UInt64(11 + index), points: 9)
        ctx.addPath(leaf)
        ctx.setFillColor(color(0x3E9B36))
        ctx.fillPath()
    }
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    for (index, leaflet) in leaflets.enumerated() {
        let leaf = blobPath(center: leaflet.0, radiusX: 26, radiusY: 44, rotation: leaflet.1,
                            wobble: 0.55, seed: UInt64(11 + index), points: 9)
        ctx.saveGState()
        ctx.addPath(leaf)
        ctx.clip()
        fillRadial(ctx, [color(0x8FDB5E), color(0x3E9B36), color(0x23661F)], [0, 0.55, 1],
                   center: CGPoint(x: leaflet.0.x - 8, y: leaflet.0.y + 14), radius: 52)
        // Centre vein.
        ctx.setStrokeColor(color(0x2C7426, 0.8))
        ctx.setLineWidth(3)
        ctx.move(to: CGPoint(x: 0, y: 66))
        ctx.addLine(to: leaflet.0)
        ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

// MARK: - Icon

func drawIcon(_ ctx: CGContext) {
    // Drop shadow under the whole tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x141C3A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    drawPan(ctx)

    // Second schnitzel, running off the right edge.
    let second = blobPath(center: CGPoint(x: 905, y: 470), radiusX: 330, radiusY: 125,
                          rotation: 1.42, wobble: 0.10, seed: 23)
    drawSchnitzel(ctx, path: second, light: CGPoint(x: 820, y: 640), seed: 77)

    // Parsley under the main schnitzel's left end, and capers.
    drawParsley(ctx, at: CGPoint(x: 300, y: 470), angle: 1.1, scale: 1.05)
    for (point, size) in [(CGPoint(x: 712, y: 345), CGFloat(19)), (CGPoint(x: 748, y: 318), 17),
                          (CGPoint(x: 720, y: 300), 16), (CGPoint(x: 470, y: 810), 18),
                          (CGPoint(x: 505, y: 830), 15)] {
        drawCaper(ctx, at: point, radius: size)
    }

    // Main schnitzel, diagonal from lower left to upper right.
    let main = blobPath(center: CGPoint(x: 500, y: 590), radiusX: 300, radiusY: 158,
                        rotation: 0.5, wobble: 0.14, seed: 7)
    drawSchnitzel(ctx, path: main, light: CGPoint(x: 430, y: 690), seed: 42)

    // Grilled lemon slice and parsley near the bottom.
    drawLemon(ctx, center: CGPoint(x: 545, y: 270), radius: 108)
    drawParsley(ctx, at: CGPoint(x: 740, y: 140), angle: -0.35, scale: 0.95)
    drawParsley(ctx, at: CGPoint(x: 830, y: 760), angle: -0.6, scale: 0.85)

    // Thin light edge so the dark icon doesn't vanish on a dark Dock.
    ctx.addPath(tilePath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.12))
    ctx.setLineWidth(4)
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
