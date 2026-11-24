import AppKit
import SoundAmpCore

/// Creates the three Winamp windows and handles docking, snapping, double size
/// and always-on-top.
@MainActor
final class WindowManager {
    let main: SkinWindow
    let equalizer: SkinWindow
    let playlist: SkinWindow
    var all: [SkinWindow] { [main, equalizer, playlist] }
    /// Windows positioned relative to the main window.
    private var satellites: [SkinWindow] { [equalizer, playlist] }
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

    init(mainView: SkinView, eqView: SkinView, playlistView: SkinView) {
        main = SkinWindow(name: "main", view: mainView)
        equalizer = SkinWindow(name: "equalizer", view: eqView)
        playlist = SkinWindow(name: "playlist", view: playlistView)
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
        for w in satellites {
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
        var offsets: [String: CGPoint] = [:]
        for w in satellites {
            offsets[w.identifierName] = CGPoint(x: (w.frame.minX - tl.x) / scale, y: (tl.y - w.frame.maxY) / scale)
        }
        Settings.windowOffsets = offsets
        Settings.showEqualizer = equalizer.isVisible
        Settings.showPlaylist = playlist.isVisible
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
        if w.isVisible { w.orderOut(nil) } else { w.orderFront(nil) }
        savePositions()
        NotificationCenter.default.post(name: PlayerController.didChange, object: nil)
    }

    /// Playlist resized (in 25×29 segments): keep its top-left fixed.
    func playlistResized() {
        let w = playlist
        let size = NSSize(width: w.skinView.skinSize.width * scale, height: w.skinView.skinSize.height * scale)
        w.setFrame(NSRect(x: w.frame.minX, y: w.frame.maxY - size.height, width: size.width, height: size.height), display: true)
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
