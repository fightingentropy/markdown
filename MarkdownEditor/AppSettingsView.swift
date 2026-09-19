import SwiftUI

struct AppSettingsView: View {
    @Bindable var preferences: AppPreferences
    @Bindable var workflowConfiguration: NoteWorkflowConfigurationStore
    @State private var selectedSection: SettingsSection? = .workspace

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case workspace
        case editor
        case preview
        case workflows

        var id: String { rawValue }

        var title: String {
            switch self {
            case .workspace: "Workspace"
            case .editor: "Editor"
            case .preview: "Preview"
            case .workflows: "Workflows"
            }
        }

        var description: String {
            switch self {
            case .workspace: "Choose how notes open and save."
            case .editor: "Set the typography and layout of the source editor."
            case .preview: "Set the appearance of rendered notes."
            case .workflows: "Set up Daily Notes and reusable templates."
            }
        }

        var systemImage: String {
            switch self {
            case .workspace: "square.grid.2x2"
            case .editor: "pencil.line"
            case .preview: "doc.text"
            case .workflows: "calendar"
            }
        }
    }

    private var currentSection: SettingsSection {
        selectedSection ?? .workspace
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detailPane
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, idealWidth: 800, minHeight: 540, idealHeight: 580)
    }

    private var sidebar: some View {
        List(selection: $selectedSection) {
            Section("Settings") {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .padding(.vertical, 5)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollDisabled(true)
        .frame(width: 180)
        .accessibilityLabel("Settings categories")
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(currentSection.title)
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                Text(currentSection.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 704, alignment: .leading)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
            .padding(.bottom, 8)

            Form {
                switch currentSection {
                case .workspace: workspaceSection
                case .editor: editorSection
                case .preview: previewSection
                case .workflows: workflowsSection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .id(currentSection)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var workspaceSection: some View {
        Group {
            Section("Notes") {
                LabeledContent("Open notes in") {
                    Picker("Open notes in", selection: $preferences.defaultOpenViewMode) {
                        ForEach(OpenViewMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                LabeledContent("Sort notes by") {
                    Picker("Sort notes by", selection: $preferences.defaultSortOrder) {
                        Text("Date Modified").tag(SortOrder.byDate)
                        Text("Name").tag(SortOrder.byName)
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }

            Section {
                sliderRow(
                    "Autosave delay",
                    value: $preferences.autosaveDelaySeconds,
                    range: 0.2...3.0,
                    step: 0.1,
                    fractionLength: 1,
                    suffix: " s"
                )
            } header: {
                Text("Saving")
            } footer: {
                Text("Notes save automatically after you stop typing.")
            }

            Section("Folders") {
                Toggle(isOn: $preferences.restoresExpandedFolders) {
                    Text("Restore expanded folders")
                    Text("When reopening a vault")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Restore expanded folders")
                .accessibilityHint("When reopening a vault")

                Toggle(isOn: $preferences.collapsesFoldersOnVaultSwitch) {
                    Text("Collapse folders when switching vaults")
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var editorSection: some View {
        Group {
            Section("Typography") {
                LabeledContent("Font") {
                    Picker("Editor font", selection: $preferences.editorFontChoice) {
                        ForEach(EditorFontChoice.allCases) { font in
                            Text(font.title).tag(font)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                sliderRow(
                    "Font size",
                    value: $preferences.editorFontSize,
                    range: 12...22,
                    suffix: " pt"
                )

                sliderRow(
                    "Line spacing",
                    value: $preferences.editorLineSpacing,
                    range: 0...12,
                    suffix: " pt"
                )
            }

            Section {
                sliderRow(
                    "Readable width",
                    value: $preferences.editorReadableWidth,
                    range: 640...1200,
                    step: 20,
                    suffix: " px"
                )
            } header: {
                Text("Layout")
            } footer: {
                Text("Limits the text column in wide windows.")
            }

            Section("Text preview") {
                Text("# A place for your thoughts\n\nWrite something worth keeping.")
                    .font(Font(preferences.editorFontChoice.nsFont(size: preferences.editorFontSizeCGFloat)))
                    .lineSpacing(preferences.editorLineSpacingCGFloat)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .textSelection(.enabled)
            }
        }
    }

    private var previewSection: some View {
        Group {
            Section("Typography") {
                LabeledContent("Body font") {
                    Picker("Body font", selection: $preferences.previewFontChoice) {
                        ForEach(PreviewFontChoice.allCases) { font in
                            Text(font.title).tag(font)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                LabeledContent("Code font") {
                    Picker("Code font", selection: $preferences.previewCodeFontChoice) {
                        ForEach(MonospacedFontChoice.allCases) { font in
                            Text(font.title).tag(font)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                sliderRow(
                    "Body font size",
                    value: $preferences.previewFontSize,
                    range: 13...22,
                    suffix: " pt"
                )
            }

            Section {
                sliderRow(
                    "Page width",
                    value: $preferences.previewPageWidth,
                    range: 680...1280,
                    step: 20,
                    suffix: " px"
                )
            } header: {
                Text("Layout")
            } footer: {
                Text("Wider pages leave more room for tables, code, and diagrams.")
            }

            Section("Text preview") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A place for your thoughts")
                        .font(preferences.previewFontChoice.swiftUIFont(size: preferences.previewFontSizeCGFloat))
                    Text("A short note, a useful idea, a little clarity.")
                        .font(preferences.previewFontChoice.swiftUIFont(size: preferences.previewFontSizeCGFloat))
                        .foregroundStyle(.secondary)
                    Text("let idea = \"Something worth keeping\"")
                        .font(preferences.previewCodeFontChoice.swiftUIFont(size: preferences.previewCodeFontSizeCGFloat))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .textSelection(.enabled)
            }
        }
    }

    private var workflowsSection: some View {
        Group {
            Section {
                textFieldRow("Folder", accessibilityLabel: "Daily Notes folder", text: dailyNotesFolderBinding, prompt: "Daily Notes")
                textFieldRow("Date format", text: dailyNotesDateFormatBinding, prompt: "YYYY-MM-DD")
                textFieldRow("Template", accessibilityLabel: "Daily Notes template", text: dailyTemplateBinding, prompt: "Optional")
            } header: {
                Text("Daily Notes")
            } footer: {
                Text("Use YYYY-MM-DD for dated notes, or YYYY/MM/DD for nested folders. Template paths are relative to your Templates folder.")
            }

            Section {
                textFieldRow("Folder", accessibilityLabel: "Templates folder", text: templatesFolderBinding, prompt: "Templates")
            } header: {
                Text("Templates")
            } footer: {
                Text("Markdown files here appear in New from Template. Folder paths are relative to each vault.")
            }
        }
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 1,
        fractionLength: Int = 0,
        suffix: String
    ) -> some View {
        let displayValue = value.wrappedValue.formatted(.number.precision(.fractionLength(fractionLength))) + suffix

        return LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: value, in: range, step: step) {
                    Text(title)
                }
                .labelsHidden()
                .accessibilityValue(displayValue)

                Text(displayValue)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .frame(width: 230)
        }
    }

    private func textFieldRow(
        _ title: String,
        accessibilityLabel: String? = nil,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        LabeledContent(title) {
            TextField(accessibilityLabel ?? title, text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .autocorrectionDisabled()
                .frame(width: 230)
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
}
