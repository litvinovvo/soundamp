import AppKit

/// Command-line switches (handy for smoke tests):
///   --paste <text>          simulate ⌘V with this text (links separated by newlines/spaces)
///   --quit-after <seconds>  log the playlist and quit
///   --volume <0-100>        initial widget volume
///   --skin <name>           e.g. base-2.91, TopazAmp1-2
///   --no-tap                don't auto-attach the audio tap
///   --reset-playlist        start with an empty playlist
///   --debug                 open the debug console
///   --scale <1-4>           UI scale for this run
///   --no-intro              don't play the first-launch intro
///   --quit-when <settled|finished|handover|skin|rate>  quit (and log/snapshot) as soon as playback is
///                           settled (links resolved, playing, bitrate known) or a
///                           track finished and the next one plays; --quit-after = timeout
///   --headless              tests: no windows, no Dock icon, volume 0 (still really
///                           loads, resolves and streams; windows can be snapshotted)
///   --effects <preset>      e.g. "Slowed + Reverb" (this run only)
///   --eq-off                EQ "ON" off for this run (bypasses the whole effects chain)
///   --fx-selftest           drive the Effects panel's controls, log the result, snapshot it
///   --start-at <seconds>    seek the first SoundCloud track here (fast end-of-track tests)
///   --data-dir <dir>        isolated settings + playlist storage (for tests)
///   --snapshot <dir>        save PNGs of the skinned windows before quitting (with --quit-after)
struct LaunchOptions {
    var snapshotDir: String?
    var scale: Double?
    var noIntro = false
    var quitWhen: String?
    var headless = false
    var effectsPreset: String?
    var fxSelfTest = false
    var eqOff = false
    var startAt: Double?
    var pasteText: String?
    var quitAfter: Double?
    var volume: Int?
    var skin: String?
    var autoAttachTap = true
    var resetPlaylist = false
    var debugConsole = false

    static func parse(_ args: [String] = CommandLine.arguments) -> LaunchOptions {
        var o = LaunchOptions()
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--paste": o.pasteText = it.next()
            case "--quit-after": o.quitAfter = it.next().flatMap(Double.init)
            case "--volume": o.volume = it.next().flatMap(Int.init)
            case "--skin": o.skin = it.next()
            case "--no-tap": o.autoAttachTap = false
            case "--reset-playlist": o.resetPlaylist = true
            case "--debug": o.debugConsole = true
            case "--snapshot": o.snapshotDir = it.next()
            case "--scale": o.scale = it.next().flatMap(Double.init)
            case "--no-intro": o.noIntro = true
            case "--quit-when": o.quitWhen = it.next()
            case "--headless": o.headless = true
            case "--effects": o.effectsPreset = it.next()
            case "--fx-selftest": o.fxSelfTest = true
            case "--eq-off": o.eqOff = true
            case "--start-at": o.startAt = it.next().flatMap(Double.init)
            default: break
            }
        }
        return o
    }
}

// Top-level code runs on the main thread; say so to the compiler.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(CommandLine.arguments.contains("--headless") ? .prohibited : .regular)
    app.run()
    withExtendedLifetime(delegate) {}
}
