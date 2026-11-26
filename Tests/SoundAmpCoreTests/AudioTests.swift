import XCTest
import ImageIO
@testable import SoundAmpCore

private func sine(_ hz: Double, amplitude: Float = 0.8, count: Int = 1024, rate: Double = 48_000) -> [Float] {
    (0..<count).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
}

final class ClassicVisualizerTests: XCTestCase {
    func testSilenceDrawsOnlyBackgroundGrid() {
        let vis = ClassicVisualizer()
        vis.render(samples: [Float](repeating: 0, count: 1024))
        let bg = vis.colors[0].packed, dot = vis.colors[1].packed
        XCTAssertTrue(vis.pixels.allSatisfy { $0 == bg || $0 == dot })
        XCTAssertEqual(vis.pixels[1 * 76 + 0], dot, "dots on even x, odd y")
        XCTAssertEqual(vis.pixels[0], bg)
    }

    func testLowAndHighToneLightUpDifferentColumns() {
        func peakColumn(_ hz: Double) -> Int {
            let vis = ClassicVisualizer()
            vis.bandwidth = .thin
            vis.render(samples: sine(hz))
            return vis.barHeights[0..<75].enumerated().max { $0.element < $1.element }!.offset
        }
        let low = peakColumn(200), mid = peakColumn(2_000), high = peakColumn(10_000)
        XCTAssertLessThan(low, mid)
        XCTAssertLessThan(mid, high)
    }

    func testBarsFallAndPeaksFloatAfterSoundStops() {
        let vis = ClassicVisualizer()
        vis.render(samples: sine(1_000))
        let col = vis.barHeights.enumerated().max { $0.element < $1.element }!.offset
        let loud = vis.barHeights[col]
        XCTAssertGreaterThan(loud, 8)
        vis.render(samples: [Float](repeating: 0, count: 1024))
        XCTAssertLessThan(vis.barHeights[col], loud, "bar falls")
        XCTAssertGreaterThan(vis.barHeights[col], 0, "…gradually")
        XCTAssertGreaterThanOrEqual(vis.peakHeights[col], vis.barHeights[col], "peak floats above the bar")
        for _ in 0..<120 { vis.render(samples: [Float](repeating: 0, count: 1024)) }
        XCTAssertEqual(vis.barHeights[col], 0)
        XCTAssertEqual(vis.peakHeights[col], 0)
    }

    func testColoringStyles() {
        func topPixel(_ style: ClassicVisualizer.AnalyzerStyle) -> (top: UInt32, bottom: UInt32) {
            let vis = ClassicVisualizer()
            vis.analyzerStyle = style
            vis.peaks = false
            vis.bandwidth = .thin
            vis.render(samples: sine(1_000, amplitude: 0.05))
            let col = vis.barHeights.enumerated().max { $0.element < $1.element }!.offset
            let h = Int(vis.barHeights[col].rounded())
            XCTAssertGreaterThan(h, 1)
            XCTAssertLessThan(h, 16)
            return (vis.pixels[(16 - h) * 76 + col], vis.pixels[15 * 76 + col])
        }
        let colors = SkinText.defaultVisColors
        XCTAssertEqual(topPixel(.fire).top, colors[2].packed, "fire: every bar starts hot")
        XCTAssertEqual(topPixel(.normal).bottom, colors[17].packed, "normal: bottom row = color 17")
        let line = topPixel(.line)
        XCTAssertEqual(line.top, line.bottom, "line: single color per bar")
    }

    func testOscilloscopeStyles() {
        for style in ClassicVisualizer.OscilloscopeStyle.allCases {
            let vis = ClassicVisualizer()
            vis.mode = .oscilloscope
            vis.oscilloscopeStyle = style
            vis.render(samples: [Float](repeating: 0, count: 1024))
            // Silence → flat line on row 7, brightest scope color (18).
            XCTAssertEqual(vis.pixels[7 * 76 + 10], vis.colors[18].packed, "\(style)")
            vis.render(samples: sine(500, amplitude: 0.4))
            XCTAssertNotNil(vis.makeImage())
        }
        let off = ClassicVisualizer()
        off.mode = .off
        off.render(samples: sine(500))
        XCTAssertNil(off.makeImage())
    }

    func testVisualizerSettlesOnSilenceAndCachesImage() {
        let vis = ClassicVisualizer()
        let silence = [Float](repeating: 0, count: 1024)

        XCTAssertFalse(vis.isSettled)
        XCTAssertTrue(vis.render(samples: silence), "first silent frame draws background")
        XCTAssertTrue(vis.isSettled)
        XCTAssertFalse(vis.render(samples: silence), "already settled silent frame is a no-op")

        let img1 = vis.makeImage()
        let img2 = vis.makeImage()
        XCTAssertNotNil(img1)
        XCTAssertTrue(img1 === img2, "unchanged frame reuses cached CGImage")

        // Signal wakes the analyzer up; silence decays it back to settled.
        XCTAssertTrue(vis.render(samples: sine(1_000)))
        XCTAssertFalse(vis.isSettled)
        var frames = 0
        while !vis.isSettled && frames < 120 {
            XCTAssertTrue(vis.render(samples: silence))
            frames += 1
        }
        XCTAssertTrue(vis.isSettled)
        XCTAssertGreaterThan(frames, 5)
        XCTAssertTrue(vis.barHeights.allSatisfy { $0 == 0 })
        XCTAssertTrue(vis.peakHeights.allSatisfy { $0 == 0 })
        XCTAssertFalse(vis.render(samples: silence))

        // Oscilloscope settles after one silent frame.
        vis.mode = .oscilloscope
        XCTAssertFalse(vis.isSettled)
        XCTAssertTrue(vis.render(samples: sine(500, amplitude: 0.4)))
        XCTAssertFalse(vis.isSettled)
        XCTAssertTrue(vis.render(samples: silence))
        XCTAssertTrue(vis.isSettled)
        XCTAssertFalse(vis.render(samples: silence))

        // 30 Hz cadence scales falloff so bars decay in half as many frames (~same wall time).
        let vis30 = ClassicVisualizer()
        vis30.frameRate = 30
        vis30.render(samples: sine(1_000))
        var frames30 = 0
        while !vis30.isSettled && frames30 < 120 {
            vis30.render(samples: silence)
            frames30 += 1
        }
        XCTAssertTrue(vis30.isSettled)
        XCTAssertLessThan(frames30, frames)
    }
}

final class EqualizerTests: XCTestCase {
    private func rms(_ x: [Float]) -> Float { sqrt(x.map { $0 * $0 }.reduce(0, +) / Float(x.count)) }

    private func run(_ eq: Equalizer, _ input: [Float]) -> [Float] {
        var buf = input
        buf.withUnsafeMutableBufferPointer { eq.process($0.baseAddress!, frames: $0.count, channel: 0) }
        return buf
    }

    func testFlatIsBitExactPassthrough() {
        let eq = Equalizer()
        let input = sine(440, count: 4096)
        XCTAssertEqual(run(eq, input), input)
    }

    func testBoostingOneBandAmplifiesThatFrequencyOnly() {
        let eq = Equalizer()
        eq.sampleRate = 48_000
        eq.setGain(band: 4, dB: 12) // 1 kHz
        let at1k = run(eq, sine(1_000, amplitude: 0.1, count: 48_000))
        let gain1k = 20 * log10(rms(Array(at1k[24_000...])) / rms(Array(sine(1_000, amplitude: 0.1, count: 48_000)[24_000...])))
        XCTAssertEqual(gain1k, 12, accuracy: 0.6)

        eq.resetState()
        let at60 = run(eq, sine(60, amplitude: 0.1, count: 48_000))
        let gain60 = 20 * log10(rms(Array(at60[24_000...])) / rms(Array(sine(60, amplitude: 0.1, count: 48_000)[24_000...])))
        XCTAssertLessThan(abs(gain60), 1, "60 Hz mostly untouched")
    }

    func testDisabledEqStillAppliesBalance() {
        let eq = Equalizer()
        eq.setGain(band: 0, dB: 12)
        eq.isEnabled = false
        eq.balance = 1 // full right → left silent
        let input = sine(440)
        XCTAssertEqual(rms(run(eq, input)), 0)
        var right = input
        right.withUnsafeMutableBufferPointer { eq.process($0.baseAddress!, frames: $0.count, channel: 1) }
        XCTAssertEqual(right, input)
    }

    func testSliderMappingAndPresets() {
        XCTAssertEqual(EqualizerModel.dB(fromSlider: 50), 0)
        XCTAssertEqual(EqualizerModel.dB(fromSlider: 100), 12)
        XCTAssertEqual(EqualizerModel.slider(fromDB: -12), 0)
        XCTAssertEqual(EqualizerModel.presets.count, 17)
        let rock = try! XCTUnwrap(EqualizerModel.presets.first { $0.name == "Rock" })
        XCTAssertGreaterThan(rock.sliderValues[0], 50, "rock boosts bass")
        XCTAssertLessThan(rock.sliderValues[3], 50, "…and cuts low mids")
    }

    func testSplinePassesThroughControlPoints() {
        let xs = (0..<10).map { Double($0 * 12) }
        let ys: [Double] = [9, 3, 12, 9, 9, 0, 18, 9, 5, 9]
        let curve = EqualizerModel.spline(xs: xs, ys: ys)
        XCTAssertEqual(curve.count, 109)
        for (i, y) in ys.enumerated() { XCTAssertEqual(curve[i * 12], y, accuracy: 1e-9) }
    }
}

/// Renders every classic visualizer style into one PNG for eyeballing:
///   SOUNDAMP_VIS_GALLERY=/tmp/vis.png swift test --filter VisualizerGallery
final class VisualizerGalleryTests: XCTestCase {
    func testRenderGallery() throws {
        guard let path = ProcessInfo.processInfo.environment["SOUNDAMP_VIS_GALLERY"] else { throw XCTSkip("set SOUNDAMP_VIS_GALLERY=/path.png") }
        // A "music-like" signal: kick + bass + chords + hats, decaying.
        func music(frame: Int) -> [Float] {
            (0..<1024).map { i -> Float in
                let t = Double(frame * 800 + i) / 48_000
                let beat = t.truncatingRemainder(dividingBy: 0.5)
                let kick = Float(sin(2 * .pi * 55 * t) * exp(-beat * 12)) * 0.9
                let bass = Float(sin(2 * .pi * 110 * t)) * 0.25
                let chord = Float(sin(2 * .pi * 440 * t) + sin(2 * .pi * 554 * t) + sin(2 * .pi * 659 * t)) * 0.06
                let hat = Float.random(in: -1...1) * Float(exp(-t.truncatingRemainder(dividingBy: 0.25) * 40)) * 0.15
                return kick + bass + chord + hat
            }
        }
        typealias V = ClassicVisualizer
        var configs: [(String, (V) -> Void)] = []
        for s in V.AnalyzerStyle.allCases {
            for b in V.Bandwidth.allCases { configs.append(("\(s) \(b)", { $0.analyzerStyle = s; $0.bandwidth = b })) }
        }
        for o in V.OscilloscopeStyle.allCases { configs.append(("scope \(o)", { $0.mode = .oscilloscope; $0.oscilloscopeStyle = o })) }

        let scale = 4, pad = 8
        let cellW = 76 * scale, cellH = 16 * scale
        let width = cellW * 3 + pad * 4, height = (cellH + pad) * ((configs.count + 2) / 3) + pad
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0.15, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .none
        for (k, (_, configure)) in configs.enumerated() {
            let v = V()
            configure(v)
            for f in 0..<20 { v.render(samples: music(frame: f)) }
            let img = try XCTUnwrap(v.makeImage())
            let col = k % 3, row = k / 3
            ctx.draw(img, in: CGRect(x: pad + col * (cellW + pad), y: height - (pad + cellH) * (row + 1), width: cellW, height: cellH))
        }
        let out = try XCTUnwrap(ctx.makeImage())
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, out, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        print("gallery order:", configs.map(\.0))
    }
}
