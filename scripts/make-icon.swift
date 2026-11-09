// SPDX-License-Identifier: GPL-3.0-or-later
//
// Renders the HP Bridge app icon (1024×1024 PNG) with AppKit.
// Usage: swift scripts/make-icon.swift <output.png>

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824×824 body centred on a 1024 canvas, with a soft shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185
let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: NSColor.black.withAlphaComponent(0.32).cgColor)
ctx.addPath(path)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let colors = [NSColor(srgbRed: 0.22, green: 0.55, blue: 1.0, alpha: 1).cgColor,
              NSColor(srgbRed: 0.33, green: 0.24, blue: 0.86, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Subtle top highlight.
let gloss = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])

// CMYK ink drops along the bottom edge.
let inks: [NSColor] = [
    NSColor(srgbRed: 0.0, green: 0.78, blue: 1.0, alpha: 1),
    NSColor(srgbRed: 1.0, green: 0.2, blue: 0.62, alpha: 1),
    NSColor(srgbRed: 1.0, green: 0.86, blue: 0.1, alpha: 1),
    NSColor(srgbRed: 0.1, green: 0.1, blue: 0.14, alpha: 1),
]
let dot: CGFloat = 70, gap: CGFloat = 26
let total = CGFloat(inks.count) * dot + CGFloat(inks.count - 1) * gap
for (i, c) in inks.enumerated() {
    let x = (size - total) / 2 + CGFloat(i) * (dot + gap)
    ctx.setFillColor(c.cgColor)
    ctx.fillEllipse(in: CGRect(x: x, y: 190, width: dot, height: dot))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
    ctx.setLineWidth(6)
    ctx.strokeEllipse(in: CGRect(x: x, y: 190, width: dot, height: dot))
}
ctx.restoreGState()

// White printer glyph.
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .regular)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "printer.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    let rect = CGRect(x: (size - s.width) / 2, y: 330 + (430 - s.height) / 2 + 40, width: s.width, height: s.height)
    symbol.draw(in: rect)
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
try png.write(to: out)
print(out.path)
