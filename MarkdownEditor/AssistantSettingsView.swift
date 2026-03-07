import SwiftUI

struct AssistantSettingsView: View {
    @Bindable var settings: AssistantSettings
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case apiKey
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                connectionSection
                modelSection
                launcherSection
                contextSection
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, minHeight: 620)
        .onAppear {
            focusedField = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Assistant Settings")
                .font(.system(size: 30, weight: .semibold))

            Text("Configure the in-app note assistant, choose the OpenCode model, and control how the launcher looks in the editor.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectionSection: some View {
        settingsCard(
            title: "Connection",
            description: "Store the OpenCode API key in your macOS Keychain."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Button("Load saved key from Keychain") {
                    settings.loadAPIKeyIfNeeded()
                }
                .buttonStyle(.bordered)

                SecureField("API key", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .apiKey)

                HStack(spacing: 12) {
                    Link("Create or manage API keys", destination: AssistantSettings.authURL)

                    if settings.isConfigured {
                        Label("Saved in Keychain", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("The assistant stays disabled until a key is loaded or entered.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
    }

    private var modelSection: some View {
        settingsCard(
            title: "Model",
            description: "Choose which OpenCode model the assistant should use for note questions."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Assistant model", selection: $settings.selectedModel) {
                    ForEach(AssistantSettings.supportedModels, id: \.id) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 280, alignment: .leading)

                Text("The assistant sends the current note contents with each question, using the selected OpenCode model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var launcherSection: some View {
        settingsCard(
            title: "Launcher",
            description: "Adjust the floating chat button directly from settings."
        ) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Preview")
                        .font(.headline)

                    ZStack {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.black.opacity(0.18))
                            .frame(width: 148, height: 148)

                        ZStack(alignment: .bottomTrailing) {
                            AssistantLauncherSurface(settings: settings)
                                .frame(width: settings.launcherSize, height: settings.launcherSize)

                            if !settings.isConfigured && settings.showsLauncherStatusBadge {
                                Circle()
                                    .fill(.black.opacity(0.8))
                                    .frame(width: 14, height: 14)
                                    .overlay {
                                        Circle()
                                            .fill(.gray.opacity(0.7))
                                            .padding(3)
                                    }
                                    .offset(x: -6, y: -5)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    Picker("Icon", selection: $settings.launcherSymbol) {
                        ForEach(AssistantSettings.supportedLauncherSymbols, id: \.id) { symbol in
                            Text(symbol.displayName).tag(symbol.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)

                    Toggle("Show status badge when API key is missing", isOn: $settings.showsLauncherStatusBadge)

                    sliderRow(
                        title: "Button size",
                        value: $settings.launcherSize,
                        range: 48...72,
                        format: .number.precision(.fractionLength(0))
                    )

                    sliderRow(
                        title: "Corner radius",
                        value: $settings.launcherCornerRadius,
                        range: 12...24,
                        format: .number.precision(.fractionLength(0))
                    )

                    sliderRow(
                        title: "Background tone",
                        value: $settings.launcherBackgroundLevel,
                        range: 0.05...0.22,
                        format: .number.precision(.fractionLength(2))
                    )

                    sliderRow(
                        title: "Icon tone",
                        value: $settings.launcherForegroundLevel,
                        range: 0.14...0.34,
                        format: .number.precision(.fractionLength(2))
                    )

                    sliderRow(
                        title: "Border tone",
                        value: $settings.launcherBorderLevel,
                        range: 0.14...0.30,
                        format: .number.precision(.fractionLength(2))
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var contextSection: some View {
        settingsCard(
            title: "Behavior",
            description: "Control how markdown behaves while you work in the editor."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Render image embeds inline while editing", isOn: $settings.showsInlineImagePreviewsWhileEditing)

                Divider()

                Label("Inline image previews hide the markdown image syntax until you place the cursor on that line.", systemImage: "photo")
                Label("The current note is sent as context with each assistant question.", systemImage: "doc.text")
                Label("Messages reset automatically when you switch to another note.", systemImage: "arrow.triangle.2.circlepath")
                Label("API keys are stored in Keychain, not in the document files.", systemImage: "key")
            }
            .foregroundStyle(.secondary)
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: FloatingPointFormatStyle<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.formatted(format))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: value, in: range)
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))

                Text(description)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.06))
        }
    }
}
