import XCTest
@testable import SoundAmpCore

/// What people actually copy: the "Copy link" button on tracks and playlists,
/// the address bar, the mobile share sheet, embed codes.
final class SoundCloudLinkTests: XCTestCase {
    private func parse(_ s: String) -> SoundCloudLink? { SoundCloudLink.parse(s) }

    // MARK: Tracks

    func testPlainTrackLink() {
        XCTAssertEqual(parse("https://soundcloud.com/forss/flickermood"), .track(user: "forss", slug: "flickermood", secret: nil))
    }

    func testCopyLinkButtonAddsTrackingParameters() {
        // "Copy link" in the web app / share sheet appends si= and utm_* parameters.
        let link = parse("https://soundcloud.com/forss/flickermood?si=8f2a1c0b9d4e4f6a&utm_source=clipboard&utm_medium=text&utm_campaign=social_sharing")
        XCTAssertEqual(link, .track(user: "forss", slug: "flickermood", secret: nil))
        XCTAssertEqual(link?.canonicalURL, "https://soundcloud.com/forss/flickermood")
    }

    func testTrackOpenedFromPlaylistIsStillTheTrack() {
        XCTAssertEqual(parse("https://soundcloud.com/forss/flickermood?in=forss/sets/soulhack"),
                       .track(user: "forss", slug: "flickermood", secret: nil))
    }

    func testHostVariantsSchemeLessAndCase() {
        let expected = SoundCloudLink.track(user: "forss", slug: "flickermood", secret: nil)
        for s in ["soundcloud.com/forss/flickermood", "www.soundcloud.com/forss/flickermood",
                  "http://m.soundcloud.com/forss/flickermood", "https://SoundCloud.com/Forss/Flickermood/",
                  "  https://soundcloud.com/forss/flickermood\n", "<https://soundcloud.com/forss/flickermood>",
                  "https://soundcloud.com/forss/flickermood#t=1:23"] {
            XCTAssertEqual(parse(s), expected, s)
        }
    }

    func testPrivateTrackKeepsSecretToken() {
        let link = parse("https://soundcloud.com/someartist/unreleased-demo/s-AbC123xYz?si=x")
        XCTAssertEqual(link, .track(user: "someartist", slug: "unreleased-demo", secret: "s-AbC123xYz"))
        XCTAssertEqual(link?.canonicalURL, "https://soundcloud.com/someartist/unreleased-demo/s-AbC123xYz")
    }

    func testTrackSubpagesMeanTheTrack() {
        XCTAssertEqual(parse("https://soundcloud.com/forss/flickermood/comments"), .track(user: "forss", slug: "flickermood", secret: nil))
    }

    // MARK: Playlists

    func testPlaylistLink() {
        let link = parse("https://soundcloud.com/forss/sets/soulhack?si=abc&utm_source=clipboard")
        XCTAssertEqual(link, .playlist(user: "forss", slug: "soulhack", secret: nil))
        XCTAssertEqual(link?.isCollection, true)
        XCTAssertEqual(link?.canonicalURL, "https://soundcloud.com/forss/sets/soulhack")
    }

    func testPrivatePlaylist() {
        XCTAssertEqual(parse("https://soundcloud.com/dj/sets/summer-mix/s-QWErty12"),
                       .playlist(user: "dj", slug: "summer-mix", secret: "s-QWErty12"))
    }

    func testUserPagesAndLikes() {
        XCTAssertEqual(parse("https://soundcloud.com/forss"), .userTracks(user: "forss"))
        XCTAssertEqual(parse("https://soundcloud.com/forss/tracks"), .userTracks(user: "forss"))
        XCTAssertEqual(parse("https://soundcloud.com/forss/likes"), .userLikes(user: "forss"))
    }

    // MARK: API / embed / URN / short links

    func testAPIAndEmbedForms() {
        XCTAssertEqual(parse("https://api.soundcloud.com/tracks/293"), .apiTrack(id: 293))
        XCTAssertEqual(parse("https://api.soundcloud.com/playlists/18"), .apiPlaylist(id: 18))
        XCTAssertEqual(parse("https://api.soundcloud.com/tracks/soundcloud:tracks:293"), .apiTrack(id: 293))
        XCTAssertEqual(parse("soundcloud:tracks:293"), .apiTrack(id: 293))
        XCTAssertEqual(parse("https://w.soundcloud.com/player/?url=https%3A//api.soundcloud.com/tracks/293&color=%23ff5500&auto_play=false"),
                       .apiTrack(id: 293))
    }

    func testMobileShareShortLinks() {
        guard case let .shortLink(url)? = parse("https://on.soundcloud.com/AbCdEf123?utm_source=x") else {
            return XCTFail("expected short link")
        }
        XCTAssertEqual(url.absoluteString, "https://on.soundcloud.com/AbCdEf123")
        XCTAssertNotNil(parse("https://soundcloud.app.goo.gl/xyz"))
    }

    // MARK: Rejections

    func testNonPlayableOrForeignLinksAreRejected() {
        for s in ["https://soundcloud.com/discover", "https://soundcloud.com/you/likes", "https://soundcloud.com/search?q=forss",
                  "https://soundcloud.com/forss/sets", "https://soundcloud.com/forss/followers", "https://soundcloud.com/",
                  "https://youtube.com/watch?v=x", "https://notsoundcloud.com/forss/flickermood", "hello", ""] {
            XCTAssertNil(parse(s), s)
        }
    }

    func testPlaceholderTitle() {
        XCTAssertEqual(parse("https://soundcloud.com/forss/my-best_track-2")?.placeholderTitle, "My Best Track 2")
    }
}

final class PasteParserTests: XCTestCase {
    func testMultipleLinksAnySeparatorDeduplicated() {
        let text = """
        check these out:
        https://soundcloud.com/forss/flickermood?si=1, https://soundcloud.com/forss/sets/soulhack
        soundcloud.com/forss/flickermood (same track again).
        """
        XCTAssertEqual(PasteParser.links(in: text), [
            .track(user: "forss", slug: "flickermood", secret: nil),
            .playlist(user: "forss", slug: "soulhack", secret: nil),
        ])
    }

    func testEmbedCodeFromShareDialog() {
        // Share › Embed copies the iframe plus attribution links to the artist and the track page.
        let embed = #"<iframe width="100%" height="166" scrolling="no" frameborder="no" allow="autoplay" src="https://w.soundcloud.com/player/?url=https%3A//api.soundcloud.com/tracks/293&amp;color=%23ff5500&amp;auto_play=false"></iframe><div style="font-size: 10px;"><a href="https://soundcloud.com/forss" title="Forss" target="_blank">Forss</a> · <a href="https://soundcloud.com/forss/flickermood" title="Flickermood" target="_blank">Flickermood</a></div>"#
        XCTAssertEqual(PasteParser.links(in: embed), [.apiTrack(id: 293)])
    }

    func testEmbedCodeMixedWithPlainLinks() {
        let text = "https://soundcloud.com/forss/sets/soulhack\n"
            + #"<iframe src="https://w.soundcloud.com/player/?url=https%3A//api.soundcloud.com/tracks/294"></iframe><a href="https://soundcloud.com/forss">Forss</a>"#
        XCTAssertEqual(PasteParser.links(in: text), [.playlist(user: "forss", slug: "soulhack", secret: nil), .apiTrack(id: 294)])
    }

    func testMarkdownAndTrailingPunctuation() {
        XCTAssertEqual(PasteParser.links(in: "[listen](https://soundcloud.com/forss/flickermood)."),
                       [.track(user: "forss", slug: "flickermood", secret: nil)])
        XCTAssertEqual(PasteParser.links(in: "playlist: https://soundcloud.com/forss/sets/soulhack!"),
                       [.playlist(user: "forss", slug: "soulhack", secret: nil)])
    }

    func testNothingToFind() {
        XCTAssertEqual(PasteParser.links(in: "just some text https://example.com/a"), [])
    }
}

final class LinkResolverTests: XCTestCase {
    final class MockHTTP: HTTPClient {
        var routes: [String: (Data, URL?, Int)] = [:]
        var requested: [URL] = []
        func get(_ url: URL) async throws -> (data: Data, finalURL: URL, status: Int) {
            requested.append(url)
            guard let r = routes.first(where: { url.absoluteString.contains($0.key) })?.value else { return (Data(), url, 404) }
            return (r.0, r.1 ?? url, r.2)
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testOEmbedTrackParsing() throws {
        let info = try OEmbedInfo.parse(fixture("oembed-track"))
        XCTAssertEqual(info.title, "Flickermood by Forss")
        XCTAssertEqual(info.shortTitle, "Flickermood")
        XCTAssertEqual(info.author, "Forss")
        XCTAssertEqual(info.kind, .track)
        XCTAssertEqual(info.id, 293)
        XCTAssertEqual(info.apiLink, .apiTrack(id: 293))
    }

    func testOEmbedPlaylistParsing() throws {
        let info = try OEmbedInfo.parse(fixture("oembed-playlist"))
        XCTAssertEqual(info.kind, .playlist)
        XCTAssertEqual(info.id, 18)
        XCTAssertEqual(info.apiLink, .apiPlaylist(id: 18))
    }

    func testShortLinkExpandsViaRedirect() async throws {
        let http = MockHTTP()
        http.routes["on.soundcloud.com/AbC"] = (Data(), URL(string: "https://soundcloud.com/forss/sets/soulhack?si=zz&utm_medium=text")!, 200)
        let link = try await LinkResolver(http: http).normalize(.shortLink(URL(string: "https://on.soundcloud.com/AbC")!))
        XCTAssertEqual(link, .playlist(user: "forss", slug: "soulhack", secret: nil))
    }

    func testShortLinkToSomethingElseFails() async {
        let http = MockHTTP()
        http.routes["on.soundcloud.com/bad"] = (Data(), URL(string: "https://example.com/")!, 200)
        do {
            _ = try await LinkResolver(http: http).normalize(.shortLink(URL(string: "https://on.soundcloud.com/bad")!))
            XCTFail("should throw")
        } catch {}
    }

    func testOEmbedRequestAndNotFound() async throws {
        let http = MockHTTP()
        http.routes["oembed"] = (try fixture("oembed-track"), nil, 200)
        let info = try await LinkResolver(http: http).oEmbed(.track(user: "forss", slug: "flickermood", secret: nil))
        XCTAssertEqual(info.id, 293)
        let q = URLComponents(url: try XCTUnwrap(http.requested.first), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(q.first { $0.name == "url" }?.value, "https://soundcloud.com/forss/flickermood")
        XCTAssertEqual(q.first { $0.name == "format" }?.value, "json")

        http.routes = [:]
        do {
            _ = try await LinkResolver(http: http).oEmbed(.apiTrack(id: 1))
            XCTFail("should throw")
        } catch let e as ResolveError {
            XCTAssertEqual(e, .notFound("https://api.soundcloud.com/tracks/1"))
        }
    }

    /// Real network round-trip. Run with SOUNDAMP_NETWORK_TESTS=1 swift test
    func testLiveOEmbed() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOUNDAMP_NETWORK_TESTS"] == "1", "network test")
        let r = LinkResolver()
        let track = try await r.oEmbed(XCTUnwrap(SoundCloudLink.parse("https://soundcloud.com/forss/flickermood?si=x")))
        XCTAssertEqual(track.apiLink, .apiTrack(id: 293))
        let set = try await r.oEmbed(XCTUnwrap(SoundCloudLink.parse("https://soundcloud.com/forss/sets/soulhack")))
        XCTAssertEqual(set.apiLink, .apiPlaylist(id: 18))
    }
}
