import MediaPlayer

/// Publishes the app's queue and routes macOS transport commands to its controller.
@MainActor
final class NowPlaying {
    private let infoCenter = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private var targets: [(MPRemoteCommand, Any)] = []
    private var published: Snapshot?

    private struct Snapshot: Equatable {
        let id: UUID
        let title: String
        let artist: String
        let duration: Double
        let rate: Double
        let index: Int
        let count: Int
    }

    init(player: PlayerController) {
        register(commands.playCommand, player: player) {
            if $0.state == .paused { $0.playButton() }
        }
        register(commands.pauseCommand, player: player) {
            if $0.state == .playing { $0.pauseButton() }
        }
        register(commands.togglePlayPauseCommand, player: player) {
            if $0.state == .playing || $0.state == .paused { $0.playPause() }
        }
        register(commands.nextTrackCommand, player: player) { $0.next() }
        register(commands.previousTrackCommand, player: player) { $0.previous() }
    }

    private func register(_ command: MPRemoteCommand, player: PlayerController,
                          action: @escaping @MainActor (PlayerController) -> Void) {
        command.isEnabled = false
        let target = command.addTarget { [weak player] _ in
            guard let player else { return .commandFailed }
            Task { @MainActor in action(player) }
            return .success
        }
        targets.append((command, target))
    }

    func update(from player: PlayerController, forcePosition: Bool = false) {
        let active = player.state == .playing || player.state == .paused
        let playing = player.state == .playing
        setEnabled(commands.playCommand, active && !playing)
        setEnabled(commands.pauseCommand, playing)
        setEnabled(commands.togglePlayPauseCommand, active)
        setEnabled(commands.nextTrackCommand, active && player.playlist.nextIndex() != nil)
        setEnabled(commands.previousTrackCommand, active &&
                   (player.playlist.previousIndex() != nil || (playing && player.positionMs > 3000)))

        guard player.state != .stopped,
              let track = player.playlist.current, let index = player.playlist.currentIndex else {
            clear()
            return
        }

        let snapshot = Snapshot(id: track.id, title: track.title, artist: track.artist,
                                duration: player.durationMs / 1000, rate: player.nowPlayingRate,
                                index: index, count: player.playlist.count)
        guard published != snapshot || forcePosition else { return }
        published = snapshot
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.positionMs / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.rate,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: snapshot.index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: snapshot.count,
        ]
        if snapshot.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = snapshot.duration }
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = playing ? .playing : .paused
    }

    private func setEnabled(_ command: MPRemoteCommand, _ enabled: Bool) {
        if command.isEnabled != enabled { command.isEnabled = enabled }
    }

    private func clear() {
        guard published != nil else { return }
        published = nil
        infoCenter.playbackState = .stopped
        infoCenter.nowPlayingInfo = nil
    }

    func shutdown() {
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets.removeAll()
        clear()
    }
}
