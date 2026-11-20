// Draws the Porthole app icon (Finder, Spotlight, Applications): the menu bar porthole in color.
// A brass ring with 8 bolts around a glass window showing sky and sea, on a deep-sea rounded square.
// Usage: swift scripts/make-app-icon.swift Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ stops: [(UInt32, CGFloat)]) -> CGGradient {
  CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { color($0.0) } as CFArray,
             locations: stops.map(\.1))!
}

/// Draw on a 1024-unit grid (Apple's macOS icon template: an 824-unit rounded square, centered).
func draw(_ cg: CGContext) {
  let c = CGPoint(x: 512, y: 512)
  func circle(_ r: CGFloat, at p: CGPoint = c) -> CGRect { CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r) }

  // Background: deep-sea rounded square with a soft drop shadow.
  let body = CGRect(x: 100, y: 100, width: 824, height: 824)
  let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
  cg.saveGState()
  cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
  cg.addPath(bodyPath)
  cg.setFillColor(color(0x0B2A44))
  cg.fillPath()
  cg.restoreGState()
  cg.saveGState()
  cg.addPath(bodyPath)
  cg.clip()
  cg.drawLinearGradient(gradient([(0x0A2238, 0), (0x134B6E, 1)]), start: CGPoint(x: 512, y: 100),
                        end: CGPoint(x: 512, y: 924), options: [])
  cg.restoreGState()

  // Ring shadow on the background.
  cg.saveGState()
  cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.45))
  cg.setFillColor(color(0x6B4A1A))
  cg.fillEllipse(in: circle(330))
  cg.restoreGState()

  // Brass ring: outer 330, inner 230 (even-odd), lit from the top-left.
  let ring = CGMutablePath()
  ring.addEllipse(in: circle(330))
  ring.addEllipse(in: circle(230))
  cg.saveGState()
  cg.addPath(ring)
  cg.clip(using: .evenOdd)
  cg.drawLinearGradient(gradient([(0xF6D88A, 0), (0xD9A441, 0.45), (0x9C6B22, 1)]),
                        start: CGPoint(x: 280, y: 790), end: CGPoint(x: 760, y: 230), options: [])
  cg.restoreGState()
  // Bevel lines on both edges of the ring.
  cg.setLineWidth(6)
  cg.setStrokeColor(color(0xFFF1C4, 0.55))
  cg.strokeEllipse(in: circle(326))
  cg.setStrokeColor(color(0x5A3B10, 0.6))
  cg.strokeEllipse(in: circle(233))

  // 8 bolts on the ring.
  for i in 0..<8 {
    let a = CGFloat(i) * .pi / 4 + .pi / 8
    let p = CGPoint(x: c.x + 280 * cos(a), y: c.y + 280 * sin(a))
    cg.setFillColor(color(0x5A3B10, 0.55))
    cg.fillEllipse(in: circle(25, at: CGPoint(x: p.x + 3, y: p.y - 4)))
    cg.saveGState()
    cg.addEllipse(in: circle(23, at: p))
    cg.clip()
    cg.drawLinearGradient(gradient([(0xFBE7AE, 0), (0xA9762A, 1)]), start: CGPoint(x: p.x - 18, y: p.y + 18),
                          end: CGPoint(x: p.x + 18, y: p.y - 18), options: [])
    cg.restoreGState()
  }

  // Glass: sky over sea, inside the ring.
  cg.saveGState()
  cg.addEllipse(in: circle(230))
  cg.clip()
  cg.drawLinearGradient(gradient([(0x9FE3FF, 0), (0x5CC2F2, 1)]), start: CGPoint(x: 512, y: 742),
                        end: CGPoint(x: 512, y: 470), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  // Sea below a gentle horizon.
  let sea = CGMutablePath()
  sea.move(to: CGPoint(x: 270, y: 470))
  sea.addCurve(to: CGPoint(x: 754, y: 470), control1: CGPoint(x: 420, y: 500), control2: CGPoint(x: 600, y: 440))
  sea.addLine(to: CGPoint(x: 754, y: 270))
  sea.addLine(to: CGPoint(x: 270, y: 270))
  sea.closeSubpath()
  cg.addPath(sea)
  cg.clip()
  cg.drawLinearGradient(gradient([(0x1F8FCB, 0), (0x0B4F86, 1)]), start: CGPoint(x: 512, y: 480),
                        end: CGPoint(x: 512, y: 282), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  cg.restoreGState()
  // Wave lines on the sea.
  cg.setLineCap(.round)
  cg.setLineWidth(9)
  cg.setStrokeColor(color(0xFFFFFF, 0.35))
  for (y, x0, x1) in [(410.0, 340.0, 470.0), (370.0, 520.0, 660.0), (330.0, 380.0, 500.0)] {
    let w = CGMutablePath()
    w.move(to: CGPoint(x: x0, y: y))
    w.addCurve(to: CGPoint(x: x1, y: y), control1: CGPoint(x: x0 + 35, y: y + 14), control2: CGPoint(x: x1 - 35, y: y - 14))
    cg.addPath(w)
    cg.strokePath()
  }

  // Inner shadow at the top of the glass, then the glint (same arc as the menu bar icon).
  cg.saveGState()
  cg.addEllipse(in: circle(230))
  cg.clip()
  cg.setStrokeColor(color(0x000000, 0.28))
  cg.setLineWidth(26)
  cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.4))
  cg.strokeEllipse(in: circle(240))
  cg.restoreGState()
  cg.setStrokeColor(color(0xFFFFFF, 0.85))
  cg.setLineWidth(30)
  cg.addArc(center: c, radius: 160, startAngle: .pi * 0.62, endAngle: .pi * 0.92, clockwise: false)
  cg.strokePath()
  cg.setFillColor(color(0xFFFFFF, 0.85))
  let dot = CGPoint(x: c.x + 160 * cos(.pi * 0.52), y: c.y + 160 * sin(.pi * 0.52))
  cg.fillEllipse(in: circle(15, at: dot))
}

func png(_ px: Int) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  let ctx = NSGraphicsContext(bitmapImageRep: rep)!
  NSGraphicsContext.current = ctx
  ctx.cgContext.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
  draw(ctx.cgContext)
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

// Build an .iconset with every size macOS wants, then pack it with iconutil.
let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
  try! png(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
  try! png(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out]
try! p.run()
p.waitUntilExit()
try? fm.removeItem(at: set)
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
// Also write a 1024px PNG preview next to the .icns.
try! png(1024).write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + ".png"))
print("wrote \(out)")
