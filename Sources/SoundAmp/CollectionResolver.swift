import Foundation
import SoundAmpCore

/// A sound as reported by the widget's getSounds().
struct WidgetSound {
    let id: Int
    let title: String
    let artist: String
    let durationMs: Double
    let artworkURL: String
    let permalink: String
    let policy: String

    init?(_ dict: [String: Any]) {
        guard let id = (dict["id"] as? NSNumber)?.intValue, id > 0 else { return nil }
        self.id = id
        title = dict["title"] as? String ?? ""
        artist = dict["artist"] as? String ?? ""
        durationMs = (dict["duration"] as? NSNumber)?.doubleValue ?? 0
        artworkURL = dict["artwork"] as? String ?? ""
        permalink = dict["permalink"] as? String ?? ""
        policy = dict["policy"] as? String ?? ""
    }

    var isComplete: Bool { !title.isEmpty }

    func makeTrack() -> Track {
        var t = Track(url: SoundCloudLink.apiTrack(id: id).canonicalURL,
                      title: title.isEmpty ? "Track \(id)" : title, artist: artist,
                      durationMs: durationMs > 0 ? durationMs : nil, soundID: id,
                      permalink: permalink.isEmpty ? nil : permalink)
        apply(to: &t)
        return t
    }

    /// Copy widget metadata onto an existing track.
    func apply(to t: inout Track) {
        if !title.isEmpty { t.title = title }
        if !artist.isEmpty { t.artist = artist }
        if durationMs > 0 { t.durationMs = durationMs }
        t.soundID = id
        if !artworkURL.isEmpty { t.artworkURL = artworkURL }
        if !permalink.isEmpty { t.permalink = permalink }
        switch policy {
        case "BLOCK": t.status = .unavailable; t.note = "blocked"
        case "SNIP": t.status = .ready; t.note = "preview"
        default: if t.status == .resolving { t.status = .ready }
        }
    }
}

/// Expands playlists / user pages into tracks (and fetches durations for single
/// tracks) using a second, silent widget instance. Jobs run one at a time.
@MainActor
final class CollectionResolver {
    let widget = WidgetPlayer(name: "resolver")

    private struct Job {
        let link: SoundCloudLink
        let completion: (Result<[WidgetSound], Error>) -> Void
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private var queue: [Job] = []
    private var active: Job?
    private var lastSounds: [WidgetSound] = []
    private var stablePolls = 0
    private var polls = 0
    private var generation = 0

    init() {
        widget.onEvent = { [weak self] type, body in self?.handle(type, body) }
    }

    var pendingCount: Int { queue.count + (active == nil ? 0 : 1) }

    func resolve(_ link: SoundCloudLink, completion: @escaping (Result<[WidgetSound], Error>) -> Void) {
        queue.append(Job(link: link, completion: completion))
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        guard active == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        active = job
        lastSounds = []
        stablePolls = 0
        polls = 0
        generation += 1
        let gen = generation
        Log("Resolver: loading \(job.link)")
        widget.load(job.link.canonicalURL, autoPlay: false, token: gen)
        // Overall timeout: accept whatever we have, or fail.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.generation == gen, self.active != nil else { return }
            self.finish(self.lastSounds.isEmpty ? .failure(Failure(description: "timed out (private, deleted or not embeddable?)"))
                                                 : .success(self.lastSounds))
        }
    }

    private func handle(_ type: String, _ body: [String: Any]) {
        guard active != nil else { return }
        // Ignore late replies that belong to a previous job.
        if let t = (body["token"] as? NSNumber)?.intValue, t != generation { return }
        switch type {
        case "ready", "loaded":
            poll()
        case "sounds":
            let list = (body["sounds"] as? [[String: Any]] ?? []).compactMap(WidgetSound.init)
            if !list.isEmpty && list.count == lastSounds.count { stablePolls += 1 } else { stablePolls = 0 }
            lastSounds = list
            let complete = !list.isEmpty && list.allSatisfy(\.isComplete)
            // Done when every sound has details, or the list stopped growing for a while.
            if complete || (stablePolls >= 4 && !list.isEmpty) || polls >= 15 {
                finish(list.isEmpty ? .failure(Failure(description: "no playable sounds")) : .success(list))
            } else {
                let gen = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.poll()
                }
            }
        case "error":
            finish(.failure(Failure(description: "widget error \(body["detail"] ?? "")")))
        default:
            break
        }
    }

    private func poll() {
        polls += 1
        widget.requestSounds()
    }

    private func finish(_ result: Result<[WidgetSound], Error>) {
        guard let job = active else { return }
        active = nil
        generation += 1
        switch result {
        case let .success(s): Log("Resolver: \(job.link) → \(s.count) sound(s), \(s.filter(\.isComplete).count) with details")
        case let .failure(e): Log("Resolver: \(job.link) failed: \(e)")
        }
        job.completion(result)
        startNextIfIdle()
    }
}
