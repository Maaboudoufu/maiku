import Foundation

/// App-wide, non-secret preferences (plan §10.7). Singleton row, one per
/// install. The LM Studio API token is not a field here — it lives in the
/// Keychain via `KeychainTokenStore` (plan §12).
public struct AppSettings: Sendable, Equatable {
    /// `AVCaptureDevice.uniqueID` of the chosen input, or nil for the system default.
    public var inputDeviceUID: String?
    /// WhisperKit model identifier, matching `SpeechModelConfiguration.modelName`.
    public var speechModelName: String
    /// BCP-47 tag passed to `SpeechModelConfiguration.language`.
    public var language: String
    public var liveDiarizationEnabled: Bool
    public var lmStudioBaseURL: URL
    public var lmStudioModelID: String?
    public var lmStudioTimeout: TimeInterval
    /// Days of audio to keep before it is eligible for cleanup, or nil to keep forever.
    public var audioRetentionDays: Int?
    /// Overrides the system Reduce Motion setting when non-nil.
    public var reducedMotionOverride: Bool?
    public var soundEffectsEnabled: Bool
    public var crtEffectsEnabled: Bool

    public init(
        inputDeviceUID: String? = nil,
        speechModelName: String = "tiny.en",
        language: String = "en",
        liveDiarizationEnabled: Bool = true,
        lmStudioBaseURL: URL = LMStudioConfiguration.defaultBaseURL,
        lmStudioModelID: String? = nil,
        lmStudioTimeout: TimeInterval = 120,
        audioRetentionDays: Int? = nil,
        reducedMotionOverride: Bool? = nil,
        soundEffectsEnabled: Bool = true,
        crtEffectsEnabled: Bool = true
    ) {
        self.inputDeviceUID = inputDeviceUID
        self.speechModelName = speechModelName
        self.language = language
        self.liveDiarizationEnabled = liveDiarizationEnabled
        self.lmStudioBaseURL = lmStudioBaseURL
        self.lmStudioModelID = lmStudioModelID
        self.lmStudioTimeout = lmStudioTimeout
        self.audioRetentionDays = audioRetentionDays
        self.reducedMotionOverride = reducedMotionOverride
        self.soundEffectsEnabled = soundEffectsEnabled
        self.crtEffectsEnabled = crtEffectsEnabled
    }

    /// This plus the Keychain token is everything `LMStudioClient` needs.
    public var lmStudioConfiguration: LMStudioConfiguration {
        LMStudioConfiguration(
            baseURL: lmStudioBaseURL, modelID: lmStudioModelID, timeout: lmStudioTimeout)
    }

    public var speechModel: SpeechModelConfiguration {
        SpeechModelConfiguration(modelName: speechModelName, language: language)
    }
}
