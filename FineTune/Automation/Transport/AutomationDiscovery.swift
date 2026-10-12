import Darwin
import Foundation

nonisolated struct AutomationDiscovery: Codable, Sendable {
    let apiVersion: Int
    let instanceId: String
    let socketPath: String
    static func prepareDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else {
                throw AutomationError(
                    .unavailable, "Automation directory must be owned by this user and not a symlink")
            }
        } else {
            guard errno == ENOENT else {
                throw AutomationError(.unavailable, "Cannot inspect automation directory")
            }
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid()
            else { throw AutomationError(.unavailable, "Invalid automation directory") }
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw AutomationError(.unavailable, "Cannot protect automation directory")
        }
    }
    func publish(to url: URL) throws {
        try Self.prepareDirectory(url.deletingLastPathComponent())
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid() else {
                throw AutomationError(.unavailable, "Unsafe discovery file")
            }
        }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else {
            throw AutomationError(.unavailable, "Cannot protect discovery file")
        }
    }
}
