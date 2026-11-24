import Foundation

/// SoundCloud stream presets as they appear in HLS URLs ("aac_160k", "mp3_128",
/// "opus_0_0", "mp3_0_0", "aac_256k" …) → bitrate in kbps.
public enum StreamPreset {
    public static func kbps(_ preset: String) -> Int? {
        let p = preset.lowercased()
        // Explicit bitrate: aac_160k, aac_256k, mp3_128k, opus_64k
        if let r = p.range(of: #"_(\d{2,3})k?(_|$)"#, options: .regularExpression) {
            let digits = p[r].filter(\.isNumber)
            if let v = Int(digits), v >= 32 { return v }
        }
        // SoundCloud's legacy names without a number
        if p.hasPrefix("opus") { return 64 }
        if p.hasPrefix("mp3") { return 128 }
        return nil
    }
}
