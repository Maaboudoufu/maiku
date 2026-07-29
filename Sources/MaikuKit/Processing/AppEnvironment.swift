import Foundation

/// The one place production dependencies are wired together. Views receive
/// this through the SwiftUI environment rather than constructing their own
/// `RecordingRepository`/`LMStudioClient`/etc., so a screen and a preview can
/// use the same shape with different instances underneath.
@MainActor
public final class AppEnvironment {
    public let databaseManager: DatabaseManager
    public let repository: RecordingRepository
    public let lmStudioClient: LMStudioClient
    public let coordinator: RecordingCoordinator
    public let recoveryService: RecoveryService

    public init() throws {
        let databaseManager = try DatabaseManager.openStandard()
        let repository = RecordingRepository(dbManager: databaseManager)
        let lmStudioClient = LMStudioClient()
        self.databaseManager = databaseManager
        self.repository = repository
        self.lmStudioClient = lmStudioClient
        self.coordinator = RecordingCoordinator(
            transcriber: WhisperKitTranscriber(),
            diarizer: FluidAudioDiarizer(),
            lmStudio: lmStudioClient,
            repository: repository)
        self.recoveryService = RecoveryService(repository: repository)
    }
}
