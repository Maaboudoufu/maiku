import AppKit
import AVFoundation
import MaikuKit
import SwiftUI

/// Plan §10.7's six sections in one scrolling column. Every field commits on
/// change (`onSubmit`/`onChange`), matching the inline-edit pattern already
/// used for a recording's title and notes — there is no separate Save button
/// to forget to press.
struct SettingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.theme) private var theme

    @State private var settings = AppSettings()
    @State private var baseURLText = ""
    @State private var apiToken = ""
    @State private var isLoaded = false

    @State private var connectionModels: [LMStudioModel] = []
    @State private var connectionError: MaikuError?
    @State private var isTestingConnection = false

    @State private var recommendedModels: (default: String, supported: [String]) = ("", [])
    @State private var installedModels: Set<String> = []
    @State private var modelInProgress: String?
    @State private var modelDownloadProgress: Double = 0
    @State private var modelError: MaikuError?

    @State private var dataDirectorySize: String?
    @State private var includeTitlesInDiagnostics = false
    @State private var diagnosticsMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space.lg) {
                Text("Settings")
                    .font(theme.font.display)
                    .foregroundStyle(theme.color.textPrimary)
                audioSection
                transcriptionSection
                lmStudioSection
                storageSection
                appearanceSection
                privacySection
            }
            .padding(theme.space.lg)
            .frame(maxWidth: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color.surface)
        .task { await load() }
    }

    // MARK: - Audio

    private var audioSection: some View {
        PixelPanel("Audio") {
            LabeledContent("Input device") {
                Text(AVCaptureDeviceName.currentDefaultInput ?? "No microphone detected")
                    .foregroundStyle(theme.color.textSecondary)
            }
            .font(theme.font.body)
        }
    }

    // MARK: - Transcription

    private var transcriptionSection: some View {
        PixelPanel("Transcription") {
            VStack(alignment: .leading, spacing: theme.space.md) {
                LabeledContent("Language") {
                    Text("English")
                        .foregroundStyle(theme.color.textSecondary)
                }
                .font(theme.font.body)

                Toggle("Live diarization", isOn: $settings.liveDiarizationEnabled)
                    .onChange(of: settings.liveDiarizationEnabled) { _, _ in Task { await persistSettings() } }

                Divider().overlay(theme.color.borderSubtle)

                Text("Whisper models")
                    .font(theme.font.subheading)
                    .foregroundStyle(theme.color.textPrimary)

                if let modelError {
                    Text(modelError.message)
                        .font(theme.font.caption)
                        .foregroundStyle(theme.color.warning)
                }

                ForEach(recommendedModels.supported, id: \.self) { model in
                    speechModelRow(model)
                }
            }
        }
    }

    private func speechModelRow(_ model: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model)
                    .font(theme.font.bodyEmphasized)
                    .foregroundStyle(theme.color.textPrimary)
                if model == recommendedModels.default {
                    Text("Recommended for this Mac")
                        .font(theme.font.caption)
                        .foregroundStyle(theme.color.textSecondary)
                }
            }
            Spacer()
            if settings.speechModelName == model {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.color.success)
            }
            if modelInProgress == model {
                ProgressView(value: modelDownloadProgress).frame(width: 60)
            } else if installedModels.contains(model) {
                Button("Use") { selectSpeechModel(model) }
                    .buttonStyle(.pixel(.secondary))
                    .disabled(settings.speechModelName == model)
                Button("Delete") { deleteSpeechModel(model) }
                    .buttonStyle(.pixel(.destructive))
            } else {
                Button("Download") { downloadSpeechModel(model) }
                    .buttonStyle(.pixel(.secondary))
            }
        }
        .font(theme.font.body)
    }

    // MARK: - LM Studio

    private var lmStudioSection: some View {
        PixelPanel("LM Studio") {
            VStack(alignment: .leading, spacing: theme.space.md) {
                TextField("Base URL", text: $baseURLText)
                    .textFieldStyle(.plain)
                    .font(theme.font.body)
                    .onSubmit { applyBaseURL() }

                if !settings.lmStudioConfiguration.isLoopback {
                    Text("This endpoint is not on this Mac — transcript text will leave the machine.")
                        .font(theme.font.caption)
                        .foregroundStyle(theme.color.warning)
                }

                SecureField("API token (optional)", text: $apiToken)
                    .textFieldStyle(.plain)
                    .font(theme.font.body)
                    .onSubmit { Task { await persistToken() } }

                Stepper(
                    "Timeout: \(Int(settings.lmStudioTimeout))s",
                    value: $settings.lmStudioTimeout, in: 15...600, step: 15
                )
                .onChange(of: settings.lmStudioTimeout) { _, _ in Task { await persistSettings() } }

                if !connectionModels.isEmpty {
                    Picker("Model", selection: $settings.lmStudioModelID) {
                        Text("First available").tag(String?.none)
                        ForEach(connectionModels) { model in
                            Text(model.id).tag(String?.some(model.id))
                        }
                    }
                    .onChange(of: settings.lmStudioModelID) { _, _ in Task { await persistSettings() } }
                }

                HStack {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if isTestingConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .buttonStyle(.pixel(.secondary))
                    .disabled(isTestingConnection)

                    if !connectionModels.isEmpty {
                        Text("Connected — \(connectionModels.count) model(s)")
                            .font(theme.font.caption)
                            .foregroundStyle(theme.color.success)
                    }
                }

                if let connectionError {
                    Text(connectionError.message)
                        .font(theme.font.caption)
                        .foregroundStyle(theme.color.warning)
                }
            }
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        PixelPanel("Storage") {
            VStack(alignment: .leading, spacing: theme.space.md) {
                LabeledContent("Data directory") {
                    Text(AppPaths.baseDirectory.path)
                        .font(theme.font.caption)
                        .foregroundStyle(theme.color.textSecondary)
                }
                .font(theme.font.body)

                if let dataDirectorySize {
                    LabeledContent("Size on disk") {
                        Text(dataDirectorySize).foregroundStyle(theme.color.textSecondary)
                    }
                    .font(theme.font.body)
                }

                Picker("Keep audio for", selection: $settings.audioRetentionDays) {
                    Text("Forever").tag(Int?.none)
                    Text("30 days").tag(Int?.some(30))
                    Text("90 days").tag(Int?.some(90))
                    Text("365 days").tag(Int?.some(365))
                }
                .onChange(of: settings.audioRetentionDays) { _, _ in Task { await persistSettings() } }
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        PixelPanel("Appearance") {
            VStack(alignment: .leading, spacing: theme.space.md) {
                Picker("Reduced motion", selection: $settings.reducedMotionOverride) {
                    Text("Follow System").tag(Bool?.none)
                    Text("On").tag(Bool?.some(true))
                    Text("Off").tag(Bool?.some(false))
                }
                .onChange(of: settings.reducedMotionOverride) { _, _ in Task { await persistSettings() } }

                Toggle("Sound effects", isOn: $settings.soundEffectsEnabled)
                    .onChange(of: settings.soundEffectsEnabled) { _, _ in Task { await persistSettings() } }

                Toggle("CRT effects", isOn: $settings.crtEffectsEnabled)
                    .onChange(of: settings.crtEffectsEnabled) { _, _ in Task { await persistSettings() } }
            }
        }
    }

    // MARK: - Privacy and diagnostics

    private var privacySection: some View {
        PixelPanel("Privacy and diagnostics") {
            VStack(alignment: .leading, spacing: theme.space.md) {
                Text(
                    "Only transcript text sent to the LM Studio endpoint above ever leaves this Mac. Recording, transcription, and diarization all run locally."
                )
                .font(theme.font.caption)
                .foregroundStyle(theme.color.textSecondary)

                Toggle("Include recording titles in diagnostics export", isOn: $includeTitlesInDiagnostics)

                Button("Export Diagnostics…") { Task { await exportDiagnostics() } }
                    .buttonStyle(.pixel(.secondary))

                if let diagnosticsMessage {
                    Text(diagnosticsMessage)
                        .font(theme.font.caption)
                        .foregroundStyle(theme.color.textSecondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        guard let appEnvironment, !isLoaded else { return }
        isLoaded = true
        settings = appEnvironment.currentSettings
        baseURLText = settings.lmStudioBaseURL.absoluteString
        apiToken = (try? appEnvironment.tokenStore.token()) ?? ""
        recommendedModels = SpeechModelLibrary.recommendedModels()
        installedModels = SpeechModelLibrary.installedModels()
        await testConnection()
        await computeDataDirectorySize()
    }

    private func persistSettings() async {
        guard let appEnvironment else { return }
        try? await appEnvironment.settingsStore.save(settings)
        appEnvironment.currentSettings = settings
    }

    private func persistToken() async {
        guard let appEnvironment else { return }
        try? appEnvironment.tokenStore.save(apiToken)
    }

    private func applyBaseURL() {
        guard let url = LMStudioConfiguration.url(from: baseURLText) else {
            baseURLText = settings.lmStudioBaseURL.absoluteString
            return
        }
        settings.lmStudioBaseURL = url
        baseURLText = url.absoluteString
        Task {
            await persistSettings()
            await testConnection()
        }
    }

    private func testConnection() async {
        isTestingConnection = true
        connectionError = nil
        defer { isTestingConnection = false }
        var configuration = settings.lmStudioConfiguration
        configuration.apiToken = apiToken.isEmpty ? nil : apiToken
        let client = LMStudioClient(configuration: configuration)
        do {
            let status = try await client.testConnection()
            connectionModels = status.models
        } catch {
            connectionModels = []
            connectionError = (error as? MaikuError) ?? .lmStudioUnreachable(baseURL: settings.lmStudioBaseURL.absoluteString)
        }
    }

    private func selectSpeechModel(_ model: String) {
        settings.speechModelName = model
        Task { await persistSettings() }
    }

    private func downloadSpeechModel(_ model: String) {
        modelInProgress = model
        modelDownloadProgress = 0
        modelError = nil
        Task {
            do {
                try await SpeechModelLibrary.download(model) { fraction in
                    Task { @MainActor in modelDownloadProgress = fraction }
                }
                installedModels.insert(model)
            } catch {
                modelError = (error as? MaikuError) ?? .speechModelLoadFailed(name: model, underlying: "\(error)")
            }
            modelInProgress = nil
        }
    }

    private func deleteSpeechModel(_ model: String) {
        do {
            try SpeechModelLibrary.delete(model)
            installedModels.remove(model)
        } catch {
            modelError = .speechModelLoadFailed(name: model, underlying: "\(error)")
        }
    }

    private func computeDataDirectorySize() async {
        let base = AppPaths.baseDirectory
        let size = await Task.detached(priority: .utility) { () -> Int64 in
            guard let enumerator = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.fileSizeKey], options: [])
            else { return 0 }
            var total: Int64 = 0
            while let url = enumerator.nextObject() as? URL {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            return total
        }.value
        dataDirectorySize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func exportDiagnostics() async {
        guard let appEnvironment else { return }
        let recordings = (try? await appEnvironment.repository.fetchAll(includeTrashed: true)) ?? []
        let logContents = await DiagnosticLog.shared.readAll()
        let report = DiagnosticsExporter.export(
            recordings: recordings, logContents: logContents, includeTranscripts: includeTitlesInDiagnostics)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "maiku-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            diagnosticsMessage = "Saved to \(url.lastPathComponent)."
        } catch {
            diagnosticsMessage = "Could not write the file: \(error.localizedDescription)"
        }
    }
}

/// The system default input device's name, shown read-only (plan §10.7 offers
/// "Microphone selection **or** current default device" — explicit routing
/// of `AVAudioEngine` to a non-default input is a capture-layer change well
/// beyond a Settings screen, so this ships the simpler alternative the plan
/// itself allows).
private enum AVCaptureDeviceName {
    static var currentDefaultInput: String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }
}
