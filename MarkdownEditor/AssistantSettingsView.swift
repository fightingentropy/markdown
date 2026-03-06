import SwiftUI

struct AssistantSettingsView: View {
    @Bindable var settings: AssistantSettings

    var body: some View {
        Form {
            Section("OpenCode") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste an OpenCode API key to enable the in-app note assistant.")
                        .foregroundStyle(.secondary)

                    SecureField("API key", text: $settings.apiKey)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 12) {
                        Link("Create or manage API keys", destination: AssistantSettings.authURL)

                        if settings.isConfigured {
                            Label("Saved in your macOS Keychain", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text("The assistant stays disabled until a key is set.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }

            Section("Model") {
                Picker("Assistant model", selection: $settings.selectedModel) {
                    ForEach(AssistantSettings.supportedModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)

                Text("The assistant sends the current note contents with each question.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(20)
    }
}
