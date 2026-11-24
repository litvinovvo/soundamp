import AppKit

/// "System Audio Recording" permission (TCC service kTCCServiceAudioCapture),
/// needed by the Core Audio process tap that feeds the EQ and visualizer.
///
/// macOS has no public API to query or request it, so this uses TCC's
/// TCCAccessPreflight / TCCAccessRequest (same approach as Apple-developer
/// sample apps like AudioCap). Fine outside the Mac App Store. If the symbols
/// ever disappear, status is `.unknown` and we just try the tap.
enum AudioPermission {
    enum Status: String { case authorized, denied, notDetermined, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let preflightFn: PreflightFn? = tcc.flatMap { dlsym($0, "TCCAccessPreflight") }.map { unsafeBitCast($0, to: PreflightFn.self) }
    private static let requestFn: RequestFn? = tcc.flatMap { dlsym($0, "TCCAccessRequest") }.map { unsafeBitCast($0, to: RequestFn.self) }

    static var status: Status {
        guard let preflightFn else { return .unknown }
        switch preflightFn(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the system prompt (only when not determined yet). Completion on main queue.
    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let requestFn else { completion(status != .denied); return }
        requestFn(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Privacy & Security › Screen & System Audio Recording (holds "System Audio Recording Only").
    static func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}
