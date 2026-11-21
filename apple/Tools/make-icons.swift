// Renders the placeholder app icon from Resources/Marks/lynx-ink.svg:
// the white lynx mark on an Ink squircle, like Lynx Battery's icon.
// Usage: swift Tools/make-icons.swift   (from apple/)
import AppKit

let svg = URL(fileURLWithPath: "Resources/Marks/lynx-ink.svg")
guard let mark = NSImage(contentsOf: svg) else { fatalError("cannot load \(svg.path)") }
let out = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int, inset: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icons sit inside the grid with margins (824/1024); iOS icons fill the square (the system masks them).
    let box = inset ? NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
                    : NSRect(x: 0, y: 0, width: s, height: s)
    let ink = NSColor(srgbRed: 14 / 255, green: 14 / 255, blue: 16 / 255, alpha: 1)
    ink.setFill()
    if inset {
        NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225).fill()
    } else {
        NSBezierPath(rect: box).fill()
    }
    // White mark: draw the SVG, then tint it white with sourceAtop.
    let m = box.insetBy(dx: box.width * 0.16, dy: box.width * 0.16)
    let tinted = NSImage(size: m.size)
    tinted.lockFocus()
    mark.draw(in: NSRect(origin: .zero, size: m.size))
    NSColor.white.set()
    NSRect(origin: .zero, size: m.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.draw(in: m)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = "mac-\(pt)@\(sc)x.png"
        try! render(pt * sc, inset: true).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(sc)x", "filename": name])
    }
}
try! render(1024, inset: false).write(to: out.appendingPathComponent("ios-1024.png"))
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios-1024.png"])
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons")
