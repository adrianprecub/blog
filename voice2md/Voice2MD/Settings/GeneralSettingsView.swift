import SwiftUI
import AppKit
import ServiceManagement

struct GeneralSettingsView: View {
    @Environment(AppConfig.self) private var config
    @Environment(AppCoordinator.self) private var coordinator
    @State private var loginStatus: SMAppService.Status = SMAppService.mainApp.status

    var body: some View {
        @Bindable var config = config
        Form {
            Section("Folders") {
                folderRow(
                    title: "Input folder",
                    resolved: config.resolveInputFolderURL()
                ) {
                    if let url = Self.pickFolder() {
                        config.inputFolderBookmark = AppConfig.makeBookmark(for: url)
                        coordinator.restartWatcher()
                    }
                }
                folderRow(
                    title: "Output folder",
                    resolved: config.resolveOutputFolderURL()
                ) {
                    if let url = Self.pickFolder() {
                        config.outputFolderBookmark = AppConfig.makeBookmark(for: url)
                    }
                }
            }
            Section("Startup") {
                Toggle("Launch at Login", isOn: $config.launchAtLogin)
                    .onChange(of: config.launchAtLogin) { _, newValue in
                        applyLaunchAtLogin(newValue)
                    }
                Text(loginStatusDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    @ViewBuilder
    private func folderRow(title: String, resolved: URL?, choose: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(resolved?.path ?? "Not set")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Choose…", action: choose)
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginStatus = SMAppService.mainApp.status
            AppLog.app.info("launch-at-login → \(enabled, privacy: .public), status=\(self.loginStatus.rawValue, privacy: .public)")
        } catch {
            loginStatus = SMAppService.mainApp.status
            AppLog.app.error("launch-at-login error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var loginStatusDescription: String {
        switch loginStatus {
        case .enabled:
            return "Registered — will launch at login."
        case .notRegistered:
            return "Not registered."
        case .requiresApproval:
            return "Approval needed — open System Settings → General → Login Items and enable Voice2MD."
        case .notFound:
            return "Service not found — for production, install the .app to /Applications."
        @unknown default:
            return "Unknown status."
        }
    }

    private static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose folder"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
