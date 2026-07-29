import Foundation
@preconcurrency import WhisperKit

/// Whisper model discovery, download, and deletion for the Settings screen
/// (plan §10.7: "Whisper model selection, download, and deletion"). WhisperKit's
/// own `prepare(model:)` path (`WhisperKitTranscriber`) downloads a model on
/// demand the first time it's used; this type exists so Settings can show
/// what's already on disk and let a user free space, without loading a model
/// just to ask.
public enum SpeechModelLibrary {

    /// Every model recommended for this Mac, and which one WhisperKit would
    /// pick with no explicit choice.
    public static func recommendedModels() -> (default: String, supported: [String]) {
        let support = WhisperKit.recommendedModels()
        return (support.default, support.supported)
    }

    // ponytail: WhisperKit exposes no "is this variant already downloaded"
    // query. Its own `download(variant:)` resolves a plain variant name
    // ("tiny.en") to a repo folder (e.g. "openai_whisper-tiny.en") by
    // substring match against the remote listing; this mirrors that same
    // heuristic against the local cache instead. Longest-name-first avoids
    // "small" wrongly matching a "small.en" folder. Upgrade if a future
    // WhisperKit version exposes a real "is variant cached" API.
    private static var modelsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appending(path: "huggingface/models/argmaxinc/whisperkit-coreml")
    }

    private static var variantsByDescendingLength: [String] {
        ModelVariant.allCases.map(\.description).sorted { $0.count > $1.count }
    }

    /// Plain variant names (`"tiny.en"`, not the repo's `"openai_whisper-tiny.en"`
    /// folder name) that already have a local folder.
    public static func installedModels() -> Set<String> {
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)
        else { return [] }
        let variants = variantsByDescendingLength
        return Set(folders.compactMap { folder in variants.first { folder.contains($0) } })
    }

    public static func download(
        _ modelName: String, progress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        do {
            _ = try await WhisperKit.download(variant: modelName) { progress($0.fractionCompleted) }
        } catch {
            throw MaikuError.speechModelLoadFailed(name: modelName, underlying: error.localizedDescription)
        }
    }

    public static func delete(_ modelName: String) throws {
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)
        else { return }
        let variants = variantsByDescendingLength
        guard let match = folders.first(where: { candidate in variants.first { candidate.contains($0) } == modelName })
        else { return }
        try FileManager.default.removeItem(at: modelsDirectory.appending(path: match))
    }
}
