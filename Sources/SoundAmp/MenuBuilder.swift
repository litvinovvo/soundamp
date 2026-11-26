import AppKit
import SoundAmpCore
import UniformTypeIdentifiers

/// NSMenu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], checked: Bool = false, enabled: Bool = true,
         _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers
        state = checked ? .on : .off
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

/// All menus (options, visualizer, skins, EQ presets, playlist buttons, menu bar)
/// and the small dialogs.
@MainActor
final class MenuBuilder: NSObject, NSMenuDelegate {
    var player: PlayerController { Env.player }
    var debugConsole: DebugConsole?
    var effectsPanel: EffectsPanel?

    func showEffects() {
        if effectsPanel == nil { effectsPanel = EffectsPanel() }
        effectsPanel?.show()
    }

    /// Effect presets + the panel.
    func effectsMenu() -> NSMenu {
        let p = player
        let m = NSMenu()
        let current = p.effectsPresetName
        for preset in EffectSettings.presets {
            m.addItem(ActionItem(preset.name, key: "", checked: current == preset.name) { p.applyEffectsPreset(preset) })
        }
        m.addItem(.separator())
        m.addItem(ActionItem("Effects…", key: "e", modifiers: [.command, .shift]) { [weak self] in self?.showEffects() })
        return m
    }

    // MARK: Paste / add

    /// Reads SoundCloud links (or a skin file) from a pasteboard. Returns links found.
    @discardableResult
    func pasteLinks(from pb: NSPasteboard) -> Int {
        var texts: [String] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            if let skinFile = urls.first(where: { $0.isFileURL && ["wsz", "zip"].contains($0.pathExtension.lowercased()) }) {
                Env.skins.install(skinFile)
                return 0
            }
            texts += urls.filter { !$0.isFileURL }.map(\.absoluteString)
        }
        if let s = pb.string(forType: .string) { texts.append(s) }
        if let html = pb.string(forType: .html) { texts.append(html) }
        let joined = texts.joined(separator: "\n")
        guard !joined.isEmpty else {
            player.flash("CLIPBOARD IS EMPTY")
            return 0
        }
        // Links to classic skins (.wsz, Winamp Skin Museum pages) → download & install.
        let skins = SkinLink.links(in: joined)
        for s in skins { Env.skins.download(s) }
        if !PasteParser.links(in: joined).isEmpty { return player.add(text: joined) + skins.count }
        if skins.isEmpty {
            if joined.lowercased().contains(".wal") { player.flash("MODERN SKINS (.WAL) AREN'T SUPPORTED"); return 0 }
            return player.add(text: joined) // shows "no SoundCloud link found"
        }
        return skins.count
    }

    func showAddLinkDialog() {
        let alert = NSAlert()
        alert.messageText = "Add SoundCloud link"
        alert.informativeText = "Paste a track, playlist, album, profile or likes link (several are fine)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://soundcloud.com/artist/track"
        if let clip = NSPasteboard.general.string(forType: .string), !PasteParser.links(in: clip).isEmpty {
            field.stringValue = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            player.add(text: field.stringValue)
        }
    }

    func copyLinks(selectedOnly: Bool) {
        let pl = player.playlist
        let idx = selectedOnly && !pl.selection.isEmpty ? Array(pl.selection) : Array(pl.tracks.indices)
        let links = idx.map { pl[$0].webURL?.absoluteString ?? pl[$0].url }
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
        player.flash("COPIED \(links.count) LINK\(links.count == 1 ? "" : "S")")
    }

    // MARK: Options menu (title bar "O" button / right click)

    func optionsMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(ActionItem("Add SoundCloud Link…", key: "l") { [weak self] in self?.showAddLinkDialog() })
        m.addItem(ActionItem("Paste Link", key: "v") { [weak self] in self?.pasteLinks(from: .general) })
        m.addItem(ActionItem("Open Current Track on SoundCloud", key: "o", modifiers: [.command, .shift]) { [weak self] in
            self?.openOnSoundCloud()
        })
        m.addItem(.separator())
        m.addItem(submenu("Skins", skinsMenu()))
        m.addItem(submenu("Visualization", visualizerMenu()))
        m.addItem(submenu("Effects (Slowed + Reverb…)", effectsMenu()))
        m.addItem(.separator())
        m.addItem(ActionItem("Playlist Editor", key: "e", modifiers: [.option], checked: Env.windows.playlist.isVisible) {
            Env.windows.toggle(Env.windows.playlist)
        })
        m.addItem(ActionItem("Equalizer", key: "g", modifiers: [.option], checked: Env.windows.equalizer.isVisible) {
            Env.windows.toggle(Env.windows.equalizer)
        })
        m.addItem(ActionItem("Artwork", key: "a", modifiers: [.option], checked: Env.windows.artwork.isVisible) {
            Env.windows.toggle(Env.windows.artwork)
        })
        m.addItem(submenu("Size", sizeMenu()))
        m.addItem(ActionItem("Always On Top", key: "t", checked: Settings.alwaysOnTop) { Env.windows.toggleAlwaysOnTop() })
        m.addItem(ActionItem("Time Remaining", key: "", checked: Settings.timeRemaining) {
            Settings.timeRemaining.toggle()
            Env.player.notifyChanged()
        })
        m.addItem(.separator())
        m.addItem(submenu("Playback", playbackMenu()))
        m.addItem(submenu("Audio Tap (EQ / Visualizer)", tapMenu()))
        m.addItem(ActionItem("Debug Console", key: "") { [weak self] in self?.showDebugConsole() })
        m.addItem(.separator())
        m.addItem(ActionItem("About SoundAmp", key: "") { [weak self] in self?.showAbout() })
        m.addItem(ActionItem("Play the Llama Intro", key: "") { Env.player.playIntro() })
        m.addItem(ActionItem("Quit", key: "q") { NSApp.terminate(nil) })
        return m
    }

    /// UI scale: Winamp's double size plus finer steps, ⌘+ / ⌘- / ⌘0, pinch on the trackpad.
    func sizeMenu() -> NSMenu {
        let w = Env.windows!
        let m = NSMenu()
        m.addItem(ActionItem("Zoom In", key: "=", enabled: w.scale < WindowManager.maxScale) { w.zoomIn() })
        m.addItem(ActionItem("Zoom Out", key: "-", enabled: w.scale > 1) { w.zoomOut() })
        m.addItem(ActionItem("Actual Size (100%)", key: "0") { w.setScale(1) })
        m.addItem(ActionItem("Double Size", key: "d", checked: w.scale == 2) { w.toggleDoubleSize() })
        m.addItem(.separator())
        for s in WindowManager.scaleSteps where s <= WindowManager.maxScale {
            m.addItem(ActionItem("\(Int(s * 100))%", key: "", checked: abs(w.scale - s) < 0.01) { w.setScale(s) })
        }
        return m
    }

    func playbackMenu() -> NSMenu {
        let p = player
        let m = NSMenu()
        m.addItem(ActionItem("Previous  (Z)", key: "") { p.previous() })
        m.addItem(ActionItem("Play  (X)", key: "") { p.playButton() })
        m.addItem(ActionItem("Pause  (C / Space)", key: "") { p.pauseButton() })
        m.addItem(ActionItem("Stop  (V)", key: "") { p.stop() })
        m.addItem(ActionItem("Next  (B)", key: "") { p.next() })
        m.addItem(.separator())
        m.addItem(ActionItem("Shuffle  (S)", key: "", checked: p.playlist.shuffle) { p.toggleShuffle() })
        m.addItem(ActionItem("Repeat  (R)", key: "", checked: p.playlist.repeatAll) { p.toggleRepeat() })
        return m
    }

    func tapMenu() -> NSMenu {
        let p = player
        let m = NSMenu()
        let permission: String
        switch p.audioPermission {
        case .authorized: permission = "allowed"
        case .denied: permission = "not allowed"
        case .notDetermined: permission = "not asked yet"
        case .unknown: permission = "unknown"
        }
        for line in ["Permission: \(permission)", "Tap: \(p.tapStatus)"] {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            m.addItem(item)
        }
        if p.needsAudioPermission {
            m.addItem(ActionItem("Enable EQ & Visualizer…", key: "") { p.requestAudioFeatures("equalizer and visualizer") })
        }
        m.addItem(ActionItem("Attach Now", key: "") { p.attachTap() })
        m.addItem(ActionItem("Detach", key: "", enabled: p.tap.isAttached) { p.detachTap() })
        m.addItem(ActionItem("Attach Automatically on Play", key: "", checked: p.autoAttachTap) { p.autoAttachTap.toggle() })
        m.addItem(.separator())
        m.addItem(ActionItem("Open Audio Recording Settings…", key: "") { AudioPermission.openSettings() })
        return m
    }

    func skinsMenu() -> NSMenu {
        let m = NSMenu()
        let skins = Env.skins!
        skins.rescan()
        for e in skins.entries {
            let title = e.name == SkinManager.baseName ? "\(e.name) (Winamp base skin)" : e.name
            m.addItem(ActionItem(title, key: "", checked: skins.current.name == e.name) { _ = skins.select(e) })
        }
        m.addItem(.separator())
        m.addItem(ActionItem("Open Skin…", key: "") { [weak self] in self?.openSkin() })
        m.addItem(ActionItem("Show Skins Folder", key: "") { NSWorkspace.shared.open(SkinManager.userSkinsDirectory) })
        m.addItem(ActionItem("Get More Skins (Winamp Skin Museum)…", key: "") {
            NSWorkspace.shared.open(URL(string: "https://skins.webamp.org/")!)
        })
        return m
    }

    func visualizerMenu() -> NSMenu {
        let v = player.visualizer
        let p = player
        let m = NSMenu()
        func add(_ title: String, _ on: Bool, _ f: @escaping () -> Void) {
            m.addItem(ActionItem(title, key: "", checked: on) { f(); p.visualizerChanged(); p.audioFeatureUsed("visualizer") })
        }
        header(m, "Mode")
        add("Spectrum Analyzer", v.mode == .analyzer) { v.mode = .analyzer }
        add("Oscilloscope", v.mode == .oscilloscope) { v.mode = .oscilloscope }
        add("Off", v.mode == .off) { v.mode = .off }
        m.addItem(.separator())
        header(m, "Analyzer")
        add("Normal Style", v.analyzerStyle == .normal) { v.analyzerStyle = .normal }
        add("Fire Style", v.analyzerStyle == .fire) { v.analyzerStyle = .fire }
        add("Line Style", v.analyzerStyle == .line) { v.analyzerStyle = .line }
        add("Thin Bands", v.bandwidth == .thin) { v.bandwidth = .thin }
        add("Thick Bands", v.bandwidth == .wide) { v.bandwidth = .wide }
        add("Show Peaks", v.peaks) { v.peaks.toggle() }
        let fall = NSMenu(), peakFall = NSMenu()
        for f in ClassicVisualizer.Falloff.allCases {
            fall.addItem(ActionItem(f.rawValue.capitalized, key: "", checked: v.falloff == f) { v.falloff = f; p.visualizerChanged() })
            peakFall.addItem(ActionItem(f.rawValue.capitalized, key: "", checked: v.peakFalloff == f) { v.peakFalloff = f; p.visualizerChanged() })
        }
        m.addItem(submenu("Analyzer Falloff", fall))
        m.addItem(submenu("Peaks Falloff", peakFall))
        m.addItem(.separator())
        header(m, "Oscilloscope")
        add("Dots", v.oscilloscopeStyle == .dots) { v.oscilloscopeStyle = .dots }
        add("Lines", v.oscilloscopeStyle == .lines) { v.oscilloscopeStyle = .lines }
        add("Solid", v.oscilloscopeStyle == .solid) { v.oscilloscopeStyle = .solid }
        if p.needsAudioPermission {
            m.addItem(.separator())
            m.addItem(ActionItem("Enable Visualizer (Audio Permission)…", key: "") { p.requestAudioFeatures("visualizer") })
        }
        return m
    }

    /// The EQ window's PRESETS button: EQ curves and the effect presets
    /// (speed, pitch, reverb, next door) in one place.
    func presetsMenu() -> NSMenu {
        let p = player
        let m = NSMenu()
        header(m, "Equalizer")
        m.addItem(ActionItem("Reset (Flat)", key: "") { p.resetEqualizer() })
        let eqPresets = NSMenu()
        for preset in EqualizerModel.presets {
            eqPresets.addItem(ActionItem(preset.name, key: "") {
                p.applyPreset(preset)
                p.flash("EQ PRESET: \(preset.name.uppercased())")
                p.audioFeatureUsed("equalizer")
            })
        }
        m.addItem(submenu("EQ Presets", eqPresets))
        m.addItem(.separator())
        header(m, "Effects")
        let current = p.effectsPresetName
        for preset in EffectSettings.presets {
            let title = preset.name == "Off" ? "No Effects" : preset.name
            m.addItem(ActionItem(title, key: "", checked: current == preset.name) { p.applyEffectsPreset(preset) })
        }
        m.addItem(ActionItem("Effects…", key: "") { [weak self] in self?.showEffects() })
        return m
    }

    // MARK: Playlist button menus

    func playlistAddMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(ActionItem("Add SoundCloud Link…", key: "") { [weak self] in self?.showAddLinkDialog() })
        m.addItem(ActionItem("Paste Link from Clipboard", key: "") { [weak self] in self?.pasteLinks(from: .general) })
        return m
    }

    func playlistRemoveMenu() -> NSMenu {
        let pl = player.playlist
        let m = NSMenu()
        m.addItem(ActionItem("Remove Selected", key: "", enabled: !pl.selection.isEmpty) { pl.remove(pl.selection) })
        m.addItem(ActionItem("Crop (Keep Selected)", key: "", enabled: !pl.selection.isEmpty) { pl.crop() })
        m.addItem(ActionItem("Remove Unavailable", key: "") {
            pl.remove(IndexSet(pl.tracks.indices.filter { pl[$0].status == .unavailable }))
        })
        m.addItem(ActionItem("Remove All", key: "") { [weak self] in self?.player.stop(); pl.removeAll() })
        return m
    }

    func playlistSelectMenu() -> NSMenu {
        let pl = player.playlist
        let m = NSMenu()
        m.addItem(ActionItem("Select All", key: "") { pl.selection = IndexSet(integersIn: 0..<pl.count); self.player.notifyChanged() })
        m.addItem(ActionItem("Select None", key: "") { pl.selection = IndexSet(); self.player.notifyChanged() })
        m.addItem(ActionItem("Invert Selection", key: "") {
            pl.selection = IndexSet(integersIn: 0..<pl.count).subtracting(pl.selection); self.player.notifyChanged()
        })
        return m
    }

    func playlistMiscMenu() -> NSMenu {
        let pl = player.playlist
        let m = NSMenu()
        m.addItem(ActionItem("Sort by Title", key: "") { pl.sort { $0.title } })
        m.addItem(ActionItem("Sort by Artist", key: "") { pl.sort { $0.artist + " " + $0.title } })
        m.addItem(ActionItem("Reverse List", key: "") { pl.reverse() })
        m.addItem(.separator())
        m.addItem(ActionItem("Track Info…", key: "") { [weak self] in self?.showTrackInfo() })
        m.addItem(ActionItem("Open on SoundCloud", key: "") { [weak self] in
            self?.openOnSoundCloud(pl.selection.first ?? pl.currentIndex)
        })
        return m
    }

    func playlistListMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(ActionItem("Copy Links of Selected", key: "") { [weak self] in self?.copyLinks(selectedOnly: true) })
        m.addItem(ActionItem("Copy All Links", key: "") { [weak self] in self?.copyLinks(selectedOnly: false) })
        m.addItem(.separator())
        m.addItem(ActionItem("New List (Clear)", key: "") { [weak self] in self?.player.stop(); self?.player.playlist.removeAll() })
        return m
    }

    // MARK: Dialogs

    func openSkin() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "wsz"), .zip].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a classic Winamp skin (.wsz)"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { Env.skins.install(url) }
    }

    func showTrackInfo() {
        let pl = player.playlist
        guard let i = pl.selection.first ?? pl.currentIndex else { return }
        let t = pl[i]
        let alert = NSAlert()
        alert.messageText = t.displayTitle
        alert.informativeText = [
            "Artist: \(t.artist)", "Title: \(t.title)",
            "Duration: \(t.durationMs.map(formatTime) ?? "unknown")",
            "Link: \(t.permalink ?? t.url)", t.soundID.map { "Track ID: \($0)" } ?? "",
            t.note.map { "Note: \($0)" } ?? "",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open on SoundCloud")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { openOnSoundCloud(i) }
    }

    /// Right-click on a playlist row.
    func trackMenu(index i: Int) -> NSMenu {
        let p = player, pl = player.playlist
        let m = NSMenu()
        guard pl.tracks.indices.contains(i) else { return m }
        let t = pl[i]
        let title = NSMenuItem(title: t.displayTitle, action: nil, keyEquivalent: "")
        title.isEnabled = false
        m.addItem(title)
        m.addItem(.separator())
        m.addItem(ActionItem("Play", key: "", enabled: t.isPlayable) { p.play(index: i) })
        m.addItem(ActionItem("Open on SoundCloud", key: "", enabled: t.webURL != nil) { [weak self] in self?.openOnSoundCloud(i) })
        m.addItem(ActionItem(pl.selection.count > 1 ? "Copy \(pl.selection.count) Links" : "Copy Link", key: "") { [weak self] in
            self?.copyLinks(selectedOnly: true)
        })
        m.addItem(ActionItem("Track Info…", key: "") { [weak self] in self?.showTrackInfo() })
        m.addItem(.separator())
        m.addItem(ActionItem(pl.selection.count > 1 ? "Remove \(pl.selection.count) Tracks" : "Remove from Playlist", key: "") {
            if pl.selection.contains(i) && pl.currentIndex == i && p.state != .stopped { p.stop() }
            pl.remove(pl.selection.isEmpty ? IndexSet(integer: i) : pl.selection)
        })
        return m
    }

    /// Open a track's SoundCloud page (default: the current track).
    func openOnSoundCloud(_ index: Int? = nil) {
        let pl = player.playlist
        guard let i = index ?? pl.currentIndex, pl.tracks.indices.contains(i) else {
            player.flash("NOTHING PLAYING")
            return
        }
        guard let url = pl[i].webURL else {
            player.flash(pl[i].url == PlayerController.introURL ? "THE INTRO HAS NO WEB PAGE" : "NO SOUNDCLOUD PAGE KNOWN YET")
            return
        }
        Log("Opening \(url.absoluteString)")
        player.flash("OPENING ON SOUNDCLOUD…")
        NSWorkspace.shared.open(url)
    }

    func showAbout() {
        let alert = NSAlert()
        alert.messageText = "SoundAmp 0.1"
        alert.informativeText = """
        A classic-skinned player for SoundCloud.

        Playback: SoundCloud widget. Audio from SoundCloud and its creators — open tracks on SoundCloud to support them.
        Skin rendering, sprite maps and visualizer behavior follow Webamp (MIT) by Jordan Eldredge.
        Winamp is a trademark of its owners; SoundAmp is not affiliated with Winamp or SoundCloud.
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func showDebugConsole() {
        if debugConsole == nil { debugConsole = DebugConsole() }
        debugConsole?.show()
    }

    // MARK: Menu bar

    func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(ActionItem("About SoundAmp", key: "") { [weak self] in self?.showAbout() })
        appMenu.addItem(ActionItem("Play the Llama Intro", key: "") { Env.player.playIntro() })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide SoundAmp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit SoundAmp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu("SoundAmp", appMenu))

        let file = NSMenu(title: "File")
        file.addItem(ActionItem("Add SoundCloud Link…", key: "l") { [weak self] in self?.showAddLinkDialog() })
        file.addItem(ActionItem("Open Skin…", key: "o") { [weak self] in self?.openSkin() })
        main.addItem(submenu("File", file))

        // Standard selectors so ⌘V/⌘C/⌘A reach the focused skinned view (or text fields in dialogs).
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu("Edit", edit))

        main.addItem(dynamicSubmenu("Controls") { [weak self] in self?.playbackMenu() ?? NSMenu() })
        main.addItem(dynamicSubmenu("Skins") { [weak self] in self?.skinsMenu() ?? NSMenu() })
        main.addItem(dynamicSubmenu("Visualization") { [weak self] in self?.visualizerMenu() ?? NSMenu() })
        main.addItem(dynamicSubmenu("Effects") { [weak self] in self?.effectsMenu() ?? NSMenu() })
        main.addItem(dynamicSubmenu("Window") { [weak self] in
            guard let self else { return NSMenu() }
            let m = NSMenu()
            m.addItem(ActionItem("Playlist Editor", key: "e", modifiers: [.option], checked: Env.windows.playlist.isVisible) {
                Env.windows.toggle(Env.windows.playlist)
            })
            m.addItem(ActionItem("Equalizer", key: "g", modifiers: [.option], checked: Env.windows.equalizer.isVisible) {
                Env.windows.toggle(Env.windows.equalizer)
            })
            m.addItem(ActionItem("Artwork", key: "a", modifiers: [.option], checked: Env.windows.artwork.isVisible) {
                Env.windows.toggle(Env.windows.artwork)
            })
            m.addItem(.separator())
            for item in self.sizeMenu().items { item.menu?.removeItem(item); m.addItem(item) }
            m.addItem(.separator())
            m.addItem(ActionItem("Always On Top", key: "t", checked: Settings.alwaysOnTop) { Env.windows.toggleAlwaysOnTop() })
            m.addItem(.separator())
            m.addItem(submenu("Audio Tap", self.tapMenu()))
            m.addItem(ActionItem("Debug Console", key: "d", modifiers: [.command, .shift]) { self.showDebugConsole() })
            return m
        })
        return main
    }

    private var dynamicBuilders: [ObjectIdentifier: () -> NSMenu] = [:]

    /// A menu-bar menu rebuilt every time it opens (so checkmarks are current).
    private func dynamicSubmenu(_ title: String, _ build: @escaping () -> NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.delegate = self
        dynamicBuilders[ObjectIdentifier(menu)] = build
        // Populate once so key equivalents work before the menu is first opened.
        for i in build().items { i.menu?.removeItem(i); menu.addItem(i) }
        item.submenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let build = dynamicBuilders[ObjectIdentifier(menu)] else { return }
        menu.removeAllItems()
        for i in build().items { i.menu?.removeItem(i); menu.addItem(i) }
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    private func header(_ m: NSMenu, _ title: String) {
        if #available(macOS 14.0, *) { m.addItem(.sectionHeader(title: title)) } else {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
        }
    }
}
