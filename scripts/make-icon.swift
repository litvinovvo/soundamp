// Renders the SoundAmp app icon (1024×1024 PNG) in the flat late-90s player-logo
// style, with just two layers: a white asymmetric cloud with a black outline, and
// an orange lightning bolt striking through it and breaking out top and bottom.
// Flat fills, two tapered highlight slivers. (A generic thundercloud.)
//
// The two shapes are aligned optically: the bolt is shifted so its center of mass
// sits under the cloud's, then the pair is scaled to fit and centered slightly
// above the canvas middle.
//
//   swift scripts/make-icon.swift out.png
//
// scripts/make-icon.sh turns it into Support/AppIcon.icns.
import AppKit
import CoreGraphics

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work in top-left design coordinates (y down) everywhere.
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
typealias Pt = CGPoint
func poly(_ pts: [Pt]) -> CGPath {
    let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p
}
func fill(_ p: CGPath, _ c: UInt32) { ctx.addPath(p); ctx.setFillColor(rgb(c)); ctx.fillPath() }

let outline: CGFloat = 24
let black: UInt32 = 0x000000, orange: UInt32 = 0xFCA800, cream: UInt32 = 0xFFE7B3, dark: UInt32 = 0xE96A00

// MARK: Shapes (raw layout)

// Asymmetric cumulus as ONE path: three puffs (the end puffs sit exactly on the
// flat bottom line), joined by a polygon through their centers, merged with a
// real path union — no overlapping-shape bumps or ledges in the outline.
let bottom: CGFloat = 620
let puffs: [(c: Pt, r: CGFloat)] = [
    (Pt(x: 285, y: bottom - 110), 110),  // left, tangent to the bottom
    (Pt(x: 472, y: 360), 192),           // big, left of center
    (Pt(x: 702, y: bottom - 142), 142),  // right, lower, tangent to the bottom
]
var cloudShape: CGPath = poly([Pt(x: puffs[0].c.x, y: bottom)] + puffs.map(\.c) + [Pt(x: puffs[puffs.count - 1].c.x, y: bottom)])
for p in puffs {
    cloudShape = cloudShape.union(CGPath(ellipseIn: CGRect(x: p.c.x - p.r, y: p.c.y - p.r, width: 2 * p.r, height: 2 * p.r), transform: nil))
}
// Round each dip between neighbouring puffs with a small fillet arc: a circle of
// radius rf touching both puffs from outside; fill the gap above the cusp, minus
// that circle. Keeps the outline an even width (no heavy blobs at the dips).
let rf: CGFloat = 40
let cloudMiddle = Pt(x: 520, y: 480)
for i in 0..<(puffs.count - 1) {
    let (c1, r1) = puffs[i], (c2, r2) = puffs[i + 1]
    let d1 = r1 + rf, d2 = r2 + rf
    let dx = c2.x - c1.x, dy = c2.y - c1.y, d = (dx * dx + dy * dy).squareRoot()
    let a = (d1 * d1 - d2 * d2 + d * d) / (2 * d), h = (d1 * d1 - a * a).squareRoot()
    let m = Pt(x: c1.x + dx * a / d, y: c1.y + dy * a / d)
    let candidates = [Pt(x: m.x - dy * h / d, y: m.y + dx * h / d), Pt(x: m.x + dy * h / d, y: m.y - dx * h / d)]
    // the fillet sits on the outside of the cloud (farther from its middle)
    let f = candidates.max { hypot($0.x - cloudMiddle.x, $0.y - cloudMiddle.y) < hypot($1.x - cloudMiddle.x, $1.y - cloudMiddle.y) }!
    let gap = poly([c1, f, c2]).subtracting(CGPath(ellipseIn: CGRect(x: f.x - rf, y: f.y - rf, width: 2 * rf, height: 2 * rf), transform: nil))
    cloudShape = cloudShape.union(gap)
}
var cloudParts: [CGPath] = [cloudShape]
// Bolt: A top-left, B top-right, C upper notch, D notch end, E tip, F lower notch, G lower notch end.
var bolt: [Pt] = [Pt(x: 575, y: 60), Pt(x: 745, y: 60), Pt(x: 630, y: 400), Pt(x: 790, y: 400),
                  Pt(x: 395, y: 900), Pt(x: 450, y: 590), Pt(x: 345, y: 590)]

// MARK: Optical alignment

/// Area centroid of a filled shape (union of paths), by sampling.
func centroid(_ paths: [CGPath], step: CGFloat = 4) -> Pt {
    let box = paths.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
    var sx: CGFloat = 0, sy: CGFloat = 0, n: CGFloat = 0
    var y = box.minY
    while y < box.maxY {
        var x = box.minX
        while x < box.maxX {
            let p = Pt(x: x, y: y)
            if paths.contains(where: { $0.contains(p) }) { sx += x; sy += y; n += 1 }
            x += step
        }
        y += step
    }
    return Pt(x: sx / n, y: sy / n)
}
// 0. Bolt size relative to the cloud (scaled around its own center of mass).
let boltScale: CGFloat = 0.8
do {
    let c = centroid([poly(bolt)])
    bolt = bolt.map { Pt(x: c.x + ($0.x - c.x) * boltScale, y: c.y + ($0.y - c.y) * boltScale) }
}
// 1. Center the bolt's mass under the cloud's mass (horizontally).
let shift = centroid(cloudParts).x - centroid([poly(bolt)]).x
bolt = bolt.map { Pt(x: $0.x + shift, y: $0.y) }

// 2. Fit and center by visual weight, not by bounding box: the heavy cloud sits
//    high and the thin bolt tip hangs low, so box-centering looks off. Put the
//    mass center of cloud + bolt slightly above the canvas middle (the optical
//    center), then shrink if anything would leave the safe area.
func strokedBox(_ p: CGPath) -> CGRect {
    p.copy(strokingWithWidth: outline * 2, lineCap: .butt, lineJoin: .miter, miterLimit: 6).boundingBox
}
let all = cloudParts.map(strokedBox).reduce(strokedBox(poly(bolt))) { $0.union($1) }
let mass = centroid(cloudParts + [poly(bolt)])
let opticalCenter = Pt(x: 512, y: 500)
let safe = CGRect(x: 72, y: 60, width: 880, height: 904)
var fitScale = min(1, 880 / max(all.width, all.height))
func placed(_ r: CGRect, _ k: CGFloat) -> CGRect {
    CGRect(x: opticalCenter.x + (r.minX - mass.x) * k, y: opticalCenter.y + (r.minY - mass.y) * k, width: r.width * k, height: r.height * k)
}
while !safe.contains(placed(all, fitScale)) && fitScale > 0.5 { fitScale -= 0.01 }
var T = CGAffineTransform(translationX: opticalCenter.x, y: opticalCenter.y)
    .scaledBy(x: fitScale, y: fitScale)
    .translatedBy(x: -mass.x, y: -mass.y)
cloudParts = cloudParts.map { $0.copy(using: &T)! }
bolt = bolt.map { $0.applying(T) }
let line = outline * fitScale

// MARK: Draw

// 1. White cloud: a single outline, then the fill
ctx.saveGState()
ctx.setLineWidth(line * 2); ctx.setLineJoin(.round); ctx.setStrokeColor(rgb(black))
for p in cloudParts { ctx.addPath(p); ctx.strokePath() }
ctx.restoreGState()
for p in cloudParts { fill(p, 0xFFFFFF) }

// 2. Orange bolt
let boltPath = poly(bolt)
ctx.saveGState()
ctx.addPath(boltPath); ctx.setLineWidth(line * 2); ctx.setLineJoin(.miter); ctx.setMiterLimit(6)
ctx.setStrokeColor(rgb(black)); ctx.strokePath()
ctx.restoreGState()
fill(boltPath, orange)

let boltCenter = centroid([boltPath], step: 8)
/// A sliver along edge a→b that tapers to points at both ends, widest at `peak` (0…1),
/// bulging toward the inside of the bolt.
func sliver(_ a: Pt, _ b: Pt, width: CGFloat, peak: CGFloat, from: CGFloat = 0.06, to: CGFloat = 0.94) -> CGPath {
    let dx = b.x - a.x, dy = b.y - a.y, len = (dx * dx + dy * dy).squareRoot()
    var n = Pt(x: -dy / len, y: dx / len)
    if (boltCenter.x - a.x) * n.x + (boltCenter.y - a.y) * n.y < 0 { n = Pt(x: -n.x, y: -n.y) }
    func along(_ t: CGFloat) -> Pt { Pt(x: a.x + dx * t, y: a.y + dy * t) }
    let p0 = along(from), p1 = along(to), m = along(peak)
    let s = CGMutablePath()
    s.move(to: p0)
    s.addQuadCurve(to: p1, control: Pt(x: m.x + n.x * width * 2, y: m.y + n.y * width * 2))
    s.closeSubpath()
    return s
}
ctx.saveGState()
ctx.addPath(boltPath); ctx.clip()
let w = line * 1.1
fill(sliver(bolt[6], bolt[0], width: w, peak: 0.55), cream)               // light on the upper-left edge
fill(sliver(bolt[3], bolt[4], width: w, peak: 0.3, to: 0.72), dark)       // shade on the long edge, fading before the tip
ctx.restoreGState()

let img = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (bolt shifted \(Int(shift)) px, scale \(String(format: "%.2f", fitScale)), mass at \(Int(mass.x)),\(Int(mass.y)) → 512,500)")
