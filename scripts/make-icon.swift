//
//  make-icon.swift
//  Builds Schnitzel's app icon from Resources/AppIcon-source.jpg and writes
//  Resources/AppIcon.icns plus Resources/AppIcon-1024.png (used in the README).
//
//  This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
//
//  Usage (from the repository root):
//      swift scripts/make-icon.swift
//
//  The source is a square photo. It is placed on the standard macOS icon grid
//  (an 824 pt rounded tile on a 1024 pt canvas) with a soft drop shadow.
//  The photo itself is not GPL: see "App icon" in README.md for its license.
//

import AppKit
import Foundation

let canvas: CGFloat = 1024
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appending(path: "Resources/AppIcon-source.jpg")

guard let source = NSImage(contentsOf: sourceURL),
      let photo = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Can't read \(sourceURL.path). Run this from the repository root.")
}

func drawIcon(_ ctx: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // The photo, clipped to the tile. Crop to the centre square if it isn't square.
    let side = min(photo.width, photo.height)
    let square = photo.cropping(to: CGRect(x: (photo.width - side) / 2,
                                           y: (photo.height - side) / 2,
                                           width: side, height: side))!
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(square, in: tile)
    ctx.restoreGState()

    // Thin light edge so the dark photo doesn't disappear on a dark Dock.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
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
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

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
