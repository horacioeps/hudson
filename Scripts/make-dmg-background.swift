#!/usr/bin/env swift
//
// Renders the installer window's background art into Design/DMG/.
//
// Run via Scripts/make-dmg.sh, which then hands the result to Finder as the
// mounted volume's background picture. Drawn in code rather than exported from
// a design tool so the palette below stays the single source of truth: these
// are the same tokens as hudson.pen, the SwiftUI Palette, and the website's
// global.css, so the installer cannot quietly drift away from the app it
// installs.
//
// Emits a 1x and a 2x PNG; make-dmg.sh combines them into one HiDPI TIFF with
// `tiffutil -cathidpicheck`, which is what keeps the art sharp on a Retina
// display instead of visibly upscaled.
//
// Usage: swift Scripts/make-dmg-background.swift <out-dir>

import AppKit
import Foundation

// MARK: - Design tokens (hudson.pen)

let bgApp = NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1A / 255, alpha: 1)
let inkSecondary = NSColor(srgbRed: 0xA2 / 255, green: 0x9E / 255, blue: 0x95 / 255, alpha: 1)
let inkTertiary = NSColor(srgbRed: 0x6E / 255, green: 0x6B / 255, blue: 0x64 / 255, alpha: 1)
let accent = NSColor(srgbRed: 0x8F / 255, green: 0xB5 / 255, blue: 0xA5 / 255, alpha: 1)

/// Window content size in points. Icon positions in make-dmg.sh's AppleScript
/// are expressed in this same coordinate space, so the two must agree: change
/// one and the arrow stops pointing at the folder.
let size = NSSize(width: 640, height: 400)

/// Where Finder places the two icons, in AppleScript's coordinate space, which
/// measures y downward from the top of the window.
let appIconCenter = CGPoint(x: 170, y: 190)
let applicationsCenter = CGPoint(x: 470, y: 190)

// MARK: - Drawing

/// Converts an AppleScript icon position (y down from top) into the bottom-up
/// coordinates Core Graphics draws in.
func flipped(_ point: CGPoint) -> CGPoint {
    CGPoint(x: point.x, y: size.height - point.y)
}

func drawCenteredText(
    _ text: String, at center: CGPoint, font: NSFont, color: NSColor, tracking: CGFloat = 0
) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: color, .kern: tracking,
    ]
    let line = NSAttributedString(string: text, attributes: attributes)
    let bounds = line.size()
    line.draw(at: NSPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2))
}

/// The arrow between the app and the Applications folder. Drawn as a shallow
/// arc rather than a straight line so it reads as a gesture — the same easing
/// the app's motion system uses — and stops short of both icons so it never
/// crowds them.
func drawArrow() {
    let start = flipped(CGPoint(x: appIconCenter.x + 78, y: appIconCenter.y))
    let end = flipped(CGPoint(x: applicationsCenter.x - 78, y: applicationsCenter.y))
    let lift: CGFloat = 26
    let control = CGPoint(x: (start.x + end.x) / 2, y: start.y + lift)

    let path = NSBezierPath()
    path.move(to: start)
    path.curve(to: end, controlPoint1: control, controlPoint2: control)
    path.lineWidth = 2
    path.lineCapStyle = .round
    inkTertiary.setStroke()
    path.stroke()

    // Arrowhead, aligned to the curve's tangent as it arrives at `end`.
    let tangent = CGPoint(x: end.x - control.x, y: end.y - control.y)
    let angle = atan2(tangent.y, tangent.x)
    let headLength: CGFloat = 11
    let spread = CGFloat.pi / 7

    let head = NSBezierPath()
    head.move(to: end)
    head.line(
        to: CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)))
    head.move(to: end)
    head.line(
        to: CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)))
    head.lineWidth = 2
    head.lineCapStyle = .round
    inkTertiary.setStroke()
    head.stroke()
}

/// The Hudson wordmark's wave, matching the site's nav mark.
func drawWave(center: CGPoint, width: CGFloat) {
    let height = width * 0.22
    let path = NSBezierPath()
    let segment = width / 3

    path.move(to: CGPoint(x: center.x - width / 2, y: center.y))
    for index in 0..<3 {
        let x0 = center.x - width / 2 + segment * CGFloat(index)
        path.curve(
            to: CGPoint(x: x0 + segment, y: center.y),
            controlPoint1: CGPoint(x: x0 + segment * 0.37, y: center.y + height),
            controlPoint2: CGPoint(x: x0 + segment * 0.63, y: center.y - height))
    }
    path.lineWidth = 2
    path.lineCapStyle = .round
    accent.withAlphaComponent(0.55).setStroke()
    path.stroke()
}

func renderBackground(scale: CGFloat) -> NSBitmapImageRep {
    let pixelWidth = Int(size.width * scale)
    let pixelHeight = Int(size.height * scale)

    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("could not allocate a \(pixelWidth)x\(pixelHeight) bitmap") }
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    bgApp.setFill()
    NSRect(origin: .zero, size: size).fill()

    drawWave(center: CGPoint(x: size.width / 2, y: size.height - 66), width: 44)

    drawCenteredText(
        "Drag Hudson into Applications",
        at: CGPoint(x: size.width / 2, y: size.height - 108),
        font: .systemFont(ofSize: 15, weight: .medium),
        color: inkSecondary)

    drawArrow()

    drawCenteredText(
        "Free, open source, and entirely on your Mac.",
        at: CGPoint(x: size.width / 2, y: 58),
        font: .systemFont(ofSize: 12, weight: .regular),
        color: inkTertiary)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Entry point

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Design/DMG"
try? FileManager.default.createDirectory(
    atPath: outputDirectory, withIntermediateDirectories: true)

for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    let rep = renderBackground(scale: scale)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(name)")
    }
    let path = (outputDirectory as NSString).appendingPathComponent(name)
    try data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
}
