import SwiftUI

struct AppSettingsView: View {
    @Bindable var assistantSettings: AssistantSettings
    @Bindable var preferences: AppPreferences
    @FocusState private var focusedField: Field?
    @State private var selectedSection: SettingsSection = .workspace

    private enum Field: Hashable {
        case apiKey
    }

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case workspace
        case editor
        case preview
        case assistant

        var id: String { rawValue }

        var title: String {
            switch self {
            case .workspace:
                return "Workspace"
            case .editor:
                return "Editor"
            case .preview:
                return "Preview"
            case .assistant:
                return "Assistant"
            }
        }

        var subtitle: String {
            switch self {
            case .workspace:
                return "Vault behavior and saving defaults"
            case .editor:
                return "Source editing layout and typography"
            case .preview:
                return "Rendered note presentation"
            case .assistant:
                return "Assistant connection and launcher tuning"
            }
        }

        var description: String {
            switch self {
            case .workspace:
                return "Set how notes open, save, and behave when switching between vaults."
            case .editor:
                return "Tune the writing surface for source editing, density, and long-form readability."
            case .preview:
                return "Adjust how rendered notes read on screen, from typography to page width."
            case .assistant:
                return "Manage the in-app assistant, including its API key, model, reasoning level, and launcher."
            }
        }

        var systemImage: String {
            switch self {
            case .workspace:
                return "square.grid.2x2.fill"
            case .editor:
                return "text.cursor"
            case .preview:
                return "doc.text.image"
            case .assistant:
                return "sparkles.rectangle.stack.fill"
            }
        }

        var accent: Color {
            switch self {
            case .workspace:
                return Color(red: 0.28, green: 0.66, blue: 0.94)
            case .editor:
                return Color(red: 0.95, green: 0.52, blue: 0.26)
            case .preview:
                return Color(red: 0.34, green: 0.78, blue: 0.66)
            case .assistant:
                return Color(red: 0.44, green: 0.72, blue: 0.98)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(width: 1)

            detailPane
        }
        .background(settingsBackground)
        .frame(minWidth: 980, minHeight: 720)
        .onAppear {
            focusedField = nil
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Settings")
                .font(.system(size: 34, weight: .semibold, design: .rounded))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(SettingsSection.allCases) { section in
                    sidebarButton(for: section)
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 280, alignment: .topLeading)
        .background(sidebarBackground)
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                detailHeader
                detailContent
            }
            .padding(30)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(selectedSection.title)
                .font(.system(size: 32, weight: .semibold, design: .rounded))

            Text(selectedSection.description)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                detailBadges
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(selectedSection.accent.opacity(0.12))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.06))
        }
    }

    @ViewBuilder
    private var detailBadges: some View {
        switch selectedSection {
        case .workspace:
            statusPill(preferences.defaultOpenViewMode.title, systemImage: preferences.defaultOpenViewMode.systemImage, tint: selectedSection.accent)
            statusPill(sortOrderTitle, systemImage: "arrow.up.arrow.down", tint: .secondary)
            statusPill(preferences.autosaveDelaySeconds.formatted(.number.precision(.fractionLength(1))) + " sec autosave", systemImage: "clock", tint: .secondary)
        case .editor:
            statusPill(preferences.editorFontChoice.title, systemImage: "textformat", tint: selectedSection.accent)
            statusPill("\(Int(preferences.editorFontSize)) pt", systemImage: "ruler", tint: .secondary)
            statusPill("\(Int(preferences.editorReadableWidth)) px", systemImage: "arrow.left.and.right", tint: .secondary)
        case .preview:
            statusPill(preferences.previewFontChoice.title, systemImage: "text.justify", tint: selectedSection.accent)
            statusPill(preferences.previewCodeFontChoice.title, systemImage: "curlybraces", tint: .secondary)
            statusPill("\(Int(preferences.previewPageWidth)) px page", systemImage: "rectangle", tint: .secondary)
        case .assistant:
            let currentModel = AssistantSettings.model(for: assistantSettings.selectedModel)
            if assistantSettings.isConfigured {
                if currentModel?.requiresAPIKey == false {
                    statusPill("Using Claude subscription", systemImage: "person.crop.circle.badge.checkmark", tint: .green)
                } else {
                    statusPill("Key loaded", systemImage: "checkmark.circle.fill", tint: .green)
                }
            } else {
                statusPill("Assistant disabled", systemImage: "exclamationmark.circle", tint: .orange)
            }

            if let currentModel {
                statusPill(currentModel.displayName, systemImage: "cpu", tint: selectedSection.accent)

                if !currentModel.supportedReasoningEfforts.isEmpty {
                    let reasoningLabel = assistantSettings.selectedReasoningEffort == .modelDefault
                        ? "Reasoning default"
                        : "Reasoning " + assistantSettings.selectedReasoningEffort.displayName
                    statusPill(reasoningLabel, systemImage: "brain", tint: .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .workspace:
            generalSection
        case .editor:
            editorSection
        case .preview:
            previewSection
        case .assistant:
            connectionSection
            modelSection
            launcherSection
            assistantBehaviorSection
        }
    }

    private var generalSection: some View {
        settingsCard(
            title: "Workspace Defaults",
            description: "Set how notes open, how often drafts save, and how the sidebar behaves across vaults."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Default open mode", selection: $preferences.defaultOpenViewMode) {
                    ForEach(OpenViewMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300, alignment: .leading)

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
        Group {
            settingsCard(
                title: "Writing Surface",
                description: "Control the source editor’s typography, line density, and readable column width."
            ) {
                VStack(alignment: .leading, spacing: 18) {
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

            settingsCard(
                title: "Why These Matter",
                description: "A quick reference for how each control affects writing flow."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Readable width keeps long notes from stretching too far across the window.", systemImage: "arrow.left.and.right.square")
                    Label("Line spacing changes how dense the editor feels during heavy writing sessions.", systemImage: "line.3.horizontal")
                    Label("Monospaced fonts keep markdown syntax alignment predictable.", systemImage: "textformat.alt")
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var previewSection: some View {
        Group {
            settingsCard(
                title: "Rendered Note Style",
                description: "Adjust rendered note typography and page width for both native and HTML preview modes."
            ) {
                VStack(alignment: .leading, spacing: 18) {
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

            settingsCard(
                title: "Preview Balance",
                description: "Use narrower widths for reading comfort and wider layouts for tables, code, and diagrams."
            ) {
                HStack(spacing: 14) {
                    previewCallout(title: "Reading", message: "Narrower widths and serif fonts feel calmer for long notes.", tint: selectedSection.accent)
                    previewCallout(title: "Reference", message: "Wider pages leave more room for tables, Mermaid, and code blocks.", tint: .secondary)
                }
            }
        }
    }

    private var connectionSection: some View {
        let currentModel = AssistantSettings.model(for: assistantSettings.selectedModel)
        let usesSubscription = currentModel?.requiresAPIKey == false

        return settingsCard(
            title: "Assistant Connection",
            description: usesSubscription
                ? "Claude (Subscription) uses the local Claude Code CLI — no API key needed."
                : "Store your OpenAI API key in this app on this Mac."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    if usesSubscription {
                        statusPill("Using Claude subscription", systemImage: "person.crop.circle.badge.checkmark", tint: .green)
                    } else if assistantSettings.isConfigured {
                        statusPill("Key saved in app", systemImage: "checkmark.circle.fill", tint: .green)
                    } else {
                        statusPill("Assistant disabled", systemImage: "exclamationmark.circle", tint: .orange)
                    }
                }

                if usesSubscription {
                    Text("The assistant will run the `claude` command-line tool under your Claude subscription. Install Claude Code if you haven't already.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Link("Install Claude Code", destination: URL(string: "https://claude.com/claude-code")!)
                        .font(.caption)
                } else {
                    SecureField("API key", text: $assistantSettings.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .apiKey)

                    HStack(spacing: 12) {
                        Link("Create or manage API keys", destination: AssistantSettings.authURL)

                        Text(assistantSettings.isConfigured ? "Saved in the app’s local settings." : "The assistant stays disabled until a key is entered.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var modelSection: some View {
        settingsCard(
            title: "Assistant Model",
            description: "Pick which model answers note questions — your Claude subscription or an OpenAI API model."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Assistant model", selection: $assistantSettings.selectedModel) {
                    ForEach(AssistantSettings.supportedModels, id: \.id) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 320, alignment: .leading)

                if let currentModel = AssistantSettings.model(for: assistantSettings.selectedModel),
                   !currentModel.supportedReasoningEfforts.isEmpty {
                    Picker("Reasoning level", selection: $assistantSettings.selectedReasoningEffort) {
                        Text(AssistantReasoningEffortOption.modelDefault.displayName)
                            .tag(AssistantReasoningEffortOption.modelDefault)

                        ForEach(currentModel.supportedReasoningEfforts) { effort in
                            Text(effort.displayName)
                                .tag(AssistantReasoningEffortOption(rawValue: effort.rawValue) ?? .modelDefault)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320, alignment: .leading)

                    Text("Only reasoning-capable models expose this control. Model default defers to the selected model’s own reasoning preset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("The assistant sends the current note contents with each question, using the selected OpenAI model.")
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
                            .fill(Color.black.opacity(0.18))
                            .frame(width: 160, height: 160)
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
                Label("API keys are stored in the app’s local settings, not in the document files.", systemImage: "key")
            }
            .foregroundStyle(.secondary)
        }
    }

    private var sortOrderTitle: String {
        switch preferences.defaultSortOrder {
        case .byDate:
            return "Date Modified"
        case .byName:
            return "Name"
        }
    }

    private func sidebarButton(for section: SettingsSection) -> some View {
        let isSelected = selectedSection == section

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                selectedSection = section
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(section.accent.opacity(isSelected ? 0.22 : 0.12))
                        .frame(width: 38, height: 38)

                    Image(systemName: section.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : section.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(section.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(section.accent.opacity(0.22))
                            : AnyShapeStyle(Color.white.opacity(0.03))
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? .white.opacity(0.10) : .white.opacity(0.04))
            }
        }
        .buttonStyle(.plain)
    }

    private func previewCallout(
        title: String,
        message: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.16))
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
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.045))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.06))
        }
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }

    private var sidebarBackground: some View {
        Color.black.opacity(0.08)
    }

    private var settingsBackground: some View {
        Color(nsColor: .windowBackgroundColor)
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
