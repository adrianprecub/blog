import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(AppConfig.self) private var config
    @Environment(StatusModel.self) private var status
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var config = config

        Text(status.statusLine(paused: config.paused))
            .font(.subheadline)

        Divider()

        Toggle("Pause", isOn: $config.paused)
            .keyboardShortcut("p")

        Button("Open Input Folder") {
            if let url = config.resolveInputFolderURL() {
                NSWorkspace.shared.open(url)
            }
        }
        .disabled(config.resolveInputFolderURL() == nil)

        Button("Open Output Folder") {
            if let url = config.resolveOutputFolderURL() {
                NSWorkspace.shared.open(url)
            }
        }
        .disabled(config.resolveOutputFolderURL() == nil)

        Divider()

        Menu("Recent") {
            if status.lastOutputs.isEmpty {
                Text("Nothing yet")
            } else {
                ForEach(status.lastOutputs, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
        .disabled(status.lastOutputs.isEmpty)

        Button("Process all in input folder") {
            Task { await coordinator.processAllInInputFolder() }
        }
        .disabled(config.paused || config.resolveInputFolderURL() == nil)

        Button("Re-process missing files…") {
            Task { await coordinator.reprocessMissing() }
        }
        .disabled(config.paused)

        if case .error = status.state {
            Button("Dismiss error") { status.clearErrorIfAny() }
        }

        Divider()

        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
