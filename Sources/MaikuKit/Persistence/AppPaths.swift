import Foundation

/// Resolves where maiku's data lives on disk, and the boundary between an
/// absolute path and one safe to store in the database.
///
/// Plan §8 requires storing paths relative to the data directory rather than
/// absolute ones, so moving `~/Library/Application Support/Maiku` (a backup
/// restore, a different user account) never orphans a recording. That only
/// holds if a relative path can never point outside the directory it is
/// relative to — the traversal checks below are a trust boundary, not
/// defensive dead code, because relative paths round-trip through the
/// database and could in principle be tampered with on disk.
public enum AppPaths {

    /// Override for tests and previews. Never set in the shipping app.
    /// `nonisolated(unsafe)`: set once, synchronously, before a test's
    /// concurrent work begins — never mutated from more than one place at once.
    nonisolated(unsafe) public static var overrideBaseDirectory: URL?

    public static var baseDirectory: URL {
        if let overrideBaseDirectory { return overrideBaseDirectory }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return support.appending(path: "Maiku", directoryHint: .isDirectory)
    }

    public static var databaseURL: URL {
        baseDirectory.appending(path: "Maiku.sqlite")
    }

    public static var audioDirectory: URL {
        baseDirectory.appending(path: "Audio", directoryHint: .isDirectory)
    }

    public static var exportsDirectory: URL {
        baseDirectory.appending(path: "Exports", directoryHint: .isDirectory)
    }

    public static var recoveryDirectory: URL {
        baseDirectory.appending(path: "Recovery", directoryHint: .isDirectory)
    }

    public static var logsDirectory: URL {
        baseDirectory.appending(path: "Logs", directoryHint: .isDirectory)
    }

    /// Creates every top-level directory maiku needs, idempotently.
    public static func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        for url in [baseDirectory, audioDirectory, exportsDirectory, recoveryDirectory, logsDirectory] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// A fresh per-recording audio directory, e.g. `Audio/<uuid>/`.
    public static func audioDirectory(for recordingID: UUID) throws -> URL {
        let url = audioDirectory.appending(path: recordingID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Converts an absolute URL under `baseDirectory` into the path stored in
    /// the database. Returns nil for anything outside the data directory —
    /// callers must not persist a path this rejects.
    public static func relativePath(of url: URL) -> String? {
        let base = baseDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard target.hasPrefix(base + "/") else { return nil }
        return String(target.dropFirst(base.count + 1))
    }

    /// Resolves a path read back from the database. Rejects anything that
    /// could escape `baseDirectory`: absolute paths, empty components, and
    /// `..` segments anywhere in the path — not just a leading one, since
    /// `"Audio/../../../etc/passwd"` is exactly as dangerous as `"../etc"`.
    public static func absoluteURL(forRelativePath relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." || $0.isEmpty }) else { return nil }
        return baseDirectory.appending(path: relativePath)
    }
}
