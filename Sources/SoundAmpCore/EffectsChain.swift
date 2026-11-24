import DSPKit
import Foundation

/// User-facing effect settings (persisted by the app).
public struct EffectSettings: Equatable, Codable {
    /// Playback speed. Applied at the source (SoundCloud's own player / the local file).
    public var speed: Double = 1
    /// true: time-stretch (pitch stays); false: varispeed (pitch follows speed, like a record).
    public var keepPitch = false
    /// Independent pitch shift in semitones (Signalsmith Stretch).
    public var semitones: Double = 0
    /// Keep a voice's character when pitch-shifting (Signalsmith formant compensation).
    public var preserveFormants = false
    public var reverbOn = false
    // Defaults ≈ 2.3 s RT60: a lush but not endless plate (measured; see EffectsTests).
    public var reverbMix: Double = 0.3
    public var reverbDecay: Double = 0.65
    public var reverbDamping: Double = 0.6
    public var reverbPredelayMs: Double = 20
    public var reverbSize: Double = 0.85
    /// "Next door": hear it through a wall (after the reverb, so the room is muffled too).
    public var wallOn = false
    /// 0…1, how thick the wall is.
    public var wallAmount: Double = 0.7

    public init() {}

    // Tolerant decoding: settings saved by older versions lack newer fields.
    private enum CodingKeys: String, CodingKey {
        case speed, keepPitch, semitones, preserveFormants, reverbOn, reverbMix, reverbDecay, reverbDamping
        case reverbPredelayMs, reverbSize, wallOn, wallAmount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EffectSettings()
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        keepPitch = try c.decodeIfPresent(Bool.self, forKey: .keepPitch) ?? d.keepPitch
        semitones = try c.decodeIfPresent(Double.self, forKey: .semitones) ?? d.semitones
        preserveFormants = try c.decodeIfPresent(Bool.self, forKey: .preserveFormants) ?? d.preserveFormants
        reverbOn = try c.decodeIfPresent(Bool.self, forKey: .reverbOn) ?? d.reverbOn
        reverbMix = try c.decodeIfPresent(Double.self, forKey: .reverbMix) ?? d.reverbMix
        reverbDecay = try c.decodeIfPresent(Double.self, forKey: .reverbDecay) ?? d.reverbDecay
        reverbDamping = try c.decodeIfPresent(Double.self, forKey: .reverbDamping) ?? d.reverbDamping
        reverbPredelayMs = try c.decodeIfPresent(Double.self, forKey: .reverbPredelayMs) ?? d.reverbPredelayMs
        reverbSize = try c.decodeIfPresent(Double.self, forKey: .reverbSize) ?? d.reverbSize
        wallOn = try c.decodeIfPresent(Bool.self, forKey: .wallOn) ?? d.wallOn
        wallAmount = try c.decodeIfPresent(Double.self, forKey: .wallAmount) ?? d.wallAmount
    }

    public static let off = EffectSettings()

    public struct Preset: Equatable {
        public let name: String
        public let settings: EffectSettings
    }

    public static let presets: [Preset] = {
        var slowedReverb = EffectSettings()
        slowedReverb.speed = 0.85
        slowedReverb.reverbOn = true

        var slowed = EffectSettings()
        slowed.speed = 0.85

        var samePitch = EffectSettings()
        samePitch.speed = 0.85
        samePitch.keepPitch = true

        var daycore = EffectSettings()
        daycore.speed = 0.75
        daycore.reverbOn = true
        daycore.reverbMix = 0.38
        daycore.reverbDecay = 0.7      // ≈ 2.9 s
        daycore.reverbDamping = 0.7
        daycore.reverbSize = 0.9

        var nightcore = EffectSettings()
        nightcore.speed = 1.25

        var nextDoor = EffectSettings()
        nextDoor.reverbOn = true
        nextDoor.reverbMix = 0.4
        nextDoor.reverbDecay = 0.55    // ≈ 1.4 s: a club room
        nextDoor.reverbDamping = 0.4
        nextDoor.reverbPredelayMs = 15
        nextDoor.reverbSize = 0.75
        nextDoor.wallOn = true
        nextDoor.wallAmount = 0.75

        var nextDoorSlowed = nextDoor
        nextDoorSlowed.speed = 0.85

        var bigHall = EffectSettings()
        bigHall.reverbOn = true
        bigHall.reverbMix = 0.35
        bigHall.reverbDecay = 0.7      // ≈ 3 s
        bigHall.reverbSize = 0.95
        bigHall.reverbPredelayMs = 35

        return [
            Preset(name: "Off", settings: .off),
            Preset(name: "Slowed + Reverb", settings: slowedReverb),
            Preset(name: "Slowed", settings: slowed),
            Preset(name: "Slowed, Same Pitch", settings: samePitch),
            Preset(name: "Daycore (very slowed + big reverb)", settings: daycore),
            Preset(name: "Nightcore (sped up)", settings: nightcore),
            Preset(name: "Big Plate (reverb only)", settings: bigHall),
            Preset(name: "Next Door Party", settings: nextDoor),
            Preset(name: "Next Door, Slowed", settings: nextDoorSlowed),
        ]
    }()

    /// Reverb values of presets from earlier versions (tails of 7–19 s), mapped to
    /// the current preset of the same name, so saved settings get the fix too.
    public func migratingOldReverbPresets() -> EffectSettings {
        let old: [(name: String, mix: Double, decay: Double, damping: Double, predelay: Double, size: Double)] = [
            ("Slowed + Reverb", 0.35, 0.85, 0.6, 20, 1.0),
            ("Daycore (very slowed + big reverb)", 0.45, 0.9, 0.7, 20, 1.3),
            ("Big Plate (reverb only)", 0.4, 0.92, 0.6, 40, 1.5),
            ("Next Door Party", 0.45, 0.8, 0.4, 15, 1.3),
        ]
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }
        guard let match = old.first(where: { near(reverbMix, $0.mix) && near(reverbDecay, $0.decay) && near(reverbDamping, $0.damping)
            && near(reverbPredelayMs, $0.predelay) && near(reverbSize, $0.size) }),
              let fresh = EffectSettings.presets.first(where: { $0.name == match.name })?.settings else { return self }
        var s = self
        s.reverbMix = fresh.reverbMix
        s.reverbDecay = fresh.reverbDecay
        s.reverbDamping = fresh.reverbDamping
        s.reverbPredelayMs = fresh.reverbPredelayMs
        s.reverbSize = fresh.reverbSize
        return s
    }

    /// True when audio needs our processing chain (pitch, reverb, or a high-quality
    /// keep-pitch speed change), i.e. the tap for SoundCloud audio.
    public var needsProcessing: Bool {
        abs(semitones) >= 0.01 || reverbOn || wallOn || (keepPitch && abs(speed - 1) >= 0.005)
    }

    /// Pitch shift the chain must apply. With keep-pitch, the source runs as
    /// varispeed (pitch moves with speed) and the chain shifts it back:
    /// varispeed + compensating pitch shift = time-stretch, at Signalsmith quality.
    public var chainSemitones: Double {
        semitones + (keepPitch && speed > 0 ? -12 * log2(speed) : 0)
    }
}

/// The real-time processing chain applied to audio we control:
/// EQ + preamp + balance → pitch shift → plate reverb → "next door" wall. RT-safe.
public final class EffectsChain {
    public let equalizer = Equalizer()
    public let sampleRate: Double
    private let pitch: OpaquePointer
    private let plate: OpaquePointer
    private let wall: OpaquePointer

    public init(sampleRate: Double, maxFrames: Int = 16_384) {
        self.sampleRate = sampleRate
        equalizer.sampleRate = sampleRate
        pitch = dsp_pitch_create(sampleRate, Int32(maxFrames))
        plate = dsp_plate_create(sampleRate)
        wall = dsp_wall_create(sampleRate)
    }

    deinit {
        dsp_pitch_destroy(pitch)
        dsp_plate_destroy(plate)
        dsp_wall_destroy(wall)
    }

    /// Tonality limit used for all pitch shifting (as in the audiostretch web app).
    public static let tonalityHz: Float = 8000

    public func apply(_ s: EffectSettings) {
        dsp_pitch_set_quality(pitch, Self.tonalityHz, s.preserveFormants ? 1 : 0, 200)
        dsp_pitch_set_semitones(pitch, Float(s.chainSemitones))
        dsp_plate_set(plate, Float(s.reverbMix), Float(s.reverbDecay), Float(s.reverbDamping),
                      Float(s.reverbPredelayMs), Float(s.reverbSize))
        dsp_plate_set_enabled(plate, s.reverbOn ? 1 : 0)
        dsp_wall_set(wall, s.wallOn ? 1 : 0, Float(s.wallAmount))
    }

    /// Latency added by the pitch shifter, in seconds.
    public var latency: Double { Double(dsp_pitch_latency(pitch)) / sampleRate }

    /// In place, planar stereo. Real-time safe.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        equalizer.process(left, frames: frames, channel: 0)
        equalizer.process(right, frames: frames, channel: 1)
        dsp_pitch_process(pitch, left, right, Int32(frames))
        dsp_plate_process(plate, left, right, Int32(frames))
        dsp_wall_process(wall, left, right, Int32(frames)) // the room you hear, through the wall
    }

    public func reset() {
        equalizer.resetState()
        dsp_plate_reset(plate)
    }
}
