import Foundation

/// A SoundCloud link the player understands, normalized from whatever the user
/// copied: the "Copy link" button on a track or playlist, the browser address
/// bar, the mobile app share sheet (short links), an embed code, etc.
public enum SoundCloudLink: Hashable, CustomStringConvertible {
    /// soundcloud.com/{user}/{track}[/s-secret]
    case track(user: String, slug: String, secret: String?)
    /// soundcloud.com/{user}/sets/{playlist}[/s-secret]  (playlists and albums)
    case playlist(user: String, slug: String, secret: String?)
    /// api.soundcloud.com/tracks/{id}, soundcloud:tracks:{id}
    case apiTrack(id: Int)
    /// api.soundcloud.com/playlists/{id}, soundcloud:playlists:{id}
    case apiPlaylist(id: Int)
    /// soundcloud.com/{user} or soundcloud.com/{user}/tracks
    case userTracks(user: String)
    /// soundcloud.com/{user}/likes
    case userLikes(user: String)
    case dailyDrops(user: String)
    /// on.soundcloud.com/xyz, snd.sc/xyz, soundcloud.app.goo.gl/xyz — must be resolved over HTTP.
    case shortLink(URL)

    /// True for links that expand into several tracks.
    public var isCollection: Bool {
        switch self {
        case .playlist, .apiPlaylist, .userTracks, .userLikes, .dailyDrops: return true
        case .track, .apiTrack, .shortLink: return false
        }
    }

    /// The URL handed to the widget / oEmbed.
    public var canonicalURL: String {
        switch self {
        case let .track(user, slug, secret):
            return "https://soundcloud.com/\(user)/\(slug)" + (secret.map { "/\($0)" } ?? "")
        case let .playlist(user, slug, secret):
            return "https://soundcloud.com/\(user)/sets/\(slug)" + (secret.map { "/\($0)" } ?? "")
        case let .apiTrack(id): return "https://api.soundcloud.com/tracks/\(id)"
        case let .apiPlaylist(id): return "https://api.soundcloud.com/playlists/\(id)"
        case let .userTracks(user): return "https://soundcloud.com/\(user)"
        case let .userLikes(user): return "https://soundcloud.com/\(user)/likes"
        case let .dailyDrops(user): return "https://soundcloud.com/discover/sets/new-for-you::\(user)"
        case let .shortLink(url): return url.absoluteString
        }
    }

    public var description: String { canonicalURL }

    /// A human placeholder until real metadata arrives ("Flickermood" for /forss/flickermood).
    public var placeholderTitle: String {
        switch self {
        case let .track(_, slug, _), let .playlist(_, slug, _): return Self.prettify(slug)
        case let .apiTrack(id): return "Track \(id)"
        case let .apiPlaylist(id): return "Playlist \(id)"
        case let .userTracks(user): return "\(user) — tracks"
        case let .userLikes(user): return "\(user) — likes"
        case .dailyDrops: return "Daily Drops"
        case let .shortLink(url): return url.absoluteString
        }
    }

    public var placeholderArtist: String {
        switch self {
        case let .track(user, _, _), let .playlist(user, _, _), let .userTracks(user), let .userLikes(user): return user
        default: return ""
        }
    }

    // MARK: Parsing

    /// First path segments that are SoundCloud pages, not user names.
    static let reservedRoots: Set<String> = [
        "discover", "stream", "search", "you", "upload", "charts", "pages", "settings", "messages",
        "notifications", "people", "tags", "terms-of-use", "imprint", "jobs", "pro", "mobile",
        "popular", "connect", "signin", "signup", "logout", "feed", "library", "artists", "for-artists",
        "premium", "go", "creators", "developers", "help", "community-guidelines", "start", "home",
        "playlists", "tracks", "explore", "oembed", "player",
    ]

    /// Track sub-pages: soundcloud.com/u/track/comments still means the track.
    static let trackSubpages: Set<String> = ["comments", "likes", "reposts", "sets", "recommended", "albums", "fans"]

    public static func parse(_ raw: String) -> SoundCloudLink? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'`"))
        guard !s.isEmpty else { return nil }

        // URN form: soundcloud:tracks:123
        if s.lowercased().hasPrefix("soundcloud:") {
            return parseURN(s)
        }

        if !s.contains("://") { s = "https://" + s }
        guard var comps = URLComponents(string: s) ?? URLComponents(string: s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              let rawHost = comps.host?.lowercased() else { return nil }
        comps.scheme = "https"
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let segments = comps.path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        let query = comps.queryItems ?? []

        switch host {
        case "on.soundcloud.com", "snd.sc", "soundcloud.app.goo.gl":
            guard !segments.isEmpty else { return nil }
            comps.query = nil
            comps.fragment = nil
            return comps.url.map(SoundCloudLink.shortLink)

        case "w.soundcloud.com":
            // Embed player URL: ...?url=https%3A//api.soundcloud.com/tracks/123
            guard let inner = query.first(where: { $0.name == "url" })?.value else { return nil }
            return parse(inner)

        case "api.soundcloud.com", "api-v2.soundcloud.com", "api-widget.soundcloud.com":
            return parseAPIPath(segments)

        case "soundcloud.com", "m.soundcloud.com", "mobi.soundcloud.com":
            let secretQuery = query.first(where: { $0.name == "secret_token" })?.value
            return parseWebPath(segments, secretQuery: secretQuery)

        default:
            return nil
        }
    }

    private static func parseURN(_ s: String) -> SoundCloudLink? {
        let parts = s.split(separator: ":")
        guard parts.count == 3, let id = Int(parts[2]) else { return nil }
        switch parts[1].lowercased() {
        case "tracks": return .apiTrack(id: id)
        case "playlists": return .apiPlaylist(id: id)
        default: return nil
        }
    }

    private static func parseAPIPath(_ segments: [String]) -> SoundCloudLink? {
        guard segments.count >= 2 else { return nil }
        let idPart = segments[1]
        let id = Int(idPart) ?? Int(idPart.split(separator: ":").last ?? "")
        guard let id else { return nil }
        switch segments[0].lowercased() {
        case "tracks": return .apiTrack(id: id)
        case "playlists": return .apiPlaylist(id: id)
        default: return nil
        }
    }

    private static func parseWebPath(_ segments: [String], secretQuery: String?) -> SoundCloudLink? {
        if segments.count == 3, segments[0] == "discover", segments[1] == "sets",
           segments[2].hasPrefix("new-for-you::") {
            let user = String(segments[2].dropFirst("new-for-you::".count)).lowercased()
            return isSlug(user) ? .dailyDrops(user: user) : nil
        }
        guard let first = segments.first else { return nil }
        let user = first.lowercased()
        guard !reservedRoots.contains(user), isSlug(user) else { return nil }
        let rest = Array(segments.dropFirst())
        func secret(_ s: String?) -> String? {
            if let s, isSecret(s) { return s }
            if let q = secretQuery, isSecret(q) { return q }
            return nil
        }

        guard let second = rest.first?.lowercased() else { return .userTracks(user: user) }
        switch second {
        case "tracks", "popular-tracks":
            return rest.count == 1 ? .userTracks(user: user) : nil
        case "likes":
            return rest.count == 1 ? .userLikes(user: user) : nil
        case "sets", "albums":
            guard rest.count >= 2 else { return nil } // the list of a user's playlists isn't playable
            let slug = rest[1].lowercased()
            guard isSlug(slug) else { return nil }
            return .playlist(user: user, slug: slug, secret: secret(rest.count >= 3 ? rest[2] : nil))
        case "reposts", "followers", "following", "comments", "spotlight", "toptracks", "insights":
            return nil
        default:
            guard isSlug(second) else { return nil }
            if rest.count >= 2 {
                let third = rest[1]
                if isSecret(third) { return .track(user: user, slug: second, secret: third) }
                guard trackSubpages.contains(third.lowercased()) else { return nil }
            }
            return .track(user: user, slug: second, secret: secret(nil))
        }
    }

    private static func isSlug(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static func isSecret(_ s: String) -> Bool {
        s.count > 2 && s.hasPrefix("s-") && s.dropFirst(2).allSatisfy { $0.isLetter || $0.isNumber }
    }

    static func prettify(_ slug: String) -> String {
        slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// Pulls every SoundCloud link out of pasted text: plain URLs (one or many,
/// any separators), Markdown links, HTML embed codes, URNs.
public enum PasteParser {
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(?:https?://)?(?:[a-z0-9-]+\.)*(?:soundcloud\.com|snd\.sc|soundcloud\.app\.goo\.gl)/[^\s"'<>\]\)\(]*"#,
        options: [.caseInsensitive])
    private static let urnPattern = try! NSRegularExpression(
        pattern: #"soundcloud:(?:tracks|playlists):\d+"#, options: [.caseInsensitive])

    public static func links(in text: String) -> [SoundCloudLink] {
        let decoded = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
        let ns = decoded as NSString
        var found: [(Int, SoundCloudLink)] = []
        let hasEmbed = decoded.range(of: "w.soundcloud.com/player", options: .caseInsensitive) != nil

        for pattern in [urlPattern, urnPattern] {
            for match in pattern.matches(in: decoded, range: NSRange(location: 0, length: ns.length)) {
                var candidate = ns.substring(with: match.range)
                while let last = candidate.last, ".,;:!?".contains(last) { candidate.removeLast() }
                guard let link = SoundCloudLink.parse(candidate) else { continue }
                // An embed code also carries attribution links (<a href="…artist">, <a href="…track">):
                // skip those anchors, keep the embedded player URL and any plain links.
                if hasEmbed, isInsideHref(ns, at: match.range.location) { continue }
                found.append((match.range.location, link))
            }
        }

        var seen = Set<SoundCloudLink>()
        return found.sorted { $0.0 < $1.0 }.compactMap { seen.insert($0.1).inserted ? $0.1 : nil }
    }

    private static func isInsideHref(_ s: NSString, at location: Int) -> Bool {
        let start = max(0, location - 8)
        let before = s.substring(with: NSRange(location: start, length: location - start)).lowercased()
        return before.hasSuffix("href=\"") || before.hasSuffix("href='") || before.hasSuffix("href=")
    }
}
