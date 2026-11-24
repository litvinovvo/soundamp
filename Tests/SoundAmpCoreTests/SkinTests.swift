import XCTest
@testable import SoundAmpCore

final class ZipArchiveTests: XCTestCase {
    /// Builds a real zip with /usr/bin/zip: one stored, one deflated, one in a folder.
    private func makeZip() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soundamp-zip-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data(String(repeating: "winamp it really whips ", count: 200).utf8).write(to: dir.appendingPathComponent("Sub/Main.BMP"))
        let out = dir.appendingPathComponent("test.wsz")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-q", "-r", out.path, "a.txt", "Sub"]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return out
    }

    func testReadsStoredAndDeflatedEntries() throws {
        let zip = try ZipArchive(contentsOf: makeZip())
        let a = try XCTUnwrap(zip.entry(named: "A.TXT"))
        XCTAssertEqual(try String(data: zip.extract(a), encoding: .utf8), "hello")
        // Case-insensitive, ignores folders inside the archive.
        let main = try XCTUnwrap(zip.entry(base: "main", extensions: ["bmp", "png"]))
        XCTAssertEqual(main.method, 8)
        XCTAssertTrue(try String(decoding: zip.extract(main), as: UTF8.self).hasPrefix("winamp it really whips"))
    }

    func testRefusesHugeEntries() throws {
        // A real zip whose central directory then lies about the size (zip-bomb style).
        var data = try Data(contentsOf: makeZip())
        let sig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        let at = try XCTUnwrap(data.firstRange(of: Data(sig))).lowerBound
        data.replaceSubrange((at + 24)..<(at + 28), with: [0xF0, 0xFF, 0xFF, 0xFF]) // uncompressed size ≈ 4 GB
        let zip = try ZipArchive(data: data)
        XCTAssertThrowsError(try zip.extract(zip.entries[0])) { error in
            guard case ZipArchive.ZipError.tooLarge = error else { return XCTFail("\(error)") }
        }
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try ZipArchive(data: Data(repeating: 7, count: 100)))
        XCTAssertThrowsError(try ZipArchive(data: Data()))
    }
}

final class SkinTextTests: XCTestCase {
    func testVisColorsWithCommentsAndOddSpacing() {
        let c = SkinText.parseVisColors("0,0,0, // bg\n24 33 41\n  239,49,16,// top\nnot a color\n")
        XCTAssertEqual(c.count, 24)
        XCTAssertEqual(c[0], RGBA(0, 0, 0))
        XCTAssertEqual(c[1], RGBA(24, 33, 41))
        XCTAssertEqual(c[2], RGBA(239, 49, 16))
        XCTAssertEqual(c[23], SkinText.defaultVisColors[23], "missing lines keep defaults")
    }

    func testPlaylistStyleToleratesMissingHashAndLongValues() {
        let s = PlaylistStyle.parse("[Text]\nNormal=00FF00\nCurrent=#FFFFFF00\nnormalbg=#000000\nSelectedBG=#0000C6\nFont=Tahoma\n")
        XCTAssertEqual(s.normal, RGBA(0, 255, 0))
        XCTAssertEqual(s.current, RGBA(255, 255, 255))
        XCTAssertEqual(s.selectedBG, RGBA(0, 0, 198))
        XCTAssertEqual(s.font, "Tahoma")
    }

    func testRegionPolygons() {
        let r = SkinRegion.parse("""
        ; comment
        [Normal]
        NumPoints=4,4
        PointList=0,0, 275,0, 275,14, 0,14,  0 14 275 14 275 116 0 116
        [Equalizer]
        NumPoints=2
        PointList=0,0 1,1
        """)
        XCTAssertEqual(r["normal"]?.count, 2)
        XCTAssertEqual(r["normal"]?[1][2].x, 275)
        XCTAssertNil(r["equalizer"], "polygons with < 3 points are dropped")
    }

    func testFontLookup() {
        XCTAssertEqual(Sprites.character("A"), Sprites.character("a"))
        XCTAssertEqual(Sprites.character("a").rect, CGRect(x: 0, y: 0, width: 5, height: 6))
        XCTAssertEqual(Sprites.character("7").rect.origin, CGPoint(x: 35, y: 6))
        XCTAssertEqual(Sprites.character("☃"), Sprites.character(" "), "unknown → space")
    }

    func testEqSliderFrames() {
        XCTAssertEqual(Sprites.eqSliderBackground(value: 0).rect.origin, CGPoint(x: 13, y: 164))
        XCTAssertEqual(Sprites.eqSliderBackground(value: 100).rect.origin, CGPoint(x: 13 + 13 * 15, y: 164 + 65))
    }
}

/// Loads the bundled classic skins (run scripts/fetch-skins.sh first).
final class BundledSkinTests: XCTestCase {
    static let skinsDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Skins")

    private func base() throws -> Skin {
        let url = Self.skinsDir.appendingPathComponent("base-2.91.wsz")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "run scripts/fetch-skins.sh")
        return try Skin(contentsOf: url, fallback: nil)
    }

    func testBaseSkin() throws {
        let skin = try base()
        for sheet in SkinSheet.allCases where sheet != .numsEx {
            XCTAssertTrue(skin.hasOwn(sheet), "base skin has \(sheet)")
        }
        XCTAssertEqual(skin.sheet(.main)?.width, 275)
        XCTAssertEqual(skin.sheet(.main)?.height, 116)
        XCTAssertEqual(skin.visColors[2], RGBA(239, 49, 16))
        XCTAssertEqual(skin.playlistStyle.normal, RGBA(0, 255, 0))
        XCTAssertEqual(skin.playlistStyle.selectedBG, RGBA(0, 0, 198))
        XCTAssertFalse(skin.usesNumsEx)
        XCTAssertTrue(skin.hasSliderThumbs(.volume))
        let play = try XCTUnwrap(skin.image(Sprites.play.normal))
        XCTAssertEqual(play.width, 23)
        XCTAssertEqual(play.height, 18)
        XCTAssertNotNil(skin.image(Sprites.character("w")))
        XCTAssertNotNil(skin.image(Sprites.eqSliderBackground(value: 50)))
        XCTAssertNotNil(skin.image(Sprites.plBottomRight))
    }

    func testEveryBundledSkinLoads() throws {
        let fallback = try base()
        let files = try FileManager.default.contentsOfDirectory(at: Self.skinsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wsz" }
        XCTAssertGreaterThanOrEqual(files.count, 2)
        for url in files {
            let skin = try Skin(contentsOf: url, fallback: fallback)
            XCTAssertTrue(skin.hasOwn(.main), "\(url.lastPathComponent) has its own main.bmp")
            XCTAssertNotNil(skin.image(Sprites.mainBackground), url.lastPathComponent)
            XCTAssertNotNil(skin.image(Sprites.titleBarActive), url.lastPathComponent)
            XCTAssertNotNil(skin.image(Sprites.digit(0, ex: skin.usesNumsEx)), url.lastPathComponent)
            XCTAssertEqual(skin.visColors.count, 24)
        }
    }

    func testSkinInsideFolderAndNumsExOnly() throws {
        let fallback = try base()
        // XMMS-Turquoise keeps its bitmaps in a sub-folder.
        let xmms = try Skin(contentsOf: Self.skinsDir.appendingPathComponent("XMMS-Turquoise.wsz"), fallback: fallback)
        XCTAssertTrue(xmms.hasOwn(.main))
        XCTAssertTrue(xmms.hasOwn(.pledit))
        // Internet-Archive ships nums_ex.bmp but no numbers.bmp.
        let ia = try Skin(contentsOf: Self.skinsDir.appendingPathComponent("Internet-Archive.wsz"), fallback: fallback)
        XCTAssertTrue(ia.usesNumsEx)
        XCTAssertNotNil(ia.image(Sprites.minusSignEx))
    }

    func testMissingBitmapsFallBackToBaseSkin() throws {
        let fallback = try base()
        // Vizor has no gen.bmp/nums_ex — and we only need to know fallback works for a sheet it lacks.
        let vizor = try Skin(contentsOf: Self.skinsDir.appendingPathComponent("Vizor1-01.wsz"), fallback: fallback)
        XCTAssertFalse(vizor.hasOwn(.numsEx))
        XCTAssertNotNil(vizor.sheet(.numbers))
    }

    func testNotASkin() {
        XCTAssertThrowsError(try Skin(name: "x", archive: ZipArchive(data: Data([0x50, 0x4B, 5, 6] + [UInt8](repeating: 0, count: 18))), fallback: nil))
    }
}

final class SkinLinkTests: XCTestCase {
    func testMuseumPageLinkMapsToTheFile() {
        let l = SkinLink.parse("https://skins.webamp.org/skin/b0fb83cc20af3abe264291bb17fb2a13/Winamp5_Classified_v5.5.wsz")
        XCTAssertEqual(l?.download.absoluteString, "https://r2.webampskins.org/skins/b0fb83cc20af3abe264291bb17fb2a13.wsz")
        XCTAssertEqual(l?.fileName, "Winamp5_Classified_v5.5.wsz")
        // page link without a file name
        XCTAssertEqual(SkinLink.parse("https://skins.webamp.org/skin/B0FB83CC20AF3ABE264291BB17FB2A13/")?.fileName,
                       "b0fb83cc20af3abe264291bb17fb2a13.wsz")
    }

    func testDirectLinks() {
        let l = SkinLink.parse("https://example.com/skins/My%20Cool%20Skin.WSZ?download=1")
        XCTAssertEqual(l?.download.absoluteString, "https://example.com/skins/My%20Cool%20Skin.WSZ?download=1")
        XCTAssertEqual(l?.fileName, "My Cool Skin.WSZ")
    }

    func testRejectsNonSkins() {
        for s in ["https://soundcloud.com/forss/flickermood", "https://example.com/skin.zip", "ftp://x.org/a.wsz",
                  "https://skins.webamp.org/about", "https://skins.webamp.org/skin/nothex/x.wsz", "file:///tmp/a.wsz"] {
            XCTAssertNil(SkinLink.parse(s), s)
        }
        XCTAssertTrue(SkinLink.isModernSkinLink("https://example.com/Bento.wal"))
    }

    func testFindsLinksInDroppedText() {
        let text = "get it: https://skins.webamp.org/skin/b0fb83cc20af3abe264291bb17fb2a13/Winamp5_Classified_v5.5.wsz, "
            + "or https://example.com/a.wsz and https://soundcloud.com/forss/flickermood"
        XCTAssertEqual(SkinLink.links(in: text).map(\.fileName), ["Winamp5_Classified_v5.5.wsz", "a.wsz"])
    }

    func testFileNamesAreSanitized() {
        XCTAssertEqual(SkinLink.sanitize("..%2F..%2Fetc%2Fevil.wsz"), "_.._etc_evil.wsz")
        XCTAssertEqual(SkinLink.sanitize(".hidden"), "hidden.wsz")
        XCTAssertEqual(SkinLink.sanitize(""), "skin.wsz")
    }
}

