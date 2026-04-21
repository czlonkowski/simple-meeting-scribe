#!/usr/bin/env swift
import AppKit
import CoreGraphics
import CoreText

// Renders the Meeting Transcriber app icon at `size` px and writes a PNG to `url`.
func renderIcon(size: CGFloat, to url: URL) throws {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create CGContext at size \(size)")
    }
    // Transparent background — squircle will define the visible shape.
    ctx.clear(rect)

    // Squircle background (22.37% corner radius is the Apple iOS icon template).
    let corner = size * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Diagonal red → orange gradient (matches Theme.accent family).
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.82, green: 0.18, blue: 0.22, alpha: 1.0),
            CGColor(red: 1.00, green: 0.48, blue: 0.18, alpha: 1.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: []
    )

    // Soft inner highlight (top-left).
    let highlight = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        highlight,
        startCenter: CGPoint(x: size * 0.25, y: size * 0.78),
        startRadius: 0,
        endCenter: CGPoint(x: size * 0.25, y: size * 0.78),
        endRadius: size * 0.65,
        options: []
    )

    // Waveform bars — stylized audio signal across the bottom half.
    // Five symmetric bars with soft rounded caps.
    let barCount = 7
    let barWidth = size * 0.055
    let gap = size * 0.038
    let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
    let startX = (size - totalWidth) / 2
    let centerY = size * 0.52
    let heights: [CGFloat] = [0.14, 0.26, 0.42, 0.55, 0.42, 0.26, 0.14] // fraction of size

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    for i in 0..<barCount {
        let h = heights[i] * size
        let x = startX + CGFloat(i) * (barWidth + gap)
        let y = centerY - h / 2
        let barRect = CGRect(x: x, y: y, width: barWidth, height: h)
        let capsule = CGPath(
            roundedRect: barRect,
            cornerWidth: barWidth / 2,
            cornerHeight: barWidth / 2,
            transform: nil
        )
        ctx.addPath(capsule)
        ctx.fillPath()
    }

    // Recording dot — pulse at top-right, clearly indicating recording intent.
    let dotRadius = size * 0.065
    let dotCenter = CGPoint(x: size * 0.78, y: size * 0.80)
    let dotRect = CGRect(
        x: dotCenter.x - dotRadius,
        y: dotCenter.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    )
    // Soft glow.
    ctx.setShadow(
        offset: .zero,
        blur: size * 0.035,
        color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.7)
    )
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: dotRect)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    ctx.restoreGState()

    // Export PNG.
    guard let cgImage = ctx.makeImage() else {
        fatalError("Could not finalize image at size \(size)")
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed at size \(size)")
    }
    try data.write(to: url)
    print("wrote \(url.lastPathComponent) (\(Int(size))px)")
}

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outDir = repoRoot
    .appendingPathComponent("MeetingTranscriber")
    .appendingPathComponent("Resources")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")
try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

let sizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]
for s in sizes {
    let file = outDir.appendingPathComponent("icon_\(s).png")
    try renderIcon(size: CGFloat(s), to: file)
}
print("done.")
