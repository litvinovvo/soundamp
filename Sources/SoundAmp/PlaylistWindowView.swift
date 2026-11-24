import AppKit
import SoundAmpCore

/// The classic resizable playlist editor.
final class PlaylistWindowView: SkinView {
    private var segments = Settings.playlistSegments
    private var scrollRow = 0
    private var anchorRow: Int?
    private var reorderFrom: Int?
    private var resizeStart: (mouse: NSPoint, segments: (w: Int, h: Int))?
    private var scrollDragOffset: CGFloat?

    override var skinSize: CGSize {
        CGSize(width: 275 + 25 * CGFloat(segments.w), height: 116 + 29 * CGFloat(segments.h))
    }

    private var listRect: CGRect { PlaylistLayout.listRect(in: skinSize) }
    private var visibleRows: Int { max(1, Int(listRect.height / PlaylistLayout.rowHeight)) }
    private var maxScroll: Int { max(0, player.playlist.count - visibleRows) }

    private var font: NSFont {
        NSFont(name: skin.playlistStyle.font, size: 9) ?? .systemFont(ofSize: 9)
    }

    func scrollToCurrent() {
        guard let c = player.playlist.currentIndex else { return }
        if c < scrollRow || c >= scrollRow + visibleRows { scrollRow = min(maxScroll, max(0, c - visibleRows / 2)) }
    }

    // MARK: Drawing

    override func drawSkin() {
        let w = skinSize.width, h = skinSize.height
        let active = isActiveWindow
        let style = skin.playlistStyle
        scrollRow = min(scrollRow, maxScroll)

        // Frame: top
        draw(active ? Sprites.plTopLeftActive : Sprites.plTopLeft, at: .zero)
        tile(active ? Sprites.plTopTileActive : Sprites.plTopTile, in: CGRect(x: 25, y: 0, width: w - 50, height: 20))
        draw(active ? Sprites.plTitleActive : Sprites.plTitle, at: ((w - 100) / 2).rounded(.down), 0)
        draw(active ? Sprites.plTopRightActive : Sprites.plTopRight, at: w - 25, 0)
        // Sides
        tile(Sprites.plLeftTile, in: CGRect(x: 0, y: 20, width: 12, height: h - 58))
        tile(Sprites.plRightTile, in: CGRect(x: w - 20, y: 20, width: 20, height: h - 58))
        // Bottom
        draw(Sprites.plBottomLeft, at: 0, h - 38)
        tile(Sprites.plBottomTile, in: CGRect(x: 125, y: h - 38, width: w - 275, height: 38))
        if w >= 350 { draw(Sprites.plVisualizerBackground, at: w - 225, h - 38) }
        draw(Sprites.plBottomRight, at: w - 150, h - 38)
        if isPressed("close") { draw(Sprites.plClosePressed, at: w - 11, 3) }

        drawRows(style)

        // Scroll handle
        let track = listRect.height - 18
        let y = maxScroll == 0 ? 0 : (CGFloat(scrollRow) / CGFloat(maxScroll) * track).rounded()
        draw(isPressed("scroll") ? Sprites.plScrollHandlePressed : Sprites.plScrollHandle, at: w - 15, 20 + y)

        // Running time "sel/total" and the mini position display
        let pl = player.playlist
        let total = pl.totalDuration()
        let sel = pl.selection.isEmpty ? nil : pl.totalDuration(of: pl.selection)
        let text = "\(sel.map { formatTime($0.ms) } ?? "0:00")/\(formatTime(total.ms))\(total.complete ? "" : "+")"
        clip(CGRect(x: w - 143, y: h - 28, width: 90, height: 6)) { drawText(text, at: CGPoint(x: w - 143, y: h - 28)) }
        if player.state != .stopped {
            let t = Int(player.positionMs / 1000)
            drawText(String(format: "%2d:%02d", min(99, t / 60), t % 60), at: CGPoint(x: w - 84, y: h - 15))
        }
    }

    private func drawRows(_ style: PlaylistStyle) {
        let r = listRect
        fill(r, style.normalBG)
        let pl = player.playlist
        guard pl.count > 0 else {
            drawSystemText("Copy a SoundCloud track or playlist link", in: CGRect(x: r.minX + 3, y: r.minY + 2, width: r.width - 6, height: 12),
                           color: style.normal, font: font)
            drawSystemText("and press ⌘V here (or drop it on the window).", in: CGRect(x: r.minX + 3, y: r.minY + 15, width: r.width - 6, height: 12),
                           color: style.normal, font: font)
            return
        }
        let digits = String(pl.count).count
        clip(r) {
            for row in 0..<visibleRows + 1 {
                let i = scrollRow + row
                guard i < pl.count else { break }
                let t = pl[i]
                let y = r.minY + CGFloat(row) * PlaylistLayout.rowHeight
                let rowRect = CGRect(x: r.minX, y: y, width: r.width, height: PlaylistLayout.rowHeight)
                if pl.selection.contains(i) { fill(rowRect, style.selectedBG) }
                let color = i == pl.currentIndex ? style.current : style.normal
                let number = String(repeating: " ", count: max(0, digits - String(i + 1).count)) + "\(i + 1). "
                let duration = t.durationMs.map(formatTime) ?? ""
                let durWidth: CGFloat = duration.isEmpty ? 0 : CGFloat(duration.count) * 6 + 6
                drawSystemText(number + t.displayTitle, in: CGRect(x: r.minX + 2, y: y + 1, width: r.width - 4 - durWidth, height: 12),
                               color: color, font: font)
                if !duration.isEmpty {
                    drawSystemText(duration, in: CGRect(x: r.maxX - durWidth - 3, y: y + 1, width: durWidth, height: 12),
                                   color: color, font: font, alignRight: true)
                }
            }
        }
    }

    // MARK: Hits

    override func hits() -> [Hit] {
        let w = skinSize.width, h = skinSize.height
        let p = player
        var list: [Hit] = [
            Hit(rect: CGRect(x: w - 11, y: 3, width: 9, height: 9), kind: .button("close") { Env.windows.toggle(Env.windows.playlist) }),
            Hit(rect: listRect, kind: .custom { [weak self] e, pt, phase in self?.listMouse(e, pt, phase) }),
            Hit(rect: CGRect(x: w - 15, y: 20, width: 8, height: listRect.height), kind: .custom { [weak self] _, pt, phase in
                self?.scrollMouse(pt, phase)
            }),
            Hit(rect: CGRect(x: w - 20, y: h - 20, width: 20, height: 20), kind: .custom { [weak self] _, _, phase in
                self?.resizeMouse(phase)
            }),
        ]
        let menus: [(String, CGFloat, () -> NSMenu)] = [
            ("add", 14, { Env.menus.playlistAddMenu() }),
            ("rem", 43, { Env.menus.playlistRemoveMenu() }),
            ("sel", 72, { Env.menus.playlistSelectMenu() }),
            ("misc", 101, { Env.menus.playlistMiscMenu() }),
            ("list", w - 44, { Env.menus.playlistListMenu() }),
        ]
        for (id, x, make) in menus {
            list.append(Hit(rect: CGRect(x: x, y: h - 30, width: 22, height: 18), kind: .button(id) { [weak self] in
                guard let self else { return }
                make().popUp(positioning: nil, at: NSPoint(x: x * self.scale, y: (h - 30) * self.scale), in: self)
            }))
        }
        // Mini transport in the bottom-right corner.
        let transport: [(String, () -> Void)] = [("mprev", p.previous), ("mplay", p.playButton), ("mpause", p.pauseButton),
                                                 ("mstop", p.stop), ("mnext", p.next), ("meject", { Env.menus.showAddLinkDialog() })]
        for (k, (id, f)) in transport.enumerated() {
            list.append(Hit(rect: CGRect(x: w - 147 + CGFloat(k) * 8.5, y: h - 16, width: 8, height: 8), kind: .button(id, f)))
        }
        return list
    }

    private func row(at pt: CGPoint) -> Int? {
        let i = scrollRow + Int((pt.y - listRect.minY) / PlaylistLayout.rowHeight)
        return i >= 0 && i < player.playlist.count ? i : nil
    }

    private func listMouse(_ e: NSEvent, _ pt: CGPoint, _ phase: Hit.Phase) {
        let pl = player.playlist
        switch phase {
        case .down:
            guard let i = row(at: pt) else { pl.selection = IndexSet(); anchorRow = nil; needsDisplay = true; return }
            if e.clickCount == 2 { player.play(index: i); return }
            if e.modifierFlags.contains(.shift), let a = anchorRow {
                pl.selection = IndexSet(integersIn: min(a, i)...max(a, i))
            } else if e.modifierFlags.contains(.command) {
                if pl.selection.contains(i) { pl.selection.remove(i) } else { pl.selection.insert(i) }
                anchorRow = i
            } else {
                if !pl.selection.contains(i) { pl.selection = IndexSet(integer: i) }
                anchorRow = i
                reorderFrom = i
            }
            needsDisplay = true
        case .dragged:
            // Drag selected rows up/down (Winamp style).
            guard let from = reorderFrom, let to = row(at: pt) ?? (pt.y < listRect.minY ? scrollRow : nil), to != from else {
                if pt.y > listRect.maxY { scrollRow = min(maxScroll, scrollRow + 1) }
                return
            }
            let delta = to - from
            let sel = pl.selection
            guard let lo = sel.first, let hi = sel.last, lo + delta >= 0, hi + delta < pl.count else { return }
            pl.move(from: sel, to: delta > 0 ? hi + delta + 1 : lo + delta)
            reorderFrom = to
            anchorRow = (anchorRow ?? from) + delta
            needsDisplay = true
        case .up:
            if let i = row(at: pt), reorderFrom == i, !e.modifierFlags.contains(.shift), !e.modifierFlags.contains(.command) {
                pl.selection = IndexSet(integer: i)
            }
            reorderFrom = nil
            needsDisplay = true
        }
    }

    private func scrollMouse(_ pt: CGPoint, _ phase: Hit.Phase) {
        let track = listRect.height - 18
        switch phase {
        case .down, .dragged:
            let f = max(0, min(1, (pt.y - 20 - 9) / max(1, track)))
            scrollRow = Int((f * CGFloat(maxScroll)).rounded())
            scrollDragOffset = pt.y
        case .up:
            scrollDragOffset = nil
        }
        needsDisplay = true
    }

    private func resizeMouse(_ phase: Hit.Phase) {
        let m = NSEvent.mouseLocation
        switch phase {
        case .down:
            resizeStart = (m, segments)
        case .dragged:
            guard let s = resizeStart else { return }
            let sc = Env.windows.scale
            let dw = Int(((m.x - s.mouse.x) / sc / 25).rounded())
            let dh = Int(((s.mouse.y - m.y) / sc / 29).rounded())
            let new = (w: max(0, s.segments.w + dw), h: max(0, s.segments.h + dh))
            if new != segments {
                segments = new
                Settings.playlistSegments = new
                Env.windows.playlistResized()
            }
        case .up:
            resizeStart = nil
            Env.windows.savePositions()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let d = event.scrollingDeltaY
        guard d != 0 else { return }
        let step = event.hasPreciseScrollingDeltas ? Int((d / 8).rounded()) : (d > 0 ? 3 : -3)
        scrollRow = max(0, min(maxScroll, scrollRow - (step == 0 ? (d > 0 ? 1 : -1) : step)))
        needsDisplay = true
    }

    // MARK: Keyboard / edit menu

    override func keyDown(with event: NSEvent) {
        let pl = player.playlist
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            pl.remove(pl.selection)
            return
        case 36, 76: // return, enter
            if let i = pl.selection.first { player.play(index: i) }
            return
        case 125, 126: // down / up
            let dir = event.keyCode == 125 ? 1 : -1
            let base = (dir > 0 ? pl.selection.last : pl.selection.first) ?? (dir > 0 ? -1 : pl.count)
            let i = max(0, min(pl.count - 1, base + dir))
            guard pl.count > 0 else { return }
            pl.selection = event.modifierFlags.contains(.shift) ? pl.selection.union(IndexSet(integer: i)) : IndexSet(integer: i)
            if i < scrollRow { scrollRow = i } else if i >= scrollRow + visibleRows { scrollRow = i - visibleRows + 1 }
            needsDisplay = true
            return
        default:
            super.keyDown(with: event)
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        player.playlist.selection = IndexSet(integersIn: 0..<player.playlist.count)
        needsDisplay = true
    }

    /// ⌘C copies the selected tracks' SoundCloud links.
    /// Right-click a song: its own menu (selecting it first, Finder-style);
    /// elsewhere: the usual options menu.
    override func rightMouseDown(with event: NSEvent) {
        let pt = skinPoint(event)
        guard listRect.contains(pt), let i = row(at: pt) else { return super.rightMouseDown(with: event) }
        let pl = player.playlist
        if !pl.selection.contains(i) { pl.selection = IndexSet(integer: i) }
        anchorRow = i
        needsDisplay = true
        NSMenu.popUpContextMenu(Env.menus.trackMenu(index: i), with: event, for: self)
    }

    @objc func copy(_ sender: Any?) {
        Env.menus.copyLinks(selectedOnly: true)
    }
}
