import SwiftUI

/// Native settings window (⌘,). The chat UI stays the harness's own web frontend.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560)
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
