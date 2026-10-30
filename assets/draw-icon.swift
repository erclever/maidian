import AppKit
import Foundation
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
let rect = CGRect(x: 42, y: 42, width: 940, height: 940)
let path = CGPath(roundedRect: rect, cornerWidth: 210, cornerHeight: 210, transform: nil)
ctx.saveGState(); ctx.addPath(path); ctx.clip()
let colors = [NSColor(calibratedRed: 0.09, green: 0.17, blue: 0.30, alpha: 1).cgColor, NSColor(calibratedRed: 0.04, green: 0.33, blue: 0.40, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0,1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 140, y: 900), end: CGPoint(x: 900, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()
ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor); ctx.setLineWidth(4)
for y in [310, 512, 714] { ctx.move(to: CGPoint(x: 188, y: y)); ctx.addLine(to: CGPoint(x: 836, y: y)); ctx.strokePath() }
func stroke(_ points: [(CGFloat,CGFloat)], color: NSColor, width: CGFloat) {
 ctx.beginPath(); ctx.move(to: CGPoint(x: points[0].0,y: points[0].1))
 for p in points.dropFirst() { ctx.addLine(to: CGPoint(x:p.0,y:p.1)) }
 ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width); ctx.strokePath()
}
let cyan = NSColor(calibratedRed:0.28,green:0.91,blue:0.88,alpha:1)
let white = NSColor(calibratedRed:0.90,green:0.96,blue:1,alpha:1)
stroke([(375,300),(375,710)],color:cyan,width:58)
stroke([(273,608),(375,710),(477,608)],color:cyan,width:58)
stroke([(649,724),(649,314)],color:white,width:58)
stroke([(547,416),(649,314),(751,416)],color:white,width:58)
image.unlockFocus()
guard let tiff=image.tiffRepresentation, let bitmap=NSBitmapImageRep(data:tiff), let data=bitmap.representation(using:.png, properties:[:]) else { fatalError("icon render failed") }
try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
