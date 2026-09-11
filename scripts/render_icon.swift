// Canonical app icon source. Run with the output .iconset directory as argument.
import AppKit

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift render_icon.swift /path/to/AppIcon.iconset")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func drawIcon(pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 202, yRadius: 202)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x16243D).withAlphaComponent(0.24)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    color(0x263955).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x4A6C9E), ending: color(0x223149))!.draw(in: tile, angle: -65)
    color(0xC3D8F5).withAlphaComponent(0.3).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    // A heatmap-shaped T stays recognizable at menu, Finder and Dock sizes.
    let cells: [(Int, Int, UInt32)] = [
        (0, 0, 0xE3ECF8), (1, 0, 0xC3D7F1), (2, 0, 0x9DBCE6), (3, 0, 0x789ED2),
        (1, 1, 0x9DBCE6), (2, 1, 0xB5A3D8),
        (1, 2, 0x7399CE), (2, 2, 0xB0CBED),
        (1, 3, 0x567DAE), (2, 3, 0x8CAEDD)
    ]
    for (column, row, hex) in cells {
        let rect = NSRect(x: CGFloat(220 + column * 152), y: CGFloat(684 - row * 152), width: 128, height: 128)
        let cell = NSBezierPath(roundedRect: rect, xRadius: 27, yRadius: 27)
        color(hex).setFill()
        cell.fill()
        color(0xFFFFFF).withAlphaComponent(0.22).setStroke()
        cell.lineWidth = 2
        cell.stroke()
    }
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let url = output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try drawIcon(pixels: points * scale).write(to: url, options: .atomic)
    }
}
