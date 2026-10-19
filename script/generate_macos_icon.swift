import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let manager = FileManager.default
try manager.createDirectory(at: output, withIntermediateDirectories: true)
let iconset = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iconset")
try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: iconset) }

let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.systemTeal.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(calibratedRed: 0.025, green: 0.48, blue: 0.51, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.77, blue: 0.80, alpha: 1)
    ])!.draw(in: tile, angle: 55)
    NSColor.white.withAlphaComponent(0.2).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    let mark = NSImage(size: NSSize(width: 560, height: 560), flipped: false) { rect in
        let symbol = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)!
        symbol.draw(in: rect.insetBy(dx: 10, dy: 10))
        NSColor.white.setFill()
        rect.fill(using: .sourceIn)
        return true
    }
    NSGraphicsContext.saveGraphicsState()
    let markShadow = NSShadow()
    markShadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
    markShadow.shadowBlurRadius = 18
    markShadow.shadowOffset = NSSize(width: 0, height: -12)
    markShadow.set()
    mark.draw(in: NSRect(x: 232, y: 232, width: 560, height: 560))
    NSGraphicsContext.restoreGraphicsState()
    return true
}

func png(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(size: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}
try png(size: 1024).write(to: output.appendingPathComponent("AppIcon.png"))
let conversion = Process()
conversion.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
conversion.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try conversion.run()
conversion.waitUntilExit()
guard conversion.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
