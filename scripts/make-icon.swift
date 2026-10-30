// Render Resources/AppIcon.icns (body, a glass two-thirds full and an orange bubble, on Apple's 1024 px grid): swift scripts/make-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func render(_ px: Int, thick: Bool = false) -> Data {
    let k = CGFloat(px) / 1024
    let s = 824.0 / 92 * k
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 100 * k + (x - 4) * s, y: CGFloat(px) - (100 * k + (y - 4) * s)) }
    let body = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 0x2A / 255.0, green: 0x86 / 255.0, blue: 0xF0 / 255.0, alpha: 1),
        CGColor(red: 0x0A / 255.0, green: 0x5C / 255.0, blue: 0xC4 / 255.0, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    // A tumbler, wide at the rim; the drink fills it from 48 down.
    ctx.setFillColor(white)
    ctx.addLines(between: [pt(34.3, 48), pt(65.7, 48), pt(63.4, 75), pt(36.6, 75)])
    ctx.fillPath()
    ctx.setStrokeColor(white)
    ctx.setLineWidth((thick ? 6.7 : 3.8) * s)
    ctx.setLineJoin(.round)
    ctx.addLines(between: [pt(32.75, 27), pt(67.25, 27), pt(63.4, 75), pt(36.6, 75)])
    ctx.closePath()
    ctx.strokePath()
    func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: CGColor) {
        let c = pt(x, y)
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: c.x - r * s, y: c.y - r * s, width: 2 * r * s, height: 2 * r * s))
    }
    // An orange bubble rises over the drink; a small white one only where there is room for it.
    if !thick { dot(45.2, 40.4, 2.4, CGColor(red: 1, green: 1, blue: 1, alpha: 0.7)) }
    dot(55.75, 37.5, thick ? 6.7 : 4.3, CGColor(red: 1, green: 0x9F / 255.0, blue: 0x0A / 255.0, alpha: 1))
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size, thick: size <= 32).write(to: set.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try FileManager.default.removeItem(at: set)
exit(iconutil.terminationStatus)
