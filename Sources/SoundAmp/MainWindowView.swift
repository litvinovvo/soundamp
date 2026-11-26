import AppKit
import CoreVideo
import IOSurface
import QuartzCore
import SoundAmpCore

/// The classic 275×116 Winamp main window.
final class MainWindowView: SkinView {
    private enum Cadence: Equatable {
        case off
        case hz1   // paused time blink (1 Hz)
        case hz5   // marquee scroll (5 Hz, 200 ms/char)
        case hz30  // active visualizer / falloff (30 Hz, classic Winamp feel)

        var interval: TimeInterval {
            switch self {
            case .off: return 0
            case .hz1: return 1.0
            case .hz5: return 0.2
            case .hz30: return 1.0 / 30
            }
        }

        var tolerance: TimeInterval {
            switch self {
            case .off: return 0
            case .hz1: return 0.15
            case .hz5: return 0.04
            case .hz30: return 0.005
            }
        }
    }

    private(set) var isShaded = false
    private var timer: Timer?
    private var cadence: Cadence = .off
    private var marqueeOffset = 0
    private var lastMarqueeAdvance = CACurrentMediaTime()
    private var blinkHidden = false
    private var lastBlinkToggle = CACurrentMediaTime()
    private var lastDisplayedSecond = -1
    private var lastDisplayedNeg = false
    private var lastTimeSkin: ObjectIdentifier?
    private var lastThumbX = -1
    private var lastThumbPressed = false
    private var lastThumbSkin: ObjectIdentifier?
    private var lastMarqueeText = ""
    private var lastMarqueeSkin: ObjectIdentifier?
    private var cachedMarqueeScroll = false
    private var windowObservers: [NSObjectProtocol] = []
    private static let layerColorSpace = CGColorSpaceCreateDeviceRGB()
    private static let layerActions: [String: CAAction] = [
        "contents": NSNull(),
        "bounds": NSNull(),
        "position": NSNull(),
        "frame": NSNull(),
        "hidden": NSNull(),
    ]
    private static func makePixelLayer(opaque: Bool = false) -> CALayer {
        let l = CALayer()
        l.isOpaque = opaque
        l.magnificationFilter = .nearest
        l.minificationFilter = .nearest
        l.contentsScale = 1
        l.actions = layerActions
        return l
    }
    /// Dedicated GPU layers for the 4 animated regions (visualizer, marquee, time,
    /// seek thumb) so playback and idle animations never trigger full-window redraws.
    private let visLayer = MainWindowView.makePixelLayer(opaque: true)
    private let marqueeLayer = MainWindowView.makePixelLayer()
    private let timeLayer = MainWindowView.makePixelLayer()
    private let positionThumbLayer = MainWindowView.makePixelLayer()
    private let visSurfaces: [IOSurfaceRef] = (0..<2).compactMap { _ in
        let w = ClassicVisualizer.width, h = ClassicVisualizer.height
        let bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * 4)
        let props: [IOSurfacePropertyKey: Any] = [
            .width: w,
            .height: h,
            .bytesPerElement: 4,
            .bytesPerRow: bpr,
            .allocSize: bpr * h,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        return IOSurfaceCreate(props as CFDictionary)
    }
    private var visSurfaceIndex = 0
    /// While a slider is dragged, Winamp shows its value in the marquee.
    private var sliderMessage: String? {
        didSet {
            refreshMarqueeScroll()
            syncMarqueeLayer()
        }
    }
    private var scrubFraction: Double? {
        didSet {
            syncTimeLayer(force: false)
            syncPositionThumbLayer(force: false)
        }
    }
    private var marqueeClick: DispatchWorkItem?
    private var marqueeDragged = false
    private var marqueeDrag: (start: CGFloat, offset: Int)? {
        didSet {
            refreshMarqueeScroll()
            syncMarqueeLayer()
        }
    }

    override var skinSize: CGSize { isShaded ? CGSize(width: 275, height: 14) : MainLayout.size }
    override var scale: CGFloat { didSet { syncAllLayers(force: false) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(positionChanged), name: PlayerController.positionDidChange, object: nil)
        nc.addObserver(self, selector: #selector(visibilityChanged), name: NSApplication.didHideNotification, object: nil)
        nc.addObserver(self, selector: #selector(visibilityChanged), name: NSApplication.didUnhideNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        timer?.invalidate()
        for o in windowObservers { NotificationCenter.default.removeObserver(o) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let nc = NotificationCenter.default
        for o in windowObservers { nc.removeObserver(o) }
        windowObservers.removeAll()
        if let w = window {
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification,
                         NSWindow.didBecomeKeyNotification] {
                windowObservers.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.visibilityChanged() }
                })
            }
        }
        refreshMarqueeScroll()
        syncAllLayers(force: true)
        updateAnimationTimer()
    }

    override func redraw() {
        super.redraw()
        if player.state != .paused {
            blinkHidden = false
            lastBlinkToggle = CACurrentMediaTime()
        }
        refreshMarqueeScroll()
        syncAllLayers(force: true)
        updateAnimationTimer()
    }

    @objc private func visibilityChanged() {
        refreshMarqueeScroll()
        syncAllLayers(force: false)
        updateAnimationTimer()
        if isWindowVisibleOnScreen { needsDisplay = true }
    }

    @objc private func positionChanged() {
        guard isWindowVisibleOnScreen else { return }
        if isShaded {
            let sec = Int(displayedTime().ms / 1000)
            if sec != lastDisplayedSecond { needsDisplay = true }
            return
        }
        syncTimeLayer(force: false)
        syncPositionThumbLayer(force: false)
    }

    private func ensureLayersAttached() {
        guard let root = layer else { return }
        for l in [visLayer, marqueeLayer, timeLayer, positionThumbLayer] where l.superlayer !== root {
            root.addSublayer(l)
        }
    }

    private func syncAllLayers(force: Bool) {
        syncVisLayer()
        syncMarqueeLayer(force: force)
        syncTimeLayer(force: force)
        syncPositionThumbLayer(force: force)
    }

    private var showsVisLayer: Bool {
        guard Env.player != nil, !isShaded else { return false }
        let p = player
        guard p.visualizer.mode != .off else { return false }
        if p.needsAudioPermission, p.state == .playing || p.state == .paused { return false }
        return true
    }

    private func syncVisLayer() {
        ensureLayersAttached()
        let r = MainLayout.visualizer
        visLayer.frame = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
        let show = showsVisLayer
        visLayer.isHidden = !show
        if show {
            if !player.visualizer.isSettled, player.state != .playing {
                _ = player.renderVisualizer()
            } else if visLayer.contents == nil {
                _ = player.visualizer.render(samples: [])
            }
            uploadVisSurface()
        }
    }

    private func updateVisLayerContents() {
        guard showsVisLayer else { visLayer.isHidden = true; return }
        ensureLayersAttached()
        visLayer.isHidden = false
        uploadVisSurface()
    }

    private func marqueeVisibleText() -> String {
        let r = MainLayout.marquee
        let text = (sliderMessage ?? player.flashMessage ?? player.marqueeTitle).uppercased()
        let fits = text.count * 5 <= Int(r.width)
        if fits || sliderMessage != nil || player.flashMessage != nil { return text }
        let loop = text + "  ***  "
        let chars = Array(loop)
        let start = (marqueeDrag?.offset ?? marqueeOffset) % chars.count
        return String((0..<32).map { chars[(start + $0) % chars.count] })
    }

    private func syncMarqueeLayer(force: Bool = false) {
        guard Env.player != nil, Env.skins != nil else { return }
        ensureLayersAttached()
        let r = MainLayout.marquee
        marqueeLayer.frame = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
        if isShaded {
            marqueeLayer.isHidden = true
            return
        }
        marqueeLayer.isHidden = false
        let visible = marqueeVisibleText()
        let skinID = ObjectIdentifier(skin)
        guard force || visible != lastMarqueeText || skinID != lastMarqueeSkin else { return }
        lastMarqueeText = visible
        lastMarqueeSkin = skinID
        let w = Int(r.width), h = Int(r.height)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Self.layerColorSpace, bitmapInfo: bitmapInfo.rawValue) else { return }
        ctx.interpolationQuality = .none
        var x: CGFloat = 0
        for ch in visible {
            guard x < CGFloat(w) else { break }
            if let img = skin.image(Sprites.character(ch)) {
                ctx.draw(img, in: CGRect(x: x, y: 0, width: CGFloat(img.width), height: CGFloat(img.height)))
            }
            x += 5
        }
        marqueeLayer.contents = ctx.makeImage()
    }

    private func syncTimeLayer(force: Bool) {
        guard Env.player != nil, Env.skins != nil else { return }
        ensureLayersAttached()
        timeLayer.frame = CGRect(x: 38 * scale, y: 26 * scale, width: 61 * scale, height: 13 * scale)
        let p = player
        guard !isShaded, p.state != .stopped else {
            timeLayer.isHidden = true
            lastDisplayedSecond = -1
            return
        }
        timeLayer.isHidden = (p.state == .paused && blinkHidden)
        let (neg, ms) = displayedTime()
        let total = Int(ms / 1000)
        let skinID = ObjectIdentifier(skin)
        guard force || total != lastDisplayedSecond || neg != lastDisplayedNeg || skinID != lastTimeSkin else { return }
        lastDisplayedSecond = total
        lastDisplayedNeg = neg
        lastTimeSkin = skinID
        let minutes = min(99, total / 60), seconds = total % 60
        let ex = skin.usesNumsEx
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: nil, width: 61, height: 13, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Self.layerColorSpace, bitmapInfo: bitmapInfo.rawValue) else { return }
        ctx.interpolationQuality = .none
        func drawSprite(_ s: Sprite, x: CGFloat, yTop: CGFloat) {
            guard let img = skin.image(s) else { return }
            let h = CGFloat(img.height)
            ctx.draw(img, in: CGRect(x: x, y: 13 - yTop - h, width: CGFloat(img.width), height: h))
        }
        if neg {
            if ex { drawSprite(Sprites.minusSignEx, x: 0, yTop: 0) }
            else { drawSprite(Sprites.minusSign, x: 0, yTop: 6) }
        }
        drawSprite(Sprites.digit(minutes / 10, ex: ex), x: 10, yTop: 0)
        drawSprite(Sprites.digit(minutes % 10, ex: ex), x: 22, yTop: 0)
        drawSprite(Sprites.digit(seconds / 10, ex: ex), x: 40, yTop: 0)
        drawSprite(Sprites.digit(seconds % 10, ex: ex), x: 52, yTop: 0)
        timeLayer.contents = ctx.makeImage()
    }

    private func syncPositionThumbLayer(force: Bool) {
        guard Env.player != nil, Env.skins != nil else { return }
        ensureLayersAttached()
        let p = player
        guard !isShaded, p.state != .stopped, p.durationMs > 0 else {
            positionThumbLayer.isHidden = true
            lastThumbX = -1
            return
        }
        let f = scrubFraction ?? p.positionMs / p.durationMs
        let dx = (max(0, min(1, f)) * (248 - 29)).rounded()
        let thumbX = Int(dx)
        let pressed = isPressed("position")
        let skinID = ObjectIdentifier(skin)
        positionThumbLayer.isHidden = false
        positionThumbLayer.frame = CGRect(x: (MainLayout.position.minX + dx) * scale,
                                          y: MainLayout.position.minY * scale,
                                          width: 29 * scale, height: 10 * scale)
        if force || pressed != lastThumbPressed || skinID != lastThumbSkin || positionThumbLayer.contents == nil {
            lastThumbPressed = pressed
            lastThumbSkin = skinID
            positionThumbLayer.contents = skin.image(pressed ? Sprites.positionThumbPressed : Sprites.positionThumb)
        }
        lastThumbX = thumbX
    }

    private func uploadVisSurface() {
        guard !visSurfaces.isEmpty else {
            visLayer.contents = player.visualizer.makeImage()
            return
        }
        visSurfaceIndex = (visSurfaceIndex + 1) % visSurfaces.count
        let surface = visSurfaces[visSurfaceIndex]
        IOSurfaceLock(surface, [], nil)
        let dst = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt32.self)
        let dstStride = IOSurfaceGetBytesPerRow(surface) / 4
        let w = ClassicVisualizer.width, h = ClassicVisualizer.height
        player.visualizer.pixels.withUnsafeBufferPointer { srcBuf in
            guard let src = srcBuf.baseAddress else { return }
            for y in 0..<h {
                let sRow = src + y * w
                let dRow = dst + y * dstStride
                for x in 0..<w {
                    let p = sRow[x]
                    // RGBA (0xAABBGGRR) → BGRA (0xAARRGGBB)
                    dRow[x] = (p & 0xFF00_FF00) | ((p & 0x0000_00FF) << 16) | ((p & 0x00FF_0000) >> 16)
                }
            }
        }
        IOSurfaceUnlock(surface, [], nil)
        visLayer.contents = surface
    }

    private var isWindowVisibleOnScreen: Bool {
        guard let w = window, w.isVisible, !w.isMiniaturized else { return false }
        return w.occlusionState.contains(.visible)
    }

    private var visNeedsTimer: Bool {
        guard !isShaded, player.visualizer.mode != .off, !player.needsAudioPermission else { return false }
        let hasAudioFeed = player.currentIsLocal || player.tap.isAttached
        return (player.state == .playing && hasAudioFeed) || !player.visualizer.isSettled
    }

    private func refreshMarqueeScroll() {
        guard Env.player != nil, !isShaded, sliderMessage == nil, player.flashMessage == nil, marqueeDrag == nil else {
            cachedMarqueeScroll = false
            return
        }
        cachedMarqueeScroll = player.marqueeTitle.uppercased().count * 5 > Int(MainLayout.marquee.width)
    }

    private var desiredCadence: Cadence {
        guard isWindowVisibleOnScreen else { return .off }
        if visNeedsTimer { return .hz30 }
        if cachedMarqueeScroll { return .hz5 }
        if !isShaded && player.state == .paused { return .hz1 }
        return .off
    }

    private func updateAnimationTimer() {
        guard Env.player != nil else { return }
        let target = desiredCadence
        guard target != cadence else { return }
        timer?.invalidate()
        timer = nil
        cadence = target
        guard target != .off else { return }
        let now = CACurrentMediaTime()
        lastMarqueeAdvance = now
        lastBlinkToggle = now
        let t = Timer(timeInterval: target.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = target.tolerance
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard isWindowVisibleOnScreen else { updateAnimationTimer(); return }
        let now = CACurrentMediaTime()

        if cadence == .hz30 {
            if player.renderVisualizer() { updateVisLayerContents() }
            if player.visualizer.isSettled { updateAnimationTimer() }
        }
        if cachedMarqueeScroll, now - lastMarqueeAdvance >= 0.195 {
            marqueeOffset += 1
            lastMarqueeAdvance = now
            syncMarqueeLayer()
        }
        if !isShaded && player.state == .paused, now - lastBlinkToggle >= 0.99 {
            blinkHidden.toggle()
            lastBlinkToggle = now
            timeLayer.isHidden = blinkHidden
        }
    }

    // Hover hint over the scrolling title.
    override func layout() {
        super.layout()
        syncAllLayers(force: false)
        removeAllToolTips()
        guard !isShaded else { return }
        let r = MainLayout.marquee.insetBy(dx: 0, dy: -3)
        addToolTip(CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale),
                   owner: "Double-click to open this track on SoundCloud (⇧⌘O)" as NSString, userData: nil)
    }

    override func regionPolygons() -> [SkinRegion.Polygon]? {
        skin.regions[isShaded ? "windowshade" : "normal"]
    }

    func toggleShade() {
        isShaded.toggle()
        Env.windows.resizeAll()
        refreshMarqueeScroll()
        syncAllLayers(force: true)
        updateAnimationTimer()
        needsDisplay = true
    }

    // MARK: Drawing

    override func drawSkin() {
        isShaded ? drawShaded() : drawNormal()
    }

    private func drawNormal() {
        let p = player
        draw(Sprites.mainBackground, at: .zero)
        draw(isActiveWindow ? Sprites.titleBarActive : Sprites.titleBar, at: .zero)
        drawTitleButtons(shade: false)

        // Clutter bar: O A I D V
        draw(Sprites.clutterBarBackground, at: MainLayout.clutterBar)
        let cb = MainLayout.clutterBar
        if isPressed("clutterO") { draw(Sprites.clutterO, at: cb.x, cb.y + 3) }
        if Settings.alwaysOnTop || isPressed("clutterA") { draw(Sprites.clutterA, at: cb.x, cb.y + 11) }
        if isPressed("clutterI") { draw(Sprites.clutterI, at: cb.x, cb.y + 18) }
        if Env.windows.scale != 1 || isPressed("clutterD") { draw(Sprites.clutterD, at: cb.x, cb.y + 25) }
        if isPressed("clutterV") { draw(Sprites.clutterV, at: cb.x, cb.y + 33) }

        // Play state indicator
        switch p.state {
        case .playing:
            draw(Sprites.playingIndicator, at: MainLayout.playStatus)
            draw(Sprites.workingIndicator, at: MainLayout.workIndicator)
        case .loading:
            draw(Sprites.playingIndicator, at: MainLayout.playStatus)
            draw(Sprites.notWorkingIndicator, at: MainLayout.workIndicator)
        case .paused: draw(Sprites.pausedIndicator, at: MainLayout.playStatus)
        case .stopped: draw(Sprites.stoppedIndicator, at: MainLayout.playStatus)
        }

        let offscreen = NSGraphicsContext.current?.isDrawingToScreen == false
        if offscreen { drawTime() }

        // Visualizer (or a hint when macOS permission is missing).
        // On screen, visLayer renders the 76×16 bitmap directly on the GPU; draw into
        // the CGContext only for off-screen snapshots (cacheDisplay).
        if p.needsAudioPermission, p.visualizer.mode != .off, p.state == .playing || p.state == .paused {
            clip(MainLayout.visualizer) {
                drawText("CLICK TO", at: CGPoint(x: MainLayout.visualizer.minX + 18, y: MainLayout.visualizer.minY + 1))
                drawText("ENABLE", at: CGPoint(x: MainLayout.visualizer.minX + 23, y: MainLayout.visualizer.minY + 9))
            }
        } else if offscreen, let img = p.visualizer.makeImage() {
            draw(image: img, in: CGRect(origin: MainLayout.visualizer.origin, size: CGSize(width: 76, height: 16)))
        }

        if offscreen { drawMarquee() }

        // kbps / kHz / stereo
        if p.state == .playing || p.state == .paused {
            if let kbps = p.streamKbps {
                let text = String(kbps)
                drawText(String(repeating: " ", count: max(0, 3 - text.count)) + text.suffix(3), at: MainLayout.kbps)
            }
            if p.currentIsLocal, p.local.sampleRate > 0 {
                drawText(String(format: "%2d", Int(p.local.sampleRate / 1000)).suffix(2).description, at: MainLayout.khz)
            } else if p.tap.isAttached {
                drawText(String(format: "%2d", Int(p.tap.sampleRate / 1000)).suffix(2).description, at: MainLayout.khz)
            }
            draw(Sprites.stereo(true), at: MainLayout.stereo)
            draw(Sprites.mono(false), at: MainLayout.mono)
        } else {
            draw(Sprites.stereo(false), at: MainLayout.stereo)
            draw(Sprites.mono(false), at: MainLayout.mono)
        }

        // Volume
        let v = Double(p.volume)
        let vFrame = max(0, Int((v / 100 * 28).rounded()) - 1)
        draw(Sprites.volumeBackground(frame: vFrame), at: MainLayout.volume.origin)
        if skin.hasSliderThumbs(.volume) {
            let x = MainLayout.volume.minX + (v / 100 * 51).rounded()
            draw(isPressed("volume") ? Sprites.volumeThumbPressed : Sprites.volumeThumb, at: x, MainLayout.volume.minY + 1)
        }

        // Balance
        let b = Double(p.balance)
        draw(Sprites.balanceBackground(frame: Int(abs(b) / 100 * 27)), at: MainLayout.balance.origin)
        if skin.hasSliderThumbs(.balance) {
            let x = MainLayout.balance.minX + ((b + 100) / 200 * 24).rounded()
            draw(isPressed("balance") ? Sprites.balanceThumbPressed : Sprites.balanceThumb, at: x, MainLayout.balance.minY + 1)
        }

        // EQ / PL window toggles
        draw(Sprites.eqButton(on: Env.windows.equalizer.isVisible, pressed: isPressed("eqToggle")), at: MainLayout.eqButton)
        draw(Sprites.playlistButton(on: Env.windows.playlist.isVisible, pressed: isPressed("plToggle")), at: MainLayout.playlistButton)

        // Position bar (on screen, positionThumbLayer moves the thumb without redrawing).
        draw(Sprites.positionBackground, at: MainLayout.position.origin)
        if offscreen, p.state != .stopped, p.durationMs > 0 {
            let f = scrubFraction ?? p.positionMs / p.durationMs
            let dx = (max(0, min(1, f)) * (248 - 29)).rounded()
            let x = MainLayout.position.minX + dx
            draw(isPressed("position") ? Sprites.positionThumbPressed : Sprites.positionThumb, at: x, MainLayout.position.minY)
        }

        // Transport
        draw(isPressed("prev") ? Sprites.previous.pressed : Sprites.previous.normal, at: MainLayout.previous)
        draw(isPressed("play") ? Sprites.play.pressed : Sprites.play.normal, at: MainLayout.play)
        draw(isPressed("pause") ? Sprites.pause.pressed : Sprites.pause.normal, at: MainLayout.pause)
        draw(isPressed("stop") ? Sprites.stop.pressed : Sprites.stop.normal, at: MainLayout.stop)
        draw(isPressed("next") ? Sprites.next.pressed : Sprites.next.normal, at: MainLayout.next)
        draw(isPressed("eject") ? Sprites.eject.pressed : Sprites.eject.normal, at: MainLayout.eject)
        draw(Sprites.shuffle(on: p.playlist.shuffle, pressed: isPressed("shuffle")), at: MainLayout.shuffle)
        draw(Sprites.repeatButton(on: p.playlist.repeatAll, pressed: isPressed("repeat")), at: MainLayout.repeatButton)
    }

    private func drawTitleButtons(shade: Bool) {
        draw(isPressed("options") ? Sprites.optionsButton.pressed : Sprites.optionsButton.normal, at: MainLayout.options)
        draw(isPressed("minimize") ? Sprites.minimizeButton.pressed : Sprites.minimizeButton.normal, at: MainLayout.minimize)
        let sh = shade ? Sprites.unshadeButton : Sprites.shadeButton
        draw(isPressed("shade") ? sh.pressed : sh.normal, at: MainLayout.shade)
        draw(isPressed("close") ? Sprites.closeButton.pressed : Sprites.closeButton.normal, at: MainLayout.close)
    }

    private func displayedTime() -> (negative: Bool, ms: Double) {
        let p = player
        let pos = scrubFraction.map { $0 * p.durationMs } ?? p.positionMs
        if Settings.timeRemaining, p.durationMs > 0 { return (true, max(0, p.durationMs - pos)) }
        return (false, pos)
    }

    private func drawTime() {
        let p = player
        guard p.state != .stopped else { lastDisplayedSecond = -1; return }
        let (neg, ms) = displayedTime()
        let total = Int(ms / 1000)
        lastDisplayedSecond = total
        if p.state == .paused, blinkHidden { return } // Winamp blinks the time when paused
        let minutes = min(99, total / 60), seconds = total % 60
        let ex = skin.usesNumsEx
        if neg {
            if ex { draw(Sprites.minusSignEx, at: 38, 26) } else { draw(Sprites.minusSign, at: 38, 32) }
        }
        draw(Sprites.digit(minutes / 10, ex: ex), at: 48, 26)
        draw(Sprites.digit(minutes % 10, ex: ex), at: 60, 26)
        draw(Sprites.digit(seconds / 10, ex: ex), at: 78, 26)
        draw(Sprites.digit(seconds % 10, ex: ex), at: 90, 26)
    }

    private func drawMarquee() {
        let r = MainLayout.marquee
        let text = (sliderMessage ?? player.flashMessage ?? player.marqueeTitle).uppercased()
        let fits = text.count * 5 <= Int(r.width)
        clip(r) {
            if fits || sliderMessage != nil || player.flashMessage != nil {
                drawText(text, at: r.origin)
            } else {
                // Winamp scrolls "title  ***  title  ***" one character at a time.
                let loop = text + "  ***  "
                let chars = Array(loop)
                let start = (marqueeDrag?.offset ?? marqueeOffset) % chars.count
                let visible = String((0..<32).map { chars[(start + $0) % chars.count] })
                drawText(visible, at: r.origin)
            }
        }
    }

    private func drawShaded() {
        draw(isActiveWindow ? Sprites.shadeBackgroundActive : Sprites.shadeBackground, at: .zero)
        drawTitleButtons(shade: true)
        let p = player
        if p.state != .stopped {
            let (neg, ms) = displayedTime()
            let t = Int(ms / 1000)
            lastDisplayedSecond = t
            drawText((neg ? "-" : " ") + String(format: "%02d:%02d", min(99, t / 60), t % 60), at: CGPoint(x: 127, y: 4))
        } else {
            lastDisplayedSecond = -1
        }
    }

    // MARK: Hits

    override func hits() -> [Hit] {
        let p = player
        var h: [Hit] = [
            Hit(rect: CGRect(origin: MainLayout.options, size: CGSize(width: 9, height: 9)), kind: .button("options") { [weak self] in
                guard let self else { return }
                Env.menus.optionsMenu().popUp(positioning: nil, at: NSPoint(x: 6 * self.scale, y: 12 * self.scale), in: self)
            }),
            Hit(rect: CGRect(origin: MainLayout.minimize, size: CGSize(width: 9, height: 9)), kind: .button("minimize") {
                Env.windows.visible.forEach { $0.miniaturize(nil) }
            }),
            Hit(rect: CGRect(origin: MainLayout.shade, size: CGSize(width: 9, height: 9)), kind: .button("shade") { [weak self] in self?.toggleShade() }),
            Hit(rect: CGRect(origin: MainLayout.close, size: CGSize(width: 9, height: 9)), kind: .button("close") { NSApp.terminate(nil) }),
        ]
        if isShaded {
            let transport: [(CGFloat, CGFloat, String, () -> Void)] = [
                (169, 7, "prev", p.previous), (176, 10, "play", p.playButton), (186, 9, "pause", p.pauseButton),
                (195, 9, "stop", p.stop), (204, 10, "next", p.next), (215, 10, "eject", { Env.menus.showAddLinkDialog() }),
            ]
            for (x, w, id, f) in transport { h.append(Hit(rect: CGRect(x: x, y: 2, width: w, height: 10), kind: .button(id, f))) }
            return h
        }

        let cb = MainLayout.clutterBar
        do { let hit: Hit = Hit(rect: CGRect(x: cb.x, y: cb.y + 3, width: 8, height: 8), kind: .button("clutterO") { [weak self] in
                guard let self else { return }
                Env.menus.optionsMenu().popUp(positioning: nil, at: NSPoint(x: 18 * self.scale, y: 25 * self.scale), in: self)
            })
            h.append(hit) }
        do { let hit: Hit = Hit(rect: CGRect(x: cb.x, y: cb.y + 11, width: 8, height: 7), kind: .button("clutterA") { Env.windows.toggleAlwaysOnTop() })
            h.append(hit) }
        do { let hit: Hit = Hit(rect: CGRect(x: cb.x, y: cb.y + 18, width: 8, height: 7), kind: .button("clutterI") { Env.menus.showTrackInfo() })
            h.append(hit) }
        do { let hit: Hit = Hit(rect: CGRect(x: cb.x, y: cb.y + 25, width: 8, height: 8), kind: .button("clutterD") { Env.windows.toggleDoubleSize() })
            h.append(hit) }
        do { let hit: Hit = Hit(rect: CGRect(x: cb.x, y: cb.y + 33, width: 8, height: 7), kind: .button("clutterV") { [weak self] in
                guard let self else { return }
                Env.menus.visualizerMenu().popUp(positioning: nil, at: NSPoint(x: 18 * self.scale, y: 60 * self.scale), in: self)
            })
            h.append(hit) }
        do { let hit: Hit = Hit(rect: MainLayout.time, kind: .button("time") {
                Settings.timeRemaining.toggle()
                p.notifyChanged()
            })
            h.append(hit) }
        do { let hit: Hit = Hit(rect: MainLayout.visualizer, kind: .button("vis") {
                // Without permission the first click asks for it instead of switching modes.
                if p.needsAudioPermission { p.requestAudioFeatures("visualizer"); return }
                let v = p.visualizer
                let all = ClassicVisualizer.Mode.allCases
                v.mode = all[(all.firstIndex(of: v.mode)! + 1) % all.count]
                p.visualizerChanged()
            })
            h.append(hit) }
        do { let hit: Hit = Hit(rect: MainLayout.marquee.insetBy(dx: 0, dy: -3), kind: .custom { [weak self] event, pt, phase in
                guard let self else { return }
                switch phase {
                case .down:
                    self.marqueeClick?.cancel()
                    self.marqueeDragged = false
                    if event.clickCount == 2 { // double-click the title → the track's SoundCloud page
                        self.marqueeDrag = nil
                        Env.menus.openOnSoundCloud()
                        return
                    }
                    self.marqueeDrag = (pt.x, self.marqueeOffset)
                    self.updateAnimationTimer()
                case .dragged:
                    if let d = self.marqueeDrag {
                        if abs(d.start - pt.x) >= 3 { self.marqueeDragged = true }
                        self.marqueeDrag = (d.start, max(0, d.offset + Int((d.start - pt.x) / 5)))
                        self.needsDisplay = true
                    }
                case .up:
                    if let d = self.marqueeDrag {
                        self.marqueeOffset = d.offset
                        if !self.marqueeDragged {
                            let click = DispatchWorkItem { Env.windows.toggle(Env.windows.artwork) }
                            self.marqueeClick = click
                            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: click)
                        }
                    }
                    self.marqueeDrag = nil
                    self.needsDisplay = true
                    self.updateAnimationTimer()
                }
            })
            h.append(hit) }
        do { let hit: Hit = Hit(rect: MainLayout.volume, kind: .slider("volume") { [weak self] pt, ended in
                let v = Int(((pt.x - MainLayout.volume.minX - 7) / 51 * 100).rounded())
                p.setVolume(v)
                self?.sliderMessage = ended ? nil : "VOLUME: \(p.volume)%"
                self?.updateAnimationTimer()
            })
            h.append(hit) }
        do { let hit: Hit = Hit(rect: MainLayout.balance, kind: .slider("balance") { [weak self] (pt: CGPoint, ended: Bool) in
                let fraction: CGFloat = (pt.x - MainLayout.balance.minX - 7) / 24
                p.setBalance(Int((fraction * 200 - 100).rounded()))
                let side: String = p.balance < 0 ? "LEFT" : "RIGHT"
                let msg: String = p.balance == 0 ? "CENTER" : "\(abs(p.balance))% \(side)"
                self?.sliderMessage = ended ? nil : "BALANCE: \(msg)"
                self?.updateAnimationTimer()
                if ended { p.audioFeatureUsed("balance") }
            })
            h.append(hit) }
        do { let hit: Hit = Hit(rect: CGRect(origin: MainLayout.eqButton, size: CGSize(width: 23, height: 12)), kind: .button("eqToggle") {
                Env.windows.toggle(Env.windows.equalizer)
            })
            h.append(hit) }
        do { let hit: Hit = Hit(rect: CGRect(origin: MainLayout.playlistButton, size: CGSize(width: 23, height: 12)), kind: .button("plToggle") {
                Env.windows.toggle(Env.windows.playlist)
            })
            h.append(hit) }
        do { let hit: Hit = Hit(rect: CGRect(origin: MainLayout.previous, size: CGSize(width: 23, height: 18)), kind: .button("prev", p.previous))
            h.append(hit) }
        do { let hit: Hit = Hit(rect: CGRect(origin: MainLayout.play, size: CGSize(width: 23, height: 18)), kind: .button("play", p.playButton))
            h.append(hit) }
        do { let hit: Hit = Hit(rect: CGRect(origin: MainLayout.pause, size: CGSize(width: 23, height: 18)), kind: .button("pause", p.pauseButton))
            h.append(hit) }
        do { let hit: Hit = Hit(rect: CGRect(origin: MainLayout.stop, size: CGSize(width: 23, height: 18)), kind: .button("stop", p.stop))
            h.append(hit) }
        do { let hit: Hit = Hit(rect: CGRect(origin: MainLayout.next, size: CGSize(width: 22, height: 18)), kind: .button("next", p.next))
            h.append(hit) }
        do { let hit: Hit = Hit(rect: CGRect(origin: MainLayout.eject, size: CGSize(width: 22, height: 16)), kind: .button("eject") { Env.menus.showAddLinkDialog() })
            h.append(hit) }
        do { let hit: Hit = Hit(rect: CGRect(origin: MainLayout.shuffle, size: CGSize(width: 47, height: 15)), kind: .button("shuffle", p.toggleShuffle))
            h.append(hit) }
        do { let hit: Hit = Hit(rect: CGRect(origin: MainLayout.repeatButton, size: CGSize(width: 28, height: 15)), kind: .button("repeat", p.toggleRepeat))
            h.append(hit) }
        do { let hit: Hit = Hit(rect: MainLayout.about, kind: .button("about") { Env.menus.showAbout() })
            h.append(hit) }
        if p.state != .stopped, p.durationMs > 0 {
            h.append(Hit(rect: MainLayout.position, kind: .slider("position") { [weak self] pt, ended in
                guard let self else { return }
                let f = max(0, min(1, (pt.x - MainLayout.position.minX - 14.5) / (248 - 29)))
                if ended {
                    self.scrubFraction = nil
                    self.sliderMessage = nil
                    self.updateAnimationTimer()
                    p.seek(fraction: f)
                } else {
                    self.scrubFraction = f
                    self.sliderMessage = "SEEK TO: \(formatTime(f * p.durationMs))/\(formatTime(p.durationMs)) (\(Int(f * 100))%)"
                    self.updateAnimationTimer()
                }
            }))
        }
        return h
    }

    override func mouseDown(with event: NSEvent) {
        let pt = skinPoint(event)
        if event.clickCount == 2, pt.y < 14, !hits().contains(where: { $0.rect.contains(pt) }) {
            toggleShade()
            return
        }
        super.mouseDown(with: event)
        syncPositionThumbLayer(force: false)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        syncPositionThumbLayer(force: false)
    }

    override func scrollWheel(with event: NSEvent) {
        player.setVolume(player.volume + Int((event.scrollingDeltaY > 0 ? 1 : -1) * max(1, abs(event.scrollingDeltaY) / 3)))
    }
}
