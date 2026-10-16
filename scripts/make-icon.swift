import AppKit

let output = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let square = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 1024, height: 1024), xRadius: 220, yRadius: 220)
NSColor(red: 0.20, green: 0.16, blue: 0.13, alpha: 1).setFill(); square.fill()
let halo = NSGradient(starting: NSColor(red: 1, green: 0.69, blue: 0.33, alpha: 0.5), ending: .clear)!
halo.draw(in: NSBezierPath(ovalIn: NSRect(x: 112, y: 130, width: 800, height: 800)), relativeCenterPosition: .zero)
NSColor(red: 1, green: 0.79, blue: 0.51, alpha: 1).setStroke()
let bulb = NSBezierPath(); bulb.lineWidth = 38; bulb.lineCapStyle = .round; bulb.lineJoinStyle = .round
bulb.move(to: NSPoint(x: 420, y: 330)); bulb.line(to: NSPoint(x: 420, y: 405))
bulb.curve(to: NSPoint(x: 330, y: 580), controlPoint1: NSPoint(x: 420, y: 460), controlPoint2: NSPoint(x: 330, y: 470))
bulb.curve(to: NSPoint(x: 694, y: 580), controlPoint1: NSPoint(x: 330, y: 820), controlPoint2: NSPoint(x: 694, y: 820))
bulb.curve(to: NSPoint(x: 604, y: 405), controlPoint1: NSPoint(x: 694, y: 470), controlPoint2: NSPoint(x: 604, y: 460))
bulb.line(to: NSPoint(x: 604, y: 330)); bulb.close(); bulb.stroke()
for y in [260, 205] {
    let line = NSBezierPath(); line.lineWidth = 30; line.lineCapStyle = .round
    line.move(to: NSPoint(x: y == 205 ? 465 : 430, y: y)); line.line(to: NSPoint(x: y == 205 ? 559 : 594, y: y)); line.stroke()
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = bitmap.representation(using: .png, properties: [:])!
// ICNS supports a PNG 1024x1024 representation in an ic10 element.
var body = Data("ic10".utf8)
var chunkLength = UInt32(png.count + 8).bigEndian
withUnsafeBytes(of: &chunkLength) { body.append(contentsOf: $0) }; body.append(png)
var result = Data("icns".utf8)
var totalLength = UInt32(body.count + 8).bigEndian
withUnsafeBytes(of: &totalLength) { result.append(contentsOf: $0) }; result.append(body)
try result.write(to: URL(fileURLWithPath: output))
