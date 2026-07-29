import Foundation

/// Plan §9's "Export Diagnostics": builds a local, redacted text report.
/// Never uploaded — the caller decides where the result goes (e.g. via
/// `NSSavePanel`), and this only ever produces the text, never sends it
/// anywhere itself.
public enum DiagnosticsExporter {
    /// - Parameter includeTranscripts: when `false` (the default), recording
    ///   titles are left out — only what's needed to diagnose a processing
    ///   problem (id, status, stage, timestamps, error message) is included.
    ///   Segment and note text is never included regardless, since nothing
    ///   here ever receives it in the first place.
    public static func export(
        recordings: [Recording], logContents: String, includeTranscripts: Bool = false
    ) -> String {
        var lines: [String] = [
            "maiku diagnostics — \(ISO8601DateFormatter().string(from: Date()))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "",
            "## Recordings (\(recordings.count))",
        ]
        for recording in recordings {
            var entry = "- \(recording.id) · status=\(recording.status.rawValue)"
            if includeTranscripts, !recording.title.isEmpty {
                entry += " · title=\"\(recording.title)\""
            }
            if let stage = recording.errorStage { entry += " · errorStage=\(stage)" }
            if let message = recording.errorMessage { entry += " · error=\(message)" }
            lines.append(entry)
        }
        lines.append("")
        lines.append("## Log")
        lines.append(logContents.isEmpty ? "(empty)" : logContents)
        return lines.joined(separator: "\n")
    }
}
