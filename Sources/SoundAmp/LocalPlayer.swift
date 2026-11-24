import AudioToolbox
import AVFoundation
import SoundAmpCore

/// Plays local audio files (the bundled intro) through our own render callback:
/// decoded file → varispeed read (speed) → EffectsChain (EQ, pitch, reverb) →
/// volume → output, plus a visualizer feed. Independent of the SoundCloud widget
/// and of the Core Audio tap, so it needs no audio-recording permission.
@MainActor
final class LocalPlayer {
    enum Event { case started, paused, finished, failed(String) }

    var onEvent: ((Event) -> Void)?
    /// Called with each new chain (one per file sample rate) to push settings in.
    var configureChain: ((EffectsChain) -> Void)?
    /// Visualizer samples (mono), written from the render callback.
    let ring = SampleRing()

    private(set) var chain: EffectsChain?
    private(set) var durationMs: Double = 0
    private(set) var sampleRate: Double = 0
    private(set) var bitrateKbps: Int?
    var isPlaying: Bool { state.playing }

    /// Shared with the real-time render callback (plain fields; races only cost a sample).
    private final class RenderState {
        var left: UnsafeMutablePointer<Float>?
        var right: UnsafeMutablePointer<Float>?
        var length = 0
        var position: Double = 0
        var rate: Double = 1
        var playing = false
        var finished = false
        var gain: Float = 1
        /// Output frames rendered while playing (to report the effective speed).
        var renderedFrames = 0
        let mono = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
        func freeAudio() { left?.deallocate(); right?.deallocate(); left = nil; right = nil; length = 0 }
    }

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let state = RenderState()
    private var pollTimer: Timer?
    private var idleSince: Date?

    // MARK: Transport

    func load(_ url: URL) throws {
        stop()
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "SoundAmp", code: 1, userInfo: [NSLocalizedDescriptionKey: "can't allocate audio buffer"])
        }
        try file.read(into: buf)
        guard let ch = buf.floatChannelData else {
            throw NSError(domain: "SoundAmp", code: 2, userInfo: [NSLocalizedDescriptionKey: "unsupported audio format"])
        }
        let n = Int(buf.frameLength)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n + 2)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: n + 2)
        l.update(from: ch[0], count: n)
        r.update(from: ch[format.channelCount > 1 ? 1 : 0], count: n)
        l[n] = 0; l[n + 1] = 0; r[n] = 0; r[n + 1] = 0

        if engine.isRunning { engine.stop() }
        state.freeAudio()
        state.left = l
        state.right = r
        state.length = n
        state.position = 0
        state.finished = false

        let newRate = format.sampleRate
        if newRate != sampleRate || source == nil { rebuildGraph(sampleRate: newRate) }
        sampleRate = newRate
        durationMs = Double(n) / newRate * 1000
        bitrateKbps = Self.bitrate(of: url)
    }

    private func rebuildGraph(sampleRate sr: Double) {
        if let old = source { engine.detach(old) }
        let chain = EffectsChain(sampleRate: sr, maxFrames: 8192)
        configureChain?(chain)
        self.chain = chain
        let st = state, ring = ring
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let n = min(Int(frameCount), 8192)
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count >= 2, let outL = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let outR = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            if st.playing, !st.finished, let L = st.left, let R = st.right {
                for i in 0..<n {
                    let p = st.position
                    let i0 = Int(p)
                    if i0 + 1 >= st.length {
                        st.finished = true
                        outL[i] = 0; outR[i] = 0
                        continue
                    }
                    let f = Float(p - Double(i0))
                    outL[i] = L[i0] + (L[i0 + 1] - L[i0]) * f
                    outR[i] = R[i0] + (R[i0 + 1] - R[i0]) * f
                    st.position = p + st.rate
                    st.renderedFrames += 1
                }
            } else {
                for i in 0..<n { outL[i] = 0; outR[i] = 0 }
            }
            chain.process(left: outL, right: outR, frames: n) // reverb tails ring on after pause/end
            let g = st.gain
            for i in 0..<n {
                outL[i] *= g; outR[i] *= g
                st.mono[i] = 0.5 * (outL[i] + outR[i])
            }
            ring.write(st.mono, count: n)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
    }

    func play() {
        guard state.left != nil else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            onEvent?(.failed("audio engine: \(error.localizedDescription)"))
            return
        }
        state.finished = false
        if state.position == 0 { state.renderedFrames = 0 }
        state.playing = true
        idleSince = nil
        startPolling()
        onEvent?(.started)
    }

    func pause() {
        guard state.playing else { return }
        state.playing = false
        idleSince = Date()
        onEvent?(.paused)
    }

    func stop() {
        state.playing = false
        state.position = 0
        state.finished = false
        idleSince = Date()
    }

    func seek(toMilliseconds ms: Double) {
        state.position = max(0, min(Double(max(0, state.length - 2)), ms / 1000 * sampleRate))
        state.finished = false
    }

    /// Playback speed (varispeed: pitch follows, like a record).
    func setRate(_ rate: Double) { state.rate = max(0.25, min(4, rate)) }

    func setVolume(_ volume: Int) { state.gain = Float(max(0, min(100, volume))) / 100 }

    var positionMs: Double { state.position / max(1, sampleRate) * 1000 }

    // MARK: Finish detection + idle shutdown (off the real-time thread)

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        if state.playing, state.finished {
            state.playing = false
            idleSince = Date()
            let out = Double(state.renderedFrames) / max(1, sampleRate)
            Log(String(format: "Local playback: %.2f s of audio in %.2f s of output → speed %.2f×", durationMs / 1000, out, durationMs / 1000 / max(0.001, out)))
            onEvent?(.finished)
        }
        // Let reverb tails ring out, then stop the engine to free the audio device.
        if !state.playing, let t = idleSince, Date().timeIntervalSince(t) > 8 {
            engine.pause()
            pollTimer?.invalidate()
            pollTimer = nil
            idleSince = nil
            chain?.reset()
        }
    }

    private static func bitrate(of url: URL) -> Int? {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else { return nil }
        defer { AudioFileClose(fileID) }
        var rate: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyBitRate, &size, &rate) == noErr, rate > 0 else { return nil }
        return Int((Double(rate) / 1000).rounded())
    }
}
