#!/usr/bin/env swift
//
//  GenerateAppIcon.swift
//  Regenerates the three AppIcon variants from the `washer` SF Symbol.
//
//  Run from the `app` directory:
//
//      swift Tools/GenerateAppIcon.swift
//
//  The glyph is drawn at the symbol's default (`.regular`) weight so the stroke
//  matches every other SF Symbol in the app. The light variant is opaque SSSB
//  blue; the dark and tinted variants are transparent, because iOS draws its own
//  backdrop behind those and only uses the glyph.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

let symbolName = "washer"
let canvas = 1024
/// Fraction of the canvas the glyph's larger inked dimension covers. iOS rounds
/// the corners aggressively, so the glyph has to stay well inside the square.
let glyphScale: CGFloat = 0.56
/// SSSB's brand blue, from the header chrome on sssb.se.
let sssbBlue = NSColor(srgbRed: 0x06 / 255, green: 0x4A / 255, blue: 0x88 / 255, alpha: 1)

struct Variant {
    let filename: String
    let background: NSColor?
    let glyph: NSColor
}

let variants = [
    Variant(filename: "AppIcon.png", background: sssbBlue, glyph: .white),
    Variant(filename: "AppIcon-Dark.png", background: nil, glyph: .white),
    Variant(filename: "AppIcon-Tinted.png", background: nil, glyph: .white),
]

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// App Store validation rejects a marketing icon that carries an alpha channel,
/// so the opaque variant is drawn into a context that has none.
func makeContext(opaque: Bool) throws -> CGContext {
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil, width: canvas, height: canvas,
              bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: alpha.rawValue
          )
    else { throw Failure("could not allocate a \(canvas)px context") }
    return context
}

func draw(into context: CGContext, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    body()
}

/// The rect the symbol actually paints, which is inset from its bounding box by
/// the symbol's own optical padding. Centring on the box instead leaves the
/// glyph visibly off-centre in the icon.
func inkBounds(of context: CGContext) throws -> NSRect {
    guard let base = context.data else { throw Failure("context has no backing store") }
    let pixels = base.assumingMemoryBound(to: UInt8.self)
    let stride = context.bytesPerRow
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
    for y in 0..<canvas {
        for x in 0..<canvas where pixels[y * stride + x * 4 + 3] > 2 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard minX <= maxX else { throw Failure("\(symbolName) rendered nothing") }
    return NSRect(x: CGFloat(minX), y: CGFloat(minY),
                  width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
}

func glyphImage(_ color: NSColor) throws -> NSImage {
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
        throw Failure("no SF Symbol named \(symbolName) on this system")
    }
    // Point size is nominal; the symbol is vector, so this only fixes the aspect
    // ratio and lets us scale it to the canvas below.
    guard let configured = symbol.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 512, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    ) else { throw Failure("could not configure \(symbolName)") }
    return configured
}

/// Where to draw the whole glyph so that its inked area lands centred on the
/// canvas at `glyphScale`.
func placement(for glyph: NSImage) throws -> NSRect {
    let side = CGFloat(canvas)
    let fit = side / max(glyph.size.width, glyph.size.height)
    let probeRect = NSRect(
        x: (side - glyph.size.width * fit) / 2, y: (side - glyph.size.height * fit) / 2,
        width: glyph.size.width * fit, height: glyph.size.height * fit
    )
    let probe = try makeContext(opaque: false)
    draw(into: probe) { glyph.draw(in: probeRect) }
    let ink = try inkBounds(of: probe)

    let scale = (side * glyphScale) / max(ink.width, ink.height)
    // Offset of the ink's centre from the drawn rect's origin, after scaling.
    let inkCentre = NSPoint(x: (ink.midX - probeRect.minX) * scale,
                            y: (ink.midY - probeRect.minY) * scale)
    return NSRect(x: side / 2 - inkCentre.x, y: side / 2 - inkCentre.y,
                  width: probeRect.width * scale, height: probeRect.height * scale)
}

func render(_ variant: Variant) throws {
    let glyph = try glyphImage(variant.glyph)
    let rect = try placement(for: glyph)
    let context = try makeContext(opaque: variant.background != nil)
    draw(into: context) {
        if let background = variant.background {
            background.setFill()
            NSRect(x: 0, y: 0, width: CGFloat(canvas), height: CGFloat(canvas)).fill()
        }
        glyph.draw(in: rect)
    }

    let url = URL(fileURLWithPath: "SSSBLaundry/Assets.xcassets/AppIcon.appiconset/\(variant.filename)")
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL, UTType.png.identifier as CFString, 1, nil
          )
    else { throw Failure("could not encode \(variant.filename)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw Failure("could not write \(variant.filename)")
    }
    print("wrote \(url.path)")
}

do {
    for variant in variants { try render(variant) }
} catch {
    FileHandle.standardError.write("GenerateAppIcon: \(error)\n".data(using: .utf8)!)
    exit(1)
}
