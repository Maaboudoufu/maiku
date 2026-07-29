import Foundation

/// The one place production dependencies are wired together. Views receive
/// this through the SwiftUI environment rather than constructing their own
/// `RecordingRepository`/`LMStudioClient`/etc., so a screen and a preview can
/// use the same shape with different instances underneath.
@MainActor
public final class AppEnvironment {
    public let databaseManager: DatabaseManager
    public let repository: RecordingRepository
    public let settingsStore: SettingsStore
    public let tokenStore: KeychainTokenStore
    public let lmStudioClient: LMStudioClient
    public let coordinator: RecordingCoordinator
    public let recoveryService: RecoveryService

    /// `async` so the very first `LMStudioClient`/`RecordingCoordinator` this
    /// launch builds already reflects whatever was saved in Settings last
    /// time (plan §16 M5), rather than always starting from defaults and
    /// waiting for a screen to push a correction in.
    public init() async throws {
        let databaseManager = try DatabaseManager.openStandard()
        let repository = RecordingRepository(dbManager: databaseManager)
        let settingsStore = SettingsStore(dbManager: databaseManager)
        let tokenStore = KeychainTokenStore()
        let settings = (try? await settingsStore.fetch()) ?? AppSettings()
        var lmStudioConfiguration = settings.lmStudioConfiguration
        lmStudioConfiguration.apiToken = try? tokenStore.token()
        let lmStudioClient = LMStudioClient(configuration: lmStudioConfiguration)
        self.databaseManager = databaseManager
        self.repository = repository
        self.settingsStore = settingsStore
        self.tokenStore = tokenStore
        self.lmStudioClient = lmStudioClient
        self.coordinator = RecordingCoordinator(
            transcriber: WhisperKitTranscriber(),
            diarizer: FluidAudioDiarizer(),
            lmStudio: lmStudioClient,
            repository: repository)
        self.recoveryService = RecoveryService(repository: repository)
    }
}
