import AppKit
import SoundAmpCore

/// The hub: playlist + SoundCloud widget playback + link resolution + audio tap
/// (EQ, balance, visualizer). Views observe `PlayerController.didChange`.
@MainActor
final class PlayerController {
    static let didChange = Notification.Name("SoundAmpPlayerDidChange")

    typealias State = PlaybackState

    var nowPlaying: NowPlaying?
    var nowPlayingRate: Double { state == .playing ? activeEffects.speed : 0 }

    let playlist: Playlist
    let player = WidgetPlayer(name: "player")
    let resolver = CollectionResolver()
    let linkResolver = LinkResolver()
    let ring = SampleRing()
    lazy var tap = TapEngine(ring: ring)
    /// Speed / pitch / reverb (slowed + reverb etc.), persisted.
    private(set) var effects = Settings.effects.migratingOldReverbPresets()
    let visualizer = ClassicVisualizer()
    /// Local files (the bundled intro) play here instead of the SoundCloud widget.
    let local = LocalPlayer()
    /// True while the current track is a local file.
    private(set) var currentIsLocal = false
    /// Tracks that played to the end this session (for tests).
    private(set) var finishedCount = 0
    /// Recent widget progress events (arrival time, media position ms) — for measuring speed.
    private(set) var progressLog: [(Date, Double)] = []
    /// One-shot seek once the first SoundCloud track starts (tests: --start-at).
    var pendingStartAtMs: Double?
    private var localTimer: Timer?

    static let introURL = "soundamp:intro"
    static var introFile: URL? {
        if let u = Bundle.main.url(forResource: "llama-intro", withExtension: "mp3") { return u }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Media/llama-intro.mp3")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }
    static func introTrack() -> Track {
        Track(url: introURL, title: "Llama Whippin' Intro", artist: "DJ Mike Llama", durationMs: 5304)
    }

    private var machine = PlaybackMachine()
    var state: State { machine.state }
    private(set) var positionMs: Double = 0
    private(set) var durationMs: Double = 0
    /// Bitrate of the stream the widget is actually playing (from its HLS preset), if known.
    private(set) var streamKbps: Int?
    private(set) var streamPreset: String?
    private(set) var volume = Settings.volume
    private(set) var balance = Settings.balance
    private(set) var eqSliders = Settings.eqSliders
    private(set) var eqPreamp = Settings.eqPreamp
    private(set) var eqOn = Settings.eqOn
    private(set) var tapStatus = "off"
    var autoAttachTap = Settings.autoAttachTap { didSet { Settings.autoAttachTap = autoAttachTap } }
    /// --no-tap: off for this run only (never persisted).
    var tapDisabledForSession = false
    var audioPermission: AudioPermission.Status { AudioPermission.status }
    private var awaitingPermissionReturn = false
    private var lastPermissionAlert: Date?
    private var hintedDeniedThisSession = false

    /// Temporary marquee text ("ADDED 3 TRACKS"), Winamp style.
    private(set) var flashMessage: String?
    private var flashGeneration = 0

    private var loadGeneration = 0
    private var playActivity: NSObjectProtocol?
    private var attachGeneration = 0
    private var lastRingIndex = -1
    private var visSamples = [Float](repeating: 0, count: ClassicVisualizer.samplesNeeded)
    private var saveScheduled = false

    init() {
        playlist = Playlist(tracks: PlaylistStore.load())
        playlist.shuffle = Settings.shuffle
        playlist.repeatAll = Settings.repeatAll
        playlist.onChange = { [weak self] in self?.playlistChanged() }
        Settings.loadVisualizer(visualizer)

        // Every effects chain (tap, local player) gets the current EQ + effects.
        tap.configureChain = { [weak self] chain in self?.configure(chain) }
        local.configureChain = { [weak self] chain in self?.configure(chain) }
        updateSpeedRouting()

        player.onEvent = { [weak self] type, body in self?.handlePlayerEvent(type, body) }
        local.onEvent = { [weak self] event in self?.handleLocalEvent(event) }
        // Back from System Settings? Pick up a freshly granted permission.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
        tap.onReattach = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.tapStatus = self.tap.summary; Log("Tap re-attached after output device change: \(self.tap.summary)")
            case let .failure(e): self.tapStatus = "failed: \(e)"; Log("❌ Tap re-attach failed: \(e)")
            }
            self.changed()
        }
    }

    // MARK: Adding links (paste, drop, dialog)

    /// Parse links out of any text and add them. Returns how many links were found.
    @discardableResult
    func add(text: String, playIfIdle: Bool = true) -> Int {
        let links = PasteParser.links(in: text)
        guard !links.isEmpty else {
            flash("NO SOUNDCLOUD LINK FOUND")
            Log("Paste: no SoundCloud link in \(text.prefix(120).debugDescription)")
            return 0
        }
        add(links: links, playIfIdle: playIfIdle)
        return links.count
    }

    func add(links: [SoundCloudLink], playIfIdle: Bool = true) {
        Log("Adding \(links.count) link(s): " + links.map(\.description).joined(separator: ", "))
        let shouldPlay = playIfIdle && (state == .stopped || state == .paused && playlist.current == nil)
        let firstNew = playlist.count
        var placeholders: [(UUID, SoundCloudLink)] = []
        var newTracks: [Track] = []
        for link in links {
            var t = Track(url: link.canonicalURL, title: link.placeholderTitle, artist: link.placeholderArtist,
                          status: .resolving, isPlaceholder: link.isCollection || isShort(link))
            if link.isCollection || isShort(link) { t.title = "Loading \(link.placeholderTitle)…" }
            newTracks.append(t)
            placeholders.append((t.id, link))
        }
        playlist.append(newTracks)
        let collections = links.filter(\.isCollection).count
        flash(collections > 0 ? "LOADING PLAYLIST…" : "ADDED \(links.count) TRACK\(links.count == 1 ? "" : "S")")

        for (id, link) in placeholders { resolveEntry(id: id, link: link) }

        if shouldPlay, let i = (firstNew..<playlist.count).first(where: { playlist[$0].isPlayable }) {
            play(index: i)
        } else if shouldPlay {
            pendingAutoplayFrom = firstNew
        }
    }

    /// If the first pasted item was a playlist, start playing once it expands.
    private var pendingAutoplayFrom: Int?

    private func isShort(_ l: SoundCloudLink) -> Bool { if case .shortLink = l { return true }; return false }

    private func resolveEntry(id: UUID, link: SoundCloudLink) {
        if case .shortLink = link {
            Task { @MainActor in
                do {
                    let full = try await linkResolver.normalize(link)
                    Log("Short link \(link) → \(full)")
                    playlist.update(id) { t in
                        t.url = full.canonicalURL
                        t.title = full.isCollection ? "Loading \(full.placeholderTitle)…" : full.placeholderTitle
                        t.artist = full.placeholderArtist
                        t.isPlaceholder = full.isCollection
                    }
                    resolveEntry(id: id, link: full)
                    if !full.isCollection { autoplayPendingIfNeeded() }
                } catch {
                    markFailed(id, "\(error)")
                }
            }
            return
        }

        if case let .dailyDrops(user) = link {
            Task { @MainActor in
                do {
                    let tracks = try await linkResolver.dailyDropsTracks(user: user)
                    playlist.replace(id, with: tracks)
                    flash("ADDED \(tracks.count) TRACKS")
                    autoplayPendingIfNeeded()
                    await loadDailyDropsMetadata(for: tracks)
                } catch {
                    markFailed(id, "couldn't load Daily Drops: \(error)")
                }
            }
            return
        }

        if link.isCollection {
            resolver.resolve(link) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(sounds):
                    self.playlist.replace(id, with: sounds.map { $0.makeTrack() })
                    self.flash("ADDED \(sounds.count) TRACKS")
                    self.autoplayPendingIfNeeded()
                case let .failure(e):
                    self.markFailed(id, "couldn't load: \(e)")
                }
            }
            return
        }

        // Single track: quick title via oEmbed, then duration/policy via the resolver widget.
        Task { @MainActor in
            if let info = try? await linkResolver.oEmbed(link) {
                playlist.update(id) { t in
                    if !info.shortTitle.isEmpty { t.title = info.shortTitle }
                    if !info.author.isEmpty { t.artist = info.author }
                    t.soundID = info.id ?? t.soundID
                }
            }
        }
        resolver.resolve(link) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(sounds):
                if let s = sounds.first { self.playlist.update(id) { s.apply(to: &$0) } }
            case let .failure(e):
                // The player may still manage; only mark if oEmbed also never found it.
                self.playlist.update(id) { t in
                    if t.status == .resolving { t.status = .ready; t.note = nil }
                }
                Log("Track details unavailable for \(link): \(e)")
            }
        }
    }

    private func loadDailyDropsMetadata(for tracks: [Track]) async {
        let tracks = tracks.filter(\.isPlayable)
        let linkResolver = self.linkResolver
        for start in stride(from: 0, to: tracks.count, by: 4) {
            await withTaskGroup(of: (Track, OEmbedInfo?).self) { group in
                for track in tracks[start..<min(start + 4, tracks.count)] {
                    guard let id = track.soundID else { continue }
                    group.addTask {
                        (track, try? await linkResolver.oEmbed(.apiTrack(id: id)))
                    }
                }
                for await (track, info) in group {
                    guard let info else { continue }
                    playlist.update(track.id) { current in
                        if current.title == track.title, !info.shortTitle.isEmpty {
                            current.title = info.shortTitle
                        }
                        if current.artist.isEmpty, !info.author.isEmpty {
                            current.artist = info.author
                        }
                    }
                }
            }
        }
    }

    private func autoplayPendingIfNeeded() {
        guard let from = pendingAutoplayFrom, state == .stopped else { return }
        if let i = (min(from, playlist.count)..<playlist.count).first(where: { playlist[$0].isPlayable }) {
            pendingAutoplayFrom = nil
            play(index: i)
        }
    }

    private func markFailed(_ id: UUID, _ why: String) {
        playlist.update(id) { t in
            if t.isPlaceholder, let link = SoundCloudLink.parse(t.url) { t.title = link.placeholderTitle }
            t.isPlaceholder = false
            t.status = .unavailable
            t.note = why
        }
        flash("COULDN'T LOAD LINK")
    }

    // MARK: Transport

    func play(index: Int) {
        guard playlist.tracks.indices.contains(index) else { return }
        let track = playlist[index]
        guard track.isPlayable else { return }
        playlist.setCurrent(index)
        loadGeneration += 1
        let gen = loadGeneration
        _ = machine.handle(.load)
        streamKbps = nil
        streamPreset = nil
        positionMs = 0
        durationMs = track.durationMs ?? 0
        visualizer.reset()
        Log("▶︎ Loading \(index + 1). \(track.displayTitle) — \(track.url)")
        if let file = localFile(for: track) {
            player.pause()
            currentIsLocal = true
            do {
                try local.load(file)
                durationMs = local.durationMs
                streamKbps = local.bitrateKbps
                local.setVolume(volume)
                local.play()
                startLocalTimer()
            } catch {
                Log("❌ Local file failed: \(error)")
                failCurrent("can't open file")
            }
            changed()
            return
        }
        if currentIsLocal { local.stop(); stopLocalTimer(); currentIsLocal = false }
        player.load(track.url, autoPlay: true, token: gen)
        changed()
        // Watchdog: a track that never starts is skipped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.loadGeneration == gen, self.state == .loading else { return }
            Log("⚠️ Track didn't start within 15 s — skipping")
            self.failCurrent("didn't start")
        }
    }

    /// Winamp play button: resume if paused, restart if playing, start if stopped.
    func playButton() {
        switch state {
        case .paused:
            if currentIsLocal { local.play() } else { player.play() }
        case .playing, .loading:
            if let i = playlist.currentIndex { play(index: i) }
        case .stopped:
            if let i = playlist.currentIndex ?? playlist.firstPlayableIndex() { play(index: i) }
        }
    }

    func pauseButton() {
        switch state {
        case .playing: if currentIsLocal { local.pause() } else { player.pause() }
        case .paused: if currentIsLocal { local.play() } else { player.play() }
        default: break
        }
    }

    func playPause() { state == .playing ? pauseButton() : playButton() }

    func stop() {
        loadGeneration += 1
        if currentIsLocal {
            local.stop()
            stopLocalTimer()
        } else if state != .stopped {
            player.pause()
            player.seek(toMilliseconds: 0)
        }
        _ = machine.handle(.stop)
        positionMs = 0
        endActivity()
        changed()
    }

    func next() {
        if let i = playlist.nextIndex() { play(index: i) } else if !playlist.repeatAll { flash("END OF PLAYLIST") }
    }

    func previous() {
        if positionMs > 3000, state == .playing { seek(fraction: 0); return }
        if let i = playlist.previousIndex() { play(index: i) }
    }

    func seek(fraction: Double) {
        guard durationMs > 0, state != .stopped else { return }
        positionMs = max(0, min(1, fraction)) * durationMs
        if currentIsLocal { local.seek(toMilliseconds: positionMs) } else { player.seek(toMilliseconds: positionMs) }
        nowPlaying?.update(from: self, forcePosition: true)
        changed()
    }

    func setVolume(_ v: Int, persist: Bool = true) {
        volume = max(0, min(100, v))
        if persist { Settings.volume = volume }
        player.setVolume(volume)
        local.setVolume(volume)
        changed()
    }

    func setBalance(_ b: Int) {
        balance = max(-100, min(100, abs(b) < 6 ? 0 : b)) // snap to center like Winamp
        Settings.balance = balance
        applyToChains()
        changed()
    }

    func toggleShuffle() {
        playlist.shuffle.toggle()
        Settings.shuffle = playlist.shuffle
        changed()
    }

    func toggleRepeat() {
        playlist.repeatAll.toggle()
        Settings.repeatAll = playlist.repeatAll
        changed()
    }

    // MARK: Equalizer

    func setEqSlider(_ band: Int, _ value: Double) {
        guard (0..<10).contains(band) else { return }
        eqSliders[band] = max(0, min(100, value))
        applyEqualizer()
    }

    func setPreamp(_ value: Double) {
        eqPreamp = max(0, min(100, value))
        applyEqualizer()
    }

    /// The EQ window's ON button is the master switch for the whole chain:
    /// EQ, pitch, reverb, next-door wall and speed. Settings are kept while off.
    func setEqOn(_ on: Bool, persist: Bool = true) {
        eqOn = on
        if persist { Settings.eqOn = on }
        updateSpeedRouting()
        applyToChains()
        flash(on ? "EQ + EFFECTS ON" : "EQ + EFFECTS BYPASSED")
        changed()
    }

    /// What's actually applied: the user's effects, or none while ON is off.
    var activeEffects: EffectSettings { eqOn ? effects : .off }

    func applyPreset(_ p: EqualizerModel.Preset) {
        eqSliders = p.sliderValues
        eqPreamp = p.preampSlider
        applyEqualizer()
    }

    func resetEqualizer() {
        eqSliders = Array(repeating: 50, count: 10)
        eqPreamp = 50
        applyEqualizer()
    }

    private func applyEqualizer() {
        Settings.eqSliders = eqSliders
        Settings.eqPreamp = eqPreamp
        applyToChains()
        changed()
    }

    /// Push EQ, balance and effects into one chain.
    private func configure(_ chain: EffectsChain) {
        let eq = chain.equalizer
        for (i, v) in eqSliders.enumerated() { eq.setGain(band: i, dB: (EqualizerModel.dB(fromSlider: v) * 2).rounded() / 2) }
        eq.setPreamp(dB: (EqualizerModel.dB(fromSlider: eqPreamp) * 2).rounded() / 2)
        eq.isEnabled = eqOn
        eq.balance = Double(balance) / 100
        chain.apply(activeEffects)
    }

    private func applyToChains() {
        if let c = tap.effects { configure(c) }
        if let c = local.chain { configure(c) }
    }

    // MARK: Effects (speed, pitch, reverb)

    /// Apply new effect settings everywhere: speed at the source (SoundCloud's
    /// player / local file), pitch + reverb in the processing chains.
    func setEffects(_ s: EffectSettings, persist: Bool = true) {
        effects = s
        if persist { Settings.effects = s }
        updateSpeedRouting()
        applyToChains()
        // Pitch / reverb on SoundCloud audio run in the tap → needs the permission.
        if s.needsProcessing, !currentIsLocal { audioFeatureUsed("effects") }
        changed()
    }

    /// Where "keep pitch" happens. With the tap running (or for local files), the
    /// source always plays as varispeed and the chain shifts the pitch back with
    /// Signalsmith Stretch — high quality. Without the tap, SoundCloud's player
    /// falls back to WebKit's own (lower quality) time-stretch.
    var keepPitchUsesSignalsmith: Bool { currentIsLocal || tap.isAttached }

    private func updateSpeedRouting() {
        let e = activeEffects
        let webkitStretch = e.keepPitch && !tap.isAttached
        player.setPlaybackRate(e.speed, keepPitch: webkitStretch)
        local.setRate(e.speed)
    }

    func applyEffectsPreset(_ p: EffectSettings.Preset) {
        if !eqOn, p.name != "Off" { eqOn = true; Settings.eqOn = true } // picking an effect means "on"
        setEffects(p.settings)
        flash(p.name == "Off" ? "EFFECTS OFF" : "FX: \(p.name.uppercased())")
    }

    /// Name of the preset the current settings match, if any.
    var effectsPresetName: String? { EffectSettings.presets.first { $0.settings == effects }?.name }

    // MARK: Visualizer

    /// Called ~60×/s by the main window.
    func renderVisualizer() {
        let source = currentIsLocal ? local.ring : ring
        let w = source.writeIndex
        if w != lastRingIndex, state == .playing {
            visSamples.withUnsafeMutableBufferPointer { source.read(latest: $0.count, into: $0.baseAddress!) }
        } else {
            for i in visSamples.indices { visSamples[i] = 0 }
        }
        lastRingIndex = w
        visualizer.render(samples: visSamples)
    }

    func visualizerChanged() {
        Settings.saveVisualizer(visualizer)
        changed()
    }

    // MARK: Messages

    func flash(_ text: String, seconds: Double = 2.5) {
        flashMessage = text
        flashGeneration += 1
        let gen = flashGeneration
        changed()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.flashGeneration == gen else { return }
            self.flashMessage = nil
            self.changed()
        }
    }

    /// The scrolling title: "1. Forss - Flickermood (3:33)".
    var marqueeTitle: String {
        guard let i = playlist.currentIndex else {
            return playlist.isEmpty ? "SOUNDAMP - COPY A SOUNDCLOUD LINK AND PRESS CMD+V" : "SOUNDAMP"
        }
        let t = playlist[i]
        let d = t.durationMs ?? (durationMs > 0 ? durationMs : nil)
        return "\(i + 1). \(t.displayTitle)" + (d.map { " (\(formatTime($0)))" } ?? "")
    }

    // MARK: Widget events

    private func handlePlayerEvent(_ type: String, _ body: [String: Any]) {
        if currentIsLocal, ["play", "pause", "finish", "progress", "error", "sound", "stream"].contains(type) {
            if type == "play" { player.pause() } // keep the widget quiet under the intro
            return
        }
        switch type {
        case "pageReady":
            Log("Player widget page ready (origin \(body["origin"] ?? "?"))")
            player.setVolume(volume)
        case "ready", "loaded":
            player.setVolume(volume)
        case "sound":
            if let t = (body["token"] as? NSNumber)?.intValue, t != loadGeneration { return }
            guard let dict = body["sound"] as? [String: Any], let s = WidgetSound(dict),
                  let id = playlist.current?.id else { return }
            playlist.update(id) { s.apply(to: &$0) }
            if s.durationMs > 0 { durationMs = s.durationMs }
            if s.policy == "BLOCK" { failCurrent("blocked") }
        case "play":
            apply(machine.handle(.play))
        case "pause":
            Log("⏸ widget pause at \(formatTime(positionMs))/\(formatTime(durationMs))")
            apply(machine.handle(.pause(positionMs: positionMs, durationMs: durationMs)))
        case "finish":
            Log("■ Finished \(playlist.current?.displayTitle ?? "")")
            apply(machine.handle(.finish))
        case "progress":
            positionMs = (body["position"] as? NSNumber)?.doubleValue ?? positionMs
            progressLog.append((Date(), positionMs))
            if progressLog.count > 200 { progressLog.removeFirst(100) }
            apply(machine.handle(.progress))
            nowPlaying?.update(from: self)
        case "error":
            Log("⚠️ Player widget error: \(body["detail"] ?? "?")")
            apply(machine.handle(.error))
        case "mediaRate":
            let keep = (body["keepPitch"] as? Bool).map { String($0) } ?? "?"
            Log("Media rate \(String(format: "%.2f", (body["rate"] as? NSNumber)?.doubleValue ?? 0)) (keepPitch \(keep), elements \(body["elements"] ?? 0))")
        case "stream":
            let preset = body["preset"] as? String ?? ""
            streamPreset = preset
            streamKbps = StreamPreset.kbps(preset)
            Log("Stream: \(preset) → \(streamKbps.map { "\($0) kbps" } ?? "unknown bitrate")")
            changed()
        case "jsError":
            Log("⚠️ JS error: \(body["message"] ?? "?")")
        default:
            break
        }
    }

    private func apply(_ action: PlaybackMachine.Action) {
        switch action {
        case .none:
            break
        case .started:
            beginActivity()
            autoAttachOnPlay()
            if let ms = pendingStartAtMs, !currentIsLocal {
                pendingStartAtMs = nil
                Log("Seeking to \(formatTime(ms)) (--start-at)")
                player.seek(toMilliseconds: ms)
            }
            changed()
        case .paused:
            endActivity()
            changed()
        case .pauseWidget:
            player.pause() // e.g. clicked inside the debug widget view while stopped
        case .advance:
            finishedCount += 1
            if let i = playlist.nextIndex() { play(index: i) } else { stop() }
        case .fail:
            failCurrent("unavailable")
        case .scheduleEndCheck:
            // The widget normally sends "finish" right after; advance anyway if it doesn't.
            let gen = loadGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.loadGeneration == gen else { return }
                let a = self.machine.handle(.endCheckTimeout)
                if a == .advance { Log("⚠️ No finish event after end-of-track pause — advancing") }
                self.apply(a)
            }
        }
    }

    // MARK: Local files (intro)

    private func localFile(for t: Track) -> URL? {
        if t.url == Self.introURL { return Self.introFile }
        if t.url.hasPrefix("file://") { return URL(string: t.url) }
        return nil
    }

    private func handleLocalEvent(_ e: LocalPlayer.Event) {
        guard currentIsLocal else { return }
        switch e {
        case .started:
            apply(machine.handle(.play))
        case .paused:
            apply(machine.handle(.pause(positionMs: local.positionMs, durationMs: 0)))
        case .finished:
            stopLocalTimer()
            positionMs = durationMs
            Log("■ Finished \(playlist.current?.displayTitle ?? "")")
            apply(machine.handle(.finish))
        case let .failed(why):
            Log("❌ \(why)")
            failCurrent(why)
        }
    }

    private func startLocalTimer() {
        stopLocalTimer()
        localTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentIsLocal, self.state == .playing else { return }
                self.positionMs = self.local.positionMs
                self.nowPlaying?.update(from: self)
            }
        }
    }

    private func stopLocalTimer() {
        localTimer?.invalidate()
        localTimer = nil
    }

    /// First launch: put the intro at the top of the playlist and play it once.
    func playIntroOnFirstLaunch() {
        guard !Settings.introPlayed, Self.introFile != nil else { return }
        Settings.introPlayed = true
        playIntro()
    }

    /// Play the intro (adds it to the top of the playlist if it isn't there).
    func playIntro() {
        guard Self.introFile != nil else { flash("INTRO NOT FOUND - RUN FETCH-SKINS.SH"); return }
        if let i = playlist.tracks.firstIndex(where: { $0.url == Self.introURL }) {
            play(index: i)
        } else {
            playlist.insert([Self.introTrack()], at: 0)
            play(index: 0)
        }
    }

    private func failCurrent(_ why: String) {
        guard let id = playlist.current?.id else { return }
        playlist.update(id) { $0.status = .unavailable; $0.note = why }
        if let i = playlist.nextIndex() { play(index: i) } else { stop() }
    }

    // MARK: Permission ("System Audio Recording") + tap

    /// On play: attach silently if allowed; ask once (first run) if never asked.
    private func autoAttachOnPlay() {
        guard autoAttachTap, !tapDisabledForSession, !tap.isAttached else { return }
        switch AudioPermission.status {
        case .authorized, .unknown:
            attachTap()
        case .notDetermined:
            if !Settings.askedAudioPermission {
                Settings.askedAudioPermission = true
                requestAudioFeatures("equalizer and visualizer", explicit: false)
            }
        case .denied:
            if !hintedDeniedThisSession {
                hintedDeniedThisSession = true
                flash("EQ/VIS OFF - CLICK VISUALIZER TO ENABLE", seconds: 4)
            }
        }
    }

    /// The user touched a feature that needs the tap (EQ, balance, visualizer):
    /// make sure we have permission — prompt, or explain and open System Settings.
    func requestAudioFeatures(_ feature: String, explicit: Bool = true) {
        guard !tapDisabledForSession else { return }
        let status = AudioPermission.status
        Log("Audio features requested (\(feature)); permission: \(status.rawValue)")
        switch status {
        case .authorized, .unknown:
            if !autoAttachTap { autoAttachTap = true }
            if state == .playing, !tap.isAttached { attachTap() }
        case .notDetermined:
            AudioPermission.request { [weak self] granted in
                guard let self else { return }
                Log("System Audio Recording permission \(granted ? "granted" : "declined")")
                if granted { self.permissionGranted() } else if explicit { self.showPermissionAlert(feature) }
                self.changed()
            }
        case .denied:
            if explicit { showPermissionAlert(feature) }
        }
    }

    /// True when the tap can't run because permission is missing (for UI hints).
    var needsAudioPermission: Bool {
        guard !currentIsLocal, !tap.isAttached, !tapDisabledForSession else { return false }
        let s = AudioPermission.status
        return s == .denied || s == .notDetermined
    }

    /// Called when the user touches EQ / balance / visualizer controls.
    func audioFeatureUsed(_ feature: String) {
        if needsAudioPermission || (state == .playing && !tap.isAttached && !tapDisabledForSession) {
            requestAudioFeatures(feature)
        }
    }

    private func permissionGranted() {
        autoAttachTap = true
        flash("EQ & VISUALIZER ENABLED")
        if state == .playing, !tap.isAttached { attachTap() }
        changed()
    }

    func showPermissionAlert(_ feature: String) {
        if let last = lastPermissionAlert, Date().timeIntervalSince(last) < 10 { return }
        lastPermissionAlert = Date()
        let alert = NSAlert()
        alert.messageText = "Allow SoundAmp to use the \(feature)"
        alert.informativeText = """
        The equalizer, balance and visualizer work on the sound SoundAmp itself plays. \
        macOS calls this "System Audio Recording". Nothing is recorded or saved — the audio is processed live.

        In System Settings › Privacy & Security › Screen & System Audio Recording, turn on SoundAmp \
        under "System Audio Recording Only", then come back to SoundAmp.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            awaitingPermissionReturn = true
            AudioPermission.openSettings()
        }
    }

    private func appBecameActive() {
        guard awaitingPermissionReturn else { return }
        if AudioPermission.status == .authorized {
            awaitingPermissionReturn = false
            Log("System Audio Recording permission now granted")
            permissionGranted()
        }
    }

    /// Restart the app (macOS sometimes only applies a new permission after relaunch).
    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func attachTap() {
        attachGeneration += 1
        tryAttach(attempt: 0, generation: attachGeneration)
    }

    func detachTap() {
        attachGeneration += 1
        tap.detach()
        updateSpeedRouting()
        tapStatus = "off"
        Log("Tap detached")
        changed()
    }

    private func tryAttach(attempt: Int, generation: Int) {
        guard generation == attachGeneration, !tap.isAttached else { return }
        let all = AudioProcess.all()
        let ours = AudioProcess.ourWebKitProcesses(in: all)
        let outputting = ours.filter(\.isRunningOutput)
        let pick = !outputting.isEmpty ? outputting : (attempt >= 6 ? ours : [])
        guard !pick.isEmpty else {
            tapStatus = "looking for WebKit audio…"
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.tryAttach(attempt: attempt + 1, generation: generation)
                }
            } else {
                tapStatus = "no WebKit audio process found"
                Log("❌ No WebKit audio process of ours. HAL clients: " + all.map(\.description).joined(separator: "; "))
            }
            changed()
            return
        }
        do {
            try tap.attach(to: pick)
            updateSpeedRouting() // keep-pitch moves from WebKit to Signalsmith
            visualizer.reset()
            tapStatus = tap.summary
            Log("✅ Tap attached: \(pick.map(\.description).joined(separator: "; ")) — \(tap.summary)")
            _ = ring.takePeak()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.checkTapSignal() }
        } catch {
            tapStatus = "failed: \(error)"
            Log("❌ Tap attach failed: \(error)")
        }
        changed()
    }

    /// Silence while playing = no permission. With mutedWhenTapped that means the
    /// user hears nothing, so detach and let the original audio through.
    private func checkTapSignal() {
        guard tap.isAttached else { return }
        let peak = ring.takePeak()
        if state == .playing && peak == 0 && positionMs > 2000 {
            // Detach first so the original (muted) audio comes back right away.
            tap.detach()
            updateSpeedRouting()
            tapStatus = "silent → detached"
            changed()
            if AudioPermission.status == .authorized {
                // Granted while running: macOS often applies it only after a relaunch.
                Log("❌ Tap delivers silence although permission is granted — needs a relaunch")
                let alert = NSAlert()
                alert.messageText = "Restart SoundAmp to enable the equalizer and visualizer"
                alert.informativeText = "macOS applies the audio recording permission after the app restarts. Playback continues without EQ and visualizer until then."
                alert.addButton(withTitle: "Restart Now")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { relaunch() }
            } else {
                Log("❌ Tap delivers silence — permission \(AudioPermission.status.rawValue)")
                showPermissionAlert("equalizer and visualizer")
            }
        } else if peak > 0 {
            Log("✅ Tap receives audio (peak \(String(format: "%.3f", peak)))")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.checkTapSignal() }
        }
    }

    // MARK: Plumbing

    func shutdown() {
        nowPlaying?.shutdown()
        tap.detach()
        PlaylistStore.save(playlist.tracks)
    }

    private func beginActivity() {
        guard playActivity == nil else { return }
        playActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Playing audio")
    }

    private func endActivity() {
        if let a = playActivity { ProcessInfo.processInfo.endActivity(a) }
        playActivity = nil
    }

    private func playlistChanged() {
        changed()
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            PlaylistStore.save(self.playlist.tracks)
        }
    }

    /// Ask views to redraw (selection changes etc.).
    func notifyChanged() { changed() }

    private func changed() {
        nowPlaying?.update(from: self)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
