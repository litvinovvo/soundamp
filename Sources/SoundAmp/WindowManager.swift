import AppKit
import SoundAmpCore

/// Creates the Winamp windows and handles docking, snapping, double size
/// and always-on-top.
@MainActor
final class WindowManager {
    let main: SkinWindow
    let equalizer: SkinWindow
    let playlist: SkinWindow
    let artwork: SkinWindow
    var all: [SkinWindow] { [main, equalizer, playlist, artwork] }
    /// Windows positioned relative to the main window.
    private var satellites: [SkinWindow] { [equalizer, playlist, artwork] }
    var visible: [SkinWindow] { all.filter(\.isVisible) }

    private(set) var scale: CGFloat = WindowManager.clampScale(CGFloat(Settings.uiScale))

    /// Scale steps. On Retina, every 0.5 step maps a skin pixel to whole device pixels (crisp).
    static let scaleSteps: [CGFloat] = [1, 1.5, 2, 2.5, 3, 3.5, 4]

    /// Largest scale at which the main window still fits the screen width.
    static var maxScale: CGFloat {
        let width = NSScreen.main?.visibleFrame.width ?? 1440
        return max(1, min(4, (width / 275 * 2).rounded(.down) / 2))
    }

    static func clampScale(_ s: CGFloat) -> CGFloat { max(1, min(maxScale, (s * 2).rounded() / 2)) }
    private var dragGroup: [(SkinWindow, NSPoint)] = []
    private var dragStartMouse = NSPoint.zero
    private var dragging: SkinWindow?
    private let snapDistance: CGFloat = 10

    init(mainView: SkinView, eqView: SkinView, playlistView: SkinView, artworkView: SkinView) {
        main = SkinWindow(name: "main", view: mainView)
        equalizer = SkinWindow(name: "equalizer", view: eqView)
        playlist = SkinWindow(name: "playlist", view: playlistView)
        artwork = SkinWindow(name: "artwork", view: artworkView)
        for w in all { w.skinView.scale = scale }
        applyAlwaysOnTop()
        NotificationCenter.default.addObserver(forName: SkinManager.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Env.windows.all.forEach { $0.invalidateShadow() } }
        }
    }

    /// The SoundCloud widgets need to live in a visible window or WebKit may
    /// throttle them; tuck them 1×1 under the main window's skin.
    func hostWebViews(_ views: [NSView]) {
        guard let container = main.contentView else { return }
        for (i, v) in views.enumerated() {
            v.removeFromSuperview()
            v.frame = NSRect(x: 2 + i, y: 2, width: 1, height: 1)
            container.addSubview(v, positioned: .below, relativeTo: main.skinView)
        }
    }

    // MARK: Layout

    func layoutInitially() {
        resizeAll()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let s = main.frame.size
        var topLeft = NSPoint(x: screen.midX - s.width / 2, y: screen.maxY - 80)
        if let saved = Settings.mainOrigin, NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -50, dy: -50).contains(saved) }) {
            topLeft = saved
        }
        main.setFrameTopLeftPoint(topLeft)
        let offsets = Settings.windowOffsets
        var y = main.frame.minY
        for w in [equalizer, playlist] {
            if let off = offsets[w.identifierName] {
                w.setFrameTopLeftPoint(NSPoint(x: topLeft.x + off.x * scale, y: topLeft.y - off.y * scale))
            } else {
                w.setFrameTopLeftPoint(NSPoint(x: main.frame.minX, y: y))
            }
            y = w.frame.minY
        }
        main.makeKeyAndOrderFront(nil)
        if Settings.showEqualizer { equalizer.orderFront(nil) }
        if Settings.showPlaylist { playlist.orderFront(nil) }
        if Settings.showArtwork {
            place(artwork)
            artwork.orderFront(nil)
            artwork.skinView.redraw()
        }
    }

    func resizeAll() {
        for w in all {
            let size = NSSize(width: w.skinView.skinSize.width * scale, height: w.skinView.skinSize.height * scale)
            let top = w.frame.maxY
            w.setFrame(NSRect(x: w.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
            w.skinView.scale = scale
            w.invalidateShadow()
        }
    }

    func savePositions() {
        let tl = NSPoint(x: main.frame.minX, y: main.frame.maxY)
        Settings.mainOrigin = tl
        // Hidden windows keep the spot they had when they were closed.
        var offsets = Settings.windowOffsets
        for w in satellites where w.isVisible {
            offsets[w.identifierName] = CGPoint(x: (w.frame.minX - tl.x) / scale, y: (tl.y - w.frame.maxY) / scale)
        }
        Settings.windowOffsets = offsets
        Settings.showEqualizer = equalizer.isVisible
        Settings.showPlaylist = playlist.isVisible
        Settings.showArtwork = artwork.isVisible
    }

    // MARK: Scale / always on top / toggles

    /// Winamp's "D" (double size): 100% ↔ 200%.
    func toggleDoubleSize() { setScale(scale == 1 ? 2 : 1) }

    func zoomIn() { setScale(Self.scaleSteps.first { $0 > scale + 0.01 } ?? scale) }
    func zoomOut() { setScale(Self.scaleSteps.last { $0 < scale - 0.01 } ?? scale) }

    /// Rescale all windows around the main window's top-left corner, keeping
    /// docked layout, then nudge everything back on screen if needed.
    func setScale(_ requested: CGFloat, persist: Bool = true) {
        let new = Self.clampScale(requested)
        let old = scale
        guard new != old else {
            if requested > old { Env.player.flash("MAX SIZE FOR THIS SCREEN") }
            return
        }
        let tl = NSPoint(x: main.frame.minX, y: main.frame.maxY)
        let offsets = satellites.map { w in
            (w, CGPoint(x: (w.frame.minX - tl.x) / old, y: (tl.y - w.frame.maxY) / old))
        }
        scale = new
        if persist { Settings.uiScale = Double(new) }
        resizeAll()
        main.setFrameTopLeftPoint(tl)
        for (w, off) in offsets { w.setFrameTopLeftPoint(NSPoint(x: tl.x + off.x * new, y: tl.y - off.y * new)) }
        keepOnScreen()
        if persist { savePositions() }
        Env.player.flash("SIZE: \(Int(new * 100))%", seconds: 1.2)
        NotificationCenter.default.post(name: PlayerController.didChange, object: nil)
    }

    /// Shift the visible windows (together) so they stay inside the main window's screen.
    private func keepOnScreen() {
        guard let screen = (main.screen ?? NSScreen.main)?.visibleFrame else { return }
        let bounds = visible.map(\.frame).reduce(main.frame) { $0.union($1) }
        var dx: CGFloat = 0, dy: CGFloat = 0
        if bounds.maxX > screen.maxX { dx = screen.maxX - bounds.maxX }
        if bounds.minX + dx < screen.minX { dx = screen.minX - bounds.minX }
        if bounds.minY < screen.minY { dy = screen.minY - bounds.minY }
        if bounds.maxY + dy > screen.maxY { dy = screen.maxY - bounds.maxY }
        guard dx != 0 || dy != 0 else { return }
        for w in all { w.setFrameOrigin(NSPoint(x: w.frame.minX + dx, y: w.frame.minY + dy)) }
    }

    func toggleAlwaysOnTop() {
        Settings.alwaysOnTop.toggle()
        applyAlwaysOnTop()
        NotificationCenter.default.post(name: PlayerController.didChange, object: nil)
    }

    private func applyAlwaysOnTop() {
        for w in all { w.level = Settings.alwaysOnTop ? .floating : .normal }
    }

    func toggle(_ w: SkinWindow) {
        if w.isVisible {
            savePositions() // remember where it was
            w.orderOut(nil)
        } else {
            place(w)
            w.orderFront(nil)
            w.skinView.redraw()
        }
        savePositions()
        NotificationCenter.default.post(name: PlayerController.didChange, object: nil)
    }

    /// Put a hidden window back where it was relative to the main window.
    /// The artwork window opens beside the others until it has been placed.
    private func place(_ w: SkinWindow) {
        if let off = Settings.windowOffsets[w.identifierName] {
            w.setFrameTopLeftPoint(NSPoint(x: main.frame.minX + off.x * scale, y: main.frame.maxY - off.y * scale))
            let header = NSRect(x: w.frame.minX, y: w.frame.maxY - 20 * scale, width: w.frame.width, height: 20 * scale)
            if w !== artwork || NSScreen.screens.contains(where: { $0.visibleFrame.contains(header) }) { return }
        }
        guard w === artwork else { return }
        let screen = (main.screen ?? NSScreen.main)?.visibleFrame ?? main.frame
        let size = w.frame.size
        let frames = [main.frame] + visible.filter { $0 !== main && $0 !== w }.map(\.frame)
        let candidates = frames.flatMap { f in
            [NSPoint(x: f.maxX, y: f.maxY - size.height), NSPoint(x: f.minX - size.width, y: f.maxY - size.height),
             NSPoint(x: f.minX, y: f.minY - size.height), NSPoint(x: f.minX, y: f.maxY)]
        }.map { NSRect(origin: $0, size: size) }
        let free = candidates.first { c in screen.contains(c) && frames.allSatisfy { !c.intersects($0) } }
        let fallback = NSPoint(x: max(screen.minX, min(main.frame.maxX, screen.maxX - size.width)),
                               y: max(screen.minY, min(main.frame.maxY - size.height, screen.maxY - size.height)))
        w.setFrameOrigin(free?.origin ?? fallback)
    }

    /// Artwork height (skin pixels) for a corner drag: fits the screen and snaps its
    /// right and bottom edges to the other windows' edges.
    func artworkHeight(dragged height: CGFloat, minimum: CGFloat, extraWidth: CGFloat) -> CGFloat {
        let f = artwork.frame
        let extra = extraWidth * scale
        var size = height * scale
        var best: CGFloat?
        for o in visible.filter({ $0 !== artwork }).map(\.frame) {
            for x in [o.minX, o.maxX] { consider(x - (f.minX + size + extra), &best) }
            for y in [o.minY, o.maxY] { consider((f.maxY - y) - size, &best) }
        }
        size += best ?? 0
        if let screen = (artwork.screen ?? NSScreen.main)?.visibleFrame {
            size = min(size, screen.maxX - f.minX - extra, f.maxY - screen.minY)
        }
        return max(minimum, (size / scale).rounded(.down))
    }

    /// A window's skin size changed (playlist segments, artwork): keep its top-left fixed,
    /// or its top-right if asked to and that's the side docked to another window.
    func resized(_ w: SkinWindow, keepDockedEdge: Bool = false) {
        let size = NSSize(width: w.skinView.skinSize.width * scale, height: w.skinView.skinSize.height * scale)
        let docked = visible.filter { $0 !== w && touching($0.frame, w.frame) }
        let keepRight = keepDockedEdge && docked.contains { abs($0.frame.minX - w.frame.maxX) <= 1.5 }
        w.setFrame(NSRect(x: keepRight ? w.frame.maxX - size.width : w.frame.minX, y: w.frame.maxY - size.height,
                          width: size.width, height: size.height), display: true)
        if keepRight { savePositions() }
    }

    // MARK: Dragging with docking + snapping

    func beginDrag(_ window: NSWindow?, event: NSEvent) {
        guard let w = window as? SkinWindow else { return }
        dragging = w
        dragStartMouse = NSEvent.mouseLocation
        // Dragging the main window drags everything docked to it (transitively).
        let group = w === main ? dockedGroup(from: main) : [w]
        dragGroup = group.map { ($0, $0.frame.origin) }
    }

    func drag(event: NSEvent) {
        guard dragging != nil else { return }
        let m = NSEvent.mouseLocation
        var dx = m.x - dragStartMouse.x
        var dy = m.y - dragStartMouse.y

        // Snap the moving group to other windows and screen edges.
        let moving = Set(dragGroup.map { ObjectIdentifier($0.0) })
        let others = visible.filter { !moving.contains(ObjectIdentifier($0)) }.map(\.frame)
        let screens = NSScreen.screens.map(\.visibleFrame)
        var bestX: CGFloat?, bestY: CGFloat?
        for (w, origin) in dragGroup {
            let f = NSRect(origin: NSPoint(x: origin.x + dx, y: origin.y + dy), size: w.frame.size)
            for o in others {
                let vOverlap = f.minY < o.maxY + snapDistance && f.maxY > o.minY - snapDistance
                let hOverlap = f.minX < o.maxX + snapDistance && f.maxX > o.minX - snapDistance
                if vOverlap {
                    for (a, b) in [(f.minX, o.maxX), (f.maxX, o.minX), (f.minX, o.minX), (f.maxX, o.maxX)] { consider(b - a, &bestX) }
                }
                if hOverlap {
                    for (a, b) in [(f.minY, o.maxY), (f.maxY, o.minY), (f.minY, o.minY), (f.maxY, o.maxY)] { consider(b - a, &bestY) }
                }
            }
            for s in screens {
                for (a, b) in [(f.minX, s.minX), (f.maxX, s.maxX)] { consider(b - a, &bestX) }
                for (a, b) in [(f.minY, s.minY), (f.maxY, s.maxY)] { consider(b - a, &bestY) }
            }
        }
        dx += bestX ?? 0
        dy += bestY ?? 0
        for (w, origin) in dragGroup { w.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy)) }
    }

    private func consider(_ delta: CGFloat, _ best: inout CGFloat?) {
        guard abs(delta) <= snapDistance else { return }
        if best == nil || abs(delta) < abs(best!) { best = delta }
    }

    func endDrag() {
        dragging = nil
        dragGroup = []
        savePositions()
    }

    /// Windows touching each other (edge to edge), starting from `root`.
    private func dockedGroup(from root: SkinWindow) -> [SkinWindow] {
        var group = [root]
        var queue = [root]
        let candidates = visible
        while let w = queue.popLast() {
            for o in candidates where !group.contains(where: { $0 === o }) && touching(w.frame, o.frame) {
                group.append(o)
                queue.append(o)
            }
        }
        return group
    }

    private func touching(_ a: NSRect, _ b: NSRect) -> Bool {
        let e: CGFloat = 1.5
        let hOverlap = a.minX < b.maxX - e && a.maxX > b.minX + e
        let vOverlap = a.minY < b.maxY - e && a.maxY > b.minY + e
        return (hOverlap && (abs(a.minY - b.maxY) <= e || abs(a.maxY - b.minY) <= e))
            || (vOverlap && (abs(a.minX - b.maxX) <= e || abs(a.maxX - b.minX) <= e))
    }
}
