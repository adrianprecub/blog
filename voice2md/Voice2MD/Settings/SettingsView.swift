import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            AISettingsView()
                .tabItem { Label("AI", systemImage: "brain") }
            TranscriptionSettingsView()
                .tabItem { Label("Transcription", systemImage: "waveform") }
        }
        .frame(width: 540, height: 380)
    }
}
