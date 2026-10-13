// Draws the app icon (1024 pt) – swift icon/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS squircle with margin (Apple grid: 824 pt body on 1024)
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill(); squircle.fill()
ctx.restoreGState()
squircle.addClip()
NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.27, alpha: 1),
                    NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.11, alpha: 1)])!
    .draw(in: body, angle: -90)

// Three stacked cards = tabs/sessions
func card(_ r: NSRect, alpha: CGFloat, dot: NSColor, front: Bool) {
    let p = NSBezierPath(roundedRect: r, xRadius: 46, yRadius: 46)
    ctx.saveGState()
    let s = NSShadow()
    s.shadowColor = NSColor.black.withAlphaComponent(0.45)
    s.shadowBlurRadius = 24
    s.shadowOffset = NSSize(width: 0, height: -10)
    s.set()
    NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.15, alpha: alpha).setFill()
    p.fill()
    ctx.restoreGState()
    NSColor.white.withAlphaComponent(front ? 0.18 : 0.10).setStroke()
    p.lineWidth = 4; p.stroke()
    // Title bar with status dot
    let bar = NSRect(x: r.minX, y: r.maxY - 78, width: r.width, height: 78)
    NSColor.white.withAlphaComponent(front ? 0.07 : 0.04).setFill()
    NSBezierPath(roundedRect: bar, xRadius: 46, yRadius: 46).fill()
    dot.setFill()
    NSBezierPath(ovalIn: NSRect(x: r.minX + 36, y: bar.midY - 17, width: 34, height: 34)).fill()
    NSColor.white.withAlphaComponent(front ? 0.35 : 0.2).setFill()
    NSBezierPath(roundedRect: NSRect(x: r.minX + 90, y: bar.midY - 9, width: r.width * 0.42, height: 18),
                 xRadius: 9, yRadius: 9).fill()
}

card(NSRect(x: 300, y: 560, width: 480, height: 280), alpha: 0.85, dot: .systemRed, front: false)
card(NSRect(x: 250, y: 440, width: 530, height: 330), alpha: 0.92, dot: .systemOrange, front: false)
let front = NSRect(x: 190, y: 220, width: 644, height: 430)
card(front, alpha: 1, dot: .systemGreen, front: true)

// Prompt "›_" on the front card
let green = NSColor(calibratedRed: 0.36, green: 0.92, blue: 0.55, alpha: 1)
let chevron = NSBezierPath()
chevron.move(to: NSPoint(x: front.minX + 80, y: front.minY + 250))
chevron.line(to: NSPoint(x: front.minX + 175, y: front.minY + 185))
chevron.line(to: NSPoint(x: front.minX + 80, y: front.minY + 120))
chevron.lineWidth = 34; chevron.lineCapStyle = .round; chevron.lineJoinStyle = .round
green.setStroke(); chevron.stroke()
green.setFill()
NSBezierPath(roundedRect: NSRect(x: front.minX + 220, y: front.minY + 104, width: 150, height: 34),
             xRadius: 17, yRadius: 17).fill()
// Hinted text lines
NSColor.white.withAlphaComponent(0.22).setFill()
NSBezierPath(roundedRect: NSRect(x: front.minX + 80, y: front.minY + 300, width: 360, height: 22), xRadius: 11, yRadius: 11).fill()
NSBezierPath(roundedRect: NSRect(x: front.minX + 460, y: front.minY + 300, width: 110, height: 22), xRadius: 11, yRadius: 11).fill()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
