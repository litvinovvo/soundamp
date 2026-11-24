import CoreGraphics
import Foundation
import ImageIO

/// A loaded classic Winamp skin (.wsz = zip of BMPs + text files).
///
/// Like Winamp, bitmaps the skin doesn't provide fall back to the base skin.
public final class Skin {
    public enum LoadError: Error, CustomStringConvertible {
        case noMainBitmap
        public var description: String { "skin has no main.bmp — probably not a classic Winamp skin" }
    }

    public let name: String
    public let visColors: [RGBA]
    public let playlistStyle: PlaylistStyle
    /// region.txt polygons by lowercased section name ("normal", "equalizer", …).
    public let regions: [String: [SkinRegion.Polygon]]

    private let sheets: [SkinSheet: CGImage]
    private let fallback: Skin?
    private var cache: [Sprite: CGImage] = [:]

    public init(name: String, archive: ZipArchive, fallback: Skin?) throws {
        self.name = name
        self.fallback = fallback

        var sheets: [SkinSheet: CGImage] = [:]
        for sheet in SkinSheet.allCases {
            guard let entry = archive.entry(base: sheet.rawValue, extensions: ["bmp", "png"]),
                  let data = try? archive.extract(entry),
                  let image = Self.decodeImage(data) else { continue }
            sheets[sheet] = image
        }
        // Some skins ship nums_ex.bmp only; use it for plain digits too.
        if sheets[.numbers] == nil, let ex = sheets[.numsEx] { sheets[.numbers] = ex }
        // A skin with no bitmaps at all (e.g. a modern .wal skin) is not usable.
        guard !sheets.isEmpty, sheets[.main] != nil || fallback != nil else { throw LoadError.noMainBitmap }
        self.sheets = sheets

        func text(_ base: String) -> String? {
            guard let e = archive.entry(base: base, extensions: ["txt"]), let d = try? archive.extract(e) else { return nil }
            return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .windowsCP1252) ?? String(data: d, encoding: .isoLatin1)
        }
        visColors = text("viscolor").map(SkinText.parseVisColors) ?? fallback?.visColors ?? SkinText.defaultVisColors
        playlistStyle = text("pledit").map(PlaylistStyle.parse) ?? fallback?.playlistStyle ?? PlaylistStyle()
        regions = text("region").map(SkinRegion.parse) ?? [:]
    }

    public convenience init(contentsOf url: URL, fallback: Skin?) throws {
        try self.init(name: url.deletingPathExtension().lastPathComponent, archive: ZipArchive(contentsOf: url), fallback: fallback)
    }

    /// True if this skin itself (not the fallback) provides the bitmap.
    public func hasOwn(_ sheet: SkinSheet) -> Bool { sheets[sheet] != nil }

    public func sheet(_ sheet: SkinSheet) -> CGImage? { sheets[sheet] ?? fallback?.sheet(sheet) }

    /// Use nums_ex.bmp (with a real minus sign) only when this skin has its own.
    public var usesNumsEx: Bool { hasOwn(.numsEx) || (!hasOwn(.numbers) && fallback?.usesNumsEx == true) }

    /// Volume/balance thumbs only exist when the bitmap is tall enough.
    public func hasSliderThumbs(_ sheet: SkinSheet) -> Bool { (self.sheet(sheet)?.height ?? 0) >= 433 }

    /// The sprite's pixels, or nil if the sheet is missing or too small.
    public func image(_ sprite: Sprite) -> CGImage? {
        if let c = cache[sprite] { return c }
        guard let sheet = sheets[sprite.sheet] ?? fallbackSheet(for: sprite) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height)
        let r = sprite.rect.intersection(bounds)
        guard !r.isNull, r.width >= 1, r.height >= 1, let img = sheet.cropping(to: r) else { return nil }
        cache[sprite] = img
        return img
    }

    private func fallbackSheet(for sprite: Sprite) -> CGImage? {
        // A skin that lacks a bitmap shows the base skin's.
        fallback?.sheet(sprite.sheet)
    }

    /// Color of one pixel of a sheet (used for EQ graph line colors).
    public func pixelColor(_ sheet: SkinSheet, x: Int, y: Int) -> RGBA? {
        guard let img = self.sheet(sheet), x < img.width, y < img.height,
              let cropped = img.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return RGBA(px[0], px[1], px[2], px[3])
    }

    static func decodeImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
