// Draws the DepthWire app icon.
// Usage: swift make_icon.swift <output.png> <mac|ios>
//   mac: rounded tile with margin and shadow, per the macOS icon grid
//   ios: full-bleed square (iOS applies its own mask)
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let outputPath = args[1]
let isMac = args.count > 2 && args[2] == "mac"
let size: CGFloat = 1024

let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Tile shape.
let tile: CGRect = isMac ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: size, height: size)
let tilePath = isMac
    ? CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    : CGPath(rect: tile, transform: nil)

if isMac {
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.45))
    context.addPath(tilePath)
    context.setFillColor(color(0x0B1020))
    context.fillPath()
    context.restoreGState()
}

context.saveGState()
context.addPath(tilePath)
context.clip()

// Background: deep navy gradient.
let background = CGGradient(colorsSpace: space, colors: [color(0x1C2546), color(0x070A16)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(background, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])

// LiDAR dot grid, fading toward the edges.
let spacing = tile.width / 17
var y = tile.minY + spacing / 2
while y < tile.maxY {
    var x = tile.minX + spacing / 2
    while x < tile.maxX {
        let distance = hypot(x - tile.midX, y - tile.midY) / (tile.width / 2)
        let alpha = max(0, 0.30 - distance * 0.22)
        context.setFillColor(color(0x8FB4FF, alpha))
        let r = tile.width * 0.0075
        context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        x += spacing
    }
    y += spacing
}

// Person silhouette: head and shoulders, scaled to the tile.
func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: tile.minX + fx * tile.width, y: tile.minY + fy * tile.height) }
let person = CGMutablePath()
let headCenter = p(0.5, 0.62)
let headRadius = tile.width * 0.135
person.addEllipse(in: CGRect(x: headCenter.x - headRadius, y: headCenter.y - headRadius,
                             width: headRadius * 2, height: headRadius * 2))
let shoulders = CGMutablePath()
shoulders.move(to: p(0.16, -0.02))
shoulders.addCurve(to: p(0.5, 0.445), control1: p(0.16, 0.30), control2: p(0.30, 0.445))
shoulders.addCurve(to: p(0.84, -0.02), control1: p(0.70, 0.445), control2: p(0.84, 0.30))
shoulders.closeSubpath()
person.addPath(shoulders)

// Soft glow behind the silhouette.
context.saveGState()
context.setShadow(offset: .zero, blur: tile.width * 0.06, color: color(0xFF6A3D, 0.55))
context.addPath(person)
context.setFillColor(color(0xFF6A3D))
context.fillPath()
context.restoreGState()

// Fill with the Turbo depth colors: red (near) at the face, out to blue.
context.saveGState()
context.addPath(person)
context.clip()
let turbo = CGGradient(colorsSpace: space,
                       colors: [color(0xE8402A), color(0xFB8022), color(0xF1CA3A), color(0xA4FC3C),
                                color(0x2EE5AE), color(0x2CA4F5), color(0x4145AB)] as CFArray,
                       locations: [0, 0.18, 0.34, 0.5, 0.64, 0.8, 1])!
context.drawRadialGradient(turbo, startCenter: headCenter, startRadius: 0,
                           endCenter: headCenter, endRadius: tile.width * 0.78, options: [.drawsAfterEndLocation])
context.restoreGState()

// Thin scan line across the face.
context.setStrokeColor(color(0xFFFFFF, 0.55))
context.setLineWidth(tile.width * 0.008)
context.move(to: p(0.08, 0.62))
context.addLine(to: p(0.92, 0.62))
context.strokePath()

context.restoreGState()

let image = context.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outputPath))
