#!/usr/bin/env swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let size = 512
let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.21, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 464, height: 464), xRadius: 76, yRadius: 76).fill()
func polygon(_ points: [(CGFloat, CGFloat)], _ color: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: points[0].0, y: points[0].1))
    for (x, y) in points.dropFirst() { path.line(to: NSPoint(x: x, y: y)) }
    path.close()
    color.setFill()
    path.fill()
}
polygon([(64, 114), (448, 114), (448, 342), (430, 360), (242, 360), (208, 396), (80, 396), (64, 378)], NSColor(calibratedRed: 0.1, green: 0.50, blue: 0.53, alpha: 1))
NSColor(calibratedRed: 0.23, green: 0.83, blue: 0.74, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 64, y: 114, width: 384, height: 214), xRadius: 14, yRadius: 14).fill()
polygon([(182, 288), (342, 288), (342, 260), (232, 182), (342, 182), (342, 150), (176, 150), (176, 180), (286, 256), (182, 256)], NSColor(calibratedRed: 0.07, green: 0.15, blue: 0.21, alpha: 1))
NSGraphicsContext.restoreGraphicsState()
try image.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("workflow/icon.png"))
