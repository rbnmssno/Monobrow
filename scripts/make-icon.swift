// Draws the Monobrow app icon (1024 px PNG). Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let side = 1024
guard CommandLine.arguments.count > 1,
      let bitmap = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    print("usage: make-icon.swift <output.png>")
    exit(1)
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

// The standard macOS icon shape: an 824 px rounded square centred on a 1024 px canvas.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let platePath = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
color(0x101216).setFill()
platePath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
platePath.addClip()
NSGradient(colors: [color(0x0C0D11), color(0x1B1E26), color(0x2B2F3A)])?.draw(in: plate, angle: 90)

// A soft glow behind the bars.
NSGradient(colors: [color(0x1ED760, alpha: 0.22), color(0x1ED760, alpha: 0)])?
    .draw(in: NSRect(x: 212, y: 120, width: 600, height: 600), relativeCenterPosition: .zero)

// The notch island hanging from the top edge.
let islandWidth: CGFloat = 400
let islandHeight: CGFloat = 118
let island = NSBezierPath()
let left = plate.midX - islandWidth / 2
let right = plate.midX + islandWidth / 2
let top = plate.maxY
let bottom = plate.maxY - islandHeight
let radius: CGFloat = 50
island.move(to: NSPoint(x: left, y: top))
island.line(to: NSPoint(x: right, y: top))
island.line(to: NSPoint(x: right, y: bottom + radius))
island.appendArc(withCenter: NSPoint(x: right - radius, y: bottom + radius), radius: radius, startAngle: 0, endAngle: 270, clockwise: true)
island.line(to: NSPoint(x: left + radius, y: bottom))
island.appendArc(withCenter: NSPoint(x: left + radius, y: bottom + radius), radius: radius, startAngle: 270, endAngle: 180, clockwise: true)
island.close()
NSColor.black.setFill()
island.fill()

// Equalizer bars.
let heights: [CGFloat] = [230, 400, 290, 350]
let barWidth: CGFloat = 88
let gap: CGFloat = 46
let total = barWidth * 4 + gap * 3
let baseline: CGFloat = 232
for (index, height) in heights.enumerated() {
    let x = plate.midX - total / 2 + CGFloat(index) * (barWidth + gap)
    let rect = NSRect(x: x, y: baseline, width: barWidth, height: height)
    let bar = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
    NSGradient(colors: [color(0x1ED760), color(0x8DF5B5)])?.draw(in: bar, angle: 90)
}
NSGraphicsContext.restoreGraphicsState()

// A faint light edge at the top of the plate.
NSGraphicsContext.saveGraphicsState()
platePath.addClip()
let edge = NSBezierPath(roundedRect: plate.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
edge.lineWidth = 4
NSColor.white.withAlphaComponent(0.07).setStroke()
edge.stroke()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
} catch {
    print("cannot write icon: \(error)")
    exit(1)
}
