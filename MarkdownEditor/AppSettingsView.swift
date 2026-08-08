import SwiftUI

struct AppSettingsView: View {
    @Bindable var preferences: AppPreferences
    @Bindable var workflowConfiguration: NoteWorkflowConfigurationStore
    @State private var selectedSection: SettingsSection = .workspace

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case workspace
        case editor
        case preview
        case workflows

        var id: String { rawValue }

        var title: String {
            switch self {
            case .workspace:
                return "Workspace"
            case .editor:
                return "Editor"
            case .preview:
                return "Preview"
            case .workflows:
                return "Workflows"
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
            case .workflows:
                return "Daily Notes, templates, and capture"
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
            case .workflows:
                return "Choose where Daily Notes and reusable note templates live inside each vault."
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
            case .workflows:
                return "calendar.badge.plus"
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
            case .workflows:
                return Color(red: 0.72, green: 0.54, blue: 0.96)
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
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Settings")
                .font(.largeTitle.weight(.semibold))
                .fontDesign(.rounded)

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
                .font(.largeTitle.weight(.semibold))
                .fontDesign(.rounded)

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
        case .workflows:
            statusPill(workflowConfiguration.dailyNotes.folderPath, systemImage: "calendar", tint: selectedSection.accent)
            statusPill(workflowConfiguration.templates.folderPath, systemImage: "doc.on.doc", tint: .secondary)
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
        case .workflows:
            workflowsSection
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
                        ForEach(EditorFontChoice.allCases) { font in
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
                    Label("System Sans creates a calmer reading surface; monospaced choices remain available for source-heavy notes.", systemImage: "textformat.alt")
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

    private var workflowsSection: some View {
        Group {
            settingsCard(
                title: "Daily Notes",
                description: "Open or create today's note from the toolbar without ever overwriting an existing file."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Daily Notes folder", text: dailyNotesFolderBinding)
                        .textFieldStyle(.roundedBorder)
                    TextField("Date format", text: dailyNotesDateFormatBinding)
                        .textFieldStyle(.roundedBorder)
                    TextField("Daily template path (optional)", text: dailyTemplateBinding)
                        .textFieldStyle(.roundedBorder)
                    Text("Examples: `YYYY-MM-DD` or `YYYY/MM/DD`. Template paths are relative to the Templates folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            settingsCard(
                title: "Templates",
                description: "Markdown files in this folder appear in the New from Template menu."
            ) {
                TextField("Templates folder", text: templatesFolderBinding)
                    .textFieldStyle(.roundedBorder)
            }
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

    private var dailyNotesFolderBinding: Binding<String> {
        Binding(
            get: { workflowConfiguration.dailyNotes.folderPath },
            set: { value in
                var configuration = workflowConfiguration.dailyNotes
                configuration.folderPath = value
                workflowConfiguration.dailyNotes = configuration
            }
        )
    }

    private var dailyNotesDateFormatBinding: Binding<String> {
        Binding(
            get: { workflowConfiguration.dailyNotes.dateFormat },
            set: { value in
                var configuration = workflowConfiguration.dailyNotes
                configuration.dateFormat = value
                workflowConfiguration.dailyNotes = configuration
            }
        )
    }

    private var dailyTemplateBinding: Binding<String> {
        Binding(
            get: { workflowConfiguration.dailyNotes.templateRelativePath ?? "" },
            set: { value in
                var configuration = workflowConfiguration.dailyNotes
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                configuration.templateRelativePath = trimmed.isEmpty ? nil : trimmed
                workflowConfiguration.dailyNotes = configuration
            }
        )
    }

    private var templatesFolderBinding: Binding<String> {
        Binding(
            get: { workflowConfiguration.templates.folderPath },
            set: { value in
                var configuration = workflowConfiguration.templates
                configuration.folderPath = value
                workflowConfiguration.templates = configuration
            }
        )
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
                        .font(.headline.weight(.semibold))
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
