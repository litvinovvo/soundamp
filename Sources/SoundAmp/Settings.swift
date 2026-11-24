import Foundation
import SoundAmpCore

/// UserDefaults-backed preferences.
enum Settings {
    /// `--data-dir <path>` (tests): use a throwaway preferences domain and data
    /// folder so test runs never touch the user's settings or playlist.
    static let isolatedDataDir: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }()

    /// Real defaults normally; with `--data-dir`, a plist inside that folder, so a
    /// test copy never reads (or writes) the user's settings — even though it has
    /// the same bundle identifier — yet still keeps them across its own relaunches.
    private static let d: Store = isolatedDataDir.map { FileStore(url: $0.appendingPathComponent("settings.plist")) } ?? DefaultsStore()

    static var volume: Int {
        get { d.object(forKey: "volume") as? Int ?? 75 }
        set { d.set(newValue, forKey: "volume") }
    }
    static var balance: Int {
        get { d.integer(forKey: "balance") }
        set { d.set(newValue, forKey: "balance") }
    }
    static var eqSliders: [Double] {
        get { (d.array(forKey: "eqSliders") as? [Double]).flatMap { $0.count == 10 ? $0 : nil } ?? Array(repeating: 50, count: 10) }
        set { d.set(newValue, forKey: "eqSliders") }
    }
    static var eqPreamp: Double {
        get { d.object(forKey: "eqPreamp") as? Double ?? 50 }
        set { d.set(newValue, forKey: "eqPreamp") }
    }
    static var eqOn: Bool {
        get { d.object(forKey: "eqOn") as? Bool ?? true }
        set { d.set(newValue, forKey: "eqOn") }
    }
    static var shuffle: Bool {
        get { d.bool(forKey: "shuffle") }
        set { d.set(newValue, forKey: "shuffle") }
    }
    static var repeatAll: Bool {
        get { d.bool(forKey: "repeat") }
        set { d.set(newValue, forKey: "repeat") }
    }
    static var skinName: String? {
        get { d.string(forKey: "skin") }
        set { d.set(newValue, forKey: "skin") }
    }
    /// UI scale (1 = classic 275×116 points). Migrates the old "double size" flag.
    static var uiScale: Double {
        get { d.object(forKey: "uiScale") as? Double ?? (d.bool(forKey: "doubleSize") ? 2 : 1) }
        set { d.set(newValue, forKey: "uiScale") }
    }
    static var alwaysOnTop: Bool {
        get { d.bool(forKey: "alwaysOnTop") }
        set { d.set(newValue, forKey: "alwaysOnTop") }
    }
    static var showEqualizer: Bool {
        get { d.object(forKey: "showEqualizer") as? Bool ?? true }
        set { d.set(newValue, forKey: "showEqualizer") }
    }
    static var showPlaylist: Bool {
        get { d.object(forKey: "showPlaylist") as? Bool ?? true }
        set { d.set(newValue, forKey: "showPlaylist") }
    }
    static var timeRemaining: Bool {
        get { d.bool(forKey: "timeRemaining") }
        set { d.set(newValue, forKey: "timeRemaining") }
    }
    static var autoAttachTap: Bool {
        get { d.object(forKey: "autoAttachTap") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoAttachTap") }
    }
    /// We show the system prompt on first play only once; later only on user action.
    static var askedAudioPermission: Bool {
        get { d.bool(forKey: "askedAudioPermission") }
        set { d.set(newValue, forKey: "askedAudioPermission") }
    }
    static var effects: EffectSettings {
        get { (d.object(forKey: "effects") as? Data).flatMap { try? JSONDecoder().decode(EffectSettings.self, from: $0) } ?? EffectSettings() }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "effects") }
    }
    static var introPlayed: Bool {
        get { d.bool(forKey: "introPlayed") }
        set { d.set(newValue, forKey: "introPlayed") }
    }
    static var playlistSegments: (w: Int, h: Int) {
        get { (d.integer(forKey: "plSegW"), max(0, d.object(forKey: "plSegH") as? Int ?? 3)) }
        set { d.set(newValue.w, forKey: "plSegW"); d.set(newValue.h, forKey: "plSegH") }
    }
    static var mainOrigin: CGPoint? {
        get { d.string(forKey: "mainOrigin").map { NSPointFromString($0) } }
        set { d.set(newValue.map { NSStringFromPoint($0) }, forKey: "mainOrigin") }
    }
    static var windowOffsets: [String: CGPoint] {
        get { (d.dictionary(forKey: "windowOffsets") as? [String: String] ?? [:]).mapValues { NSPointFromString($0) } }
        set { d.set(newValue.mapValues { NSStringFromPoint($0) }, forKey: "windowOffsets") }
    }

    static func loadVisualizer(_ v: ClassicVisualizer) {
        func get<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            d.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        v.mode = get("vis.mode", v.mode)
        v.analyzerStyle = get("vis.style", v.analyzerStyle)
        v.bandwidth = get("vis.bands", v.bandwidth)
        v.oscilloscopeStyle = get("vis.osc", v.oscilloscopeStyle)
        v.falloff = get("vis.falloff", v.falloff)
        v.peakFalloff = get("vis.peakFalloff", v.peakFalloff)
        v.peaks = d.object(forKey: "vis.peaks") as? Bool ?? true
    }

    static func saveVisualizer(_ v: ClassicVisualizer) {
        d.set(v.mode.rawValue, forKey: "vis.mode")
        d.set(v.analyzerStyle.rawValue, forKey: "vis.style")
        d.set(v.bandwidth.rawValue, forKey: "vis.bands")
        d.set(v.oscilloscopeStyle.rawValue, forKey: "vis.osc")
        d.set(v.falloff.rawValue, forKey: "vis.falloff")
        d.set(v.peakFalloff.rawValue, forKey: "vis.peakFalloff")
        d.set(v.peaks, forKey: "vis.peaks")
    }

    static let supportDirectory: URL = {
        let url = isolatedDataDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundAmp")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

/// Saves/restores the playlist as JSON in Application Support.
enum PlaylistStore {
    static let url = Settings.supportDirectory.appendingPathComponent("playlist.json")

    static func load() -> [Track] {
        guard let data = try? Data(contentsOf: url),
              let tracks = try? JSONDecoder().decode([Track].self, from: data) else { return [] }
        return tracks.filter { !$0.isPlaceholder }
    }

    static func save(_ tracks: [Track]) {
        let keep = tracks.filter { !$0.isPlaceholder }.map { t -> Track in
            var t = t
            if t.status == .resolving { t.status = .ready }
            return t
        }
        if let data = try? JSONEncoder().encode(keep) { try? data.write(to: url, options: .atomic) }
    }
}

private protocol Store {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

private extension Store {
    func bool(forKey k: String) -> Bool { object(forKey: k) as? Bool ?? false }
    func integer(forKey k: String) -> Int { object(forKey: k) as? Int ?? 0 }
    func string(forKey k: String) -> String? { object(forKey: k) as? String }
    func array(forKey k: String) -> [Any]? { object(forKey: k) as? [Any] }
    func dictionary(forKey k: String) -> [String: Any]? { object(forKey: k) as? [String: Any] }
}

private struct DefaultsStore: Store {
    func object(forKey key: String) -> Any? { UserDefaults.standard.object(forKey: key) }
    func set(_ value: Any?, forKey key: String) { UserDefaults.standard.set(value, forKey: key) }
}

private final class FileStore: Store {
    private let url: URL
    private var values: [String: Any]

    init(url: URL) {
        self.url = url
        values = (NSDictionary(contentsOf: url) as? [String: Any]) ?? [:]
    }

    func object(forKey key: String) -> Any? { values[key] }

    func set(_ value: Any?, forKey key: String) {
        values[key] = value
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        (values as NSDictionary).write(to: url, atomically: true)
    }
}
