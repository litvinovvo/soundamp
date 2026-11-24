import AppKit
import SoundAmpCore

/// Finds, loads and switches skins. The base skin (Winamp 2.91) is always the
/// fallback for bitmaps a skin doesn't provide.
@MainActor
final class SkinManager {
    static let didChange = Notification.Name("SoundAmpSkinDidChange")
    static let baseName = "base-2.91"

    struct Entry: Equatable {
        let name: String
        let url: URL
        let isBundled: Bool
    }

    private(set) var current: Skin
    private(set) var base: Skin
    private(set) var entries: [Entry] = []

    static let userSkinsDirectory: URL = {
        let url = Settings.supportDirectory.appendingPathComponent("Skins")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Bundled skins live in SoundAmp.app/Contents/Resources/Skins; when run from
    /// `swift run`, fall back to the repo's Skins/ folder.
    static var bundledSkinsDirectory: URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Skins"),
           FileManager.default.fileExists(atPath: r.path) { return r }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Skins")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    init() {
        let found = Self.scan()
        entries = found
        let baseURL = found.first { $0.name == Self.baseName }?.url
        if let baseURL, let b = try? Skin(contentsOf: baseURL, fallback: nil) {
            base = b
        } else {
            Log("⚠️ Base skin not found — run scripts/fetch-skins.sh. Using an empty skin.")
            base = try! Skin(name: "empty", archive: ZipArchive(data: SkinManager.emptyZip), fallback: nil)
        }
        current = base
        if let name = Settings.skinName, name != Self.baseName, let e = found.first(where: { $0.name == name }) {
            _ = select(e)
        }
    }

    static func scan() -> [Entry] {
        var out: [Entry] = []
        let fm = FileManager.default
        // User skins first, so a downloaded/installed skin wins over a bundled one with the same name.
        for (dir, bundled) in [(userSkinsDirectory, false), (bundledSkinsDirectory, true)] {
            guard let dir, let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where ["wsz", "zip"].contains(f.pathExtension.lowercased()) {
                let name = f.deletingPathExtension().lastPathComponent
                if !out.contains(where: { $0.name == name }) { out.append(Entry(name: name, url: f, isBundled: bundled)) }
            }
        }
        return out.sorted { a, b in
            if a.name == baseName { return true }
            if b.name == baseName { return false }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    @discardableResult
    func select(_ entry: Entry, persist: Bool = true) -> Bool {
        do {
            current = entry.name == Self.baseName ? base : try Skin(contentsOf: entry.url, fallback: base)
            if persist { Settings.skinName = entry.name }
            Log("Skin: \(entry.name) (\(entry.isBundled ? "bundled" : "installed: \(entry.url.path)"))")
            NotificationCenter.default.post(name: Self.didChange, object: self)
            return true
        } catch {
            Log("❌ Skin \(entry.name) failed to load: \(error)")
            return false
        }
    }

    func select(named name: String, persist: Bool = true) -> Bool {
        guard let e = entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
        return select(e, persist: persist)
    }

    /// Copy a .wsz into the user skins folder and switch to it.
    @discardableResult
    func install(_ url: URL) -> Bool {
        let dest = Self.userSkinsDirectory.appendingPathComponent(url.lastPathComponent)
        do {
            if url.standardizedFileURL != dest.standardizedFileURL {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
            }
            entries = Self.scan()
            guard let e = entries.first(where: { $0.url.standardizedFileURL == dest.standardizedFileURL }) else { return false }
            return select(e)
        } catch {
            Log("❌ Couldn't install skin \(url.lastPathComponent): \(error)")
            return false
        }
    }

    func rescan() { entries = Self.scan() }

    /// Download a classic skin from a link, check it really is one, install and switch to it.
    func download(_ link: SkinLink) {
        Env.player.flash("DOWNLOADING SKIN…", seconds: 10)
        Log("Downloading skin \(link.fileName) from \(link.download.absoluteString)")
        Task { @MainActor in
            do {
                var req = URLRequest(url: link.download, timeoutInterval: 30)
                req.setValue("SoundAmp/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
                let (data, resp) = try await URLSession.shared.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw DownloadError.http(status) }
                guard data.count <= 20 * 1024 * 1024 else { throw DownloadError.tooBig }
                // Validate before installing: must be a zip that loads as a classic skin.
                let skin = try Skin(name: link.fileName, archive: ZipArchive(data: data), fallback: base)
                guard skin.hasOwn(.main) else { throw Skin.LoadError.noMainBitmap }
                let dest = Self.userSkinsDirectory.appendingPathComponent(link.fileName)
                try data.write(to: dest, options: .atomic)
                Log("Installed skin \(dest.lastPathComponent) (\(data.count / 1024) KB)")
                entries = Self.scan()
                if let e = entries.first(where: { $0.url.standardizedFileURL == dest.standardizedFileURL }) {
                    select(e)
                    Env.player.flash("SKIN: \(e.name.uppercased())")
                }
            } catch {
                Log("❌ Skin download failed (\(link.download.absoluteString)): \(error)")
                Env.player.flash(error is ZipArchive.ZipError || error is Skin.LoadError ? "NOT A CLASSIC WINAMP SKIN" : "SKIN DOWNLOAD FAILED")
            }
        }
    }

    enum DownloadError: Error, CustomStringConvertible {
        case http(Int), tooBig
        var description: String {
            switch self {
            case let .http(s): return "HTTP \(s)"
            case .tooBig: return "file too large for a skin"
            }
        }
    }

    /// A valid zip with one 1×1 main.bmp is overkill; an empty archive + no fallback
    /// throws, so this holds a tiny stored PNG named main.png.
    private static let emptyZip: Data = {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        var d = Data()
        func u16(_ v: Int) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8 & 0xFF)) }
        func u32(_ v: Int) { u16(v & 0xFFFF); u16(v >> 16 & 0xFFFF) }
        let name = Data("main.png".utf8)
        // local header
        u32(0x0403_4B50); u16(10); u16(0); u16(0); u16(0); u16(0); u32(0); u32(png.count); u32(png.count); u16(name.count); u16(0)
        d.append(name); d.append(png)
        let cd = d.count
        u32(0x0201_4B50); u16(20); u16(10); u16(0); u16(0); u16(0); u16(0); u32(0); u32(png.count); u32(png.count)
        u16(name.count); u16(0); u16(0); u16(0); u16(0); u32(0); u32(0)
        d.append(name)
        let cdSize = d.count - cd
        u32(0x0605_4B50); u16(0); u16(0); u16(1); u16(1); u32(cdSize); u32(cd); u16(0)
        return d
    }()
}
