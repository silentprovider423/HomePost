// Erzeugt das App-Symbol von HomePost (Briefumschlag, dessen Klappe ein Hausdach bildet):
//   swift tools/make-icon.swift Resources/Assets.xcassets/AppIcon.appiconset
// iOS rundet die Ecken selbst ab – daher volle quadratische Fläche ohne Transparenz.
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
    }
    // Hintergrund: Verlauf Tiefblau → Himmelblau
    let bg = CGGradient(colorsSpace: nil, colors: [rgb(0x46B4FF), rgb(0x1560E8)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])

    // Umschlag (Körper)
    let koerper = CGRect(x: 192, y: 250, width: 640, height: 420)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(0x0A2A6B, 0.45))
    ctx.addPath(CGPath(roundedRect: koerper, cornerWidth: 54, cornerHeight: 54, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // untere Falzlinien (V von den unteren Ecken zur Mitte)
    ctx.setStrokeColor(rgb(0xC9DBF5))
    ctx.setLineWidth(18)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 236, y: 290)); ctx.addLine(to: CGPoint(x: 512, y: 470)); ctx.addLine(to: CGPoint(x: 788, y: 290))
    ctx.strokePath()

    // Klappe = Hausdach über dem Umschlag, mit Schornstein
    let dach = CGMutablePath()
    dach.move(to: CGPoint(x: 160, y: 640))
    dach.addLine(to: CGPoint(x: 512, y: 860))
    dach.addLine(to: CGPoint(x: 864, y: 640))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: rgb(0x0A2A6B, 0.35))
    ctx.addPath(dach)
    ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.setLineWidth(70)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 690, y: 700, width: 64, height: 120), cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()

    // Tür als Briefschlitz-Akzent
    ctx.addPath(CGPath(roundedRect: CGRect(x: 452, y: 540, width: 120, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil))
    ctx.setFillColor(rgb(0x1E6EF0))
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let ziel = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Assets.xcassets/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: ziel, withIntermediateDirectories: true)
let png = render(1024).representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: ziel).appendingPathComponent("AppIcon.png"))
let json = """
{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
"""
try json.write(toFile: ziel + "/Contents.json", atomically: true, encoding: .utf8)
print("AppIcon geschrieben: \(ziel)")
