// Draws the app icon: a macOS-style rounded square with a blue-to-indigo gradient and a white checklist.
// Usage: swift scripts/make-icon.swift <output.iconset>   (then: iconutil -c icns <output.iconset>)
import AppKit

func render(_ pixels: Int) -> Data {
  let size = CGFloat(pixels)
  let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icons leave ~10% around the shape.
    let inset = size * 0.098
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = size * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(
      colors: [NSColor(srgbRed: 0.30, green: 0.55, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.33, green: 0.25, blue: 0.85, alpha: 1)]
    )!.draw(in: shape, angle: -60)

    // A soft highlight on the upper half.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0)])!
      .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The white checklist glyph, tinted by filling over the symbol's own shape.
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
      let glyph = NSImage(size: symbol.size, flipped: false) { bounds in
        symbol.draw(in: bounds)
        NSColor.white.set()
        bounds.fill(using: .sourceAtop)
        return true
      }
      let target = NSRect(
        x: (size - glyph.size.width) / 2, y: (size - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height)
      let glyphShadow = NSShadow()
      glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
      glyphShadow.shadowBlurRadius = size * 0.015
      glyphShadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
      NSGraphicsContext.saveGraphicsState()
      glyphShadow.set()
      glyph.draw(in: target)
      NSGraphicsContext.restoreGraphicsState()
    }
    return true
  }
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count > 1 else {
  print("usage: swift make-icon.swift <output.iconset>")
  exit(1)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
// (name, pixels) — the sizes an .icns needs.
for (name, pixels) in [
  ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
  ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512),
  ("icon_512x512@2x", 1024),
] {
  try render(pixels).write(to: directory.appendingPathComponent(name + ".png"))
}
