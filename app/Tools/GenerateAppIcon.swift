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
/// Fraction of the canvas the washing machine's larger dimension covers. iOS
/// rounds the corners aggressively, so the glyph has to stay well inside the
/// square — and the basin overhangs the machine to the right, which eats into
/// the margin on that side.
let machineScale: CGFloat = 0.62
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

/// Which pixels of a rendered probe the symbol actually painted.
///
/// A bitmap context's first row is the *top* of the image while its drawing
/// origin is bottom-left, so rows here are top-down throughout; `placement(for:)`
/// flips back once, at the end.
struct InkMask {
    let side: Int
    private let alpha: [UInt8]

    init(_ context: CGContext) throws {
        guard let base = context.data else { throw Failure("context has no backing store") }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        side = context.width
        var alpha = [UInt8](repeating: 0, count: side * side)
        for row in 0..<side {
            for x in 0..<side {
                alpha[row * side + x] = pixels[row * context.bytesPerRow + x * 4 + 3]
            }
        }
        self.alpha = alpha
    }

    func inked(x: Int, row: Int) -> Bool { alpha[row * side + x] > 2 }

    /// Bounding box of the ink within `columns` × `rows`. `minY` is the top edge
    /// and `maxY` the bottom one, since rows run downwards.
    func bounds(columns: ClosedRange<Int>, rows: ClosedRange<Int>) throws -> NSRect {
        var minX = Int.max, minRow = Int.max, maxX = Int.min, maxRow = Int.min
        for row in rows {
            for x in columns where inked(x: x, row: row) {
                minX = min(minX, x); maxX = max(maxX, x)
                minRow = min(minRow, row); maxRow = max(maxRow, row)
            }
        }
        guard minX <= maxX else { throw Failure("\(symbolName) rendered nothing") }
        return NSRect(x: CGFloat(minX), y: CGFloat(minRow),
                      width: CGFloat(maxX - minX + 1), height: CGFloat(maxRow - minRow + 1))
    }

    var everything: ClosedRange<Int> { 0...(side - 1) }
}

/// The washing machine's body, excluding the basin that overhangs it to the
/// right. The machine is what the eye reads as the subject, so it is what gets
/// centred; centring the composite instead pushes the machine off to the left.
func machineBounds(_ mask: InkMask) throws -> NSRect {
    let ink = try mask.bounds(columns: mask.everything, rows: mask.everything)
    // The basin sits low in the glyph, so the top half of the ink is machine
    // only and gives its two side walls.
    let walls = try mask.bounds(
        columns: mask.everything,
        rows: Int(ink.minY)...Int(ink.midY)
    )
    // It never reaches the left third either, so that band gives the machine's
    // bottom edge.
    let leftBand = try mask.bounds(
        columns: Int(walls.minX)...Int(walls.minX + walls.width / 3),
        rows: mask.everything
    )
    return NSRect(x: walls.minX, y: ink.minY,
                  width: walls.width, height: leftBand.maxY - ink.minY)
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

/// Where to draw the whole glyph so that the machine lands centred on the canvas
/// at `machineScale`.
func placement(for glyph: NSImage) throws -> NSRect {
    let side = CGFloat(canvas)
    let fit = side / max(glyph.size.width, glyph.size.height)
    let probeRect = NSRect(
        x: (side - glyph.size.width * fit) / 2, y: (side - glyph.size.height * fit) / 2,
        width: glyph.size.width * fit, height: glyph.size.height * fit
    )
    let probe = try makeContext(opaque: false)
    draw(into: probe) { glyph.draw(in: probeRect) }
    let machine = try machineBounds(try InkMask(probe))

    let scale = (side * machineScale) / max(machine.width, machine.height)
    // Back into drawing coordinates, where y counts up from the bottom.
    let centre = NSPoint(x: machine.midX, y: side - machine.midY)
    let offset = NSPoint(x: (centre.x - probeRect.minX) * scale,
                         y: (centre.y - probeRect.minY) * scale)
    return NSRect(x: side / 2 - offset.x, y: side / 2 - offset.y,
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
