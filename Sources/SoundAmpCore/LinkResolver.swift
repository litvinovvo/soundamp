import Foundation

/// Metadata from SoundCloud's public oEmbed endpoint (no API key needed).
public struct OEmbedInfo: Equatable {
    public enum Kind: String { case track = "tracks", playlist = "playlists", user = "users" }

    public var title: String
    public var author: String
    public var authorURL: String?
    public var thumbnailURL: String?
    public var kind: Kind?
    public var id: Int?

    /// "Flickermood by Forss" → "Flickermood" when the author is Forss.
    public var shortTitle: String {
        let suffix = " by \(author)"
        if !author.isEmpty, title.hasSuffix(suffix) { return String(title.dropLast(suffix.count)) }
        return title
    }

    /// The link that the widget can always play, by numeric id.
    public var apiLink: SoundCloudLink? {
        guard let id, let kind else { return nil }
        switch kind {
        case .track: return .apiTrack(id: id)
        case .playlist: return .apiPlaylist(id: id)
        case .user: return nil
        }
    }

    public static func parse(_ data: Data) throws -> OEmbedInfo {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResolveError.badResponse("oEmbed: not a JSON object")
        }
        let html = obj["html"] as? String ?? ""
        let (kind, id) = Self.extractID(fromEmbedHTML: html)
        return OEmbedInfo(
            title: obj["title"] as? String ?? "",
            author: obj["author_name"] as? String ?? "",
            authorURL: obj["author_url"] as? String,
            thumbnailURL: obj["thumbnail_url"] as? String,
            kind: kind, id: id)
    }

    private static let idPattern = try! NSRegularExpression(
        pattern: #"api\.soundcloud\.com(?:/|%2F)(tracks|playlists|users)(?:/|%2F)(\d+)"#, options: [.caseInsensitive])

    static func extractID(fromEmbedHTML html: String) -> (Kind?, Int?) {
        let ns = html as NSString
        guard let m = idPattern.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return (nil, nil) }
        return (Kind(rawValue: ns.substring(with: m.range(at: 1)).lowercased()), Int(ns.substring(with: m.range(at: 2))))
    }
}

public enum ResolveError: Error, CustomStringConvertible, Equatable {
    case badResponse(String)
    case notFound(String)
    case notSoundCloud(String)

    public var description: String {
        switch self {
        case let .badResponse(s): return "bad response: \(s)"
        case let .notFound(s): return "not found (private, deleted or region-blocked?): \(s)"
        case let .notSoundCloud(s): return "not a SoundCloud link: \(s)"
        }
    }
}

/// Minimal HTTP seam so resolution can be unit-tested without the network.
public protocol HTTPClient {
    /// GET following redirects. Returns body, final URL and status code.
    func get(_ url: URL) async throws -> (data: Data, finalURL: URL, status: Int)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}
    public func get(_ url: URL) async throws -> (data: Data, finalURL: URL, status: Int) {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("SoundAmp/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        return (data, http?.url ?? url, http?.statusCode ?? 0)
    }
}

/// Resolves short links and fetches oEmbed metadata.
public struct LinkResolver {
    let http: HTTPClient
    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    /// on.soundcloud.com/abc → the full link it redirects to.
    public func expandShortLink(_ url: URL) async throws -> SoundCloudLink {
        let (_, final, status) = try await http.get(url)
        guard (200..<400).contains(status) || final != url else { throw ResolveError.notFound(url.absoluteString) }
        guard let link = SoundCloudLink.parse(final.absoluteString), !isShort(link) else {
            throw ResolveError.notSoundCloud(final.absoluteString)
        }
        return link
    }

    /// Fully resolves anything pasted: expands short links, keeps the rest.
    public func normalize(_ link: SoundCloudLink) async throws -> SoundCloudLink {
        if case let .shortLink(url) = link { return try await expandShortLink(url) }
        return link
    }

    public static func oEmbedURL(for link: SoundCloudLink) -> URL {
        var c = URLComponents(string: "https://soundcloud.com/oembed")!
        c.queryItems = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "url", value: link.canonicalURL)]
        // URLComponents leaves ':' and '/' unescaped inside query values; SoundCloud accepts both.
        return c.url!
    }

    public func oEmbed(_ link: SoundCloudLink) async throws -> OEmbedInfo {
        let (data, _, status) = try await http.get(Self.oEmbedURL(for: link))
        if status == 404 || status == 403 { throw ResolveError.notFound(link.canonicalURL) }
        guard status == 200 else { throw ResolveError.badResponse("oEmbed HTTP \(status)") }
        return try OEmbedInfo.parse(data)
    }

    private struct HydrationEntry: Decodable {
        let hydratable: String
        let data: PlaylistData?

        struct PlaylistData: Decodable {
            let tracks: [TrackData]

            struct TrackData: Decodable {
                let id: Int
                let policy: String?
            }
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            hydratable = try values.decode(String.self, forKey: .hydratable)
            data = hydratable == "systemPlaylist" ? try values.decode(PlaylistData.self, forKey: .data) : nil
        }

        private enum CodingKeys: String, CodingKey { case hydratable, data }
    }

    public func dailyDropsTracks(user: String) async throws -> [Track] {
        let link = SoundCloudLink.dailyDrops(user: user)
        guard let url = URL(string: link.canonicalURL) else {
            throw ResolveError.notSoundCloud(link.canonicalURL)
        }
        let (data, _, status) = try await http.get(url)
        guard status == 200 else { throw ResolveError.badResponse("Daily Drops HTTP \(status)") }

        let html = String(decoding: data, as: UTF8.self)
        guard let assignment = html.range(of: "window.__sc_hydration = "),
              let end = html.range(of: "</script>", range: assignment.upperBound..<html.endIndex) else {
            throw ResolveError.badResponse("Daily Drops track list missing")
        }
        let json = html[assignment.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
        let entries = try JSONDecoder().decode([HydrationEntry].self, from: Data(json.utf8))
        guard let tracks = entries.compactMap(\.data).first?.tracks, !tracks.isEmpty else {
            throw ResolveError.badResponse("Daily Drops track list is empty")
        }
        return tracks.map { track in
            let link = SoundCloudLink.apiTrack(id: track.id)
            return Track(url: link.canonicalURL, title: link.placeholderTitle, soundID: track.id,
                         status: track.policy == "BLOCK" ? .unavailable : .ready,
                         note: track.policy == "BLOCK" ? "blocked" : track.policy == "SNIP" ? "preview" : nil)
        }
    }

    private func isShort(_ l: SoundCloudLink) -> Bool {
        if case .shortLink = l { return true }
        return false
    }
}
