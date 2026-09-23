import SwiftUI

/// Native settings window (⌘,). The chat UI stays the harness's own web frontend.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            IntegrationSettingsView()
                .tabItem { Label("Integrations", systemImage: "link") }
        }
        .frame(width: 660, height: 620)
        .preferredColorScheme(.dark)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Preferences.keepAwakeKey) private var keepAwake = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $keepAwake) {
                    Text("Keep the Mac awake while DSH is open")
                    Text("Agents keep running when you step away. The display may still sleep.")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
