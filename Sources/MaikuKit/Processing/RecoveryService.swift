import Foundation

/// Surfaces recordings interrupted by a crash, a force-quit, or a power loss
/// (plan §9), and carries out "Delete" from the three-way recovery choice —
/// "Recover and process" and "Keep raw audio only" are
/// `RecordingCoordinator` methods, since both need it to run the pipeline or
/// touch `state`.
@MainActor
public struct RecoveryService {
    private let repository: RecordingRepository

    public init(repository: RecordingRepository) {
        self.repository = repository
    }

    /// See `RecordingRepository.fetchInterrupted()` for why this needs no
    /// separate manifest file.
    public func detectInterrupted() async throws -> [Recording] {
        try await repository.fetchInterrupted()
    }

    /// Removes the database rows and the recording's audio directory.
    /// `RecordingRepository.deletePermanently` deliberately never touches
    /// files itself — this is the one caller for an interrupted recording
    /// that actually wants both gone together.
    public func deletePermanently(_ recording: Recording) async throws {
        try await repository.deletePermanently(id: recording.id)
        let directory = AppPaths.audioDirectory.appending(path: recording.id.uuidString)
        try? FileManager.default.removeItem(at: directory)
    }
}
