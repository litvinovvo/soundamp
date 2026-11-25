import AppKit
import SoundAmpCore

/// The classic 275×116 Winamp main window.
final class MainWindowView: SkinView {
    private(set) var isShaded = false
    private var timer: Timer?
    private var marqueeOffset = 0
    private var marqueeTick = 0
    private var blinkTick = 0
    /// While a slider is dragged, Winamp shows its value in the marquee.
    private var sliderMessage: String?
    private var scrubFraction: Double?
    private var marqueeClick: DispatchWorkItem?
    private var marqueeDragged = false
    private var marqueeDrag: (start: CGFloat, offset: Int)?

    override var skinSize: CGSize { isShaded ? CGSize(width: 275, height: 14) : MainLayout.size }

    override init(frame: NSRect) {
        super.init(frame: frame)
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func tick() {
        player.renderVisualizer()
        marqueeTick += 1
        if marqueeTick % 12 == 0 { marqueeOffset += 1 } // one character every 200 ms
        blinkTick += 1
        needsDisplay = true
    }

    // Hover hint over the scrolling title.
    override func layout() {
        super.layout()
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

        drawTime()

        // Visualizer (or a hint when macOS permission is missing)
        if p.needsAudioPermission, p.visualizer.mode != .off, p.state == .playing || p.state == .paused {
            clip(MainLayout.visualizer) {
                drawText("CLICK TO", at: CGPoint(x: MainLayout.visualizer.minX + 18, y: MainLayout.visualizer.minY + 1))
                drawText("ENABLE", at: CGPoint(x: MainLayout.visualizer.minX + 23, y: MainLayout.visualizer.minY + 9))
            }
        } else if let img = p.visualizer.makeImage() {
            draw(image: img, in: CGRect(origin: MainLayout.visualizer.origin, size: CGSize(width: 76, height: 16)))
        }

        drawMarquee()

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

        // Position bar
        draw(Sprites.positionBackground, at: MainLayout.position.origin)
        if p.state != .stopped, p.durationMs > 0 {
            let f = scrubFraction ?? p.positionMs / p.durationMs
            let x = MainLayout.position.minX + (max(0, min(1, f)) * (248 - 29)).rounded()
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
        guard p.state != .stopped else { return }
        if p.state == .paused, (blinkTick / 60) % 2 == 1 { return } // Winamp blinks the time when paused
        let (neg, ms) = displayedTime()
        let total = Int(ms / 1000)
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
            drawText((neg ? "-" : " ") + String(format: "%02d:%02d", min(99, t / 60), t % 60), at: CGPoint(x: 127, y: 4))
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
                case .dragged:
                    if let d = self.marqueeDrag {
                        if abs(d.start - pt.x) >= 3 { self.marqueeDragged = true }
                        self.marqueeDrag = (d.start, max(0, d.offset + Int((d.start - pt.x) / 5)))
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
                }
            })
            h.append(hit) }
        do { let hit: Hit = Hit(rect: MainLayout.volume, kind: .slider("volume") { [weak self] pt, ended in
                let v = Int(((pt.x - MainLayout.volume.minX - 7) / 51 * 100).rounded())
                p.setVolume(v)
                self?.sliderMessage = ended ? nil : "VOLUME: \(p.volume)%"
            })
            h.append(hit) }
        do { let hit: Hit = Hit(rect: MainLayout.balance, kind: .slider("balance") { [weak self] (pt: CGPoint, ended: Bool) in
                let fraction: CGFloat = (pt.x - MainLayout.balance.minX - 7) / 24
                p.setBalance(Int((fraction * 200 - 100).rounded()))
                let side: String = p.balance < 0 ? "LEFT" : "RIGHT"
                let msg: String = p.balance == 0 ? "CENTER" : "\(abs(p.balance))% \(side)"
                self?.sliderMessage = ended ? nil : "BALANCE: \(msg)"
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
                    p.seek(fraction: f)
                } else {
                    self.scrubFraction = f
                    self.sliderMessage = "SEEK TO: \(formatTime(f * p.durationMs))/\(formatTime(p.durationMs)) (\(Int(f * 100))%)"
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
    }

    override func scrollWheel(with event: NSEvent) {
        player.setVolume(player.volume + Int((event.scrollingDeltaY > 0 ? 1 : -1) * max(1, abs(event.scrollingDeltaY) / 3)))
    }
}
