import AVFoundation

/// Microphone authorisation, expressed in `MaikuError` terms.
///
/// Wrapped so recording code never branches on all four `AVAuthorizationStatus`
/// cases, and so "not asked yet" stays distinct from "refused" — plan §19 gives
/// those two the same buttons but a different message.
public enum MicrophonePermission {

    public enum Status: Sendable, Equatable {
        case granted
        case denied
        case undetermined
    }

    public static var status: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        // `.restricted` (managed device) is indistinguishable from `.denied`
        // to the user: both mean "we cannot record, go look at Settings".
        default: .denied
        }
    }

    public static var isGranted: Bool { status == .granted }

    /// Throws without ever prompting. Call this immediately before capture so a
    /// permission revoked in System Settings surfaces before a file is created.
    public static func check() throws {
        switch status {
        case .granted: return
        case .denied: throw MaikuError.microphonePermissionDenied
        case .undetermined: throw MaikuError.microphonePermissionUndetermined
        }
    }

    /// Prompts when undetermined. Returns normally only when access is granted;
    /// a previously refused app gets `false` back with no prompt shown, which is
    /// still `.microphonePermissionDenied`.
    public static func request() async throws {
        if isGranted { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw MaikuError.microphonePermissionDenied
        }
    }
}
