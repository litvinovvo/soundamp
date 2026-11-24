import XCTest
@testable import SoundAmpCore

/// Measures the effects on real signals (headless, fast).
final class EffectsTests: XCTestCase {
    let sr = 48_000.0

    private func sine(_ hz: Double, seconds: Double, amp: Float = 0.5) -> [Float] {
        (0..<Int(sr * seconds)).map { amp * Float(sin(2 * .pi * hz * Double($0) / sr)) }
    }

    /// Run a stereo signal through a chain in device-sized blocks.
    private func run(_ chain: EffectsChain, _ l: [Float], _ r: [Float]? = nil, block: Int = 512) -> ([Float], [Float]) {
        var L = l, R = r ?? l
        var i = 0
        while i < L.count {
            let n = min(block, L.count - i)
            L.withUnsafeMutableBufferPointer { lp in
                R.withUnsafeMutableBufferPointer { rp in
                    chain.process(left: lp.baseAddress! + i, right: rp.baseAddress! + i, frames: n)
                }
            }
            i += n
        }
        return (L, R)
    }

    /// Frequency by counting rising zero crossings (good enough for a clean tone).
    private func frequency(_ x: ArraySlice<Float>) -> Double {
        var crossings = 0
        var prev = x.first ?? 0
        for v in x.dropFirst() { if prev < 0 && v >= 0 { crossings += 1 }; prev = v }
        return Double(crossings) / (Double(x.count) / sr)
    }

    private func rms(_ x: ArraySlice<Float>) -> Float { sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))) }

    // MARK: Pitch (Signalsmith Stretch)

    func testPitchShiftOctaveUpAndDown() {
        for (semis, expected) in [(12.0, 880.0), (-12.0, 220.0), (7.0, 659.26)] {
            let chain = EffectsChain(sampleRate: sr)
            var s = EffectSettings(); s.semitones = semis
            chain.apply(s)
            let (out, _) = run(chain, sine(440, seconds: 2))
            // skip the start (latency + settling)
            let f = frequency(out[Int(sr * 0.6)..<Int(sr * 1.9)])
            XCTAssertEqual(f, expected, accuracy: expected * 0.02, "\(semis) st")
            XCTAssertGreaterThan(rms(out[Int(sr)..<Int(sr * 1.5)]), 0.2, "level kept")
        }
    }

    func testPitchZeroIsExactPassthroughWithoutLatency() {
        let chain = EffectsChain(sampleRate: sr)
        chain.apply(EffectSettings())
        let input = sine(440, seconds: 0.5)
        let (out, _) = run(chain, input)
        XCTAssertEqual(out, input)
        XCTAssertEqual(chain.latency, 0)
    }

    // MARK: Plate reverb (Dattorro)

    private func impulse(seconds: Double) -> [Float] {
        var x = [Float](repeating: 0, count: Int(sr * seconds)); x[0] = 1; return x
    }

    func testPlateTailIsStereoAndDecays() {
        let chain = EffectsChain(sampleRate: sr)
        var s = EffectSettings(); s.reverbOn = true; s.reverbMix = 1; s.reverbDecay = 0.8; s.reverbPredelayMs = 0
        chain.apply(s)
        let (l, r) = run(chain, impulse(seconds: 4))
        let early = rms(l[Int(sr * 0.1)..<Int(sr * 0.5)]), late = rms(l[Int(sr * 2.5)..<Int(sr * 3)])
        XCTAssertGreaterThan(early, 1e-3, "there is a tail")
        XCTAssertLessThan(late, early * 0.2, "and it decays")
        XCTAssertFalse(l.contains { !$0.isFinite } || r.contains { !$0.isFinite })
        // decorrelated channels (stereo width)
        let a = l[Int(sr * 0.1)..<Int(sr * 0.6)], b = r[Int(sr * 0.1)..<Int(sr * 0.6)]
        let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let corr = dot / (sqrt(a.reduce(0) { $0 + $1 * $1 }) * sqrt(b.reduce(0) { $0 + $1 * $1 }))
        XCTAssertLessThan(abs(corr), 0.5, "L/R tails differ")
    }

    func testLongerDecayGivesLongerTail() {
        func tail(_ decay: Double) -> Float {
            let chain = EffectsChain(sampleRate: sr)
            var s = EffectSettings(); s.reverbOn = true; s.reverbMix = 1; s.reverbDecay = decay; s.reverbPredelayMs = 0
            chain.apply(s)
            let (l, _) = run(chain, impulse(seconds: 3))
            return rms(l[Int(sr * 1.5)..<Int(sr * 2.5)])
        }
        XCTAssertGreaterThan(tail(0.95), tail(0.5) * 4)
    }

    func testPlateOffOrDryIsPassthroughAndStableUnderNoise() {
        let input = sine(220, seconds: 0.3)
        let off = EffectsChain(sampleRate: sr)
        off.apply(EffectSettings())
        XCTAssertEqual(run(off, input).0, input)

        // Max settings on loud noise for 10 s: must stay finite and bounded.
        let chain = EffectsChain(sampleRate: sr)
        var s = EffectSettings(); s.reverbOn = true; s.reverbMix = 1; s.reverbDecay = 0.99; s.reverbSize = 1.5; s.semitones = 5
        chain.apply(s)
        var rng = SeededRandom(seed: 7)
        let noise = (0..<Int(sr * 10)).map { _ in Float(Double(rng.next() % 2000) / 1000 - 1) * 0.8 }
        let (l, r) = run(chain, noise)
        XCTAssertFalse(l.contains { !$0.isFinite } || r.contains { !$0.isFinite })
        XCTAssertLessThan(l.map(abs).max()!, 20)
    }

    func testPresets() {
        let names = EffectSettings.presets.map(\.name)
        XCTAssertEqual(names.first, "Off")
        let sr = EffectSettings.presets.first { $0.name == "Slowed + Reverb" }!.settings
        XCTAssertLessThan(sr.speed, 1)
        XCTAssertTrue(sr.reverbOn)
        XCTAssertFalse(sr.keepPitch, "classic slowed = varispeed, pitch drops")
        XCTAssertTrue(sr.needsProcessing)
        XCTAssertFalse(EffectSettings.presets.first { $0.name.hasPrefix("Slowed") && !$0.settings.reverbOn }!.settings.needsProcessing,
                       "speed alone needs no tap")
    }
}

/// Keep-pitch = varispeed at the source + compensating pitch shift in the chain.
final class KeepPitchTests: XCTestCase {
    let sr = 48_000.0

    func testVarispeedPlusCompensationRestoresPitch() {
        // The source plays a 440 Hz tone at 0.8× varispeed → it arrives at 352 Hz.
        let speed = 0.8
        let input: [Float] = (0..<Int(sr * 2)).map { 0.5 * Float(sin(2 * .pi * 440 * speed * Double($0) / sr)) }
        let chain = EffectsChain(sampleRate: sr)
        var s = EffectSettings(); s.speed = speed; s.keepPitch = true
        XCTAssertEqual(s.chainSemitones, 3.863, accuracy: 0.01)
        XCTAssertTrue(s.needsProcessing)
        chain.apply(s)
        var L = input, R = input
        var i = 0
        while i < L.count {
            let n = min(512, L.count - i)
            L.withUnsafeMutableBufferPointer { l in R.withUnsafeMutableBufferPointer { r in
                chain.process(left: l.baseAddress! + i, right: r.baseAddress! + i, frames: n)
            } }
            i += n
        }
        var crossings = 0
        let seg = L[Int(sr * 0.6)..<Int(sr * 1.9)]
        var prev = seg.first!
        for v in seg.dropFirst() { if prev < 0 && v >= 0 { crossings += 1 }; prev = v }
        let f = Double(crossings) / (Double(seg.count) / sr)
        XCTAssertEqual(f, 440, accuracy: 440 * 0.02, "pitch back at the original 440 Hz")
    }

    func testNoCompensationWithoutKeepPitchOrAtNormalSpeed() {
        var s = EffectSettings(); s.speed = 0.85
        XCTAssertEqual(s.chainSemitones, 0)
        XCTAssertFalse(s.needsProcessing, "plain slowed needs no tap")
        s.keepPitch = true; s.speed = 1
        XCTAssertEqual(s.chainSemitones, 0)
        s.speed = 1.25; s.semitones = 2
        XCTAssertEqual(s.chainSemitones, 2 - 12 * log2(1.25), accuracy: 1e-9)
    }

    func testFormantPreservationRunsClean() {
        let chain = EffectsChain(sampleRate: sr)
        var s = EffectSettings(); s.semitones = 7; s.preserveFormants = true
        chain.apply(s)
        var L: [Float] = (0..<Int(sr)).map { 0.3 * Float(sin(2 * .pi * 220 * Double($0) / sr)) }
        var R = L
        L.withUnsafeMutableBufferPointer { l in R.withUnsafeMutableBufferPointer { r in
            chain.process(left: l.baseAddress!, right: r.baseAddress!, frames: 4096)
        } }
        XCTAssertFalse(L.contains { !$0.isFinite })
    }
}

final class NextDoorTests: XCTestCase {
    let sr = 48_000.0

    private func level(_ hz: Double, wall: Double?) -> Float {
        let chain = EffectsChain(sampleRate: sr)
        var s = EffectSettings()
        if let w = wall { s.wallOn = true; s.wallAmount = w }
        chain.apply(s)
        var L: [Float] = (0..<Int(sr)).map { 0.3 * Float(sin(2 * .pi * hz * Double($0) / sr)) }
        var R = L
        var i = 0
        while i < L.count {
            let n = min(512, L.count - i)
            L.withUnsafeMutableBufferPointer { l in R.withUnsafeMutableBufferPointer { r in
                chain.process(left: l.baseAddress! + i, right: r.baseAddress! + i, frames: n)
            } }
            i += n
        }
        let tail = L[Int(sr * 0.5)...]
        return sqrt(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))
    }

    func testWallKeepsBassAndKillsHighs() {
        let bassDry = level(80, wall: nil), bassWall = level(80, wall: 0.75)
        let highDry = level(4000, wall: nil), highWall = level(4000, wall: 0.75)
        XCTAssertGreaterThan(bassWall, bassDry * 0.8, "the thump gets through")
        XCTAssertLessThan(highWall, highDry * 0.02, "highs are gone (> 34 dB down)")
    }

    func testThickerWallIsDarker() {
        XCTAssertLessThan(level(1000, wall: 0.95), level(1000, wall: 0.4) * 0.3)
    }

    func testOffIsPassthroughAndSettingsDecodeFromOlderVersions() throws {
        XCTAssertEqual(level(1000, wall: nil), Float(0.3 / 2.0.squareRoot()), accuracy: 0.005)
        // JSON saved before the formant/wall options existed still loads.
        let old = #"{"speed":0.85,"keepPitch":false,"semitones":0,"reverbOn":true,"reverbMix":0.35,"reverbDecay":0.85,"reverbDamping":0.6,"reverbPredelayMs":20,"reverbSize":1}"#
        let s = try JSONDecoder().decode(EffectSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.speed, 0.85)
        XCTAssertTrue(s.reverbOn)
        XCTAssertFalse(s.wallOn)
        XCTAssertFalse(s.preserveFormants)
    }
}

/// Keeps preset reverb tails musical (they once measured 7–19 s).
final class ReverbLengthTests: XCTestCase {
    /// RT60 via Schroeder backward integration (T30 × 2), wet only.
    static func rt60(_ settings: EffectSettings, sr: Double = 48_000) -> Double {
        var s = settings
        s.speed = 1; s.keepPitch = false; s.semitones = 0; s.wallOn = false; s.reverbOn = true
        s.reverbMix = 1; s.reverbPredelayMs = 0
        let chain = EffectsChain(sampleRate: sr)
        chain.apply(s)
        let n = Int(sr * 8)
        var L = [Float](repeating: 0, count: n), R = L
        L[0] = 1; R[0] = 1
        var i = 0
        while i < n {
            let k = min(512, n - i)
            L.withUnsafeMutableBufferPointer { l in R.withUnsafeMutableBufferPointer { r in
                chain.process(left: l.baseAddress! + i, right: r.baseAddress! + i, frames: k)
            } }
            i += k
        }
        var energy = [Double](repeating: 0, count: n), acc = 0.0
        for j in stride(from: n - 1, through: 0, by: -1) { acc += Double(L[j] * L[j] + R[j] * R[j]); energy[j] = acc }
        let e0 = energy[Int(sr * 0.01)]
        func t(_ db: Double) -> Double { Double(energy.firstIndex { 10 * log10($0 / e0) <= db } ?? n) / sr }
        return (t(-35) - t(-5)) * 2
    }

    func testPresetTailsAreMusical() {
        let expected: [String: ClosedRange<Double>] = [
            "Slowed + Reverb": 1.8...2.8, "Daycore (very slowed + big reverb)": 2.4...3.4,
            "Big Plate (reverb only)": 2.4...3.6, "Next Door Party": 1.0...1.9, "Next Door, Slowed": 1.0...1.9,
        ]
        for p in EffectSettings.presets where p.settings.reverbOn {
            let rt = Self.rt60(p.settings)
            let range = expected[p.name] ?? 1.0...3.6
            XCTAssertTrue(range.contains(rt), String(format: "%@: RT60 %.2f s, want %.1f–%.1f s", p.name, rt, range.lowerBound, range.upperBound))
        }
        XCTAssertTrue((1.8...2.8).contains(Self.rt60(EffectSettings())), "plain reverb-on default ≈ 2.3 s")
    }

    func testOldLongPresetsMigrate() {
        var old = EffectSettings()
        old.speed = 0.85; old.reverbOn = true; old.reverbMix = 0.35; old.reverbDecay = 0.85; old.reverbDamping = 0.6
        old.reverbPredelayMs = 20; old.reverbSize = 1
        let migrated = old.migratingOldReverbPresets()
        XCTAssertEqual(migrated, EffectSettings.presets.first { $0.name == "Slowed + Reverb" }!.settings)
        var custom = old; custom.reverbDecay = 0.5
        XCTAssertEqual(custom.migratingOldReverbPresets(), custom, "hand-tuned settings are left alone")
    }
}
