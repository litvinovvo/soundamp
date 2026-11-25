import Foundation

public struct Track: Identifiable, Equatable, Codable {
    public enum Status: String, Codable { case resolving, ready, unavailable }

    public var id: UUID
    /// What the widget loads: a permalink or https://api.soundcloud.com/tracks/{id}.
    public var url: String
    public var title: String
    public var artist: String
    public var durationMs: Double?
    public var soundID: Int?
    public var permalink: String?
    public var artworkURL: String?
    public var status: Status
    /// "preview only", "blocked", error text…
    public var note: String?
    /// For placeholder rows of a collection being expanded.
    public var isPlaceholder: Bool

    public init(id: UUID = UUID(), url: String, title: String, artist: String = "", durationMs: Double? = nil,
                soundID: Int? = nil, permalink: String? = nil, status: Status = .ready, note: String? = nil,
                isPlaceholder: Bool = false) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.durationMs = durationMs
        self.soundID = soundID
        self.permalink = permalink
        self.status = status
        self.note = note
        self.isPlaceholder = isPlaceholder
    }

    /// "Forss - Flickermood", Winamp style.
    public var displayTitle: String {
        let base = artist.isEmpty ? title : "\(artist) - \(title)"
        return note.map { "\(base) [\($0)]" } ?? base
    }

    public var isPlayable: Bool { status != .unavailable && !isPlaceholder }

    /// The track's SoundCloud web page, if known. API links (api.soundcloud.com/…)
    /// and local files have no page to open, so they give nil.
    public var webURL: URL? {
        for candidate in [permalink, url].compactMap({ $0 }) {
            guard let u = URL(string: candidate), let host = u.host?.lowercased(),
                  u.scheme == "https" || u.scheme == "http" else { continue }
            if host == "soundcloud.com" || host == "www.soundcloud.com" || host == "m.soundcloud.com" { return u }
        }
        return nil
    }
}

/// Winamp-style playlist: ordered tracks, current item, selection, shuffle/repeat.
public final class Playlist {
    public private(set) var tracks: [Track] = []
    public private(set) var currentIndex: Int?
    public var selection = IndexSet()
    public var shuffle = false { didSet { if shuffle != oldValue { rebuildShuffleOrder() } } }
    public var repeatAll = false
    public var onChange: (() -> Void)?

    private var shuffleOrder: [UUID] = []
    private var rng: RandomNumberGenerator

    public init(tracks: [Track] = [], rng: RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.tracks = tracks
        self.rng = rng
        rebuildShuffleOrder()
    }

    public var count: Int { tracks.count }
    public var isEmpty: Bool { tracks.isEmpty }
    public var current: Track? { currentIndex.map { tracks[$0] } }
    public subscript(i: Int) -> Track { tracks[i] }
    public func index(of id: UUID) -> Int? { tracks.firstIndex { $0.id == id } }

    // MARK: Editing

    @discardableResult
    public func append(_ new: [Track]) -> Range<Int> {
        let start = tracks.count
        tracks.append(contentsOf: new)
        rebuildShuffleOrder()
        changed()
        return start..<tracks.count
    }

    /// Insert tracks at a position, keeping the current item pointing at the same track.
    public func insert(_ new: [Track], at index: Int) {
        let i = max(0, min(index, tracks.count))
        tracks.insert(contentsOf: new, at: i)
        if let c = currentIndex, c >= i { currentIndex = c + new.count }
        selection = IndexSet()
        rebuildShuffleOrder()
        changed()
    }

    public func update(_ id: UUID, _ body: (inout Track) -> Void) {
        guard let i = index(of: id) else { return }
        body(&tracks[i])
        changed()
    }

    /// Replace one (placeholder) row with many tracks, keeping position and the current item.
    public func replace(_ id: UUID, with new: [Track]) {
        guard let i = index(of: id) else { return }
        let wasCurrent = currentIndex == i
        tracks.replaceSubrange(i...i, with: new)
        if let c = currentIndex {
            if wasCurrent { currentIndex = new.isEmpty ? nil : i }
            else if c > i { currentIndex = c + new.count - 1 }
        }
        selection = IndexSet()
        rebuildShuffleOrder()
        changed()
    }

    public func remove(_ indices: IndexSet) {
        guard !indices.isEmpty else { return }
        if let c = currentIndex {
            if indices.contains(c) { currentIndex = nil }
            else { currentIndex = c - indices.count(in: 0..<c) }
        }
        for i in indices.reversed() where i < tracks.count { tracks.remove(at: i) }
        selection = IndexSet()
        rebuildShuffleOrder()
        changed()
    }

    public func removeAll() {
        tracks.removeAll()
        currentIndex = nil
        selection = IndexSet()
        rebuildShuffleOrder()
        changed()
    }

    /// Keep only the selected tracks.
    public func crop() {
        remove(IndexSet(integersIn: 0..<tracks.count).subtracting(selection))
    }

    public func move(from source: IndexSet, to destination: Int) {
        let currentID = current?.id
        let moving = source.map { tracks[$0] }
        var dest = destination - source.count(in: 0..<destination)
        for i in source.reversed() { tracks.remove(at: i) }
        dest = max(0, min(dest, tracks.count))
        tracks.insert(contentsOf: moving, at: dest)
        currentIndex = currentID.flatMap(index(of:))
        selection = IndexSet(integersIn: dest..<(dest + moving.count))
        changed()
    }

    public func sort(by key: (Track) -> String) {
        let currentID = current?.id
        tracks.sort { key($0).localizedCaseInsensitiveCompare(key($1)) == .orderedAscending }
        currentIndex = currentID.flatMap(index(of:))
        selection = IndexSet()
        changed()
    }

    public func reverse() {
        let currentID = current?.id
        tracks.reverse()
        currentIndex = currentID.flatMap(index(of:))
        changed()
    }

    // MARK: Navigation

    public func setCurrent(_ i: Int?) {
        currentIndex = i.flatMap { tracks.indices.contains($0) ? $0 : nil }
        changed()
    }

    /// Next playable index. `auto` = called because a track finished.
    public func nextIndex() -> Int? {
        guard !tracks.isEmpty else { return nil }
        let order = playOrder
        let pos = currentIndex.flatMap { c in order.firstIndex(of: tracks[c].id) } ?? -1
        for step in 1...order.count {
            var p = pos + step
            if p >= order.count {
                guard repeatAll else { return nil }
                p %= order.count
            }
            if let i = index(of: order[p]), tracks[i].isPlayable { return i }
        }
        return nil
    }

    public func previousIndex() -> Int? {
        guard !tracks.isEmpty else { return nil }
        let order = playOrder
        let pos = currentIndex.flatMap { c in order.firstIndex(of: tracks[c].id) } ?? order.count
        for step in 1...order.count {
            var p = pos - step
            if p < 0 {
                guard repeatAll else { return nil }
                p = (p % order.count + order.count) % order.count
            }
            if let i = index(of: order[p]), tracks[i].isPlayable { return i }
        }
        return nil
    }

    /// First playable index, honoring shuffle.
    public func firstPlayableIndex() -> Int? {
        playOrder.lazy.compactMap { self.index(of: $0) }.first { self.tracks[$0].isPlayable }
    }

    // MARK: Totals

    /// Total duration in ms of the given indices (all if nil), plus whether any were unknown.
    public func totalDuration(of indices: IndexSet? = nil) -> (ms: Double, complete: Bool) {
        let set = indices ?? IndexSet(integersIn: 0..<tracks.count)
        var ms = 0.0, complete = true
        for i in set where i < tracks.count {
            if let d = tracks[i].durationMs { ms += d } else { complete = false }
        }
        return (ms, complete)
    }

    // MARK: Internals

    private var playOrder: [UUID] { shuffle ? shuffleOrder : tracks.map(\.id) }

    private func rebuildShuffleOrder() {
        var ids = tracks.map(\.id)
        ids.shuffle(using: &rng)
        // Keep the current track first so shuffle continues from it.
        if let c = current?.id, let i = ids.firstIndex(of: c) { ids.swapAt(0, i) }
        shuffleOrder = ids
    }

    private func changed() { onChange?() }
}

/// Seedable RNG for deterministic tests.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public func formatTime(_ ms: Double) -> String {
    let total = max(0, Int(ms / 1000))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
