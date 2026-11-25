import AppKit
import SoundAmpCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var options = LaunchOptions()

    func applicationDidFinishLaunching(_ notification: Notification) {
        options = LaunchOptions.parse()
        Log("SoundAmp started (pid \(getpid())) — System Audio Recording permission: \(AudioPermission.status.rawValue), asked before: \(Settings.askedAudioPermission)")

        if options.resetPlaylist { PlaylistStore.save([]) }
        Env.skins = SkinManager()
        // Command-line switches apply to this run only — never saved as settings.
        if let s = options.skin, !Env.skins.select(named: s, persist: false) { Log("Unknown skin \(s)") }
        Env.player = PlayerController()
        if !options.headless { Env.player.nowPlaying = NowPlaying(player: Env.player) }
        if let v = options.volume { Env.player.setVolume(v, persist: false) }
        if !options.autoAttachTap { Env.player.tapDisabledForSession = true }
        if options.headless { Env.player.setVolume(0, persist: false) }
        if options.eqOff { Env.player.setEqOn(false, persist: false) }
        if let name = options.effectsPreset {
            if let p = EffectSettings.presets.first(where: { $0.name.lowercased().hasPrefix(name.lowercased()) }) {
                Env.player.setEffects(p.settings, persist: false)
                Log("Effects preset (this run): \(p.name)")
            } else { Log("Unknown effects preset \(name)") }
        }
        Env.menus = MenuBuilder()

        Env.windows = WindowManager(mainView: MainWindowView(frame: .zero),
                                    eqView: EqualizerWindowView(frame: .zero),
                                    playlistView: PlaylistWindowView(frame: .zero),
                                    artworkView: ArtworkWindowView(frame: .zero))
        if options.headless {
            // Windows exist (for snapshots) but are never shown; the widgets live in a
            // 1×1 off-screen window so WebKit keeps running them.
            Env.windows.resizeAll()
            let host = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 2, height: 2), styleMask: [.borderless],
                                backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            for v in [Env.player.player.webView, Env.player.resolver.widget.webView] {
                v.removeFromSuperview()
                v.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
                host.contentView?.addSubview(v)
            }
            host.orderFrontRegardless()
            headlessHost = host
            Log("Headless mode: no windows, volume 0")
        } else {
            Env.windows.hostWebViews([Env.player.player.webView, Env.player.resolver.widget.webView])
            NSApp.mainMenu = Env.menus.buildMainMenu()
            Env.windows.layoutInitially()
            if let s = options.scale { Env.windows.setScale(CGFloat(s), persist: false) }
            NSApp.activate(ignoringOtherApps: true)
        }

        if options.debugConsole { Env.menus.showDebugConsole() }
        if options.fxSelfTest {
            let panel = EffectsPanel()
            Env.menus.effectsPanel = panel
            let e = panel.selfTest()
            Log(String(format: "FX self-test: speed %.2f, pitch %+.1f, reverb %@, mix %.2f", e.speed, e.semitones, e.reverbOn ? "on" : "off", e.reverbMix))
        }
        if !options.noIntro {
            // Give the windows a moment to appear, then whip it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Env.player.playIntroOnFirstLaunch() }
        }
        if let text = options.pasteText {
            // Simulates ⌘V with the given text once the widget page is up. Uses a
            // private pasteboard so the user's clipboard is left alone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Log("--paste: \(text.debugDescription)")
                let pb = NSPasteboard(name: NSPasteboard.Name("dev.soundamp.test-paste.\(getpid())")) // per process: named pasteboards are system-wide
                pb.clearContents()
                pb.setString(text, forType: .string)
                Env.menus.pasteLinks(from: pb)
                pb.releaseGlobally()
            }
        }
        if let s = options.startAt { Env.player.pendingStartAtMs = s * 1000 }
        if let secs = options.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { self.finishRun("--quit-after reached") }
        }
        if let cond = options.quitWhen {
            let started = Date()
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let p = Env.player!
                    let playing = p.state == .playing && Date().timeIntervalSince(started) > 2
                    let met: Bool
                    switch cond {
                    case "finished": met = p.finishedCount > 0 && (playing || p.state == .stopped)
                    // measure real playback speed: media time advanced ÷ wall time over ~4 s
                    case "rate":
                        // Speed = media time ÷ wall time between progress events (stamped on
                        // arrival). A buffering stall can only slow a window down, never speed
                        // it up, so the true rate is the max over 3 s windows of settled playback.
                        var measured = false
                        let log = p.progressLog.filter { $0.1 > 1500 }
                        if playing, let first = log.first, let last = log.last, last.0.timeIntervalSince(first.0) >= 9 {
                            var best = 0.0
                            for (i, a) in log.enumerated() {
                                guard let b = log[i...].first(where: { $0.0.timeIntervalSince(a.0) >= 3 }) else { break }
                                best = max(best, (b.1 - a.1) / 1000 / b.0.timeIntervalSince(a.0))
                            }
                            Log(String(format: "Measured playback rate %.2f (best 3 s window of %.0f s)", best, last.0.timeIntervalSince(first.0)))
                            measured = true
                        }
                        met = measured
                    // a downloaded skin got installed and selected
                    case "skin": met = Env.skins.current.name != SkinManager.baseName
                    // intro (local) finished → a SoundCloud track took over and streams
                    case "handover": met = p.finishedCount > 0 && playing && !p.currentIsLocal && p.streamKbps != nil
                    default: met = playing && p.resolver.pendingCount == 0 && (p.currentIsLocal || p.streamKbps != nil)
                    }
                    if met { timer.invalidate(); self.finishRun("--quit-when \(cond) met") }
                }
            }
        }
    }

    /// Log the outcome (playlist, state), snapshot, quit — used by --quit-after / --quit-when.
    private func finishRun(_ reason: String) {
        guard !finished else { return }
        finished = true
        Log("\(reason), playlist:")
        for (i, t) in Env.player.playlist.tracks.enumerated() {
            Log("   \(i + 1). \(t.displayTitle) [\(t.durationMs.map(formatTime) ?? "?")] status=\(t.status.rawValue) url=\(t.url)")
        }
        Log("state=\(Env.player.state) position=\(formatTime(Env.player.positionMs)) skin=\(Env.skins.current.name) tap=\(Env.player.tapStatus)")
        if let dir = options.snapshotDir { Self.snapshot(to: URL(fileURLWithPath: dir)) }
        NSApp.terminate(nil)
    }
    private var finished = false
    private var headlessHost: NSWindow?

    /// Render each skinned window into a PNG (no screen-recording permission needed).
    static func snapshot(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for w in Env.windows.all where w.isVisible || NSApp.activationPolicy() == .prohibited {
            let v = w.skinView
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let url = dir.appendingPathComponent("\(w.identifierName)-\(Env.skins.current.name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            Log("snapshot: \(url.path)")
        }
        if let view = Env.menus.effectsPanel?.contentView {
            view.layoutSubtreeIfNeeded() // real window size, not the ideal size
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = dir.appendingPathComponent("effects-panel.png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                Log("snapshot: \(url.path)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Env.windows?.savePositions()
        Env.player?.shutdown()
    }

    /// ⌘V anywhere in the app (if no view handled it) adds SoundCloud links.
    @objc func paste(_ sender: Any?) {
        Env.menus.pasteLinks(from: .general)
    }

    /// Dropping a .wsz on the Dock icon / "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where ["wsz", "zip"].contains(url.pathExtension.lowercased()) { Env.skins.install(url) }
    }
}
