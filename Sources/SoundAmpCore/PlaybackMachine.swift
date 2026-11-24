import Foundation

public enum PlaybackState: Equatable {
    case stopped, loading, playing, paused
}

/// Turns SoundCloud widget events into player state + what to do next.
///
/// Widget quirk this exists for: at the end of a track the widget sends
/// `pause` and then `finish`. That pause must not count as the user pausing,
/// or the following `finish` would be ignored and the playlist would stop.
public struct PlaybackMachine {
    public enum Event: Equatable {
        /// We asked the widget to load a track.
        case load
        case play
        case pause(positionMs: Double, durationMs: Double)
        case finish
        case progress
        case error
        case stop
        /// Fallback fired a few seconds after an end-of-track pause.
        case endCheckTimeout
    }

    public enum Action: Equatable {
        case none
        /// Playback (re)started: keep the Mac awake, attach the tap, redraw.
        case started
        /// The user paused.
        case paused
        /// Track ended: play the next one.
        case advance
        /// The widget started on its own while we're stopped: pause it again.
        case pauseWidget
        /// The track failed to load.
        case fail
        /// End-of-track pause seen: call back with `.endCheckTimeout` if `finish` never arrives.
        case scheduleEndCheck
    }

    /// A pause this close to the end is the widget finishing, not the user.
    public static let endTolerance: Double = 2500

    public private(set) var state: PlaybackState = .stopped
    public private(set) var sawEndOfTrackPause = false

    public init() {}

    public mutating func handle(_ event: Event) -> Action {
        switch event {
        case .load:
            state = .loading
            sawEndOfTrackPause = false
            return .none

        case .play:
            switch state {
            case .loading, .paused:
                state = .playing
                sawEndOfTrackPause = false
                return .started
            case .stopped: return .pauseWidget
            case .playing: return .none
            }

        case let .pause(position, duration):
            guard state == .playing else { return .none }
            if duration > 0, position >= duration - Self.endTolerance {
                sawEndOfTrackPause = true
                return .scheduleEndCheck
            }
            state = .paused
            return .paused

        case .finish:
            guard state == .playing || state == .paused else { return .none }
            sawEndOfTrackPause = false
            return .advance

        case .progress:
            guard state == .loading else { return .none }
            state = .playing
            return .started

        case .error:
            return state == .loading ? .fail : .none

        case .stop:
            state = .stopped
            sawEndOfTrackPause = false
            return .none

        case .endCheckTimeout:
            guard sawEndOfTrackPause, state == .playing else { return .none }
            sawEndOfTrackPause = false
            return .advance
        }
    }
}
