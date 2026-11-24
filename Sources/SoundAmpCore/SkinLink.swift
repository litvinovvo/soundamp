import Foundation

/// A downloadable classic skin found in dropped/pasted text.
public struct SkinLink: Equatable {
    /// Where to fetch the .wsz bytes from.
    public let download: URL
    /// File name to install it under ("Winamp5_Classified_v5.5.wsz").
    public let fileName: String

    /// Winamp Skin Museum page links (skins.webamp.org/skin/<md5>/<name>.wsz) serve an
    /// HTML page; the file itself lives here.
    static let museumFiles = "https://r2.webampskins.org/skins/"

    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#, options: [.caseInsensitive])

    /// Every skin link in the text, in order, without duplicates.
    public static func links(in text: String) -> [SkinLink] {
        let ns = text as NSString
        var out: [SkinLink] = []
        for m in urlPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var s = ns.substring(with: m.range)
            while let last = s.last, ".,;:!?)]".contains(last) { s.removeLast() }
            if let link = parse(s), !out.contains(link) { out.append(link) }
        }
        return out
    }

    public static func parse(_ string: String) -> SkinLink? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)

        // Winamp Skin Museum: /skin/<md5>[/<name>.wsz]
        if host == "skins.webamp.org" || host == "www.skins.webamp.org" {
            guard parts.count >= 2, parts[0] == "skin", isMD5(parts[1]) else { return nil }
            let md5 = parts[1].lowercased()
            let name = parts.count >= 3 && parts[2].lowercased().hasSuffix(".wsz") ? parts[2] : "\(md5).wsz"
            return SkinLink(download: URL(string: museumFiles + md5 + ".wsz")!, fileName: sanitize(name))
        }

        // Any direct link to a .wsz file (query strings allowed: ?download=1)
        guard let last = parts.last, last.lowercased().hasSuffix(".wsz") else { return nil }
        return SkinLink(download: url, fileName: sanitize(last))
    }

    /// True for modern (Winamp 3/5 freeform) skins, which we can't render.
    public static func isModernSkinLink(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return url.path.lowercased().hasSuffix(".wal")
    }

    private static func isMD5(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy(\.isHexDigit)
    }

    /// Safe single file name: no folders, no hidden files, ends in .wsz.
    static func sanitize(_ name: String) -> String {
        var n = (name.removingPercentEncoding ?? name)
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while n.hasPrefix(".") { n.removeFirst() }
        if n.isEmpty { n = "skin" }
        if !n.lowercased().hasSuffix(".wsz") { n += ".wsz" }
        return String(n.suffix(120))
    }
}
