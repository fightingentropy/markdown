import SwiftUI

struct ContentView: View {
    @Bindable var workspace: Workspace
    @Bindable var assistant: NoteAssistant
    @Bindable var assistantSettings: AssistantSettings
    @Bindable var preferences: AppPreferences
    @State private var controller = EditorController()
    @State private var renameRequest: RenameRequest?
    @State private var viewMode: OpenViewMode
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var expandedFolderURLs: Set<URL> = []
    @State private var isSidebarRootDropTargeted = false
    @State private var restoredVaultKey: String?
    @State private var workspaceSession = WorkspaceSession()
    @State private var isInspectorPresented = false
    @Bindable var workflowConfiguration: NoteWorkflowConfigurationStore
    @State private var recentVaults = RecentVaultStore()
    @State private var selectedTemplate: TemplateDescriptor?
    @State private var workflowError: String?
    @State private var isVaultHealthPresented = false

    init(
        workspace: Workspace,
        assistant: NoteAssistant,
        assistantSettings: AssistantSettings,
        preferences: AppPreferences,
        workflowConfiguration: NoteWorkflowConfigurationStore
    ) {
        self.workspace = workspace
        self.assistant = assistant
        self.assistantSettings = assistantSettings
        self.preferences = preferences
        self.workflowConfiguration = workflowConfiguration
        _viewMode = State(initialValue: preferences.defaultOpenViewMode)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
                .focusedValue(\.editorController, controller)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(workspace.selectedFileName)
        .overlay(alignment: .bottomTrailing) {
            NoteAssistantPanel(
                assistant: assistant,
                settings: assistantSettings,
                currentFileTitle: workspace.selectedFileName,
                hasSelectedFile: workspace.selectedFileURL != nil
            )
            .padding(.trailing, 22)
            .padding(.bottom, 20)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditorSearchToolbarField(
                    query: controller.searchQuery,
                    controller: controller,
                    isEnabled: workspace.selectedFileIsMarkdown,
                    onActivate: showEditorForSearch
                )
                .frame(width: 150)
                .help("Search Current Document")
            }

            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }

            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 2) {
                    Button { workspace.createNewFile() } label: {
                        Image(systemName: "plus")
                    }
                    .help("New File")
                    .accessibilityLabel("New File")

                    Button {
                        openDailyNote()
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .help("Open Today's Daily Note")

                    Menu {
                        if availableTemplates.isEmpty {
                            Text("No templates in \(workflowConfiguration.templates.folderPath)")
                        } else {
                            ForEach(availableTemplates) { template in
                                Button(template.displayName) {
                                    selectedTemplate = template
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "doc.badge.plus")
                    }
                    .menuStyle(.borderlessButton)
                    .help("New from Template")

                    ForEach(OpenViewMode.allCases) { mode in
                        Button {
                            viewMode = mode
                        } label: {
                            Image(systemName: mode.systemImage)
                        }
                        .help(mode.title)
                        .disabled(mode != .bases && !workspace.selectedFileIsMarkdown)
                        .opacity(viewMode == mode ? 1 : 0.5)
                        .accessibilityLabel(mode.title)
                        .accessibilityAddTraits(viewMode == mode ? [.isButton, .isSelected] : .isButton)
                    }

                    Button {
                        workspaceSession.splitPreview.toggle()
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .help(workspaceSession.splitPreview ? "Hide Split Preview" : "Show Split Preview")
                    .disabled(!workspace.selectedFileIsMarkdown || viewMode != .editor)
                    .opacity(workspaceSession.splitPreview ? 1 : 0.5)

                    if let selectedURL = workspace.selectedFileURL {
                        Button {
                            workspaceSession.togglePinned(selectedURL)
                        } label: {
                            Image(systemName: workspaceSession.isPinned(selectedURL) ? "pin.fill" : "pin")
                        }
                        .help(workspaceSession.isPinned(selectedURL) ? "Unpin Note" : "Pin Note")
                    }

                    Button {
                        isInspectorPresented.toggle()
                    } label: {
                        Image(systemName: "sidebar.trailing")
                    }
                    .help(isInspectorPresented ? "Hide Note Inspector" : "Show Note Inspector")
                    .opacity(isInspectorPresented ? 1 : 0.5)

                    Button {
                        isVaultHealthPresented = true
                    } label: {
                        Image(systemName: "checkmark.shield")
                    }
                    .help("Vault Health")
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .inspector(isPresented: $isInspectorPresented) {
            NoteInspectorView(workspace: workspace, controller: controller)
                .inspectorColumnWidth(min: 270, ideal: 320, max: 440)
        }
        .background(WindowToolbarConfigurator())
        .overlay {
            if workspace.isCommandPalettePresented {
                CommandPaletteView(workspace: workspace) {
                    restoreEditorFocusAfterPaletteDismiss()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .onAppear {
            restoreExpandedFoldersIfNeeded()
            restoreWorkspaceSession()
            recordCurrentVault()
            applyPreferredViewMode()
            synchronizeAssistantContext()
        }
        .onDisappear {
            persistExpandedFolders()
        }
        .onChange(of: workspace.vaultURL) { _, _ in
            restoreExpandedFoldersIfNeeded(force: true)
            restoreWorkspaceSession()
            recordCurrentVault()
        }
        .onChange(of: workspace.sidebarNodes) { _, _ in
            restoreExpandedFoldersIfNeeded()
            if !workspace.isLoadingSnapshot,
               workspaceSession.isLoaded(for: workspace.vaultURL) {
                workspaceSession.prune(availableFiles: Set(workspace.files.map(\.url)))
            }
        }
        .onChange(of: workspace.isLoadingSnapshot) { _, _ in
            restoreExpandedFoldersIfNeeded()
            restoreWorkspaceSession()
        }
        .onChange(of: expandedFolderURLs) { _, _ in
            persistExpandedFolders()
        }
        .onChange(of: workspace.text) { _, _ in
            workspace.scheduleAutosave()
            synchronizeAssistantContext()
        }
        .onChange(of: workspace.selectedFileURL) { _, _ in
            if workspaceSession.isLoaded(for: workspace.vaultURL) {
                workspaceSession.noteSelected(workspace.selectedFileURL)
            }
            applyPreferredViewMode()
            synchronizeAssistantContext()
            controller.requestEditorFocus()
        }
        .onChange(of: preferences.restoresExpandedFolders) { _, _ in
            restoreExpandedFoldersIfNeeded(force: true)
        }
        .onChange(of: preferences.collapsesFoldersOnVaultSwitch) { _, _ in
            restoreExpandedFoldersIfNeeded(force: true)
        }
        .onChange(of: preferences.defaultOpenViewMode) { _, _ in
            applyPreferredViewMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .editorFindCommand)) { _ in
            guard workspace.selectedFileIsMarkdown else { return }
            showEditorForSearch()
            controller.activateSearch()
        }
        .sheet(item: $renameRequest) { request in
            RenameItemSheet(target: request) { proposedName in
                try workspace.renameItem(request.url, to: proposedName)
            }
        }
        .sheet(item: $selectedTemplate) { template in
            if let vaultURL = workspace.vaultURL {
                TemplateCreationSheet(
                    vaultURL: vaultURL,
                    template: template,
                    templateConfiguration: workflowConfiguration.templates
                ) { url in
                    workspace.refreshFiles()
                    workspace.selectFile(url)
                }
            }
        }
        .sheet(isPresented: $isVaultHealthPresented) {
            VaultHealthView(workspace: workspace)
        }
        .alert("Note Workflow Failed", isPresented: Binding(
            get: { workflowError != nil },
            set: { if !$0 { workflowError = nil } }
        )) {
            Button("OK", role: .cancel) { workflowError = nil }
        } message: {
            Text(workflowError ?? "")
        }
        .modifier(SaveStatusAlerts(workspace: workspace))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            Group {
                if workspace.sidebarNodes.isEmpty {
                    ContentUnavailableView(
                        "No Notes",
                        systemImage: "folder",
                        description: Text("This folder doesn't contain any markdown files or visible subfolders yet.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        SidebarNodeList(
                            nodes: workspace.sidebarNodes,
                            workspace: workspace,
                            expandedFolderURLs: $expandedFolderURLs,
                            onRenameRequested: { request in
                                renameRequest = request
                            }
                        )

                        BacklinksSection(workspace: workspace)
                    }
                    .listStyle(.sidebar)
                    .contentMargins(.top, 0, for: .scrollContent)
                }
            }
            .background {
                SidebarRootDropArea(
                    workspace: workspace,
                    isTargeted: $isSidebarRootDropTargeted
                )
            }
            .overlay {
                SidebarBackgroundContextMenuHost(
                    onCreateFile: { workspace.createNewFile() },
                    onCreateFolder: { workspace.createNewFolder() },
                    onDeleteSelection: {
                        guard let selectedFileURL = workspace.selectedFileURL else { return }
                        workspace.deleteItem(selectedFileURL)
                    }
                )
            }

            Divider()

            HStack {
                Menu {
                    Button { workspace.sortOrder = .byDate } label: {
                        Label("Date Modified", systemImage: workspace.sortOrder == .byDate ? "checkmark" : "")
                    }
                    Button { workspace.sortOrder = .byName } label: {
                        Label("Name", systemImage: workspace.sortOrder == .byName ? "checkmark" : "")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort Order")
                .accessibilityLabel("Sort Order")

                Button {
                    collapseSidebarFolders()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Collapse All Folders")
                .accessibilityLabel("Collapse All Folders")
                .disabled(expandedFolderURLs.isEmpty)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 180)
        .overlay {
            if isSidebarRootDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                    .padding(6)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if workspace.selectedFileIsImage, let selectedURL = workspace.selectedFileURL {
            ImagePreview(url: selectedURL)
        } else if viewMode == .bases {
            basesView
        } else if workspace.selectedFileURL != nil {
            noteWorkspaceView
        } else {
            ContentUnavailableView(
                "No File Selected",
                systemImage: "doc.text",
                description: Text("Select a file from the sidebar or create a new one.")
            )
        }
    }

    private var previewView: some View {
        MarkdownPreview(
            markdown: workspace.text,
            documentURL: workspace.selectedFileURL,
            vaultURL: workspace.vaultURL,
            assetLookupByFilename: workspace.assetLookupSnapshot,
            preferences: preferences,
            onOpenInternalFile: { url in
                workspace.selectFile(url)
            }
        )
        .id(workspace.selectedFileURL)
    }

    @ViewBuilder
    private var noteWorkspaceView: some View {
        VStack(spacing: 0) {
            NoteTabBar(workspace: workspace, session: workspaceSession)
            Divider()

            if viewMode == .editor && workspaceSession.splitPreview {
                HSplitView {
                    editorView
                        .frame(minWidth: 360)
                    previewView
                        .frame(minWidth: 360)
                }
            } else {
                switch viewMode {
                case .editor:
                    editorView
                case .preview:
                    previewView
                case .graph:
                    graphView
                case .bases:
                    basesView
                }
            }
        }
    }

    private var editorView: some View {
        SourceEditorView(
            text: $workspace.text,
            documentURL: workspace.selectedFileURL,
            vaultURL: workspace.vaultURL,
            noteLinkCompletions: workspace.files.map { workspace.title(for: $0) },
            controller: controller,
            preferences: preferences,
            savedSelection: workspace.editorSelection(for: workspace.selectedFileURL),
            onSelectionChange: { documentURL, selection in
                workspace.persistEditorSelection(selection, for: documentURL)
            }
        )
    }

    private var graphView: some View {
        NoteGraphView(workspace: workspace)
            .id(workspace.selectedFileURL)
    }

    private var basesView: some View {
        BasesView(workspace: workspace) { url in
            workspace.selectFile(url)
            viewMode = .editor
        }
    }

    private func restoreEditorFocusAfterPaletteDismiss() {
        guard viewMode == .editor, workspace.selectedFileIsMarkdown else { return }
        controller.focusEditor()
    }
}

// MARK: - Helpers

private extension ContentView {
    var availableTemplates: [TemplateDescriptor] {
        guard let vaultURL = workspace.vaultURL else { return [] }
        return (try? TemplateLibraryService().availableTemplates(
            in: vaultURL,
            configuration: workflowConfiguration.templates
        )) ?? []
    }

    func openDailyNote() {
        guard let vaultURL = workspace.vaultURL else { return }
        do {
            let result = try DailyNoteService().createOrOpen(
                in: vaultURL,
                configuration: workflowConfiguration.dailyNotes,
                templateConfiguration: workflowConfiguration.templates
            )
            workspace.refreshFiles()
            workspace.selectFile(result.fileURL)
        } catch {
            workflowError = error.localizedDescription
        }
    }

    func recordCurrentVault() {
        guard let vaultURL = workspace.vaultURL else { return }
        recentVaults.recordOpened(vaultURL)
    }

    func restoreWorkspaceSession() {
        guard workspaceSession.load(
            for: workspace.vaultURL,
            availableFiles: Set(workspace.files.map(\.url)),
            inventoryReady: !workspace.isLoadingSnapshot
        ) else { return }
        workspaceSession.noteSelected(workspace.selectedFileURL)
    }

    func applyPreferredViewMode() {
        viewMode = WorkspaceViewModePolicy.modeAfterSelection(
            current: viewMode,
            preferred: preferences.defaultOpenViewMode,
            isMarkdown: workspace.selectedFileIsMarkdown,
            isImage: workspace.selectedFileIsImage
        )
    }

    func showEditorForSearch() {
        guard workspace.selectedFileIsMarkdown else { return }
        if viewMode != .editor {
            viewMode = .editor
        }
    }

    func synchronizeAssistantContext() {
        guard workspace.selectedFileIsMarkdown else {
            assistant.updateContext(
                fileURL: nil,
                title: "",
                markdown: ""
            )
            return
        }

        assistant.updateContext(
            fileURL: workspace.selectedFileURL,
            title: workspace.selectedFileName,
            markdown: workspace.text
        )
    }

    func collapseSidebarFolders() {
        expandedFolderURLs.removeAll()
    }

    func folderURLs(in nodes: [SidebarNode]) -> Set<URL> {
        Set(nodes.flatMap { node -> [URL] in
            if node.isFolder {
                return [node.url] + Array(folderURLs(in: node.children))
            }
            return []
        })
    }

    func restoreExpandedFoldersIfNeeded(force: Bool = false) {
        guard let storageKey = sidebarExpansionStorageKey else {
            expandedFolderURLs = []
            restoredVaultKey = nil
            return
        }

        if !preferences.restoresExpandedFolders {
            expandedFolderURLs = []
            restoredVaultKey = storageKey
            return
        }

        if force && preferences.collapsesFoldersOnVaultSwitch {
            expandedFolderURLs = []
            restoredVaultKey = storageKey
            return
        }

        let validFolderURLs = folderURLs(in: workspace.sidebarNodes)

        guard force || restoredVaultKey != storageKey else {
            let filteredURLs = SidebarExpansionPersistence.filteredExpandedFolderURLs(
                expandedFolderURLs,
                validFolderURLs: validFolderURLs
            )
            if filteredURLs != expandedFolderURLs {
                expandedFolderURLs = filteredURLs
                persistExpandedFolders()
            }
            return
        }

        let storedPaths = UserDefaults.standard.stringArray(forKey: storageKey) ?? []

        switch SidebarExpansionPersistence.restoreResult(
            storedPaths: storedPaths,
            validFolderURLs: validFolderURLs,
            isLoadingSnapshot: workspace.isLoadingSnapshot
        ) {
        case .deferred:
            expandedFolderURLs = []
            restoredVaultKey = nil
        case .restored(let restoredURLs):
            expandedFolderURLs = restoredURLs
            restoredVaultKey = storageKey
        }
    }

    func persistExpandedFolders() {
        guard preferences.restoresExpandedFolders, let storageKey = sidebarExpansionStorageKey else { return }
        let paths = expandedFolderURLs
            .map { $0.standardizedFileURL.path }
            .sorted()
        UserDefaults.standard.set(paths, forKey: storageKey)
    }

    var sidebarExpansionStorageKey: String? {
        guard let vaultURL = workspace.vaultURL else { return nil }
        return "sidebarExpandedFolders::" + vaultURL.standardizedFileURL.path
    }
}

enum WorkspaceViewModePolicy {
    static func modeAfterSelection(
        current: OpenViewMode,
        preferred: OpenViewMode,
        isMarkdown: Bool,
        isImage: Bool
    ) -> OpenViewMode {
        if isMarkdown { return preferred }
        if isImage, current == .bases { return .preview }
        return current
    }
}

// MARK: - Save Status Alerts

/// Surfaces save failures and external-modification conflicts. Extracted into a
/// modifier so the alert closures don't bloat `ContentView.body` past the
/// type-checker's complexity budget.
private struct SaveStatusAlerts: ViewModifier {
    @Bindable var workspace: Workspace

    func body(content: Content) -> some View {
        content
            .alert(
                "File Changed on Disk",
                isPresented: Binding(
                    get: { workspace.saveConflict != nil },
                    set: { if !$0 { workspace.saveConflict = nil } }
                ),
                presenting: workspace.saveConflict
            ) { _ in
                Button("Keep My Version") { workspace.resolveSaveConflictKeepingMine() }
                Button("Reload From Disk", role: .destructive) { workspace.resolveSaveConflictUsingDisk() }
            } message: { conflict in
                Text("\u{201C}\(conflict.fileName)\u{201D} was modified by another app since you opened it. Keeping your version overwrites those changes; reloading discards your unsaved edits.")
            }
            .alert(
                "Save Failed",
                isPresented: Binding(
                    get: { workspace.saveError != nil },
                    set: { if !$0 { workspace.saveError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { workspace.saveError = nil }
            } message: {
                Text(workspace.saveError ?? "")
            }
    }
}

// MARK: - Window Toolbar Configurator

private struct WindowToolbarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureToolbar(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureToolbar(for: nsView)
        }
    }

    private func configureToolbar(for view: NSView) {
        guard let toolbar = view.window?.toolbar else { return }
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
    }
}
