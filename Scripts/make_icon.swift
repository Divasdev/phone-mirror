// Draws the app icon (a 1024×1024 PNG): a phone, and next to it a Mac window showing
// the very same screen. Everything is drawn in code, so there is no image file to keep.
// Usage: swift Scripts/make_icon.swift <output.png>
// build.sh then turns it into AppIcon.icns with `sips` + `iconutil`.

import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024

// Draw into a plain bitmap (no screen needed).
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("Could not create bitmap")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

/// A colour from a web-style number, e.g. 0x34D98C.
func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

/// Draws something with a soft shadow underneath it.
func withShadow(blur: CGFloat, drop: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: -drop)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// Draws only inside `shape`.
func clipped(to shape: NSBezierPath, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// What is "on screen": a home screen with app tiles. The phone and the Mac window both
/// show it, which is the whole idea of the app.
func drawHomeScreen(in rect: NSRect) {
    NSGradient(starting: color(0xFFFFFF), ending: color(0xD9E9FA))!.draw(in: rect, angle: -90)

    let tileColors: [UInt32] = [0xFF6B6B, 0xFFB932, 0x2ED188, 0x3B9DFF, 0x9B6BFF, 0x1EC8C8]
    let columns = 3, rows = 4
    let side = rect.width * 0.2
    let gap = (rect.width - CGFloat(columns) * side) / CGFloat(columns + 1)
    let top = rect.maxY - rect.height * 0.13
    for row in 0..<rows {
        for column in 0..<columns {
            let tile = NSRect(x: rect.minX + gap + CGFloat(column) * (side + gap),
                              y: top - side - CGFloat(row) * (side + gap * 0.8),
                              width: side, height: side)
            color(tileColors[(row * 2 + column) % tileColors.count]).setFill()
            rounded(tile, side * 0.28).fill()
        }
    }

    // The dock at the bottom of the home screen.
    let dock = NSRect(x: rect.minX + rect.width * 0.1, y: rect.minY + rect.height * 0.045,
                      width: rect.width * 0.8, height: side * 1.2)
    color(0xFFFFFF, alpha: 0.85).setFill()
    rounded(dock, dock.height * 0.36).fill()
    let dot = dock.height * 0.5
    for (index, hex) in ([0x2ED188, 0x3B9DFF, 0xFF6B6B] as [UInt32]).enumerated() {
        let x = dock.minX + dock.width * (0.2 + 0.3 * CGFloat(index)) - dot / 2
        color(hex).setFill()
        rounded(NSRect(x: x, y: dock.midY - dot / 2, width: dot, height: dot), dot * 0.28).fill()
    }
}

/// A Mac window (title bar with the three coloured buttons) showing the phone's screen.
func drawWindow(_ frame: NSRect) {
    let shape = rounded(frame, 30)
    withShadow(blur: 36, drop: 18, alpha: 0.38) {
        color(0xFFFFFF).setFill()
        shape.fill()
    }
    clipped(to: shape) {
        let barHeight: CGFloat = 58
        let content = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - barHeight)
        drawHomeScreen(in: content)
        color(0xEEF2F6).setFill()
        NSRect(x: frame.minX, y: content.maxY, width: frame.width, height: barHeight).fill()
        for (index, hex) in ([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32]).enumerated() {
            color(hex).setFill()
            NSBezierPath(ovalIn: NSRect(x: frame.minX + 22 + CGFloat(index) * 34, y: content.maxY + barHeight / 2 - 11,
                                        width: 22, height: 22)).fill()
        }
    }
}

/// The phone: a dark body, the screen, and the small camera hole.
func drawPhone(_ frame: NSRect) {
    let radius: CGFloat = 58
    let bezel: CGFloat = 16
    withShadow(blur: 36, drop: 18, alpha: 0.42) {
        color(0x0E1620).setFill()
        rounded(frame, radius).fill()
    }
    let rim = rounded(frame.insetBy(dx: 2, dy: 2), radius - 2)
    rim.lineWidth = 4
    color(0x3D4E5F).setStroke()
    rim.stroke()

    let screen = frame.insetBy(dx: bezel, dy: bezel)
    clipped(to: rounded(screen, radius - bezel)) { drawHomeScreen(in: screen) }
    color(0x0E1620).setFill()
    NSBezierPath(ovalIn: NSRect(x: frame.midX - 11, y: screen.maxY - 42, width: 22, height: 22)).fill()
}

// 1. The rounded-square background: green → teal → blue, with a soft glow in one corner.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tileShape = rounded(tile, 186)
withShadow(blur: 22, drop: 10, alpha: 0.28) {
    color(0x0B5FA8).setFill()
    tileShape.fill()
}
NSGradient(colors: [color(0x38DC8E), color(0x12A7A0), color(0x0B5AA6)])!.draw(in: tileShape, angle: -62)
clipped(to: tileShape) {
    NSGradient(starting: color(0xFFFFFF, alpha: 0.22), ending: color(0xFFFFFF, alpha: 0))!
        .draw(fromCenter: NSPoint(x: 300, y: 860), radius: 0, toCenter: NSPoint(x: 300, y: 860), radius: 560, options: [])
}

// 2. The Mac window on the left, the phone on the right, drawn a little larger than laid out.
let grow = NSAffineTransform()
grow.translateX(by: 512, yBy: 512)
grow.scale(by: 1.1)
grow.translateX(by: -512, yBy: -512)
grow.concat()

drawWindow(NSRect(x: 218, y: 252, width: 258, height: 548))
drawPhone(NSRect(x: 516, y: 228, width: 290, height: 540))

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
try png.write(to: URL(fileURLWithPath: outputPath))
print("Icon written to \(outputPath)")
