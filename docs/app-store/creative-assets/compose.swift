// Renders App Store header/search art from real screenshots. Run: swift compose.swift
import AppKit
let shots = "../screenshots/"
func img(_ p: String) -> NSImage { NSImage(contentsOfFile: shots + p)! }
func rgb(_ h: Int, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: CGFloat(h>>16&255)/255, green: CGFloat(h>>8&255)/255, blue: CGFloat(h&255)/255, alpha: a) }

func render(_ W: CGFloat, _ H: CGFloat, _ out: String, _ s: CGFloat, _ text: CGPoint, _ items: [(String, NSRect)]) {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGradient(colors: [rgb(0xFBF4EC), rgb(0xF3DFC8)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -35)
  // warm glow behind devices
  NSGradient(colors: [rgb(0xFFA347, 0.35), rgb(0xFFA347, 0)])!.draw(in: NSBezierPath(ovalIn: NSRect(x: W*0.42, y: -H*0.2, width: W*0.75, height: H*1.3)), relativeCenterPosition: .zero)
  for (p, r) in items {
    let rad = r.width * 0.075, path = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = rgb(0x5A2E00, 0.28); sh.shadowBlurRadius = 60*s; sh.shadowOffset = NSSize(width: 0, height: -24*s); sh.set()
    rgb(0xFFFFFF).setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); path.addClip(); img(p).draw(in: r); NSGraphicsContext.restoreGraphicsState()
    rgb(0x1A1A1C).setStroke(); path.lineWidth = 10*s; path.stroke()
  }
  let t = NSAttributedString(string: "Luma", attributes: [.font: NSFont.systemFont(ofSize: 300*s, weight: .bold), .foregroundColor: rgb(0x1D1D1F), .kern: -6*s])
  t.draw(at: text)
  let ac = NSAttributedString(string: "Your lights, beautifully simple.", attributes: [.font: NSFont.systemFont(ofSize: 112*s, weight: .medium), .foregroundColor: rgb(0xA84C00)])
  ac.draw(at: NSPoint(x: text.x + 8*s, y: text.y - 150*s))
  NSGraphicsContext.current = nil
  let ext = (out as NSString).pathExtension
  let data = ext == "png" ? rep.representation(using: .png, properties: [:])! : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])!
  try! data.write(to: URL(fileURLWithPath: out))
}
func phone(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x, y: y, width: h*1320/2868, height: h) }
func pad(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x, y: y, width: h*2064/2752, height: h) }

// Header 5244x2950 (key content kept inside central safe area)
let header: [(String, NSRect)] = [
  ("ipad-13/3-floorplan.jpg", pad(2700, 420, 2100)),
  ("iphone-6.9/2-scenes.jpg", phone(2260, 260, 1900)),
  ("iphone-6.9/1-home.jpg", phone(3380, 160, 2100)),
]
for e in ["png", "jpg"] { render(5244, 2950, "luma-header-5244x2950.\(e)", 1, CGPoint(x: 560, y: 1500), header) }

// Search 1920x1280
let search: [(String, NSRect)] = [
  ("iphone-6.9/2-scenes.jpg", phone(940, 150, 960)),
  ("iphone-6.9/1-home.jpg", phone(1340, 90, 1080)),
]
for e in ["png", "jpg"] { render(1920, 1280, "luma-search-1920x1280.\(e)", 0.42, CGPoint(x: 110, y: 640), search) }
