import Foundation

/// A speaker within one recording.
///
/// Version 1 deliberately does **not** persist reusable voiceprints across
/// recordings (plan §12). Diarization embeddings stay in memory for the
/// duration of a single processing run and are never written to disk.
public struct Speaker: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var recordingID: UUID
    /// Label emitted by the diarizer, e.g. `"1"`. Stable within one recording.
    public var diarizerLabel: String
    /// User-supplied name. When nil the UI falls back to `displayName`.
    public var customName: String?
    /// Index into the semantic speaker colour ramp, not a raw colour value.
    public var colorIndex: Int

    public init(
        id: UUID = UUID(),
        recordingID: UUID,
        diarizerLabel: String,
        customName: String? = nil,
        colorIndex: Int = 0
    ) {
        self.id = id
        self.recordingID = recordingID
        self.diarizerLabel = diarizerLabel
        self.customName = customName
        self.colorIndex = colorIndex
    }

    /// What the interface and exports should show.
    public var displayName: String {
        if let customName, !customName.trimmingCharacters(in: .whitespaces).isEmpty {
            return customName
        }
        return "Speaker \(diarizerLabel)"
    }

    public var isRenamed: Bool {
        !(customName?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }
}
