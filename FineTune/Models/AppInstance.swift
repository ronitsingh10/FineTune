// FineTune/Models/AppInstance.swift
import Darwin
import Foundation

/// Distinguishes a second copy of the same app launched with its own profile directory,
/// e.g. `open -na "Brave Browser" --args --user-data-dir=~/BraveWork`. Each such copy has
/// its own process tree (and, for Chromium browsers, its own audio service process), so it
/// can be tapped and persisted separately from the default instance.
///
/// A normal launch has no instance, which keeps its persistence identifier as the plain
/// bundle ID and leaves existing settings untouched.
struct AppInstance: Equatable, Hashable {
    /// Stable key appended to the bundle ID for persistence (the profile path, `~`-abbreviated).
    let key: String
    /// Short label shown next to the app name (the profile directory's last path component).
    let label: String

    /// Parses the profile flag out of a process's argument vector (argv[0] included).
    /// Recognises Chromium's `--user-data-dir` and Firefox's `-profile` / `-P`.
    static func from(arguments: [String], homeDirectory: String = NSHomeDirectory()) -> AppInstance? {
        let args = arguments.dropFirst()
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if let value = value(of: arg, flags: ["--user-data-dir"], next: &iterator)
                ?? value(of: arg, flags: ["-profile", "--profile"], next: &iterator) {
                return fromPath(value, homeDirectory: homeDirectory)
            }
            if let name = value(of: arg, flags: ["-P"], next: &iterator), !name.isEmpty {
                return AppInstance(key: "profile:\(name)", label: name)
            }
        }
        return nil
    }

    /// Reads the instance for a running process, or nil if it has no profile flag or
    /// its arguments can't be read.
    static func from(pid: pid_t) -> AppInstance? {
        guard let arguments = processArguments(pid: pid) else { return nil }
        return from(arguments: arguments)
    }

    private static func value(
        of arg: String,
        flags: [String],
        next iterator: inout IndexingIterator<ArraySlice<String>>
    ) -> String? {
        for flag in flags {
            if arg == flag { return iterator.next() }
            if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
        }
        return nil
    }

    private static func fromPath(_ rawPath: String, homeDirectory: String) -> AppInstance? {
        let path = (rawPath as NSString).expandingTildeInPath
        let standardized = ((path as NSString).standardizingPath as NSString)
        let full = standardized as String
        guard !full.isEmpty, full != "/" else { return nil }
        let home = (homeDirectory as NSString).standardizingPath
        let key = full.hasPrefix(home + "/") ? "~" + full.dropFirst(home.count) : full
        return AppInstance(key: String(key), label: standardized.lastPathComponent)
    }

    /// Reads argv for a process via `KERN_PROCARGS2`. Works for processes owned by the
    /// same user without extra entitlements.
    static func processArguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Layout: `argc` (Int32), exec path, NUL padding, then `argc` NUL-terminated strings.
    static func parseProcArgs(_ buffer: [UInt8]) -> [String]? {
        guard buffer.count > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        // Skip the exec path and the NUL padding that follows it.
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < argc, index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == argc ? arguments : nil
    }
}
