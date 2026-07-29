import AppKit
import SwiftUI

/// Where each mascot state's sprite frames live, by filename.
///
/// The repository ships no Clawd artwork on purpose: the character is
/// Anthropic's, and plan §14 allows only art the user is authorised to use.
/// The manifest is the whole contract — drop correctly named PNGs into
/// `Resources/Clawd/` and `ClawdView` stops drawing its placeholder. Nothing
/// else in the app knows a filename.
public struct ClawdAssetManifest: Sendable {

    /// One state's frame sequence. A single-frame entry is a still.
    public struct Entry: Sendable, Equatable {
        public var frames: [String]
        /// Seconds each frame is held.
        public var frameDuration: Double

        public init(_ frames: [String], frameDuration: Double = 0.18) {
            self.frames = frames
            self.frameDuration = frameDuration
        }
    }

    public static let standard = ClawdAssetManifest()

    /// Subdirectory searched inside the app bundle.
    public static let assetDirectory = "Clawd"

    /// Every frame is this size; see `Resources/Clawd/README.md`.
    public static let spriteSize = CGSize(width: 64, height: 64)

    /// Every filename plan §14 names, in the order it names them. Authorised
    /// art must use these exact names.
    public let fileNames = [
        "clawd_idle_notebook.png",
        "clawd_ready_mic.png",
        "clawd_listening_01.png",
        "clawd_listening_02.png",
        "clawd_listening_03.png",
        "clawd_listening_04.png",
        "clawd_paused.png",
        "clawd_transcribing_01.png",
        "clawd_transcribing_02.png",
        "clawd_organizing_01.png",
        "clawd_organizing_02.png",
        "clawd_organizing_03.png",
        "clawd_complete.png",
        "clawd_error.png",
        "clawd_lmstudio_disconnected.png",
    ]

    public init() {}

    public func entry(for state: ClawdState) -> Entry {
        switch state {
        case .idle:
            Entry(["clawd_idle_notebook.png"])
        case .ready:
            Entry(["clawd_ready_mic.png"])
        case .listening:
            // Fast enough to read as talking, slow enough to stay legible.
            Entry(
                [
                    "clawd_listening_01.png", "clawd_listening_02.png",
                    "clawd_listening_03.png", "clawd_listening_04.png",
                ], frameDuration: 0.12)
        case .paused:
            Entry(["clawd_paused.png"])
        case .transcribing:
            Entry(["clawd_transcribing_01.png", "clawd_transcribing_02.png"], frameDuration: 0.25)
        case .organizing:
            Entry(
                [
                    "clawd_organizing_01.png", "clawd_organizing_02.png",
                    "clawd_organizing_03.png",
                ], frameDuration: 0.22)
        case .complete:
            Entry(["clawd_complete.png"])
        case .error:
            Entry(["clawd_error.png"])
        case .lmStudioDisconnected:
            Entry(["clawd_lmstudio_disconnected.png"])
        }
    }

    /// Resolves a frame to a file on disk.
    ///
    /// `MAIKU_CLAWD_DIR` is checked first so artwork can be tried from the
    /// working copy during `swift run`, before it is bundled.
    nonisolated public static func url(for fileName: String, in bundle: Bundle = .main) -> URL? {
        if let dir = ProcessInfo.processInfo.environment["MAIKU_CLAWD_DIR"], !dir.isEmpty {
            let candidate = URL(fileURLWithPath: dir, isDirectory: true)
                .appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        return bundle.url(forResource: name, withExtension: ext, subdirectory: assetDirectory)
            ?? bundle.url(forResource: name, withExtension: ext)
    }
}

/// Loads sprite frames once each.
///
/// A four-frame loop asks for the same file eight times a second, and
/// `NSImage(contentsOf:)` hits the disk every time it is called.
@MainActor
enum ClawdArtwork {
    private static var cache: [String: NSImage?] = [:]

    static func image(_ fileName: String) -> Image? {
        let loaded: NSImage?
        if let hit = cache[fileName] {
            loaded = hit
        } else {
            loaded = ClawdAssetManifest.url(for: fileName).flatMap(NSImage.init(contentsOf:))
            cache[fileName] = loaded
        }
        return loaded.map { Image(nsImage: $0) }
    }

    /// Whether any authorised artwork is installed. Drives the placeholder
    /// badge, and is resolved once — art does not appear mid-session.
    static let isInstalled: Bool = ClawdAssetManifest.standard.fileNames.contains {
        ClawdAssetManifest.url(for: $0) != nil
    }
}
