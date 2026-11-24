import AppKit
import SoundAmpCore

/// Shared app objects (set up once by AppDelegate).
@MainActor
enum Env {
    static var player: PlayerController!
    static var skins: SkinManager!
    static var windows: WindowManager!
    static var menus: MenuBuilder!
}

/// A clickable area of a skinned window, in skin pixels.
struct Hit {
    enum Kind {
        /// Momentary button: drawn pressed while held, fires on release inside.
        case button(String, () -> Void)
        /// Slider: called with the point (skin coords) on press, drag and release.
        case slider(String, (CGPoint, _ ended: Bool) -> Void)
        /// Pass the raw events to the view (playlist rows etc.).
        case custom((NSEvent, CGPoint, _ phase: Phase) -> Void)
        /// Drag the window (title bar / background).
        case dragWindow
    }
    enum Phase { case down, dragged, up }
    let rect: CGRect
    let kind: Kind
}

/// Base view for the main, equalizer and playlist windows: pixel-exact sprite
/// drawing (nearest neighbor, optional 2× "double size"), hit testing, window
/// dragging, paste and drag-and-drop of SoundCloud links / skins.
@MainActor
class SkinView: NSView {
    var skin: Skin { Env.skins.current }
    var player: PlayerController { Env.player }

    /// Logical size in skin pixels.
    var skinSize: CGSize { CGSize(width: 275, height: 116) }
    var scale: CGFloat = 1 { didSet { needsDisplay = true } }

    /// id of the button currently held down (for pressed sprites).
    private(set) var pressedID: String?
    private var activeHit: Hit?
    private var pressedInside = false

    private var ctx: CGContext!

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.URL, .fileURL, .string])
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: SkinManager.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: PlayerController.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func redraw() { needsDisplay = true }

    var isActiveWindow: Bool { window?.isKeyWindow ?? false }

    // MARK: Subclass hooks

    func drawSkin() {}
    func hits() -> [Hit] { [] }
    /// Region polygons (from region.txt) to clip the window shape, if any.
    func regionPolygons() -> [SkinRegion.Polygon]? { nil }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        ctx = c
        c.clear(bounds)
        c.saveGState()
        c.interpolationQuality = .none
        c.setShouldAntialias(false)
        c.scaleBy(x: scale, y: scale)
        if let polys = regionPolygons(), !polys.isEmpty {
            let path = CGMutablePath()
            for poly in polys where poly.count >= 3 {
                path.move(to: CGPoint(x: poly[0].x, y: poly[0].y))
                for p in poly.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
                path.closeSubpath()
            }
            c.addPath(path)
            c.clip()
        }
        drawSkin()
        c.restoreGState()
        ctx = nil
    }

    func draw(_ sprite: Sprite?, at p: CGPoint) {
        guard let sprite, let img = skin.image(sprite) else { return }
        draw(image: img, in: CGRect(origin: p, size: CGSize(width: img.width, height: img.height)))
    }

    func draw(_ sprite: Sprite?, at x: CGFloat, _ y: CGFloat) { draw(sprite, at: CGPoint(x: x, y: y)) }

    func draw(image: CGImage, in r: CGRect) {
        guard let ctx else { return }
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    /// Repeat a sprite to fill a rect (clipped).
    func tile(_ sprite: Sprite, in r: CGRect) {
        guard let ctx, let img = skin.image(sprite), img.width > 0, img.height > 0, r.width > 0, r.height > 0 else { return }
        ctx.saveGState()
        ctx.clip(to: r)
        var y = r.minY
        while y < r.maxY {
            var x = r.minX
            while x < r.maxX {
                draw(image: img, in: CGRect(x: x, y: y, width: CGFloat(img.width), height: CGFloat(img.height)))
                x += CGFloat(img.width)
            }
            y += CGFloat(img.height)
        }
        ctx.restoreGState()
    }

    func fill(_ r: CGRect, _ color: RGBA, alpha: CGFloat = 1) {
        ctx?.setFillColor(CGColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: alpha))
        ctx?.fill(r)
    }

    func clip(_ r: CGRect, _ body: () -> Void) {
        ctx?.saveGState()
        ctx?.clip(to: r)
        body()
        ctx?.restoreGState()
    }

    /// Text in the skin's 5×6 bitmap font (text.bmp).
    func drawText(_ text: String, at p: CGPoint) {
        var x = p.x
        for ch in text {
            draw(Sprites.character(ch), at: CGPoint(x: x, y: p.y))
            x += 5
        }
    }

    /// Normal system-font text (playlist rows), honoring the flipped context.
    func drawSystemText(_ s: String, in r: CGRect, color: RGBA, font: NSFont, alignRight: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignRight ? .right : .left
        style.lineBreakMode = .byClipping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: style, .kern: 0.4,
            .foregroundColor: NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1),
        ]
        ctx?.saveGState()
        ctx?.setShouldAntialias(true)
        NSString(string: s).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        ctx?.restoreGState()
    }

    func isPressed(_ id: String) -> Bool { pressedID == id && pressedInside }

    // MARK: Mouse

    func skinPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / scale, y: p.y / scale)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let p = skinPoint(event)
        guard let hit = hits().last(where: { $0.rect.contains(p) }) else {
            activeHit = Hit(rect: .zero, kind: .dragWindow)
            Env.windows.beginDrag(window, event: event)
            return
        }
        activeHit = hit
        switch hit.kind {
        case let .button(id, _):
            pressedID = id
            pressedInside = true
            needsDisplay = true
        case let .slider(id, f):
            pressedID = id
            pressedInside = true
            f(p, false)
            needsDisplay = true
        case let .custom(f):
            f(event, p, .down)
        case .dragWindow:
            Env.windows.beginDrag(window, event: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let hit = activeHit else { return }
        let p = skinPoint(event)
        switch hit.kind {
        case .button:
            let inside = hit.rect.contains(p)
            if inside != pressedInside { pressedInside = inside; needsDisplay = true }
        case let .slider(_, f):
            f(p, false)
            needsDisplay = true
        case let .custom(f):
            f(event, p, .dragged)
        case .dragWindow:
            Env.windows.drag(event: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let hit = activeHit else { return }
        let p = skinPoint(event)
        activeHit = nil
        switch hit.kind {
        case let .button(_, action):
            let fire = hit.rect.contains(p)
            pressedID = nil
            needsDisplay = true
            if fire { action() }
        case let .slider(_, f):
            f(p, true)
            pressedID = nil
            needsDisplay = true
        case let .custom(f):
            f(event, p, .up)
        case .dragWindow:
            Env.windows.endDrag()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(Env.menus.optionsMenu(), with: event, for: self)
    }

    // MARK: Pinch to zoom

    private var magnifyAccumulator: CGFloat = 0

    override func magnify(with event: NSEvent) {
        if event.phase == .began { magnifyAccumulator = 0 }
        magnifyAccumulator += event.magnification
        if magnifyAccumulator > 0.25 { Env.windows.zoomIn(); magnifyAccumulator = 0 }
        if magnifyAccumulator < -0.25 { Env.windows.zoomOut(); magnifyAccumulator = 0 }
    }

    // MARK: Keyboard (Winamp hotkeys)

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let c = event.charactersIgnoringModifiers?.lowercased() {
            switch c {
            case "z": player.previous(); return
            case "x": player.playButton(); return
            case "c": player.pauseButton(); return
            case "v": player.stop(); return
            case "b": player.next(); return
            case "s": player.toggleShuffle(); return
            case "r": player.toggleRepeat(); return
            case "l": Env.menus.showAddLinkDialog(); return
            default: break
            }
            switch event.keyCode {
            case 123: player.seek(fraction: (player.positionMs - 5000) / max(1, player.durationMs)); return // ←
            case 124: player.seek(fraction: (player.positionMs + 5000) / max(1, player.durationMs)); return // →
            case 126: player.setVolume(player.volume + 2); return // ↑
            case 125: player.setVolume(player.volume - 2); return // ↓
            default: break
            }
        }
        super.keyDown(with: event)
    }

    // MARK: Paste & drag and drop

    @objc func paste(_ sender: Any?) {
        Env.menus.pasteLinks(from: .general)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let skinFile = files.first(where: { ["wsz", "zip"].contains($0.pathExtension.lowercased()) }) {
            return Env.skins.install(skinFile)
        }
        return Env.menus.pasteLinks(from: pb) > 0
    }
}

/// Borderless, non-opaque window hosting a SkinView (shape comes from region.txt).
final class SkinWindow: NSWindow {
    let identifierName: String
    let skinView: SkinView

    init(name: String, view: SkinView) {
        identifierName = name
        skinView = view
        super.init(contentRect: NSRect(origin: .zero, size: view.skinSize), styleMask: [.borderless, .miniaturizable],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.managed, .participatesInCycle, .fullScreenNone]
        let container = NSView(frame: NSRect(origin: .zero, size: view.skinSize))
        container.autoresizesSubviews = true
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        contentView = container
        initialFirstResponder = view
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: self, queue: .main) { [weak view] _ in
            MainActor.assumeIsolated { view?.needsDisplay = true }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: self, queue: .main) { [weak view] _ in
            MainActor.assumeIsolated { view?.needsDisplay = true }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
