import Accelerate
import CoreGraphics
import Foundation

/// Winamp 2.x main-window visualizer: 76×16 pixels, colored by the skin's
/// viscolor.txt. Behavior follows Winamp (as reverse-engineered in Webamp's
/// VisPainter.ts, MIT): log-ish frequency mapping, bar falloff, floating peaks,
/// thin/wide bands, normal/fire/line coloring, dots/lines/solid oscilloscope.
public final class ClassicVisualizer {
    public enum Mode: String, CaseIterable { case analyzer, oscilloscope, off }
    public enum AnalyzerStyle: String, CaseIterable { case normal, fire, line }
    public enum Bandwidth: String, CaseIterable { case thin, wide }
    public enum OscilloscopeStyle: String, CaseIterable { case dots, lines, solid }
    public enum Falloff: String, CaseIterable { case slower, slow, moderate, fast, faster }

    public static let width = 76
    public static let height = 16
    /// How many samples `render` wants (FFT size).
    public static let samplesNeeded = 1024

    public var mode: Mode = .analyzer
    public var analyzerStyle: AnalyzerStyle = .normal
    public var bandwidth: Bandwidth = .wide
    public var oscilloscopeStyle: OscilloscopeStyle = .lines
    public var peaks = true
    public var falloff: Falloff = .moderate
    public var peakFalloff: Falloff = .slow
    public var colors: [RGBA] = SkinText.defaultVisColors {
        didSet { if colors.count < 24 { colors += SkinText.defaultVisColors[colors.count...] } }
    }

    /// RGBA pixels, row-major, top row first.
    public private(set) var pixels = [UInt32](repeating: 0, count: width * height)
    /// Current bar heights (0…16) — exposed for tests.
    public private(set) var barHeights = [Float](repeating: 0, count: width)
    public private(set) var peakHeights = [Float](repeating: 0, count: width)

    private let columns = 75
    private let maxHeight: Float = 16
    private let fftSize = 1024
    private let log2n: vDSP_Length = 10
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: 1024)
    private var windowed = [Float](repeating: 0, count: 1024)
    private var real = [Float](repeating: 0, count: 512)
    private var imag = [Float](repeating: 0, count: 512)
    private var magnitudes = [Float](repeating: 0, count: 512)
    private var sample = [Float](repeating: 0, count: 76)
    private var saFalloff = [Float](repeating: 0, count: 76)
    private var saPeaks = [Float](repeating: 0, count: 76)
    private var saPeakSpeed = [Float](repeating: 0, count: 76)
    private var lastOscY = 0

    public init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    public func reset() {
        for i in 0..<76 { saFalloff[i] = 0; saPeaks[i] = 0; saPeakSpeed[i] = 0; barHeights[i] = 0; peakHeights[i] = 0 }
    }

    /// Render one frame from the latest mono samples (≥ 1024 for the analyzer,
    /// the last 576 are used by the oscilloscope). Pass silence when stopped.
    public func render(samples: [Float]) {
        drawBackground()
        switch mode {
        case .analyzer: renderAnalyzer(samples)
        case .oscilloscope: renderOscilloscope(samples)
        case .off: break
        }
    }

    public func makeImage() -> CGImage? {
        guard mode != .off else { return nil }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: Self.width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: Self.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Background

    private func drawBackground() {
        let bg = colors[0].packed, dot = colors[1].packed
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                pixels[y * Self.width + x] = (x % 2 == 0 && y % 2 == 1) ? dot : bg
            }
        }
    }

    @inline(__always) private func set(_ x: Int, _ y: Int, _ colorIndex: Int) {
        guard x >= 0, x < Self.width, y >= 0, y < Self.height else { return }
        pixels[y * Self.width + x] = colors[max(0, min(23, colorIndex))].packed
    }

    // MARK: Analyzer

    private func spectrum(_ samples: [Float]) {
        let n = fftSize
        let count = min(samples.count, n)
        // Right-align the newest samples; zero-pad if fewer than n.
        for i in 0..<n {
            let j = samples.count - n + i
            windowed[i] = (j >= 0 && j < samples.count && i >= n - count) ? samples[j] * window[i] : 0
        }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                ip[0] = 0 // packed Nyquist
                magnitudes.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }
        // zrip is 2× scaled and Hann has 0.5 coherent gain → full-scale sine ≈ n/2.
        let norm = Float(n / 2)
        for k in 0..<(n / 2) {
            let db = 20 * log10(magnitudes[k] / norm + 1e-9)
            magnitudes[k] = max(0, (db + 72) / 60 * maxHeight) // -72 dB…-12 dB → 0…16 rows
        }
    }

    private func renderAnalyzer(_ samples: [Float]) {
        spectrum(samples)

        // Column → FFT bin: 91% logarithmic, 9% linear (Webamp's Winamp approximation).
        let maxIndex = 512
        let logMax = log10(Float(maxIndex))
        for x in 0..<columns {
            let linear = Float(x) / Float(columns - 1) * Float(maxIndex - 1)
            let logIndex = pow(10, logMax * Float(x) / Float(columns - 1))
            let idx = 0.09 * linear + 0.91 * logIndex
            let i1 = min(maxIndex - 1, Int(idx.rounded(.down)))
            let i2 = min(maxIndex - 1, Int(idx.rounded(.up)))
            let f = idx - Float(i1)
            sample[x] = i1 == i2 ? magnitudes[i1] : (1 - f) * magnitudes[i1] + f * magnitudes[i2]
        }

        let fall = Float(falloffRate(falloff)) / 16
        let peakAccel = peakFalloffRate(peakFalloff)

        for x in 0..<columns {
            var value: Float
            var chunk = 0
            if bandwidth == .wide {
                chunk = x & ~3
                let c = min(chunk, columns - 4)
                value = (sample[c] + sample[c + 1] + sample[c + 2] + sample[c + 3]) / 4
            } else {
                value = sample[x]
            }
            value = min(value, maxHeight)

            saFalloff[x] -= fall
            if saFalloff[x] <= value { saFalloff[x] = value }
            if saPeaks[x] <= saFalloff[x] * 256 {
                saPeaks[x] = saFalloff[x] * 256
                saPeakSpeed[x] = 3
            }
            let peak = saPeaks[x] / 256
            saPeaks[x] = max(0, saPeaks[x] - saPeakSpeed[x])
            saPeakSpeed[x] *= peakAccel

            barHeights[x] = saFalloff[x]
            peakHeights[x] = peak

            if bandwidth == .wide && x == chunk + 3 { continue } // 1px gap between 3px bands
            drawBar(x: x, height: Int(saFalloff[x].rounded()), peak: Int(peak.rounded()))
        }
    }

    private func drawBar(x: Int, height h: Int, peak: Int) {
        let h = max(0, min(Self.height, h))
        let top = Self.height - h
        if h > 0 {
            for y in top..<Self.height {
                switch analyzerStyle {
                case .normal: set(x, y, 2 + y)          // color by absolute row: 2 = top … 17 = bottom
                case .fire: set(x, y, 2 + (y - top))    // every bar starts at the "hot" color
                case .line: set(x, y, 2 + top)          // whole bar in the color of its height
                }
            }
        }
        if peaks, peak >= 1 {
            set(x, Self.height - min(Self.height, peak), 23)
        }
    }

    private func falloffRate(_ f: Falloff) -> Int {
        switch f { case .slower: return 3; case .slow: return 6; case .moderate: return 12; case .fast: return 16; case .faster: return 32 }
    }

    private func peakFalloffRate(_ f: Falloff) -> Float {
        switch f { case .slower: return 1.05; case .slow: return 1.1; case .moderate: return 1.2; case .fast: return 1.4; case .faster: return 1.6 }
    }

    // MARK: Oscilloscope

    private func oscColorIndex(_ y: Int) -> Int {
        switch y {
        case 14...: return 4
        case 12...: return 3
        case 10...: return 2
        case 8...: return 1
        case 6...: return 0
        case 4...: return 1
        case 2...: return 2
        default: return 3
        }
    }

    private func renderOscilloscope(_ samples: [Float]) {
        let window = 576
        let start = max(0, samples.count - window)
        let slice = window / 75
        for x in 0..<columns {
            let i = start + x * slice
            let s = i < samples.count ? samples[i] : 0
            // Winamp maps the byte waveform with ±16 px of swing around row 7.
            let y = max(0, min(Self.height - 1, Int((7 + s * 16).rounded())))
            if x == 0 { lastOscY = y }
            var top = y, bottom = lastOscY
            switch oscilloscopeStyle {
            case .dots:
                top = y; bottom = y
            case .solid:
                if y >= 8 { top = 8; bottom = y } else { top = y; bottom = 7 }
            case .lines:
                if bottom < top { swap(&top, &bottom); top += 1 }
                top = min(top, bottom)
            }
            lastOscY = y
            let c = 18 + oscColorIndex(y)
            for yy in top...bottom { set(x, yy, c) }
        }
    }
}
