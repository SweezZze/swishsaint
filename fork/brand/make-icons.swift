// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat
//
// Provisional Swishsaint icons: two fingertips swiping, on a gradient tile.
// Writes AppIcon.icns, MenuBarIcon.png, MenuBarIcon@2x.png and BrandMark.png
// next to this script.
//
//   swift fork/brand/make-icons.swift

import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

func canvas(_ width: Int, _ height: Int, draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    draw(context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Two fingertips and their trails, in a unit square (y up).
func drawGlyph(_ ctx: CGContext, in rect: CGRect, color: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.minY)
    ctx.scaleBy(x: rect.width, y: rect.height)
    ctx.setStrokeColor(color)
    ctx.setFillColor(color)
    ctx.setLineCap(.round)
    for (index, y) in [CGFloat(0.68), 0.32].enumerated() {
        let tipX: CGFloat = index == 0 ? 0.74 : 0.80
        let trail = CGMutablePath()
        trail.move(to: CGPoint(x: 0.12, y: y - 0.06))
        trail.addQuadCurve(to: CGPoint(x: tipX - 0.14, y: y), control: CGPoint(x: 0.36, y: y + 0.03))
        ctx.addPath(trail)
        ctx.setLineWidth(0.075)
        ctx.strokePath()
        ctx.fillEllipse(in: CGRect(x: tipX - 0.11, y: y - 0.11, width: 0.22, height: 0.22))
    }
    ctx.restoreGState()
}

func appIcon(px: Int) -> Data {
    canvas(px, px) { ctx in
        let size = CGFloat(px)
        // macOS grid: an 824/1024 tile, centered.
        let tile = CGRect(x: size * 100 / 1024, y: size * 100 / 1024,
                          width: size * 824 / 1024, height: size * 824 / 1024)
        let shape = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225,
                           cornerHeight: tile.width * 0.225, transform: nil)
        ctx.addPath(shape)
        ctx.clip()
        let colors = [CGColor(red: 0.18, green: 0.78, blue: 0.80, alpha: 1),
                      CGColor(red: 0.33, green: 0.30, blue: 0.86, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY),
                               end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
        drawGlyph(ctx, in: tile.insetBy(dx: tile.width * 0.14, dy: tile.width * 0.14),
                  color: CGColor(gray: 1, alpha: 1))
    }
}

func appendBE(_ value: Int, to data: inout Data) {
    for shift in [24, 16, 8, 0] { data.append(UInt8((value >> shift) & 0xff)) }
}

var icns = Data()
let entries = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256),
               ("ic09", 512), ("ic10", 1024), ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)]
    .map { ($0.0, appIcon(px: $0.1)) }
icns.append(contentsOf: "icns".utf8)
appendBE(8 + entries.reduce(0) { $0 + 8 + $1.1.count }, to: &icns)
for (type, png) in entries {
    icns.append(contentsOf: type.utf8)
    appendBE(8 + png.count, to: &icns)
    icns.append(png)
}
try icns.write(to: outDir.appendingPathComponent("AppIcon.icns"))

// Same canvas as the official menu bar mark (26 × 20 pt): a black template.
for scale in [1, 2] {
    let png = canvas(26 * scale, 20 * scale) { ctx in
        let side = CGFloat(18 * scale)
        drawGlyph(ctx, in: CGRect(x: CGFloat(4 * scale), y: CGFloat(scale), width: side, height: side),
                  color: CGColor(gray: 0, alpha: 1))
    }
    try png.write(to: outDir.appendingPathComponent(scale == 1 ? "MenuBarIcon.png" : "MenuBarIcon@2x.png"))
}

// Same size as the official brand mark (640 × 324).
let mark = canvas(640, 324) { ctx in
    drawGlyph(ctx, in: CGRect(x: 158, y: 0, width: 324, height: 324),
              color: CGColor(red: 0.33, green: 0.30, blue: 0.86, alpha: 1))
}
try mark.write(to: outDir.appendingPathComponent("BrandMark.png"))
print("icons written to \(outDir.path)")
