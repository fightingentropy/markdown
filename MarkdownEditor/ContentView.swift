import SwiftUI

struct ContentView: View {
    @Bindable var workspace: Workspace
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
        preferences: AppPreferences,
        workflowConfiguration: NoteWorkflowConfigurationStore
    ) {
        self.workspace = workspace
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
        .navigationTitle("")
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    titlebarTabs
                }
                // Keep the tab bar floating directly on the titlebar; without
                // this macOS 26 draws a glass tile behind the custom view.
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    titlebarTabs
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .inspector(isPresented: $isInspectorPresented) {
            NoteInspectorView(workspace: workspace, controller: controller)
                .inspectorColumnWidth(min: 270, ideal: 320, max: 440)
        }
        .background(WindowToolbarConfigurator(title: workspace.selectedFileName))
        .background(TitlebarAccessoryInstaller(content: noteViewToolbar, layoutAttribute: .right))
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
        }
        .onChange(of: workspace.selectedFileURL) { _, _ in
            if workspaceSession.isLoaded(for: workspace.vaultURL) {
                workspaceSession.noteSelected(workspace.selectedFileURL)
            }
            applyPreferredViewMode()
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
            Button {
                workspace.isCommandPalettePresented = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))

                    Text("Search")
                        .font(.system(size: 13))

                    Spacer()

                    Text("⌘ K")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search Notes")
            .accessibilityLabel("Search Notes")
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            HStack {
                Text("Everything")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    workspace.createNewFile()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Note")
                .accessibilityLabel("New Note")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.bottom, 4)

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
                    .contentMargins(.horizontal, 6, for: .scrollContent)
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

            HStack(spacing: 9) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(workspace.vaultURL?.lastPathComponent ?? "Vault")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 8)

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

            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 340)
        .overlay {
            if isSidebarRootDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                    .padding(6)
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        detailContent
    }

    @ViewBuilder
    private var titlebarTabs: some View {
        if !workspaceSession.tabs.isEmpty {
            NoteTabBar(workspace: workspace, session: workspaceSession, isCompact: true)
                // A horizontal ScrollView reports a zero ideal width before its
                // first layout pass. Give the titlebar a real starting width so
                // the restored tab is visible while still allowing it to scroll.
                .frame(minWidth: 120, maxWidth: 520, alignment: .leading)
        }
    }

    private var noteViewToolbar: some View {
        HStack(spacing: 2) {
            ForEach(OpenViewMode.allCases) { mode in
                TitlebarIconButton(
                    systemImage: mode.systemImage,
                    isSelected: viewMode == mode,
                    help: mode.title
                ) {
                    viewMode = mode
                }
            }

            TitlebarSeparator()

            TitlebarIconButton(
                systemImage: "rectangle.split.2x1",
                isActive: workspaceSession.splitPreview,
                help: workspaceSession.splitPreview ? "Hide Split Preview" : "Show Split Preview"
            ) {
                workspaceSession.splitPreview.toggle()
            }
            .disabled(!workspace.selectedFileIsMarkdown || viewMode != .editor)

            TitlebarIconButton(
                systemImage: "sidebar.trailing",
                isActive: isInspectorPresented,
                help: isInspectorPresented ? "Hide Note Inspector" : "Show Note Inspector"
            ) {
                isInspectorPresented.toggle()
            }

            TitlebarSeparator()

            moreNoteActionsMenu
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
        .fixedSize()
    }

    private var moreNoteActionsMenu: some View {
        Menu {
            Button {
                workspace.createNewFile()
            } label: {
                Label("New Note", systemImage: "plus")
            }

            Button {
                openDailyNote()
            } label: {
                Label("Open Today's Daily Note", systemImage: "calendar")
            }

            Menu("New from Template") {
                if availableTemplates.isEmpty {
                    Text("No templates in \(workflowConfiguration.templates.folderPath)")
                } else {
                    ForEach(availableTemplates) { template in
                        Button(template.displayName) {
                            selectedTemplate = template
                        }
                    }
                }
            }

            Divider()

            Button {
                showEditorForSearch()
                controller.activateSearch()
            } label: {
                Label("Find in Current Note", systemImage: "magnifyingglass")
            }
            .disabled(!workspace.selectedFileIsMarkdown)

            if let selectedURL = workspace.selectedFileURL {
                Button {
                    workspaceSession.togglePinned(selectedURL)
                } label: {
                    Label(
                        workspaceSession.isPinned(selectedURL) ? "Unpin Note" : "Pin Note",
                        systemImage: workspaceSession.isPinned(selectedURL) ? "pin.slash" : "pin"
                    )
                }
            }

            Button {
                isVaultHealthPresented = true
            } label: {
                Label("Vault Health", systemImage: "checkmark.shield")
            }
        } label: {
            TitlebarMenuLabel()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More Note Actions")
        .accessibilityLabel("More Note Actions")
    }

    @ViewBuilder
    private var detailContent: some View {
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

    private var editorView: some View {
        VStack(spacing: 0) {
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

            EditorStatusBar(text: workspace.text)
        }
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
                    // Dismiss without a choice must not clear the conflict; only
                    // Keep / Reload resolve it.
                    set: { _ in }
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

// MARK: - Titlebar Controls

/// A borderless icon button for the titlebar. Selected segments get a soft
/// accent highlight (matching the selected tab); active toggles only tint the
/// glyph. No boxed bezels.
private struct TitlebarIconButton: View {
    let systemImage: String
    var isSelected = false
    var isActive = false
    var help: String = ""
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 26, height: 22)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(isHovering ? 0.13 : 0.09))
                    } else if isHovering, isEnabled {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
        .help(help)
        .accessibilityLabel(help)
    }

    private var iconColor: Color {
        guard isEnabled else { return .secondary.opacity(0.5) }
        if isSelected || isActive { return .primary }
        return isHovering ? .primary : .secondary
    }
}

private struct EditorStatusBar: View {
    let text: String

    private var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    var body: some View {
        HStack(spacing: 5) {
            Spacer()
            Text("\(wordCount) words")
            Text("·")
            Text("\(text.count) characters")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(wordCount) words, \(text.count) characters")
    }
}

private struct TitlebarSeparator: View {
    var body: some View {
        Divider()
            .frame(height: 14)
            .padding(.horizontal, 3)
            .opacity(0.6)
    }
}

private struct TitlebarMenuLabel: View {
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isHovering ? Color.primary : Color.secondary)
            .frame(width: 22, height: 22)
            .background {
                if isHovering {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.1), value: isHovering)
    }
}

// MARK: - Window Toolbar Configurator

private struct WindowToolbarConfigurator: NSViewRepresentable {
    let title: String

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
        guard let window = view.window, let toolbar = window.toolbar else { return }
        window.title = title
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
    }
}

private struct TitlebarAccessoryInstaller<Content: View>: NSViewRepresentable {
    let content: Content
    let layoutAttribute: NSLayoutConstraint.Attribute

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content, layoutAttribute: layoutAttribute)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.update(
                content: content,
                layoutAttribute: layoutAttribute,
                in: view
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.update(
                content: content,
                layoutAttribute: layoutAttribute,
                in: nsView
            )
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private let titlebarHeight: CGFloat = 44
        private let verticalCenteringCorrection: CGFloat = 4
        private let trailingEdgeInset: CGFloat = 8

        private let accessoryController = NSTitlebarAccessoryViewController()
        private let accessoryView = NSView()
        private let hostingView: NSHostingView<Content>
        private weak var attachedWindow: NSWindow?
        private var installedSize = NSSize.zero

        init(content: Content, layoutAttribute: NSLayoutConstraint.Attribute) {
            hostingView = NSHostingView(rootView: content)
            accessoryView.addSubview(hostingView)
            accessoryController.layoutAttribute = layoutAttribute
            accessoryController.view = accessoryView
        }

        func update(
            content: Content,
            layoutAttribute: NSLayoutConstraint.Attribute,
            in containerView: NSView
        ) {
            hostingView.rootView = content
            accessoryController.layoutAttribute = layoutAttribute

            let fittingSize = hostingView.fittingSize
            // The accessory controller is anchored to the window's right edge,
            // so the extra width becomes trailing breathing room.
            let targetSize = NSSize(
                width: ceil(max(0, fittingSize.width + trailingEdgeInset)),
                height: titlebarHeight
            )
            let sizeChanged = abs(targetSize.width - installedSize.width) > 0.5
                || abs(targetSize.height - installedSize.height) > 0.5

            hostingView.frame = NSRect(
                x: 0,
                // AppKit seats right-side titlebar accessories slightly below
                // the visual center used by native toolbar items.
                y: max(
                    0,
                    (targetSize.height - fittingSize.height) / 2
                        + verticalCenteringCorrection
                ),
                width: targetSize.width,
                height: fittingSize.height
            )
            accessoryView.setFrameSize(targetSize)
            installedSize = targetSize

            guard let window = containerView.window else { return }

            // An empty accessory has no useful titlebar presence. Waiting until it
            // has a width also avoids AppKit caching a zero-width view.
            guard targetSize.width > 0.5 else {
                detach()
                return
            }

            if attachedWindow === window {
                guard sizeChanged else { return }

                // AppKit does not reliably relayout an already-installed titlebar
                // accessory when its SwiftUI hosting view changes intrinsic width.
                // Reinstalling is cheap and keeps the accessory positioned correctly.
                detach()
            } else {
                detach()
            }

            window.addTitlebarAccessoryViewController(accessoryController)
            attachedWindow = window
        }

        func detach() {
            guard let attachedWindow,
                  let index = attachedWindow.titlebarAccessoryViewControllers.firstIndex(where: {
                      $0 === accessoryController
                  }) else {
                self.attachedWindow = nil
                return
            }
            attachedWindow.removeTitlebarAccessoryViewController(at: index)
            self.attachedWindow = nil
        }
    }
}
