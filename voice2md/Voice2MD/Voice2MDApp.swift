import SwiftUI

@main
struct Voice2MDApp: App {
    @State private var config: AppConfig
    @State private var status: StatusModel
    @State private var coordinator: AppCoordinator

    init() {
        let cfg = AppConfig()
        let stat = StatusModel()
        let coord = AppCoordinator(config: cfg, status: stat)
        _config = State(initialValue: cfg)
        _status = State(initialValue: stat)
        _coordinator = State(initialValue: coord)
        Task { @MainActor in coord.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(config)
                .environment(status)
                .environment(coordinator)
        } label: {
            Image(systemName: status.iconName(paused: config.paused))
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(config)
                .environment(status)
                .environment(coordinator)
        }
    }
}
