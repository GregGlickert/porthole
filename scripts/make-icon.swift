// Draws the Porthole menu bar icon: a ship's porthole (thick ring with 8 bolts + a glass glint).
// Output is a template image (black + alpha) so macOS tints it for light/dark menu bars.
// Usage: swift scripts/make-icon.swift assets/porthole-icon.png [px=36]
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "porthole-icon.png"
let px = args.count > 2 ? Int(args[2])! : 36
let s = CGFloat(px)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: s / 2, height: s / 2) // @2x → 18pt in the menu bar

NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
cg.scaleBy(x: rep.size.width / 36, y: rep.size.height / 36) // design on a 36-unit grid (context is in points)
let c = CGPoint(x: 18, y: 18)

func circle(_ r: CGFloat, at p: CGPoint = c) -> CGRect { CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r) }

// Frame ring (outer 17, inner 11.5) via even-odd fill.
cg.setFillColor(NSColor.black.cgColor)
let ring = CGMutablePath()
ring.addEllipse(in: circle(17))
ring.addEllipse(in: circle(11.5))
cg.addPath(ring)
cg.fillPath(using: .evenOdd)

// 8 bolts punched out of the ring.
cg.setBlendMode(.clear)
for i in 0..<8 {
  let a = CGFloat(i) * .pi / 4 + .pi / 8
  let p = CGPoint(x: c.x + 14.25 * cos(a), y: c.y + 14.25 * sin(a))
  cg.fillEllipse(in: circle(1.35, at: p))
}
cg.setBlendMode(.normal)

// Glass glint: a short arc in the upper-left of the window.
cg.setStrokeColor(NSColor.black.cgColor)
cg.setLineWidth(2.2)
cg.setLineCap(.round)
cg.addArc(center: c, radius: 7.5, startAngle: .pi * 0.62, endAngle: .pi * 0.98, clockwise: false)
cg.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(px)px)")
