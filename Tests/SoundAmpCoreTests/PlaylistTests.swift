import XCTest
@testable import SoundAmpCore

final class PlaylistTests: XCTestCase {
    private func tracks(_ n: Int) -> [Track] {
        (0..<n).map { Track(url: "https://api.soundcloud.com/tracks/\($0)", title: "T\($0)", durationMs: 60_000) }
    }

    func testNextPreviousWithoutRepeatStopsAtEnds() {
        let p = Playlist(tracks: tracks(3))
        XCTAssertEqual(p.nextIndex(), 0) // nothing current → first
        p.setCurrent(2)
        XCTAssertNil(p.nextIndex())
        p.setCurrent(0)
        XCTAssertNil(p.previousIndex())
    }

    func testRepeatWraps() {
        let p = Playlist(tracks: tracks(3))
        p.repeatAll = true
        p.setCurrent(2)
        XCTAssertEqual(p.nextIndex(), 0)
        p.setCurrent(0)
        XCTAssertEqual(p.previousIndex(), 2)
    }

    func testSkipsUnavailableAndPlaceholders() {
        var t = tracks(4)
        t[1].status = .unavailable
        t[2].isPlaceholder = true
        let p = Playlist(tracks: t)
        p.setCurrent(0)
        XCTAssertEqual(p.nextIndex(), 3)
    }

    func testShuffleVisitsEveryTrackOnce() {
        let p = Playlist(tracks: tracks(20), rng: SeededRandom(seed: 42))
        p.shuffle = true
        var seen = Set<Int>()
        var i = p.firstPlayableIndex()
        while let cur = i {
            XCTAssertTrue(seen.insert(cur).inserted, "visited \(cur) twice")
            p.setCurrent(cur)
            i = p.nextIndex()
        }
        XCTAssertEqual(seen.count, 20)
        XCTAssertNotEqual(Array(seen), Array(0..<20), "order should actually be shuffled")
    }

    func testRemovingKeepsCurrentPointingAtSameTrack() {
        let p = Playlist(tracks: tracks(5))
        p.setCurrent(3)
        let id = p.current!.id
        p.remove(IndexSet([0, 1]))
        XCTAssertEqual(p.current?.id, id)
        XCTAssertEqual(p.currentIndex, 1)
        p.remove(IndexSet([1]))
        XCTAssertNil(p.currentIndex)
    }

    func testReplacePlaceholderWithExpandedPlaylist() {
        let placeholder = Track(url: "https://soundcloud.com/forss/sets/soulhack", title: "Soulhack", isPlaceholder: true)
        let p = Playlist(tracks: tracks(2) + [placeholder] + tracks(1))
        p.setCurrent(3)
        let currentID = p.current!.id
        p.replace(placeholder.id, with: tracks(4))
        XCTAssertEqual(p.count, 7)
        XCTAssertEqual(p.current?.id, currentID)
        XCTAssertEqual(p.currentIndex, 6)
        XCTAssertFalse(p.tracks.contains { $0.isPlaceholder })
    }

    func testCropMoveAndTotals() {
        let p = Playlist(tracks: tracks(5))
        p.selection = IndexSet([1, 3])
        p.crop()
        XCTAssertEqual(p.tracks.map(\.title), ["T1", "T3"])
        p.move(from: IndexSet([1]), to: 0)
        XCTAssertEqual(p.tracks.map(\.title), ["T3", "T1"])
        XCTAssertEqual(p.totalDuration().ms, 120_000)
        XCTAssertEqual(formatTime(p.totalDuration().ms), "2:00")
        XCTAssertEqual(formatTime(3_725_000), "1:02:05")
    }

    func testInsertAtTopKeepsCurrent() {
        let p = Playlist(tracks: tracks(3))
        p.setCurrent(1)
        let id = p.current!.id
        p.insert([Track(url: "soundamp:intro", title: "Intro")], at: 0)
        XCTAssertEqual(p.count, 4)
        XCTAssertEqual(p[0].title, "Intro")
        XCTAssertEqual(p.current?.id, id)
        XCTAssertEqual(p.currentIndex, 2)
    }

    func testDisplayTitleWinampStyle() {
        XCTAssertEqual(Track(url: "x", title: "Flickermood", artist: "Forss").displayTitle, "Forss - Flickermood")
        XCTAssertEqual(Track(url: "x", title: "Flickermood", artist: "Forss", note: "preview").displayTitle, "Forss - Flickermood [preview]")
    }
}

final class TrackWebURLTests: XCTestCase {
    func testOpensThePermalinkNotTheAPI() {
        var t = Track(url: "https://api.soundcloud.com/tracks/293", title: "Flickermood")
        XCTAssertNil(t.webURL, "API link alone has no web page")
        t.permalink = "https://soundcloud.com/forss/flickermood"
        XCTAssertEqual(t.webURL?.absoluteString, "https://soundcloud.com/forss/flickermood")
        XCTAssertEqual(Track(url: "https://soundcloud.com/forss/sets/soulhack", title: "x").webURL?.path, "/forss/sets/soulhack")
        XCTAssertNil(Track(url: "soundamp:intro", title: "Intro").webURL)
        XCTAssertNil(Track(url: "file:///tmp/a.mp3", title: "a").webURL)
    }
}
