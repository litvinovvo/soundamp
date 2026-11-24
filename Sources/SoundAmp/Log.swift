import Foundation

/// Logs to stdout, to ~/Library/Logs/SoundAmp.log (truncated each launch) and to
/// the in-app log view.
final class Logger {
    static let shared = Logger()
    /// `SOUNDAMP_LOG=<path>` overrides the location (used by scripts/smoke.sh so a
    /// test run doesn't clobber the log of the instance you're using).
    static let fileURL = ProcessInfo.processInfo.environment["SOUNDAMP_LOG"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SoundAmp.log")

    /// Called on the main thread with each formatted line.
    var sink: ((String) -> Void)?
    /// Recent lines (main thread), for the debug console.
    private(set) var history: [String] = []

    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "soundamp.log")
    private let start = Date()

    private init() {
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Self.fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: Self.fileURL)
    }

    func log(_ message: String) {
        let line = String(format: "[%7.2f] ", Date().timeIntervalSince(start)) + message
        queue.async { [handle] in
            print(line)
            handle?.write(Data((line + "\n").utf8))
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.history.append(line)
            if self.history.count > 2000 { self.history.removeFirst(500) }
            self.sink?(line)
        }
    }
}

func Log(_ message: String) { Logger.shared.log(message) }
