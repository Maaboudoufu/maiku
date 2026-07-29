import Foundation

/// A local, rotating diagnostic log (plan §9). Never uploaded — the only way
/// its contents leave the machine is `DiagnosticsExporter`, which the user
/// triggers explicitly and which redacts recording titles and transcript
/// content by default.
public actor DiagnosticLog {
    public enum Level: String, Sendable {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    public static let shared = DiagnosticLog()

    private let url: URL
    private let maxFileSize: Int64
    private let maxRotations: Int

    public init(
        directory: URL? = nil, maxFileSize: Int64 = 5 * 1024 * 1024, maxRotations: Int = 3
    ) {
        self.url = (directory ?? AppPaths.logsDirectory).appending(path: "maiku.log")
        self.maxFileSize = maxFileSize
        self.maxRotations = max(1, maxRotations)
    }

    public func log(_ message: String, level: Level = .info) {
        let line = "\(Self.timestamp()) [\(level.rawValue)] \(message)\n"
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            rotateIfNeeded()
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        } catch {
            // A logging failure must never interrupt the feature it's
            // describing.
        }
    }

    /// Every retained line, oldest rotation first — what `DiagnosticsExporter`
    /// bundles up.
    public func readAll() -> String {
        let fm = FileManager.default
        var chunks: [String] = []
        for index in stride(from: maxRotations, through: 1, by: -1) {
            let rotated = url.appendingPathExtension("\(index)")
            if let text = try? String(contentsOf: rotated, encoding: .utf8) { chunks.append(text) }
        }
        if fm.fileExists(atPath: url.path), let text = try? String(contentsOf: url, encoding: .utf8) {
            chunks.append(text)
        }
        return chunks.joined()
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard
            let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64,
            size >= maxFileSize
        else { return }

        try? fm.removeItem(at: url.appendingPathExtension("\(maxRotations)"))
        for index in stride(from: maxRotations - 1, through: 1, by: -1) {
            let from = url.appendingPathExtension("\(index)")
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.removeItem(at: url.appendingPathExtension("\(index + 1)"))
            try? fm.moveItem(at: from, to: url.appendingPathExtension("\(index + 1)"))
        }
        try? fm.moveItem(at: url, to: url.appendingPathExtension("1"))
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
