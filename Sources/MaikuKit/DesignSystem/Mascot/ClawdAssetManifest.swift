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
    ///
    /// `listening` ships 7 frames, not the 4 plan §14's suggested manifest
    /// sketched — the authorized art actually supplied for this mascot came
    /// as an 8-frame loop (110ms/frame; see `Resources/Clawd/README.md`),
    /// with the 8th (the mic being set down) dropped as a distinct beat that
    /// didn't belong in a continuously-looping "still listening" cycle. The
    /// plan's own frame list was explicitly a *suggested* starting manifest,
    /// not a fixed frame count.
    public let fileNames = [
        "clawd_idle_notebook.png",
        "clawd_ready_mic.png",
        "clawd_listening_01.png",
        "clawd_listening_02.png",
        "clawd_listening_03.png",
        "clawd_listening_04.png",
        "clawd_listening_05.png",
        "clawd_listening_06.png",
        "clawd_listening_07.png",
        "clawd_paused.png",
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
            // 110ms/frame matches the authorized artwork's own metadata
            // (Resources/Clawd/README.md) — fast enough to read as talking,
            // slow enough to stay legible.
            Entry(
                [
                    "clawd_listening_01.png", "clawd_listening_02.png",
                    "clawd_listening_03.png", "clawd_listening_04.png",
                    "clawd_listening_05.png", "clawd_listening_06.png",
                    "clawd_listening_07.png",
                ], frameDuration: 0.11)
        case .paused:
            // A still, matching idle's treatment — paused is a held state,
            // not something actively looping (the 6-frame animation this
            // replaced had no motion worth animating in a "waiting" pose).
            Entry(["clawd_paused.png"])
        case .transcribing, .organizing:
            // No manifest files: `ClawdView` renders a code-drawn
            // `ProcessingSprite` for both states directly and never reads
            // this entry. An AI-supplied contact sheet was tried here twice
            // and needed re-registration both times to stop visibly jittering
            // (`Resources/Clawd/README.md`) — a procedurally animated shape
            // can't drift out of registration, so there is nothing to supply.
            Entry([])
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

    private static var installedCache: [[String]: Bool] = [:]

    /// Whether every frame *this state's* entry needs is installed. Per
    /// state, not app-wide: art lands one state at a time (README), so
    /// installing `listening`'s frames must not hide the placeholder badge
    /// on `idle`/`ready`/etc., which still have none. Resolved once per
    /// distinct frame list — art does not appear mid-session.
    static func isFullyInstalled(_ entry: ClawdAssetManifest.Entry) -> Bool {
        isFullyInstalled(entry) { ClawdAssetManifest.url(for: $0) != nil }
    }

    /// `resolve` is injectable so this can be tested without a real bundle or
    /// mutating process-wide environment state.
    static func isFullyInstalled(_ entry: ClawdAssetManifest.Entry, resolve: (String) -> Bool) -> Bool {
        if let cached = installedCache[entry.frames] { return cached }
        let result = entry.frames.allSatisfy(resolve)
        installedCache[entry.frames] = result
        return result
    }
}
