import XCTest
@testable import SoundAmpCore

final class PlaybackMachineTests: XCTestCase {
    /// Exact sequence the SoundCloud widget sends at the end of a 40 s track
    /// (recorded with a probe): play, progress…, pause, finish.
    func testEndOfTrackPauseThenFinishAdvances() {
        var m = PlaybackMachine()
        XCTAssertEqual(m.handle(.load), .none)
        XCTAssertEqual(m.handle(.play), .started)
        XCTAssertEqual(m.handle(.progress), .none)
        XCTAssertEqual(m.handle(.pause(positionMs: 39_545, durationMs: 40_228)), .scheduleEndCheck)
        XCTAssertEqual(m.state, .playing, "end-of-track pause is not a user pause")
        XCTAssertEqual(m.handle(.finish), .advance)
        // The fallback timer firing later must not advance a second time.
        XCTAssertEqual(m.handle(.endCheckTimeout), .none)
    }

    func testEndOfTrackWithoutFinishEventStillAdvances() {
        var m = PlaybackMachine()
        _ = m.handle(.load)
        _ = m.handle(.play)
        XCTAssertEqual(m.handle(.pause(positionMs: 40_000, durationMs: 40_228)), .scheduleEndCheck)
        XCTAssertEqual(m.handle(.endCheckTimeout), .advance)
    }

    func testUserPauseMidTrackAndResume() {
        var m = PlaybackMachine()
        _ = m.handle(.load)
        _ = m.handle(.play)
        XCTAssertEqual(m.handle(.pause(positionMs: 12_000, durationMs: 40_228)), .paused)
        XCTAssertEqual(m.state, .paused)
        XCTAssertEqual(m.handle(.play), .started)
        XCTAssertEqual(m.state, .playing)
    }

    func testFinishWhilePausedStillAdvances() {
        // If an end-of-track pause got classified as a user pause (e.g. duration unknown), finish must still advance.
        var m = PlaybackMachine()
        _ = m.handle(.load)
        _ = m.handle(.play)
        XCTAssertEqual(m.handle(.pause(positionMs: 39_000, durationMs: 0)), .paused)
        XCTAssertEqual(m.handle(.finish), .advance)
    }

    func testStoppedIgnoresFinishAndRepausesStrayPlay() {
        var m = PlaybackMachine()
        _ = m.handle(.load)
        _ = m.handle(.play)
        _ = m.handle(.stop)
        XCTAssertEqual(m.handle(.finish), .none)
        XCTAssertEqual(m.handle(.play), .pauseWidget)
        XCTAssertEqual(m.state, .stopped)
    }

    func testLoadingProgressStartsAndErrorFails() {
        var m = PlaybackMachine()
        _ = m.handle(.load)
        XCTAssertEqual(m.handle(.progress), .started)
        var n = PlaybackMachine()
        _ = n.handle(.load)
        XCTAssertEqual(n.handle(.error), .fail)
        XCTAssertEqual(m.handle(.error), .none, "errors after playback started are ignored")
    }

    func testNewLoadCancelsPendingEndCheck() {
        var m = PlaybackMachine()
        _ = m.handle(.load)
        _ = m.handle(.play)
        _ = m.handle(.pause(positionMs: 40_000, durationMs: 40_228))
        _ = m.handle(.load) // user picked another track
        XCTAssertEqual(m.handle(.endCheckTimeout), .none)
    }
}

final class StreamPresetTests: XCTestCase {
    func testBitrateFromHLSPreset() {
        XCTAssertEqual(StreamPreset.kbps("aac_160k"), 160) // seen live from the widget
        XCTAssertEqual(StreamPreset.kbps("aac_256k"), 256)
        XCTAssertEqual(StreamPreset.kbps("mp3_128"), 128)
        XCTAssertEqual(StreamPreset.kbps("mp3_0_0"), 128)
        XCTAssertEqual(StreamPreset.kbps("opus_0_0"), 64)
        XCTAssertEqual(StreamPreset.kbps("opus_64k"), 64)
        XCTAssertNil(StreamPreset.kbps("abr_sq"))
    }
}
