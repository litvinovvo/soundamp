import Foundation

/// 8-bit RGBA color.
public struct RGBA: Equatable, Hashable, CustomStringConvertible {
    public var r, g, b, a: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) { self.r = r; self.g = g; self.b = b; self.a = a }

    /// "#00FF00", "00ff00", "#00FF00FF" (extra chars ignored, like Winamp).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        s = String(s.prefix(6))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
    }

    public var description: String { String(format: "#%02X%02X%02X", r, g, b) }
    /// Little-endian RGBA packed for a premultiplied-last 32-bit bitmap.
    public var packed: UInt32 { UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(a) << 24 }
}

public enum SkinText {
    /// Winamp 2.91 base skin viscolor.txt.
    public static let defaultVisColors: [RGBA] = [
        RGBA(0, 0, 0), RGBA(24, 33, 41), RGBA(239, 49, 16), RGBA(206, 41, 16), RGBA(214, 90, 0),
        RGBA(214, 102, 0), RGBA(214, 115, 0), RGBA(198, 123, 8), RGBA(222, 165, 24), RGBA(214, 181, 33),
        RGBA(189, 222, 41), RGBA(148, 222, 33), RGBA(41, 206, 16), RGBA(50, 190, 16), RGBA(57, 181, 16),
        RGBA(49, 156, 8), RGBA(41, 148, 0), RGBA(24, 132, 8), RGBA(255, 255, 255), RGBA(214, 214, 222),
        RGBA(181, 189, 189), RGBA(160, 170, 175), RGBA(148, 156, 165), RGBA(150, 150, 150),
    ]

    /// viscolor.txt: up to 24 lines "r,g,b, // comment". Missing entries keep defaults.
    public static func parseVisColors(_ text: String) -> [RGBA] {
        var colors = defaultVisColors
        let regex = try! NSRegularExpression(pattern: #"^\s*(\d+)\s*,?\s*(\d+)\s*,?\s*(\d+)"#)
        var i = 0
        for line in text.components(separatedBy: .newlines) where i < 24 {
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            func c(_ k: Int) -> UInt8 { UInt8(clamping: Int(ns.substring(with: m.range(at: k))) ?? 0) }
            colors[i] = RGBA(c(1), c(2), c(3))
            i += 1
        }
        return colors
    }

    /// Minimal INI: sections and keys are lowercased, comments start with ';'.
    public static func parseINI(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var section: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("//") { continue }
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                section = line[line.index(after: line.startIndex)..<end].trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard let s = section, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(line[line.index(after: eq)...])
            if let second = value.firstIndex(of: "=") { value = String(value[..<second]) } // like Webamp
            value = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            result[s, default: [:]][key] = value
        }
        return result
    }
}

/// pledit.txt [Text] section.
public struct PlaylistStyle: Equatable {
    public var normal = RGBA(0, 255, 0)
    public var current = RGBA(255, 255, 255)
    public var normalBG = RGBA(0, 0, 0)
    public var selectedBG = RGBA(0, 0, 198)
    public var font = "Arial"

    public init() {}

    public static func parse(_ text: String) -> PlaylistStyle {
        var s = PlaylistStyle()
        guard let t = SkinText.parseINI(text)["text"] else { return s }
        if let c = t["normal"].flatMap(RGBA.init(hex:)) { s.normal = c }
        if let c = t["current"].flatMap(RGBA.init(hex:)) { s.current = c }
        if let c = t["normalbg"].flatMap(RGBA.init(hex:)) { s.normalBG = c }
        if let c = t["selectedbg"].flatMap(RGBA.init(hex:)) { s.selectedBG = c }
        if let f = t["font"], !f.isEmpty { s.font = f }
        return s
    }
}

/// region.txt: window shape polygons per section ("normal", "windowshade", "equalizer", "equalizerws").
public enum SkinRegion {
    public typealias Polygon = [(x: Double, y: Double)]

    public static func parse(_ text: String) -> [String: [Polygon]] {
        var out: [String: [Polygon]] = [:]
        for (section, values) in SkinText.parseINI(text) {
            guard let np = values["numpoints"], let pl = values["pointlist"] else { continue }
            let counts = np.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
            let nums = pl.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" }).compactMap { Double($0) }
            var points: [(x: Double, y: Double)] = []
            var k = 0
            while k + 1 < nums.count { points.append((nums[k], nums[k + 1])); k += 2 }
            var idx = 0
            var polygons: [Polygon] = []
            for n in counts {
                defer { idx += n }
                guard n >= 3, idx + n <= points.count else { continue }
                polygons.append(Array(points[idx..<(idx + n)]))
            }
            if !polygons.isEmpty { out[section] = polygons }
        }
        return out
    }
}
