import SwiftUI

struct AppSettingsView: View {
    @Bindable var assistantSettings: AssistantSettings
    @Bindable var preferences: AppPreferences
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case apiKey
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                generalSection
                editorSection
                previewSection
                connectionSection
                modelSection
                launcherSection
                assistantBehaviorSection
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .background(settingsBackground)
        .frame(minWidth: 780, minHeight: 720)
        .onAppear {
            focusedField = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.system(size: 32, weight: .semibold, design: .rounded))

            Text("Shape how notes open, read, and save, then tune the in-app assistant without leaving the app.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                statusPill("Editor + Preview", systemImage: "doc.richtext")
                statusPill("Keychain-backed assistant", systemImage: "lock.shield")
            }
        }
    }

    private var generalSection: some View {
        settingsCard(
            title: "General",
            description: "Set how notes open, how often drafts save, and how the sidebar behaves across vaults."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Default open mode", selection: $preferences.defaultOpenViewMode) {
                    ForEach(OpenViewMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280, alignment: .leading)

                Picker("Default sort order", selection: $preferences.defaultSortOrder) {
                    Text("Date Modified").tag(SortOrder.byDate)
                    Text("Name").tag(SortOrder.byName)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 240, alignment: .leading)

                sliderRow(
                    title: "Autosave delay",
                    value: $preferences.autosaveDelaySeconds,
                    range: 0.2...3.0,
                    format: .number.precision(.fractionLength(1)),
                    suffix: " sec"
                )

                Toggle("Restore expanded folders when reopening a vault", isOn: $preferences.restoresExpandedFolders)
                Toggle("Collapse all folders when switching to another vault", isOn: $preferences.collapsesFoldersOnVaultSwitch)
            }
        }
    }

    private var editorSection: some View {
        settingsCard(
            title: "Editor",
            description: "Control the source editor’s typography, line density, and readable column width."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Font family", selection: $preferences.editorFontChoice) {
                    ForEach(MonospacedFontChoice.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260, alignment: .leading)

                sliderRow(
                    title: "Font size",
                    value: $preferences.editorFontSize,
                    range: 12...22,
                    format: .number.precision(.fractionLength(0)),
                    suffix: " pt"
                )

                sliderRow(
                    title: "Line spacing",
                    value: $preferences.editorLineSpacing,
                    range: 0...12,
                    format: .number.precision(.fractionLength(0)),
                    suffix: " pt"
                )

                sliderRow(
                    title: "Readable width",
                    value: $preferences.editorReadableWidth,
                    range: 640...1200,
                    format: .number.precision(.fractionLength(0)),
                    suffix: " px"
                )
            }
        }
    }

    private var previewSection: some View {
        settingsCard(
            title: "Preview",
            description: "Adjust rendered note typography and page width for both native and HTML preview modes."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Body font", selection: $preferences.previewFontChoice) {
                    ForEach(PreviewFontChoice.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 240, alignment: .leading)

                Picker("Code font", selection: $preferences.previewCodeFontChoice) {
                    ForEach(MonospacedFontChoice.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 240, alignment: .leading)

                sliderRow(
                    title: "Body font size",
                    value: $preferences.previewFontSize,
                    range: 13...22,
                    format: .number.precision(.fractionLength(0)),
                    suffix: " pt"
                )

                sliderRow(
                    title: "Page width",
                    value: $preferences.previewPageWidth,
                    range: 680...1280,
                    format: .number.precision(.fractionLength(0)),
                    suffix: " px"
                )
            }
        }
    }

    private var connectionSection: some View {
        settingsCard(
            title: "Assistant Connection",
            description: "Store the OpenCode API key in your macOS Keychain."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Button("Load saved key from Keychain") {
                        assistantSettings.loadAPIKeyIfNeeded()
                    }
                    .buttonStyle(.bordered)

                    if assistantSettings.isConfigured {
                        statusPill("Key loaded", systemImage: "checkmark.circle.fill", tint: .green)
                    } else {
                        statusPill("Assistant disabled", systemImage: "exclamationmark.circle", tint: .orange)
                    }
                }

                SecureField("API key", text: $assistantSettings.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .apiKey)

                HStack(spacing: 12) {
                    Link("Create or manage API keys", destination: AssistantSettings.authURL)

                    Text(assistantSettings.isConfigured ? "Stored in Keychain." : "The assistant stays disabled until a key is loaded or entered.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }

    private var modelSection: some View {
        settingsCard(
            title: "Assistant Model",
            description: "Choose which OpenCode model the assistant should use for note questions."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Assistant model", selection: $assistantSettings.selectedModel) {
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

                if let currentModel = AssistantSettings.model(for: assistantSettings.selectedModel) {
                    statusPill(currentModel.displayName, systemImage: "cpu", tint: .accentColor)
                }
            }
        }
    }

    private var launcherSection: some View {
        settingsCard(
            title: "Assistant Launcher",
            description: "Adjust the floating chat button directly from settings."
        ) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Preview")
                        .font(.headline)

                    ZStack {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.black.opacity(0.26), Color.black.opacity(0.10)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 148, height: 148)
                            .overlay {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(.white.opacity(0.08))
                            }

                        ZStack(alignment: .bottomTrailing) {
                            AssistantLauncherSurface(settings: assistantSettings)
                                .frame(width: assistantSettings.launcherSize, height: assistantSettings.launcherSize)

                            if !assistantSettings.isConfigured && assistantSettings.showsLauncherStatusBadge {
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
                    Picker("Icon", selection: $assistantSettings.launcherSymbol) {
                        ForEach(AssistantSettings.supportedLauncherSymbols, id: \.id) { symbol in
                            Text(symbol.displayName).tag(symbol.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)

                    Toggle("Show status badge when API key is missing", isOn: $assistantSettings.showsLauncherStatusBadge)

                    sliderRow(
                        title: "Button size",
                        value: $assistantSettings.launcherSize,
                        range: 48...72,
                        format: .number.precision(.fractionLength(0)),
                        suffix: " pt"
                    )

                    sliderRow(
                        title: "Corner radius",
                        value: $assistantSettings.launcherCornerRadius,
                        range: 12...24,
                        format: .number.precision(.fractionLength(0)),
                        suffix: " pt"
                    )

                    sliderRow(
                        title: "Background tone",
                        value: $assistantSettings.launcherBackgroundLevel,
                        range: 0.05...0.22,
                        format: .number.precision(.fractionLength(2))
                    )

                    sliderRow(
                        title: "Icon tone",
                        value: $assistantSettings.launcherForegroundLevel,
                        range: 0.14...0.34,
                        format: .number.precision(.fractionLength(2))
                    )

                    sliderRow(
                        title: "Border tone",
                        value: $assistantSettings.launcherBorderLevel,
                        range: 0.14...0.30,
                        format: .number.precision(.fractionLength(2))
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var assistantBehaviorSection: some View {
        settingsCard(
            title: "Assistant Behavior",
            description: "Quick reminders about how the assistant behaves while you work."
        ) {
            VStack(alignment: .leading, spacing: 10) {
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
        format: FloatingPointFormatStyle<Double>,
        suffix: String = ""
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(value.wrappedValue.formatted(format) + suffix)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.05), in: Capsule())
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
                .fill(.white.opacity(0.045))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.06))
        }
        .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
    }

    private var settingsBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color.white.opacity(0.015)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func statusPill(
        _ title: String,
        systemImage: String,
        tint: Color = .secondary
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(0.05), in: Capsule())
    }
}
