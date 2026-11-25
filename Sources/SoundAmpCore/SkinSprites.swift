import CoreGraphics

// Sprite coordinates and window layout of classic (Winamp 2.x) skins.
// Ported from Webamp's skinSprites.ts and CSS (MIT, github.com/captbaritone/webamp).

public enum SkinSheet: String, CaseIterable {
    case main, cbuttons, titlebar, shufrep, posbar, volume, balance, monoster, playpaus
    case numbers, numsEx = "nums_ex", text, eqmain, eqEx = "eq_ex", pledit, gen
}

public struct Sprite: Hashable {
    public let sheet: SkinSheet
    public let rect: CGRect
    public init(_ sheet: SkinSheet, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        self.sheet = sheet
        rect = CGRect(x: x, y: y, width: w, height: h)
    }
    public var size: CGSize { rect.size }
}

/// A pair of normal / pressed sprites.
public struct ButtonSprites {
    public let normal: Sprite
    public let pressed: Sprite
}

public enum Sprites {
    // MAIN
    public static let mainBackground = Sprite(.main, 0, 0, 275, 116)

    // TITLEBAR
    public static let titleBar = Sprite(.titlebar, 27, 15, 275, 14)
    public static let titleBarActive = Sprite(.titlebar, 27, 0, 275, 14)
    public static let shadeBackground = Sprite(.titlebar, 27, 42, 275, 14)
    public static let shadeBackgroundActive = Sprite(.titlebar, 27, 29, 275, 14)
    public static let optionsButton = ButtonSprites(normal: Sprite(.titlebar, 0, 0, 9, 9), pressed: Sprite(.titlebar, 0, 9, 9, 9))
    public static let minimizeButton = ButtonSprites(normal: Sprite(.titlebar, 9, 0, 9, 9), pressed: Sprite(.titlebar, 9, 9, 9, 9))
    public static let shadeButton = ButtonSprites(normal: Sprite(.titlebar, 0, 18, 9, 9), pressed: Sprite(.titlebar, 9, 18, 9, 9))
    public static let unshadeButton = ButtonSprites(normal: Sprite(.titlebar, 0, 27, 9, 9), pressed: Sprite(.titlebar, 9, 27, 9, 9))
    public static let closeButton = ButtonSprites(normal: Sprite(.titlebar, 18, 0, 9, 9), pressed: Sprite(.titlebar, 18, 9, 9, 9))
    public static let clutterBarBackground = Sprite(.titlebar, 304, 0, 8, 43)
    public static let clutterO = Sprite(.titlebar, 304, 47, 8, 8)
    public static let clutterA = Sprite(.titlebar, 312, 55, 8, 7)
    public static let clutterI = Sprite(.titlebar, 320, 62, 8, 7)
    public static let clutterD = Sprite(.titlebar, 328, 69, 8, 8)
    public static let clutterV = Sprite(.titlebar, 336, 77, 8, 7)

    // CBUTTONS
    public static let previous = ButtonSprites(normal: Sprite(.cbuttons, 0, 0, 23, 18), pressed: Sprite(.cbuttons, 0, 18, 23, 18))
    public static let play = ButtonSprites(normal: Sprite(.cbuttons, 23, 0, 23, 18), pressed: Sprite(.cbuttons, 23, 18, 23, 18))
    public static let pause = ButtonSprites(normal: Sprite(.cbuttons, 46, 0, 23, 18), pressed: Sprite(.cbuttons, 46, 18, 23, 18))
    public static let stop = ButtonSprites(normal: Sprite(.cbuttons, 69, 0, 23, 18), pressed: Sprite(.cbuttons, 69, 18, 23, 18))
    public static let next = ButtonSprites(normal: Sprite(.cbuttons, 92, 0, 22, 18), pressed: Sprite(.cbuttons, 92, 18, 22, 18))
    public static let eject = ButtonSprites(normal: Sprite(.cbuttons, 114, 0, 22, 16), pressed: Sprite(.cbuttons, 114, 16, 22, 16))

    // SHUFREP — four states: off, off+pressed, on, on+pressed
    public static func shuffle(on: Bool, pressed: Bool) -> Sprite { Sprite(.shufrep, 28, (on ? 30 : 0) + (pressed ? 15 : 0), 47, 15) }
    public static func repeatButton(on: Bool, pressed: Bool) -> Sprite { Sprite(.shufrep, 0, (on ? 30 : 0) + (pressed ? 15 : 0), 28, 15) }
    public static func eqButton(on: Bool, pressed: Bool) -> Sprite { Sprite(.shufrep, pressed ? 46 : 0, on ? 73 : 61, 23, 12) }
    public static func playlistButton(on: Bool, pressed: Bool) -> Sprite { Sprite(.shufrep, pressed ? 69 : 23, on ? 73 : 61, 23, 12) }

    // POSBAR
    public static let positionBackground = Sprite(.posbar, 0, 0, 248, 10)
    public static let positionThumb = Sprite(.posbar, 248, 0, 29, 10)
    public static let positionThumbPressed = Sprite(.posbar, 278, 0, 29, 10)

    // VOLUME / BALANCE: 28 stacked 15px-tall frames, thumbs at y=422 (if present)
    public static func volumeBackground(frame: Int) -> Sprite { Sprite(.volume, 0, max(0, min(27, frame)) * 15, 68, 13) }
    public static let volumeThumb = Sprite(.volume, 15, 422, 14, 11)
    public static let volumeThumbPressed = Sprite(.volume, 0, 422, 14, 11)
    public static func balanceBackground(frame: Int) -> Sprite { Sprite(.balance, 9, max(0, min(27, frame)) * 15, 38, 13) }
    public static let balanceThumb = Sprite(.balance, 15, 422, 14, 11)
    public static let balanceThumbPressed = Sprite(.balance, 0, 422, 14, 11)

    // MONOSTER
    public static func stereo(_ on: Bool) -> Sprite { Sprite(.monoster, 0, on ? 0 : 12, 29, 12) }
    public static func mono(_ on: Bool) -> Sprite { Sprite(.monoster, 29, on ? 0 : 12, 27, 12) }

    // PLAYPAUS
    public static let playingIndicator = Sprite(.playpaus, 0, 0, 9, 9)
    public static let pausedIndicator = Sprite(.playpaus, 9, 0, 9, 9)
    public static let stoppedIndicator = Sprite(.playpaus, 18, 0, 9, 9)
    public static let workingIndicator = Sprite(.playpaus, 39, 0, 3, 9)
    public static let notWorkingIndicator = Sprite(.playpaus, 36, 0, 3, 9)

    // NUMBERS / NUMS_EX
    public static func digit(_ d: Int, ex: Bool) -> Sprite { Sprite(ex ? .numsEx : .numbers, d * 9, 0, 9, 13) }
    public static let minusSign = Sprite(.numbers, 20, 6, 5, 1)
    public static let noMinusSign = Sprite(.numbers, 9, 6, 5, 1)
    public static let minusSignEx = Sprite(.numsEx, 99, 0, 9, 13)
    public static let noMinusSignEx = Sprite(.numsEx, 90, 0, 9, 13)

    // EQMAIN
    public static let eqBackground = Sprite(.eqmain, 0, 0, 275, 116)
    public static let eqTitleBar = Sprite(.eqmain, 0, 149, 275, 14)
    public static let eqTitleBarActive = Sprite(.eqmain, 0, 134, 275, 14)
    public static let eqClose = ButtonSprites(normal: Sprite(.eqmain, 0, 116, 9, 9), pressed: Sprite(.eqmain, 0, 125, 9, 9))
    public static func eqOn(on: Bool, pressed: Bool) -> Sprite {
        Sprite(.eqmain, on ? (pressed ? 187 : 69) : (pressed ? 128 : 10), 119, 26, 12)
    }
    public static func eqAuto(on: Bool, pressed: Bool) -> Sprite {
        Sprite(.eqmain, on ? (pressed ? 213 : 95) : (pressed ? 154 : 36), 119, 32, 12)
    }
    public static let eqPresets = ButtonSprites(normal: Sprite(.eqmain, 224, 164, 44, 12), pressed: Sprite(.eqmain, 224, 176, 44, 12))
    public static let eqGraphBackground = Sprite(.eqmain, 0, 294, 113, 19)
    public static let eqGraphLineColors = Sprite(.eqmain, 115, 294, 1, 19)
    public static let eqPreampLine = Sprite(.eqmain, 0, 314, 113, 1)
    public static let eqSliderThumb = Sprite(.eqmain, 0, 164, 11, 11)
    public static let eqSliderThumbPressed = Sprite(.eqmain, 0, 176, 11, 11)
    /// Band slider background: 28 frames (14 per row, 15px apart; rows 65px apart). value 0…100 (50 = 0 dB).
    public static func eqSliderBackground(value: Double) -> Sprite {
        let n = Int((max(0, min(100, value)) / 100 * 27).rounded())
        return Sprite(.eqmain, 13 + (n % 14) * 15, 164 + (n / 14) * 65, 14, 63)
    }

    // PLEDIT
    public static let plTopLeft = Sprite(.pledit, 0, 21, 25, 20)
    public static let plTitle = Sprite(.pledit, 26, 21, 100, 20)
    public static let plTopTile = Sprite(.pledit, 127, 21, 25, 20)
    public static let plTopRight = Sprite(.pledit, 153, 21, 25, 20)
    public static let plTopLeftActive = Sprite(.pledit, 0, 0, 25, 20)
    public static let plTitleActive = Sprite(.pledit, 26, 0, 100, 20)
    public static let plTopTileActive = Sprite(.pledit, 127, 0, 25, 20)
    public static let plTopRightActive = Sprite(.pledit, 153, 0, 25, 20)
    public static let plLeftTile = Sprite(.pledit, 0, 42, 12, 29)
    /// The part of the title bar behind the title text.
    public static let plTitleBackground = Sprite(.pledit, 127, 24, 25, 8)
    public static let plRightTile = Sprite(.pledit, 31, 42, 20, 29)
    public static let plBottomTile = Sprite(.pledit, 179, 0, 25, 38)
    public static let plBottomLeft = Sprite(.pledit, 0, 72, 125, 38)
    public static let plBottomRight = Sprite(.pledit, 126, 72, 150, 38)
    public static let plVisualizerBackground = Sprite(.pledit, 205, 0, 75, 38)
    public static let plScrollHandle = Sprite(.pledit, 52, 53, 8, 18)
    public static let plScrollHandlePressed = Sprite(.pledit, 61, 53, 8, 18)
    public static let plClosePressed = Sprite(.pledit, 52, 42, 9, 9)

    // GEN: the frame Winamp gives extra windows (media library, video…).
    // Two title-bar states (active at y 0, inactive at y 21), six 25×20 pieces each.
    public static func genTop(_ piece: GenTopPiece, active: Bool) -> Sprite { Sprite(.gen, piece.rawValue * 26, active ? 0 : 21, 25, 20) }
    public static let genBottomLeft = Sprite(.gen, 0, 42, 125, 14)
    public static let genBottomRight = Sprite(.gen, 0, 57, 125, 14)
    public static let genBottomTile = Sprite(.gen, 127, 72, 25, 14)
    public static let genLeftTile = Sprite(.gen, 127, 42, 11, 29)
    public static let genRightTile = Sprite(.gen, 139, 42, 8, 29)
    public static let genLeftBottom = Sprite(.gen, 158, 42, 11, 24)
    public static let genRightBottom = Sprite(.gen, 170, 42, 8, 24)
    public static let genClosePressed = Sprite(.gen, 148, 42, 9, 9)

    // A slim frame cut from PLEDIT, for skins without gen.bmp: no scrollbar, no footer.
    // The right border is the left one mirrored. The bottom edge keeps only the footer's
    // inner edge (3 rows) and outer edge (8 rows), which are clear of its buttons.
    public static let plFrameLeftJoin = Sprite(.pledit, 0, 35, 12, 6)
    public static let plFrameLeftJoinActive = Sprite(.pledit, 0, 14, 12, 6)
    public static let plFrameBottomInner = (corner: Sprite(.pledit, 0, 72, 12, 3), tile: Sprite(.pledit, 179, 0, 25, 3))
    public static let plFrameBottomOuter = (corner: Sprite(.pledit, 0, 102, 12, 8), tile: Sprite(.pledit, 179, 30, 25, 8))

    // TEXT: 5×6 glyphs, 31 per row
    public static func character(_ c: Character) -> Sprite {
        let (row, col) = fontLookup[Character(c.lowercased())] ?? fontLookup[" "]!
        return Sprite(.text, col * 5, row * 6, 5, 6)
    }

    static let fontLookup: [Character: (Int, Int)] = {
        var t: [Character: (Int, Int)] = [:]
        for (i, ch) in "abcdefghijklmnopqrstuvwxyz".enumerated() { t[ch] = (0, i) }
        t["\""] = (0, 26); t["@"] = (0, 27); t[" "] = (0, 30)
        for (i, ch) in "0123456789".enumerated() { t[ch] = (1, i) }
        let row1: [(Character, Int)] = [
            ("…", 10), (".", 11), (":", 12), ("(", 13), (")", 14), ("-", 15), ("'", 16), ("!", 17), ("_", 18),
            ("+", 19), ("\\", 20), ("/", 21), ("[", 22), ("]", 23), ("^", 24), ("&", 25), ("%", 26), (",", 27),
            ("=", 28), ("$", 29), ("#", 30), ("<", 22), (">", 23), ("{", 22), ("}", 23),
        ]
        for (ch, col) in row1 { t[ch] = (1, col) }
        t["å"] = (2, 0); t["ö"] = (2, 1); t["ä"] = (2, 2); t["?"] = (2, 3); t["*"] = (2, 4)
        return t
    }()
}

/// A gen.bmp title letter, drawn as `body` with `lastRow` (if separate) right below.
public struct GenLetter {
    public let body: Sprite
    public let lastRow: Sprite?
    public var width: CGFloat { body.size.width }
}

public enum GenTopPiece: Int {
    case left, leftEnd, titleFill, rightEnd, fill, right
}

/// Border widths of a framed window.
public struct FrameLayout {
    public let top, left, bottom, right: CGFloat
    public static let gen = FrameLayout(top: 20, left: 11, bottom: 14, right: 8)
    public static let pledit = FrameLayout(top: 20, left: 12, bottom: 11, right: 12)

    /// The window size of this height whose content area is square.
    public func squareContentSize(height: CGFloat) -> CGSize {
        CGSize(width: height - top - bottom + left + right, height: height)
    }

    public func content(in size: CGSize) -> CGRect {
        CGRect(x: left, y: top, width: size.width - left - right, height: size.height - top - bottom)
    }
}

/// Where things go on the 275×116 main window.
public enum MainLayout {
    public static let size = CGSize(width: 275, height: 116)
    public static let titleBar = CGRect(x: 0, y: 0, width: 275, height: 14)
    public static let options = CGPoint(x: 6, y: 3)
    public static let minimize = CGPoint(x: 244, y: 3)
    public static let shade = CGPoint(x: 254, y: 3)
    public static let close = CGPoint(x: 264, y: 3)
    public static let clutterBar = CGPoint(x: 10, y: 22)
    public static let playStatus = CGPoint(x: 26, y: 28)
    public static let workIndicator = CGPoint(x: 24, y: 28)
    public static let time = CGRect(x: 39, y: 26, width: 59, height: 13)
    public static let visualizer = CGRect(x: 24, y: 43, width: 76, height: 16)
    public static let marquee = CGRect(x: 111, y: 27, width: 154, height: 6)
    public static let kbps = CGPoint(x: 111, y: 43)
    public static let khz = CGPoint(x: 156, y: 43)
    public static let mono = CGPoint(x: 212, y: 41)
    public static let stereo = CGPoint(x: 239, y: 41)
    public static let volume = CGRect(x: 107, y: 57, width: 68, height: 13)
    public static let balance = CGRect(x: 177, y: 57, width: 38, height: 13)
    public static let eqButton = CGPoint(x: 219, y: 58)
    public static let playlistButton = CGPoint(x: 242, y: 58)
    public static let position = CGRect(x: 16, y: 72, width: 248, height: 10)
    public static let previous = CGPoint(x: 16, y: 88)
    public static let play = CGPoint(x: 39, y: 88)
    public static let pause = CGPoint(x: 62, y: 88)
    public static let stop = CGPoint(x: 85, y: 88)
    public static let next = CGPoint(x: 108, y: 88)
    public static let eject = CGPoint(x: 136, y: 89)
    public static let shuffle = CGPoint(x: 164, y: 89)
    public static let repeatButton = CGPoint(x: 210, y: 89)
    public static let about = CGRect(x: 253, y: 91, width: 13, height: 15)
}

public enum EqLayout {
    public static let size = CGSize(width: 275, height: 116)
    public static let close = CGPoint(x: 264, y: 3)
    public static let on = CGPoint(x: 14, y: 18)
    public static let auto = CGPoint(x: 40, y: 18)
    public static let presets = CGPoint(x: 217, y: 18)
    public static let graph = CGPoint(x: 86, y: 17)
    public static let preamp = CGPoint(x: 21, y: 38)
    public static func band(_ i: Int) -> CGPoint { CGPoint(x: 78 + i * 18, y: 38) }
    public static let sliderSize = CGSize(width: 14, height: 63)
}

public enum PlaylistLayout {
    public static let minSize = CGSize(width: 275, height: 116)
    public static let segment = CGSize(width: 25, height: 29)
    public static let rowHeight: CGFloat = 13
    public static func listRect(in size: CGSize) -> CGRect {
        CGRect(x: 12, y: 20, width: size.width - 32, height: size.height - 58)
    }
}
