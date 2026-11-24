import CoreAudio
import Darwin
import Foundation

struct CAError: Error, CustomStringConvertible {
    let status: OSStatus
    let what: String
    init(_ status: OSStatus, _ what: String) { self.status = status; self.what = what }
    var description: String { "\(what) failed: \(status) (\(fourCC(UInt32(bitPattern: status))))" }
}

func fourCC(_ v: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(decoding: bytes, as: UTF8.self) }
    return String(v)
}

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var addr = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw CAError(err, "get '\(fourCC(selector))'") }
        return value
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard err == noErr, let str = value?.takeRetainedValue() else { throw CAError(err, "get string '\(fourCC(selector))'") }
        return str as String
    }

    static func getObjectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard err == noErr else { throw CAError(err, "size '\(fourCC(selector))'") }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids)
        guard err == noErr else { throw CAError(err, "get list '\(fourCC(selector))'") }
        return ids
    }
}

/// `responsibility_get_pid_responsible_for_pid` (private libsystem symbol) tells us
/// which app an XPC service works for — used to find *our* WebKit helper
/// processes and not Safari's.
enum Responsibility {
    private typealias Fn = @convention(c) (pid_t) -> pid_t
    private static let fn: Fn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()
    static var isAvailable: Bool { fn != nil }
    static func pid(for pid: pid_t) -> pid_t? { fn.map { $0(pid) } }
}

/// A process that is (or was) a client of the audio HAL.
struct AudioProcess: CustomStringConvertible {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningOutput: Bool
    let responsiblePID: pid_t?

    var description: String {
        "\(bundleID.isEmpty ? "?" : bundleID) pid=\(pid) obj=\(objectID) output=\(isRunningOutput) resp=\(responsiblePID.map(String.init) ?? "?")"
    }

    static func all() -> [AudioProcess] {
        guard let ids = try? CA.getObjectList(CA.system, kAudioHardwarePropertyProcessObjectList) else { return [] }
        return ids.map { id in
            let pid = (try? CA.get(id, kAudioProcessPropertyPID, initial: pid_t(-1))) ?? -1
            let bundle = (try? CA.getString(id, kAudioProcessPropertyBundleID)) ?? ""
            let running = (try? CA.get(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundle, isRunningOutput: running != 0,
                                responsiblePID: Responsibility.pid(for: pid))
        }
    }

    /// WebKit helper processes (GPU / WebContent) that belong to this app.
    static func ourWebKitProcesses(in all: [AudioProcess]) -> [AudioProcess] {
        let me = getpid()
        let myResponsible = Responsibility.pid(for: me) ?? me
        let webkit = all.filter { $0.bundleID.hasPrefix("com.apple.WebKit") && $0.pid != me }
        guard Responsibility.isAvailable else { return webkit } // fallback: may include Safari's helpers
        return webkit.filter { p in
            guard let r = p.responsiblePID else { return false }
            return r == me || r == myResponsible
        }
    }
}
