import AppKit
import Foundation

// Renders the Gridora app icon into Resources/AppIcon.icns

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
ctx.setAllowsAntialiasing(true)

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let path = NSBezierPath(roundedRect: rect.insetBy(dx: 62, dy: 62), xRadius: 210, yRadius: 210)

// Drop shadow
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 40
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()
NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.12, alpha: 1).setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()

// Base gradient
NSGraphicsContext.saveGraphicsState()
path.addClip()
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.30, blue: 0.62, alpha: 1),
    NSColor(calibratedRed: 0.12, green: 0.11, blue: 0.26, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.10, alpha: 1)
], atLocations: [0.0, 0.55, 1.0], colorSpace: .deviceRGB)!
gradient.draw(in: rect, angle: -70)

// Aurora glow
let glow = NSGradient(colors: [
    NSColor(calibratedRed: 0.35, green: 0.55, blue: 1.0, alpha: 0.55),
    NSColor(calibratedRed: 0.35, green: 0.55, blue: 1.0, alpha: 0.0)
])!
glow.draw(in: NSRect(x: -160, y: 380, width: 900, height: 900), relativeCenterPosition: NSPoint(x: -0.1, y: 0.1))

let glow2 = NSGradient(colors: [
    NSColor(calibratedRed: 0.75, green: 0.35, blue: 0.95, alpha: 0.45),
    NSColor(calibratedRed: 0.75, green: 0.35, blue: 0.95, alpha: 0.0)
])!
glow2.draw(in: NSRect(x: 420, y: -240, width: 800, height: 800), relativeCenterPosition: NSPoint(x: 0.1, y: -0.1))
NSGraphicsContext.restoreGraphicsState()

// Top light
NSGraphicsContext.saveGraphicsState()
path.addClip()
let topLight = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.16),
    NSColor.white.withAlphaComponent(0.0)
])!
topLight.draw(in: NSRect(x: 62, y: 560, width: 900, height: 430), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// 3x3 grid glyph
let cell: CGFloat = 150
let gap: CGFloat = 46
let total = cell * 3 + gap * 2
let startX = (size - total) / 2
let startY = (size - total) / 2 + 10

for row in 0..<3 {
    for col in 0..<3 {
        let r = NSRect(x: startX + CGFloat(col) * (cell + gap),
                       y: startY + CGFloat(row) * (cell + gap),
                       width: cell, height: cell)
        let tile = NSBezierPath(roundedRect: r, xRadius: 44, yRadius: 44)

        let highlight = (row == 2 && col == 1)
        if highlight {
            let g = NSGradient(colors: [
                NSColor(calibratedRed: 0.42, green: 0.72, blue: 1.0, alpha: 1),
                NSColor(calibratedRed: 0.28, green: 0.46, blue: 0.98, alpha: 1)
            ])!
            g.draw(in: tile, angle: -90)
        } else {
            NSColor.white.withAlphaComponent(row == 0 ? 0.92 : (row == 1 ? 0.72 : 0.5)).setFill()
            tile.fill()
        }

        NSColor.white.withAlphaComponent(highlight ? 0.5 : 0.18).setStroke()
        tile.lineWidth = 3
        tile.stroke()
    }
}

image.unlockFocus()

// Export iconset
let dir = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]

for (pixel, name) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixel, pixelsHigh: pixel,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixel, height: pixel)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixel, height: pixel),
               from: NSRect(x: 0, y: 0, width: size, height: size),
               operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: dir.appendingPathComponent(name))
}

print("iconset written")
