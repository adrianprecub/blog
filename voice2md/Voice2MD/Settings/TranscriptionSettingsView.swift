import SwiftUI
import AppKit

struct TranscriptionSettingsView: View {
    @Environment(AppConfig.self) private var config
    @State private var manager = WhisperModelManager()
    @State private var ffmpegOK = false
    @State private var whisperOK = false

    var body: some View {
        @Bindable var config = config
        Form {
            Section("Whisper Model") {
                Picker("Model", selection: $config.whisperModel) {
                    ForEach(WhisperModelManager.allModels) { model in
                        Text("\(model.displayName) — \(model.sizeMB) MB — \(model.useCase)")
                            .tag(model.id)
                    }
                }
                .pickerStyle(.menu)

                if let opt = WhisperModelManager.option(forId: config.whisperModel) {
                    downloadRow(opt: opt)
                }
            }
            Section("Tooling") {
                toolRow(name: "ffmpeg", ok: ffmpegOK)
                toolRow(name: "whisper-cli", ok: whisperOK)
                if !ffmpegOK || !whisperOK {
                    HStack {
                        Text("brew install whisper-cpp ffmpeg")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                "brew install whisper-cpp ffmpeg",
                                forType: .string
                            )
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { refreshTools() }
    }

    @ViewBuilder
    private func downloadRow(opt: WhisperModelManager.ModelOption) -> some View {
        let present = manager.isPresent(id: opt.id)
        let state = manager.states[opt.id] ?? .notStarted
        HStack {
            if present {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Re-download") {
                    Task { await manager.download(opt) }
                }
            } else {
                switch state {
                case .notStarted, .failed:
                    Button("Download \(opt.displayName) (\(opt.sizeMB) MB)") {
                        Task { await manager.download(opt) }
                    }
                    Spacer()
                    if case .failed(let msg) = state {
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                case .downloading(let p):
                    ProgressView(value: p)
                    Text("\(Int(p * 100))%")
                        .font(.footnote)
                        .monospacedDigit()
                case .finished:
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
    }

    @ViewBuilder
    private func toolRow(name: String, ok: Bool) -> some View {
        HStack {
            Text(name).font(.system(.body, design: .monospaced))
            Spacer()
            if ok {
                Label("Found", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Missing", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func refreshTools() {
        ffmpegOK = Transcriber.isToolPresent("ffmpeg")
        whisperOK = Transcriber.isToolPresent("whisper-cli")
    }
}
