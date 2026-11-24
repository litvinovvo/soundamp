import Foundation

/// Winamp EQ UI model: slider values 0…100 (50 = 0 dB, ±12 dB range).
public enum EqualizerModel {
    public static let range = 12.0

    public static func dB(fromSlider v: Double) -> Double { (max(0, min(100, v)) - 50) / 50 * range }
    public static func slider(fromDB db: Double) -> Double { max(0, min(100, db / range * 50 + 50)) }

    public struct Preset: Equatable {
        public let name: String
        /// 10 bands, Winamp .q1 scale 1…64 (33 ≈ 0 dB).
        public let bands: [Int]
        public let preamp: Int

        /// 0…100 slider values.
        public var sliderValues: [Double] { bands.map(Preset.toSlider) }
        public var preampSlider: Double { Preset.toSlider(preamp) }
        static func toSlider(_ q: Int) -> Double { (Double(q) - 1) / 63 * 100 }
    }

    /// Winamp's built-in presets (from Webamp's presets/builtin.json, MIT).
    public static let presets: [Preset] = [
        Preset(name: "Classical", bands: [33, 33, 33, 33, 33, 33, 20, 20, 20, 16], preamp: 33),
        Preset(name: "Club", bands: [33, 33, 38, 42, 42, 42, 38, 33, 33, 33], preamp: 33),
        Preset(name: "Dance", bands: [48, 44, 36, 32, 32, 22, 20, 20, 32, 32], preamp: 33),
        Preset(name: "Laptop speakers/headphones", bands: [40, 50, 41, 26, 28, 35, 40, 48, 53, 56], preamp: 33),
        Preset(name: "Large hall", bands: [49, 49, 42, 42, 33, 24, 24, 24, 33, 33], preamp: 33),
        Preset(name: "Party", bands: [44, 44, 33, 33, 33, 33, 33, 33, 44, 44], preamp: 33),
        Preset(name: "Pop", bands: [29, 40, 44, 45, 41, 30, 28, 28, 29, 29], preamp: 33),
        Preset(name: "Reggae", bands: [33, 33, 31, 22, 33, 43, 43, 33, 33, 33], preamp: 33),
        Preset(name: "Rock", bands: [45, 40, 23, 19, 26, 39, 47, 50, 50, 50], preamp: 33),
        Preset(name: "Soft", bands: [40, 35, 30, 28, 30, 39, 46, 48, 50, 52], preamp: 33),
        Preset(name: "Ska", bands: [28, 24, 25, 31, 39, 42, 47, 48, 50, 48], preamp: 33),
        Preset(name: "Full Bass", bands: [48, 48, 48, 42, 35, 25, 18, 15, 14, 14], preamp: 33),
        Preset(name: "Soft Rock", bands: [39, 39, 36, 31, 25, 23, 26, 31, 37, 47], preamp: 33),
        Preset(name: "Full Treble", bands: [16, 16, 16, 25, 37, 50, 58, 58, 58, 60], preamp: 33),
        Preset(name: "Full Bass & Treble", bands: [44, 42, 33, 20, 24, 35, 46, 50, 52, 52], preamp: 33),
        Preset(name: "Live", bands: [24, 33, 39, 41, 42, 42, 39, 37, 37, 36], preamp: 33),
        Preset(name: "Techno", bands: [45, 42, 33, 23, 24, 33, 45, 48, 48, 47], preamp: 33),
    ]

    /// Natural cubic spline through (xs, ys), sampled at every integer x in xs.first…xs.last.
    /// Used to draw the EQ response curve like Winamp.
    public static func spline(xs: [Double], ys: [Double]) -> [Double] {
        let n = xs.count
        guard n >= 2, ys.count == n else { return ys }
        var a = ys, b = [Double](repeating: 0, count: n), d = [Double](repeating: 0, count: n)
        var c = [Double](repeating: 0, count: n)
        var h = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { h[i] = xs[i + 1] - xs[i] }
        var alpha = [Double](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            alpha[i] = 3 / h[i] * (a[i + 1] - a[i]) - 3 / h[i - 1] * (a[i] - a[i - 1])
        }
        var l = [Double](repeating: 1, count: n), mu = [Double](repeating: 0, count: n), z = [Double](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            l[i] = 2 * (xs[i + 1] - xs[i - 1]) - h[i - 1] * mu[i - 1]
            mu[i] = h[i] / l[i]
            z[i] = (alpha[i] - h[i - 1] * z[i - 1]) / l[i]
        }
        for j in stride(from: n - 2, through: 0, by: -1) {
            c[j] = z[j] - mu[j] * c[j + 1]
            b[j] = (a[j + 1] - a[j]) / h[j] - h[j] * (c[j + 1] + 2 * c[j]) / 3
            d[j] = (c[j + 1] - c[j]) / (3 * h[j])
        }
        a.removeLast(0)
        var out: [Double] = []
        let x0 = Int(xs.first!.rounded()), x1 = Int(xs.last!.rounded())
        var seg = 0
        for xi in x0...x1 {
            let x = Double(xi)
            while seg < n - 2 && x > xs[seg + 1] { seg += 1 }
            let dx = x - xs[seg]
            out.append(a[seg] + b[seg] * dx + c[seg] * dx * dx + d[seg] * dx * dx * dx)
        }
        return out
    }
}
