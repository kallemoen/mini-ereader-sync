#!/usr/bin/env swift
// Generates a macOS .icns file. Uses CGBitmapContext directly (rather than
// NSImage lockFocus) so it works when run under the Swift interpreter.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.icns>\n".data(using: .utf8)!)
    exit(1)
}
let outICNS = CommandLine.arguments[1]

func render(size pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let space = CGColorSpaceCreateDeviceRGB()
    let bpr = pixels * 4
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: bpr,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("CGContext alloc") }

    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // Rounded-rect gradient background — deep indigo → near-black.
    let corner = s * 0.225
    let bgPath = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
        cornerWidth: corner, cornerHeight: corner, transform: nil
    )
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let colors: [CGColor] = [
        CGColor(red: 0.20, green: 0.31, blue: 0.55, alpha: 1),
        CGColor(red: 0.07, green: 0.11, blue: 0.23, alpha: 1),
    ]
    let gradient = CGGradient(
        colorsSpace: space,
        colors: colors as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    ctx.restoreGState()

    // Book glyph: two pages meeting at a spine. Filled in white.
    let bookRect = CGRect(
        x: s * 0.22, y: s * 0.30,
        width: s * 0.56, height: s * 0.40
    )
    let midX = bookRect.minX + bookRect.width * 0.5
    let dipY = bookRect.height * 0.05

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

    let left = CGMutablePath()
    left.move(to: CGPoint(x: bookRect.minX, y: bookRect.minY + dipY))
    left.addLine(to: CGPoint(x: midX, y: bookRect.minY))
    left.addLine(to: CGPoint(x: midX, y: bookRect.maxY))
    left.addLine(to: CGPoint(x: bookRect.minX, y: bookRect.maxY - dipY))
    left.closeSubpath()
    ctx.addPath(left)
    ctx.fillPath()

    let right = CGMutablePath()
    right.move(to: CGPoint(x: bookRect.maxX, y: bookRect.minY + dipY))
    right.addLine(to: CGPoint(x: midX, y: bookRect.minY))
    right.addLine(to: CGPoint(x: midX, y: bookRect.maxY))
    right.addLine(to: CGPoint(x: bookRect.maxX, y: bookRect.maxY - dipY))
    right.closeSubpath()
    ctx.addPath(right)
    ctx.fillPath()

    // Faint page lines at larger sizes.
    if pixels >= 128 {
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.18))
        ctx.setLineWidth(max(1, s * 0.008))
        let margin = bookRect.width * 0.06
        let spacing = bookRect.height * 0.16
        for page in 0...1 {
            let xStart = bookRect.minX + (page == 0 ? margin : bookRect.width * 0.5 + margin)
            let xEnd   = bookRect.minX + (page == 0 ? bookRect.width * 0.5 - margin : bookRect.width - margin)
            for i in 1...3 {
                let y = bookRect.maxY - bookRect.height * 0.18 - CGFloat(i) * spacing
                ctx.move(to: CGPoint(x: xStart, y: y))
                ctx.addLine(to: CGPoint(x: xEnd, y: y))
                ctx.strokePath()
            }
        }
    }

    guard let cg = ctx.makeImage() else { fatalError("makeImage") }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("PNG dest")
    }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG finalize") }
    return data as Data
}

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let iconsetDir = NSTemporaryDirectory() + "MiniEreader-\(UUID().uuidString).iconset"
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
for (name, size) in variants {
    let path = (iconsetDir as NSString).appendingPathComponent(name)
    try render(size: size).write(to: URL(fileURLWithPath: path))
}

let proc = Process()
proc.launchPath = "/usr/bin/iconutil"
proc.arguments = ["-c", "icns", iconsetDir, "-o", outICNS]
try proc.run()
proc.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconsetDir)

guard proc.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
FileHandle.standardOutput.write("wrote \(outICNS)\n".data(using: .utf8)!)
