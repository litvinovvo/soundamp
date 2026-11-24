import Foundation

/// Single-writer (audio thread) / single-reader (UI) ring of mono samples for the
/// visualizer. Unsynchronized on purpose: a torn read only shows up as one
/// slightly wrong visualizer frame.
public final class SampleRing {
    public let capacity = 8192
    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    public private(set) var writeIndex = 0
    /// Peak absolute sample value since the last `takePeak()` — used to detect a
    /// tap that delivers pure silence (e.g. missing permission).
    private var peak: Float = 0

    public init() {
        mask = capacity - 1
        buffer = .allocate(capacity: capacity)
        buffer.update(repeating: 0, count: capacity)
    }

    deinit { buffer.deallocate() }

    public func write(_ samples: UnsafePointer<Float>, count: Int) {
        var w = writeIndex
        var p = peak
        for i in 0..<count {
            let s = samples[i]
            buffer[w & mask] = s
            let a = abs(s)
            if a > p { p = a }
            w &+= 1
        }
        peak = p
        writeIndex = w
    }

    public func read(latest count: Int, into out: UnsafeMutablePointer<Float>) {
        let w = writeIndex
        for i in 0..<count { out[i] = buffer[(w &- count &+ i) & mask] }
    }

    public func takePeak() -> Float {
        let p = peak
        peak = 0
        return p
    }
}
