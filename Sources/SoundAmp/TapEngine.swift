import AudioToolbox
import CoreAudio
import Foundation
import SoundAmpCore

/// Taps the audio of our own WebKit helper process(es), mutes the original, runs
/// it through the EQ and plays it to the default output device. Also feeds the
/// visualizer ring.
///
/// Pipeline:
///   WebKit GPU process ──(process tap, mutedWhenTapped)──┐
///                                                        ▼
///   private aggregate device [ main sub-device = default output, tap ]
///        IOProc: tap input ─► EQ ─► visualizer ring ─► device output
final class TapEngine {
    /// EQ → pitch → reverb chain at the aggregate device's rate (made on attach).
    private(set) var effects: EffectsChain?
    /// Called on attach with the new chain, to push current settings into it.
    var configureChain: ((EffectsChain) -> Void)?
    let ring: SampleRing

    private(set) var isAttached = false
    /// True while the aggregate device IOProc is actively pulling audio.
    private(set) var isRunning = false
    private(set) var sampleRate: Double = 48_000
    private(set) var summary = ""
    /// Called on the main queue after an automatic re-attach (output device changed).
    var onReattach: ((Result<Void, Error>) -> Void)?

    private var tappedProcesses: [AudioProcess] = []
    private var deviceListener: AudioObjectPropertyListenerBlock?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private let maxFrames = 16_384
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let mono: UnsafeMutablePointer<Float>

    init(ring: SampleRing) {
        self.ring = ring
        left = .allocate(capacity: maxFrames)
        right = .allocate(capacity: maxFrames)
        mono = .allocate(capacity: maxFrames)
    }

    deinit {
        detach()
        left.deallocate()
        right.deallocate()
        mono.deallocate()
    }

    func attach(to processes: [AudioProcess], startImmediately: Bool = true) throws {
        teardown()
        guard !processes.isEmpty else { throw CAError(0, "no processes to tap") }

        let description = CATapDescription(stereoMixdownOfProcesses: processes.map { $0.objectID })
        description.uuid = UUID()
        description.name = "SoundAmp tap"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tap)
        guard err == noErr else { throw CAError(err, "AudioHardwareCreateProcessTap") }
        tapID = tap

        do {
            let format = try CA.get(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else {
                throw CAError(0, "unexpected tap format \(format)")
            }

            let outputDevice = try CA.get(CA.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))
            let outputUID = try CA.getString(outputDevice, kAudioDevicePropertyDeviceUID)
            let outputName = (try? CA.getString(outputDevice, kAudioObjectPropertyName)) ?? outputUID

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SoundAmp Aggregate",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            var agg = AudioObjectID(kAudioObjectUnknown)
            err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
            guard err == noErr else { throw CAError(err, "AudioHardwareCreateAggregateDevice") }
            aggregateID = agg

            sampleRate = (try? CA.get(agg, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? format.mSampleRate
            if sampleRate <= 0 { sampleRate = format.mSampleRate }
            let chain = EffectsChain(sampleRate: sampleRate, maxFrames: maxFrames)
            configureChain?(chain)
            effects = chain

            var procID: AudioDeviceIOProcID?
            err = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { [unowned self, chain] _, inInput, _, outOutput, _ in
                self.render(input: inInput, output: outOutput, chain: chain)
            }
            guard err == noErr, let procID else { throw CAError(err, "AudioDeviceCreateIOProcIDWithBlock") }
            ioProcID = procID

            if startImmediately {
                err = AudioDeviceStart(agg, procID)
                guard err == noErr else { throw CAError(err, "AudioDeviceStart") }
                isRunning = true
            }

            isAttached = true
            tappedProcesses = processes
            startDeviceListener()
            summary = "tap \(format.mChannelsPerFrame)ch @ \(Int(format.mSampleRate)) Hz → \(outputName) @ \(Int(sampleRate)) Hz"
        } catch {
            teardown()
            throw error
        }
    }

    /// Stop the HAL IOProc while idle/paused so CoreAudio and the DSP chain use 0% CPU.
    func suspend() {
        guard isAttached, isRunning, let procID = ioProcID, aggregateID != kAudioObjectUnknown else { return }
        AudioDeviceStop(aggregateID, procID)
        isRunning = false
        effects?.reset()
    }

    /// Restart the HAL IOProc when playback resumes. Re-attaches if the device went stale.
    @discardableResult
    func resume() -> Bool {
        guard isAttached else { return false }
        if isRunning { return true }
        guard let procID = ioProcID, aggregateID != kAudioObjectUnknown else { return false }
        let err = AudioDeviceStart(aggregateID, procID)
        if err == noErr {
            isRunning = true
            return true
        }
        let procs = tappedProcesses
        guard !procs.isEmpty else { return false }
        do {
            try attach(to: procs, startImmediately: true)
            return true
        } catch {
            return false
        }
    }

    func detach() {
        stopDeviceListener()
        tappedProcesses = []
        teardown()
    }

    private func teardown() {
        if let procID = ioProcID {
            if isRunning { AudioDeviceStop(aggregateID, procID) }
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        isRunning = false
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        isAttached = false
        effects = nil
        summary = ""
    }

    // MARK: Output device changes (headphones, AirPods, …)

    private func startDeviceListener() {
        guard deviceListener == nil else { return }
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isAttached else { return }
            let procs = self.tappedProcesses
            let wasRunning = self.isRunning
            do {
                try self.attach(to: procs, startImmediately: wasRunning)
                self.onReattach?(.success(()))
            } catch {
                self.onReattach?(.failure(error))
            }
        }
        if AudioObjectAddPropertyListenerBlock(CA.system, &addr, DispatchQueue.main, block) == noErr {
            deviceListener = block
        }
    }

    private func stopDeviceListener() {
        guard let block = deviceListener else { return }
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(CA.system, &addr, DispatchQueue.main, block)
        deviceListener = nil
    }

    // MARK: Real-time render (HAL IO thread — no allocation, no locks)

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, chain: EffectsChain) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        // The tap's streams come after any input streams of the output sub-device,
        // so walk the input list backwards and pick up to two channels (L/R).
        var lPtr: UnsafePointer<Float>?
        var rPtr: UnsafePointer<Float>?
        var lStride = 1
        var rStride = 1
        var frames = Int.max
        var i = inList.count - 1
        while i >= 0, lPtr == nil {
            let buf = inList[i]
            i -= 1
            guard let data = buf.mData, buf.mNumberChannels > 0 else { continue }
            let ch = Int(buf.mNumberChannels)
            let f = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            frames = min(frames, Int(buf.mDataByteSize) / (4 * ch))
            if ch >= 2 {
                if rPtr == nil { lPtr = f; rPtr = f + 1; lStride = ch; rStride = ch }
                else { lPtr = f + (ch - 1); lStride = ch }
            } else if rPtr == nil {
                rPtr = f; rStride = 1
            } else {
                lPtr = f; lStride = 1
            }
        }
        if lPtr == nil, let r = rPtr { lPtr = r; lStride = rStride } // mono tap
        guard let lIn = lPtr, let rIn = rPtr, frames != Int.max else {
            zero(outList)
            return
        }
        frames = min(frames, maxFrames)

        for k in 0..<frames {
            left[k] = lIn[k * lStride]
            right[k] = rIn[k * rStride]
        }
        chain.process(left: left, right: right, frames: frames)
        for k in 0..<frames { mono[k] = 0.5 * (left[k] + right[k]) }
        ring.write(mono, count: frames)

        // Write L/R into the first two output channels, silence the rest.
        var channelBase = 0
        for buf in outList {
            guard let data = buf.mData, buf.mNumberChannels > 0 else { continue }
            let ch = Int(buf.mNumberChannels)
            let out = data.assumingMemoryBound(to: Float.self)
            let outFrames = Int(buf.mDataByteSize) / (4 * ch)
            let n = min(outFrames, frames)
            for c in 0..<ch {
                let channel = channelBase + c
                let src: UnsafeMutablePointer<Float>? = channel == 0 ? left : (channel == 1 ? right : nil)
                if let src {
                    for k in 0..<n { out[k * ch + c] = src[k] }
                } else {
                    for k in 0..<n { out[k * ch + c] = 0 }
                }
                if outFrames > n { for k in n..<outFrames { out[k * ch + c] = 0 } }
            }
            channelBase += ch
        }
    }

    private func zero(_ list: UnsafeMutableAudioBufferListPointer) {
        for buf in list {
            if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
        }
    }
}
