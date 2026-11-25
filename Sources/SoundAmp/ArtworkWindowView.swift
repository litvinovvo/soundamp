import AppKit
import ImageIO
import SoundAmpCore

/// The current track's cover in a skinned window: title bar, borders and resize
/// grip from gen.bmp, or cut from the playlist's bitmap if the skin has no gen.bmp.
final class ArtworkWindowView: SkinView {
    private static let title = "ARTWORK"
    private static let minHeight: CGFloat = 174

    private var height = max(minHeight, CGFloat(Settings.artworkHeight))
    private var artworkURL: URL?
    private var artwork: CGImage?
    private var artworkTask: Task<Void, Never>?
    private var resizeStart: (mouse: NSPoint, height: CGFloat)?
    private var dragStart: NSPoint?

    private var frameLayout: FrameLayout { skin.hasGenFrame ? .gen : .pledit }
    override var skinSize: CGSize { frameLayout.squareContentSize(height: height) }

    private var contentRect: CGRect { frameLayout.content(in: skinSize) }
    private var closeRect: CGRect { CGRect(x: skinSize.width - 11, y: 3, width: 9, height: 9) }

    private var gripRect: CGRect { CGRect(x: skinSize.width - 20, y: height - 20, width: 20, height: 20) }

    // MARK: Artwork

    override func redraw() {
        super.redraw()
        // The window is a little wider or narrower depending on the skin's borders.
        if let window, Env.windows != nil, abs(window.frame.width - skinSize.width * scale) > 1 {
            Env.windows.resized(Env.windows.artwork, keepDockedEdge: true)
        }
        guard window?.isVisible == true || NSApp.activationPolicy() == .prohibited else { return }
        let url = player.playlist.current?.artworkURL.flatMap { URL(string: $0) }
        guard url != artworkURL else { return }
        artworkTask?.cancel()
        artworkURL = url
        artwork = nil
        window?.invalidateCursorRects(for: self)
        guard let url, url.scheme == "https" else { return }
        artworkTask = Task { [weak self] in
            let preferred = Self.highResolutionURL(for: url)
            if let preferred, let image = await Self.loadArtwork(at: preferred) {
                self?.showArtwork(image, for: url)
            } else if !Task.isCancelled, let image = await Self.loadArtwork(at: url) {
                self?.showArtwork(image, for: url)
            }
        }
    }

    private static func highResolutionURL(for url: URL) -> URL? {
        guard let host = url.host, host.hasSuffix(".sndcdn.com"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.percentEncodedPath
        guard let suffix = path.range(of: #"-(?:large|small|tiny|mini|badge|crop|original|t[0-9]+x[0-9]+)(?=\.[^./]+$)"#,
                                      options: .regularExpression) else { return nil }
        components.percentEncodedPath = path.replacingCharacters(in: suffix, with: "-t1080x1080")
        guard components.url != url else { return nil }
        return components.url
    }

    private nonisolated static func loadArtwork(at url: URL) async -> CGImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1080,
        ] as [CFString: Any]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func showArtwork(_ image: CGImage, for url: URL) {
        guard !Task.isCancelled, artworkURL == url else { return }
        artwork = image
        needsDisplay = true
    }

    // MARK: Drawing

    override func drawSkin() {
        if skin.hasGenFrame { drawGenFrame() } else { drawPlaylistFrame() }
        drawContent()
    }

    private func drawContent() {
        let r = contentRect
        fill(r, skin.playlistStyle.normalBG)
        if let artwork {
            // Covers are square; crop the odd one that isn't.
            let factor = max(r.width / CGFloat(artwork.width), r.height / CGFloat(artwork.height))
            let size = CGSize(width: CGFloat(artwork.width) * factor, height: CGFloat(artwork.height) * factor)
            clip(r) {
                draw(image: artwork, in: CGRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2,
                                                width: size.width, height: size.height), interpolation: .high)
            }
        } else if artworkURL == nil {
            drawCentered("No artwork", in: CGRect(x: r.minX, y: r.midY - 6, width: r.width, height: 12),
                         color: skin.playlistStyle.normal, font: NSFont(name: skin.playlistStyle.font, size: 9) ?? .systemFont(ofSize: 9))
        }
    }

    private func drawGenFrame() {
        let w = skinSize.width, h = skinSize.height
        let active = isActiveWindow
        let f = FrameLayout.gen

        // Title bar: corner · fill · end · title · end · fill · corner
        let letters = skin.genLetters(active: active)
        let textWidth = Self.title.reduce(0) { $0 + (letters[$1]?.width ?? 5) }
        let titleWidth = textWidth + 8
        let titleX = ((w - titleWidth) / 2).rounded(.down)
        tile(Sprites.genTop(.fill, active: active), in: CGRect(x: 25, y: 0, width: titleX - 50, height: 20))
        tile(Sprites.genTop(.fill, active: active), in: CGRect(x: titleX + titleWidth + 25, y: 0, width: w - titleX - titleWidth - 50, height: 20))
        tile(Sprites.genTop(.titleFill, active: active), in: CGRect(x: titleX, y: 0, width: titleWidth, height: 20))
        draw(Sprites.genTop(.leftEnd, active: active), at: titleX - 25, 0)
        draw(Sprites.genTop(.rightEnd, active: active), at: titleX + titleWidth, 0)
        draw(Sprites.genTop(.left, active: active), at: 0, 0)
        draw(Sprites.genTop(.right, active: active), at: w - 25, 0)
        var x = titleX + 4
        for c in Self.title {
            if let letter = letters[c] {
                draw(letter.body, at: x, 4)
                draw(letter.lastRow, at: x, 4 + letter.body.size.height)
            }
            x += letters[c]?.width ?? 5
        }

        // Sides
        tile(Sprites.genLeftTile, in: CGRect(x: 0, y: f.top, width: f.left, height: h - f.top - f.bottom))
        tile(Sprites.genRightTile, in: CGRect(x: w - f.right, y: f.top, width: f.right, height: h - f.top - f.bottom))
        draw(Sprites.genLeftBottom, at: 0, h - f.bottom - 24)
        draw(Sprites.genRightBottom, at: w - f.right, h - f.bottom - 24)

        // Bottom: two 125-wide corners, which meet in the middle of narrow windows
        tile(Sprites.genBottomTile, in: CGRect(x: 125, y: h - f.bottom, width: w - 250, height: f.bottom))
        let half = min(125, (w / 2).rounded(.up))
        clip(CGRect(x: 0, y: h - f.bottom, width: half, height: f.bottom)) { draw(Sprites.genBottomLeft, at: 0, h - f.bottom) }
        clip(CGRect(x: w - half, y: h - f.bottom, width: half, height: f.bottom)) { draw(Sprites.genBottomRight, at: w - 125, h - f.bottom) }

        if isPressed("close") { draw(Sprites.genClosePressed, at: closeRect.origin) }
    }

    private func drawPlaylistFrame() {
        let w = skinSize.width, h = skinSize.height
        let active = isActiveWindow
        let f = FrameLayout.pledit

        draw(active ? Sprites.plTopLeftActive : Sprites.plTopLeft, at: .zero)
        let top = active ? Sprites.plTopTileActive : Sprites.plTopTile
        tile(top, in: CGRect(x: 25, y: 0, width: w - 50, height: 20))
        draw(active ? Sprites.plTopRightActive : Sprites.plTopRight, at: w - 25, 0)
        let dark = skin.averageLuminance(Sprites.plTitleBackground) < 0.5
        let ink = dark ? RGBA(255, 255, 255) : RGBA(0, 0, 0)
        drawCentered(Self.title, in: CGRect(x: 30, y: 1, width: w - 60, height: 11), color: ink,
                     font: .systemFont(ofSize: 7.5, weight: .bold), alpha: active ? 0.9 : 0.5)

        // Below the title: bottom edge, then the left border and the same mirrored on the right.
        // Corners come last, as the header's right corner is made to continue into a scrollbar.
        let inner = Sprites.plFrameBottomInner, outer = Sprites.plFrameBottomOuter
        tile(inner.tile, in: CGRect(x: f.left, y: h - 11, width: w - f.left - f.right, height: 3))
        tile(outer.tile, in: CGRect(x: f.left, y: h - 8, width: w - f.left - f.right, height: 8))
        let join = active ? Sprites.plFrameLeftJoinActive : Sprites.plFrameLeftJoin
        clip(CGRect(x: w - 25, y: 14, width: 25, height: 6)) { draw(top, at: w - 25, 0) }
        for right in [false, true] {
            mirrored(right) {
                draw(join, at: 0, 14)
                tile(Sprites.plLeftTile, in: CGRect(x: 0, y: f.top, width: f.left, height: h - f.top - f.bottom))
                draw(inner.corner, at: 0, h - 11)
                draw(outer.corner, at: 0, h - 8)
            }
        }
        if isPressed("close") { draw(Sprites.plClosePressed, at: closeRect.origin) }
    }

    // MARK: Mouse & keyboard

    override func hits() -> [Hit] {
        [
            Hit(rect: contentRect, kind: .custom { [weak self] event, _, phase in self?.artworkMouse(event, phase) }),
            Hit(rect: closeRect, kind: .button("close") { Env.windows.toggle(Env.windows.artwork) }),
            Hit(rect: gripRect, kind: .custom { [weak self] _, _, phase in
                self?.resizeMouse(phase)
            }),
        ]
    }

    /// Click the cover to open the track on SoundCloud; drag it to move the window.
    private func artworkMouse(_ event: NSEvent, _ phase: Hit.Phase) {
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .down:
            dragStart = mouse
        case .dragged:
            if let start = dragStart {
                guard abs(mouse.x - start.x) >= 3 || abs(mouse.y - start.y) >= 3 else { return }
                dragStart = nil
                Env.windows.beginDrag(window, event: event)
            }
            Env.windows.drag(event: event)
        case .up:
            if dragStart == nil {
                Env.windows.endDrag()
            } else if event.clickCount == 1, player.playlist.current?.webURL != nil {
                Env.menus.openOnSoundCloud()
            }
            dragStart = nil
        }
    }

    private func resizeMouse(_ phase: Hit.Phase) {
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .down:
            resizeStart = (mouse, height)
        case .dragged:
            guard let start = resizeStart else { return }
            let delta = max(mouse.x - start.mouse.x, start.mouse.y - mouse.y) / scale
            let new = Env.windows.artworkHeight(dragged: (start.height + delta).rounded(), minimum: Self.minHeight,
                                                    extraWidth: skinSize.width - height)
            guard new != height else { return }
            height = new
            Env.windows.resized(Env.windows.artwork)
        case .up:
            resizeStart = nil
            Settings.artworkHeight = Double(height)
            Env.windows.savePositions()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let grip = gripRect
        if #available(macOS 15, *) {
            addCursorRect(CGRect(x: grip.minX * scale, y: grip.minY * scale, width: grip.width * scale, height: grip.height * scale),
                          cursor: .frameResize(position: .bottomRight, directions: .all))
        }
        guard player.playlist.current?.webURL != nil else { return }
        let r = contentRect
        addCursorRect(CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale), cursor: .pointingHand)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { Env.windows.toggle(Env.windows.artwork) } else { super.keyDown(with: event) }
    }
}
