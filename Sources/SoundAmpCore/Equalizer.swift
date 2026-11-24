import Foundation

/// Winamp-style 10-band graphic EQ (RBJ peaking biquads, TDF-II) + preamp +
/// balance, applied to the tapped audio.
///
/// `process` runs on the real-time audio thread and never allocates. Settings
/// change from the main thread; a coefficient update racing a render cycle can
/// at worst cause a one-buffer glitch.
public final class Equalizer {
    public static let frequencies: [Double] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]
    public static let labels = ["60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K"]
    public static let bandCount = 10
    public static let maxChannels = 2
    static let q = 1.2

    /// EQ bands + preamp on/off (Winamp's "ON" button). Balance applies regardless.
    public var isEnabled = true { didSet { if isEnabled != oldValue { resetState() } } }
    public var sampleRate: Double = 48_000 { didSet { recomputeAll() } }
    /// -1 (left) … 0 … +1 (right).
    public var balance: Double = 0 { didSet { updateGains() } }

    public private(set) var gainsDB = [Double](repeating: 0, count: bandCount)
    public private(set) var preampDB: Double = 0

    private let coeffs = UnsafeMutablePointer<Double>.allocate(capacity: bandCount * 5)
    private let state = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels * bandCount * 2)
    private var preampLinear: Double = 1
    private var channelGain: (Double, Double) = (1, 1)
    private var isFlat = true

    public init() {
        recomputeAll()
        resetState()
    }

    deinit {
        coeffs.deallocate()
        state.deallocate()
    }

    public func setGain(band: Int, dB: Double) {
        guard (0..<Self.bandCount).contains(band) else { return }
        gainsDB[band] = dB
        computeBand(band)
        updateFlatness()
    }

    public func setPreamp(dB: Double) {
        preampDB = dB
        preampLinear = pow(10, dB / 20)
        updateFlatness()
    }

    public func resetGains() {
        for b in 0..<Self.bandCount { gainsDB[b] = 0; computeBand(b) }
        setPreamp(dB: 0)
    }

    public func resetState() {
        state.update(repeating: 0, count: Self.maxChannels * Self.bandCount * 2)
    }

    /// In-place processing of one channel (non-interleaved samples).
    public func process(_ samples: UnsafeMutablePointer<Float>, frames: Int, channel: Int) {
        guard channel < Self.maxChannels else { return }
        let gain = channel == 0 ? channelGain.0 : channelGain.1
        guard isEnabled, !isFlat else {
            if gain != 1 { for i in 0..<frames { samples[i] = Float(Double(samples[i]) * gain) } }
            return
        }
        let st = state + channel * Self.bandCount * 2
        let pre = preampLinear * gain
        for i in 0..<frames {
            var v = Double(samples[i]) * pre
            var k = coeffs
            var z = st
            for _ in 0..<Self.bandCount {
                let y = k[0] * v + z[0]
                z[0] = k[1] * v - k[3] * y + z[1]
                z[1] = k[2] * v - k[4] * y
                v = y
                k += 5
                z += 2
            }
            samples[i] = Float(v)
        }
    }

    private func updateGains() {
        let b = max(-1, min(1, balance))
        channelGain = (b > 0 ? 1 - b : 1, b < 0 ? 1 + b : 1)
    }

    private func updateFlatness() {
        let wasFlat = isFlat
        isFlat = preampDB == 0 && gainsDB.allSatisfy { $0 == 0 }
        if wasFlat && !isFlat { resetState() }
    }

    private func recomputeAll() {
        for b in 0..<Self.bandCount { computeBand(b) }
    }

    private func computeBand(_ band: Int) {
        let f = min(Self.frequencies[band], sampleRate * 0.45)
        let a = pow(10, gainsDB[band] / 40)
        let w0 = 2 * Double.pi * f / sampleRate
        let alpha = sin(w0) / (2 * Self.q)
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        let k = coeffs + band * 5
        k[0] = (1 + alpha * a) / a0
        k[1] = (-2 * cosw) / a0
        k[2] = (1 - alpha * a) / a0
        k[3] = (-2 * cosw) / a0
        k[4] = (1 - alpha / a) / a0
    }
}
