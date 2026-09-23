import SwiftUI

struct IntegrationSettingsView: View {
    @State private var jevEnabled = OptionalIntegration.jev.isEnabled
    @State private var omniEnabled = OptionalIntegration.omniRoute.isEnabled
    @State private var jevHasKey = OptionalIntegration.jev.hasStoredKey
    @State private var omniHasKey = OptionalIntegration.omniRoute.hasStoredKey
    @State private var jevInput = ""
    @State private var omniInput = ""
    @State private var notice = ""

    var body: some View {
        Form {
            Section("Jev · TypeSafe") {
                Text("Optional semantic decisions. A configured Jev adapter may send up to 2,048 characters of your task to TypeSafe to choose a route. This switch only forwards your key; configure the adapter separately.")
                    .font(.caption).foregroundStyle(.secondary)
                integrationRow(.jev, enabled: $jevEnabled, hasKey: $jevHasKey, input: $jevInput)
            }
            Section("OmniRoute") {
                Text("Optional model gateway. Configure an OmniRoute provider in the DSH model settings with apiKeyEnv: OMNI_ROUTER_API_KEY. This switch supplies your key to that provider.")
                    .font(.caption).foregroundStyle(.secondary)
                integrationRow(.omniRoute, enabled: $omniEnabled, hasKey: $omniHasKey, input: $omniInput)
            }
            Section("Knowledge and extensions") {
                Text("RAG, rerank, brain, memory, summaries, graph, skills, and MCPs depend on installed DSH plugins or external services. Open the DSH settings to configure and inspect each actual adapter.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
            Text("Changes to integration keys take effect after Restart Harness. Keys stay in this Mac's Keychain and are never bundled into DSH.app.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 550)
    }

    @ViewBuilder
    private func integrationRow(_ integration: OptionalIntegration,
                                enabled: Binding<Bool>, hasKey: Binding<Bool>,
                                input: Binding<String>) -> some View {
        Toggle("Forward my key to DSH", isOn: enabled)
            .disabled(!hasKey.wrappedValue)
            .onChange(of: enabled.wrappedValue) { _, value in integration.setEnabled(value) }
        HStack {
            SecureField("Your API key", text: input)
                .textContentType(.password)
            Button("Save key") {
                do {
                    try integration.saveKey(input.wrappedValue)
                    input.wrappedValue = ""
                    hasKey.wrappedValue = true
                    notice = "Key saved in macOS Keychain."
                } catch { notice = error.localizedDescription }
            }
            .disabled(input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Remove") {
                do {
                    try integration.removeKey()
                    input.wrappedValue = ""
                    enabled.wrappedValue = false
                    hasKey.wrappedValue = false
                    notice = "Key removed."
                } catch { notice = error.localizedDescription }
            }
            .disabled(!hasKey.wrappedValue)
        }
        Text(hasKey.wrappedValue ? "Key saved on this Mac" : "No key saved · off by default")
            .font(.caption).foregroundStyle(.secondary)
    }
}
