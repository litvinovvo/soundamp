import AppKit
import SoundAmpCore

/// The classic 275×116 equalizer window.
final class EqualizerWindowView: SkinView {
    private var autoOn = false
    private var lineColors: [RGBA] = []
    private var lineColorsSkin: ObjectIdentifier?

    override func regionPolygons() -> [SkinRegion.Polygon]? { skin.regions["equalizer"] }

    override func drawSkin() {
        let p = player
        draw(Sprites.eqBackground, at: .zero)
        draw(isActiveWindow ? Sprites.eqTitleBarActive : Sprites.eqTitleBar, at: .zero)
        if isPressed("close") { draw(Sprites.eqClose.pressed, at: EqLayout.close) }

        draw(Sprites.eqOn(on: p.eqOn, pressed: isPressed("on")), at: EqLayout.on)
        draw(Sprites.eqAuto(on: autoOn, pressed: isPressed("auto")), at: EqLayout.auto)
        draw(isPressed("presets") ? Sprites.eqPresets.pressed : Sprites.eqPresets.normal, at: EqLayout.presets)

        drawGraph()

        drawSlider(id: "preamp", value: p.eqPreamp, at: EqLayout.preamp)
        for i in 0..<10 { drawSlider(id: "band\(i)", value: p.eqSliders[i], at: EqLayout.band(i)) }
    }

    private func drawSlider(id: String, value: Double, at origin: CGPoint) {
        draw(Sprites.eqSliderBackground(value: value), at: origin)
        let y = origin.y + ((1 - value / 100) * (62 - 11)).rounded()
        draw(isPressed(id) ? Sprites.eqSliderThumbPressed : Sprites.eqSliderThumb, at: origin.x + 1, y)
    }

    private func drawGraph() {
        let g = EqLayout.graph
        draw(Sprites.eqGraphBackground, at: g)
        let colors = graphLineColors()
        // Preamp line
        if let line = skin.image(Sprites.eqPreampLine) {
            let y = ((1 - player.eqPreamp / 100) * 18).rounded()
            draw(image: line, in: CGRect(x: g.x, y: g.y + y, width: CGFloat(line.width), height: 1))
        }
        // Spline through the 10 bands; color comes from the skin's 1×19 color strip.
        let xs = (0..<10).map { Double($0 * 12) }
        let ys = player.eqSliders.map { (100 - $0) / 100 * 18 }
        let curve = EqualizerModel.spline(xs: xs, ys: ys)
        var lastY = Int(ys[0].rounded())
        for (x, yv) in curve.enumerated() {
            let y = max(0, min(18, Int(yv.rounded())))
            let top = min(y, lastY), height = abs(lastY - y) + 1
            for yy in top..<(top + height) {
                fill(CGRect(x: g.x + 2 + CGFloat(x), y: g.y + CGFloat(yy), width: 1, height: 1),
                     colors.indices.contains(yy) ? colors[yy] : RGBA(0, 255, 0))
            }
            lastY = y
        }
    }

    private func graphLineColors() -> [RGBA] {
        let id = ObjectIdentifier(skin)
        if lineColorsSkin != id {
            lineColors = (0..<19).map { skin.pixelColor(.eqmain, x: 115, y: 294 + $0) ?? RGBA(0, 255, 0) }
            lineColorsSkin = id
        }
        return lineColors
    }

    override func hits() -> [Hit] {
        let p = player
        var h: [Hit] = [
            Hit(rect: CGRect(origin: EqLayout.close, size: CGSize(width: 9, height: 9)), kind: .button("close") {
                Env.windows.toggle(Env.windows.equalizer)
            }),
            Hit(rect: CGRect(origin: EqLayout.on, size: CGSize(width: 26, height: 12)), kind: .button("on") {
                p.setEqOn(!p.eqOn)
                if p.eqOn { p.audioFeatureUsed("equalizer") }
            }),
            Hit(rect: CGRect(origin: EqLayout.auto, size: CGSize(width: 32, height: 12)), kind: .button("auto") { [weak self] in
                self?.autoOn.toggle()
                p.flash("AUTO PRESETS: NOT SUPPORTED YET")
            }),
            Hit(rect: CGRect(origin: EqLayout.presets, size: CGSize(width: 44, height: 12)), kind: .button("presets") { [weak self] in
                guard let self else { return }
                Env.menus.presetsMenu().popUp(positioning: nil, at: NSPoint(x: 217 * self.scale, y: 30 * self.scale), in: self)
            }),
        ]
        func slider(_ id: String, _ origin: CGPoint, label: String, set: @escaping (Double) -> Void) -> Hit {
            Hit(rect: CGRect(origin: origin, size: EqLayout.sliderSize), kind: .slider(id) { pt, ended in
                var v = 100 - (pt.y - origin.y - 5.5) / 51 * 100
                if abs(v - 50) < 3 { v = 50 } // snap to 0 dB
                set(max(0, min(100, v)))
                if ended { p.audioFeatureUsed("equalizer") } else {
                    let db = EqualizerModel.dB(fromSlider: v)
                    p.flash("EQ: \(label): \(db >= 0 ? "+" : "")\(String(format: "%.1f", db)) DB", seconds: 1)
                }
            })
        }
        h.append(slider("preamp", EqLayout.preamp, label: "PREAMP") { p.setPreamp($0) })
        for i in 0..<10 {
            h.append(slider("band\(i)", EqLayout.band(i), label: Equalizer.labels[i] + "HZ") { p.setEqSlider(i, $0) })
        }
        return h
    }
}
