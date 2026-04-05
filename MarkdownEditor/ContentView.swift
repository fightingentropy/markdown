import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

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

    init(
        workspace: Workspace,
        assistant: NoteAssistant,
        assistantSettings: AssistantSettings,
        preferences: AppPreferences
    ) {
        self.workspace = workspace
        self.assistant = assistant
        self.assistantSettings = assistantSettings
        self.preferences = preferences
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

                    Menu {
                        ForEach(OpenViewMode.allCases) { mode in
                            Button {
                                viewMode = mode
                            } label: {
                                Label(mode.title, systemImage: viewMode == mode ? "checkmark" : mode.systemImage)
                            }
                        }
                    } label: {
                        Image(systemName: viewMode.systemImage)
                    }
                    .help("View Mode")
                    .disabled(!workspace.selectedFileIsMarkdown)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
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
            applyPreferredViewMode()
            synchronizeAssistantContext()
        }
        .onDisappear {
            persistExpandedFolders()
        }
        .onChange(of: workspace.vaultURL) { _, _ in
            restoreExpandedFoldersIfNeeded(force: true)
        }
        .onChange(of: workspace.sidebarNodes) { _, _ in
            restoreExpandedFoldersIfNeeded()
        }
        .onChange(of: workspace.isLoadingSnapshot) { _, _ in
            restoreExpandedFoldersIfNeeded()
        }
        .onChange(of: expandedFolderURLs) { _, _ in
            persistExpandedFolders()
        }
        .onChange(of: workspace.text) { _, _ in
            workspace.scheduleAutosave()
            synchronizeAssistantContext()
        }
        .onChange(of: workspace.selectedFileURL) { _, _ in
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

                Button {
                    collapseSidebarFolders()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Collapse All Folders")
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
        if workspace.selectedFileURL != nil {
            if workspace.selectedFileIsImage, let selectedURL = workspace.selectedFileURL {
                ImagePreview(url: selectedURL)
            } else {
                noteWorkspaceView
            }
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
            preferences: preferences
        )
        .id(workspace.selectedFileURL)
    }

    @ViewBuilder
    private var noteWorkspaceView: some View {
        switch viewMode {
        case .editor:
            editorView
        case .preview:
            previewView
        case .graph:
            graphView
        }
    }

    private var editorView: some View {
        SourceEditorView(
            text: $workspace.text,
            documentURL: workspace.selectedFileURL,
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

    private func restoreEditorFocusAfterPaletteDismiss() {
        guard viewMode == .editor, workspace.selectedFileIsMarkdown else { return }
        controller.focusEditor()
    }
}

private struct SidebarDragItem: Codable, Transferable {
    let path: String

    init(url: URL) {
        path = url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sidebarDragItem)
    }

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let encodedItem = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.sidebarDragItem.identifier, visibility: .all) { completion in
            completion(encodedItem, nil)
            return nil
        }
        return provider
    }

    static func loadFirst(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor (SidebarDragItem?) -> Void
    ) {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.sidebarDragItem.identifier) }) else {
            Task { @MainActor in
                completion(nil)
            }
            return
        }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.sidebarDragItem.identifier) { data, _ in
            let item = data.flatMap { try? JSONDecoder().decode(SidebarDragItem.self, from: $0) }
            Task { @MainActor in
                completion(item)
            }
        }
    }
}

private extension UTType {
    static let sidebarDragItem = UTType(exportedAs: "com.md.markdown.sidebar-drag-item")
}

private enum SidebarDropSupport {
    static let internalTypeIdentifiers = [UTType.sidebarDragItem.identifier]
    static let rootTypeIdentifiers = [
        UTType.sidebarDragItem.identifier,
        UTType.fileURL.identifier,
        UTType.url.identifier
    ]

    static func handleMoveDrop(
        providers: [NSItemProvider],
        to directoryURL: URL?,
        workspace: Workspace,
        onSuccess: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        guard providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.sidebarDragItem.identifier) }) else {
            return false
        }

        SidebarDragItem.loadFirst(from: providers) { item in
            guard let item else { return }
            if workspace.moveItem(item.url, toFolder: directoryURL) {
                onSuccess()
            }
        }

        return true
    }

    static func handleRootDrop(providers: [NSItemProvider], workspace: Workspace) -> Bool {
        if handleMoveDrop(providers: providers, to: nil, workspace: workspace) {
            return true
        }

        let urlProviders = providers.filter { $0.canLoadObject(ofClass: NSURL.self) }
        guard !urlProviders.isEmpty else {
            return false
        }

        for provider in urlProviders {
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = object as? NSURL else { return }
                let fileURL = url as URL
                guard isMD(fileURL) else { return }
                Task { @MainActor in
                    workspace.importDroppedFile(fileURL)
                }
            }
        }

        return true
    }
}

private struct CommandPaletteView: View {
    let workspace: Workspace
    let onDismiss: () -> Void

    @State private var query = ""
    @FocusState private var isSearchFieldFocused: Bool

    private var filteredFiles: [FileItem] {
        let files = workspace.sortedFiles
        if query.isEmpty {
            return files
        }

        return files.filter { file in
            workspace.title(for: file).localizedStandardContains(query) ||
            file.displayName.localizedStandardContains(query) ||
            file.name.localizedStandardContains(query)
        }
    }

    private var primaryResult: PaletteResult? {
        if let file = filteredFiles.first {
            return .file(file.id)
        }

        return nil
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.35))
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search notes…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($isSearchFieldFocused)
                        .onSubmit {
                            activatePrimaryResult()
                        }
                }
                .padding(20)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        paletteSection("Notes") {
                            if filteredFiles.isEmpty {
                                Text("No matching notes")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            } else {
                                ForEach(filteredFiles) { file in
                                    paletteButton(
                                        title: workspace.title(for: file),
                                        subtitle: workspace.relativePath(for: file),
                                        systemImage: file.url == workspace.selectedFileURL ? "doc.text.fill" : "doc.text",
                                        isSelected: primaryResult == .file(file.id)
                                    ) {
                                        workspace.selectFile(file.url)
                                        dismiss()
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
                .frame(maxHeight: 420)
            }
            .frame(width: 640)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            }
            .shadow(color: .black.opacity(0.2), radius: 24, y: 16)
            .padding(24)
        }
        .onAppear {
            isSearchFieldFocused = true
        }
        .onExitCommand {
            dismiss()
        }
    }

    @ViewBuilder
    private func paletteSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            content()
        }
    }

    private func paletteButton(
        title: String,
        subtitle: String?,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? .white.opacity(0.08) : .white.opacity(0.04))
        )
    }

    private func dismiss() {
        workspace.isCommandPalettePresented = false
        onDismiss()
    }

    private func activatePrimaryResult() {
        switch primaryResult {
        case .file(let id):
            guard let file = filteredFiles.first(where: { $0.id == id }) else { return }
            workspace.selectFile(file.url)
            dismiss()
        case nil:
            break
        }
    }
}

private struct SidebarNodeList: View {
    let nodes: [SidebarNode]
    let workspace: Workspace
    @Binding var expandedFolderURLs: Set<URL>
    let onRenameRequested: (RenameRequest) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.isFolder {
                SidebarFolderRow(
                    node: node,
                    workspace: workspace,
                    expandedFolderURLs: $expandedFolderURLs,
                    onRenameRequested: onRenameRequested
                )
            } else if let file = workspace.fileItem(for: node.url) {
                SidebarFileRow(
                    file: file,
                    workspace: workspace,
                    onRenameRequested: {
                        onRenameRequested(RenameRequest(file: file))
                    }
                )
            } else {
                SidebarAssetRow(node: node, workspace: workspace)
            }
        }
    }
}

private struct SidebarFolderRow: View {
    let node: SidebarNode
    let workspace: Workspace
    @Binding var expandedFolderURLs: Set<URL>
    let onRenameRequested: (RenameRequest) -> Void
    @State private var isDropTargeted = false

    var body: some View {
        DisclosureGroup(isExpanded: expansionBinding) {
            SidebarNodeList(
                nodes: node.children,
                workspace: workspace,
                expandedFolderURLs: $expandedFolderURLs,
                onRenameRequested: onRenameRequested
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)

                Text(node.name)
                    .lineLimit(1)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expansionBinding.wrappedValue.toggle()
                }
            }
            .contextMenu {
                Button {
                    onRenameRequested(RenameRequest(folder: node))
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button {
                    expandedFolderURLs.insert(node.url)
                    workspace.createNewFile(in: node.url)
                } label: {
                    Label("New File", systemImage: "doc.badge.plus")
                }

                Button {
                    expandedFolderURLs.insert(node.url)
                    workspace.createNewFolder(in: node.url)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }

                Divider()

                Button(role: .destructive) {
                    workspace.deleteItem(node.url)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .onDrop(of: SidebarDropSupport.internalTypeIdentifiers, isTargeted: $isDropTargeted) { providers in
                SidebarDropSupport.handleMoveDrop(
                    providers: providers,
                    to: node.url,
                    workspace: workspace
                ) {
                    expandedFolderURLs.insert(node.url)
                }
            }
        }
        .listRowInsets(sidebarRowInsets)
        .listRowBackground(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expandedFolderURLs.contains(node.url) },
            set: { isExpanded in
                if isExpanded {
                    expandedFolderURLs.insert(node.url)
                } else {
                    expandedFolderURLs.remove(node.url)
                }
            }
        )
    }
}

private struct SidebarAssetRow: View {
    let node: SidebarNode
    let workspace: Workspace

    var body: some View {
        Button {
            workspace.selectFile(node.url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)

                Text(node.name)
                    .lineLimit(1)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .listRowInsets(sidebarRowInsets)
        .onDrag {
            SidebarDragItem(url: node.url).itemProvider()
        }
        .contextMenu {
            Button(role: .destructive) {
                workspace.deleteItem(node.url)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .listRowBackground(node.url == workspace.selectedFileURL ? Color.accentColor.opacity(0.14) : Color.clear)
    }
}

private struct SidebarFileRow: View {
    let file: FileItem
    let workspace: Workspace
    let onRenameRequested: () -> Void

    var body: some View {
        Button {
            workspace.selectFile(file.url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: file.url == workspace.selectedFileURL ? "doc.text.fill" : "doc.text")
                    .foregroundStyle(.secondary)

                Text(workspace.title(for: file))
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text(file.modificationDate, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(sidebarRowInsets)
        .onDrag {
            SidebarDragItem(url: file.url).itemProvider()
        }
        .contextMenu {
            Button {
                onRenameRequested()
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button("Delete", role: .destructive) {
                workspace.deleteItem(file.url)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                onRenameRequested()
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.accentColor)

            Button(role: .destructive) {
                workspace.deleteItem(file.url)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .listRowBackground(file.url == workspace.selectedFileURL ? Color.accentColor.opacity(0.14) : Color.clear)
    }
}

private let sidebarRowInsets = EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 10)

private struct SidebarRootDropArea: View {
    let workspace: Workspace
    @Binding var isTargeted: Bool

    var body: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onDrop(of: SidebarDropSupport.rootTypeIdentifiers, isTargeted: $isTargeted) { providers in
                SidebarDropSupport.handleRootDrop(providers: providers, workspace: workspace)
            }
    }
}

private enum PaletteResult: Equatable {
    case file(URL)
}

private enum RenameItemKind {
    case file
    case folder

    var title: String {
        switch self {
        case .file:
            "Rename File"
        case .folder:
            "Rename Folder"
        }
    }

    var prompt: String {
        switch self {
        case .file:
            "Choose a new name for this file."
        case .folder:
            "Choose a new name for this folder."
        }
    }

    var placeholder: String {
        switch self {
        case .file:
            "File name"
        case .folder:
            "Folder name"
        }
    }
}

private struct RenameRequest: Identifiable {
    let url: URL
    let displayName: String
    let kind: RenameItemKind

    var id: URL { url }
    var pathExtension: String { url.pathExtension }

    init(file: FileItem) {
        self.url = file.url
        self.displayName = file.displayName
        self.kind = .file
    }

    init(folder: SidebarNode) {
        self.url = folder.url
        self.displayName = folder.name
        self.kind = .folder
    }
}

private struct RenameItemSheet: View {
    let target: RenameRequest
    let onSave: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFieldFocused: Bool
    @State private var proposedName: String
    @State private var errorMessage: String?

    init(target: RenameRequest, onSave: @escaping (String) throws -> Void) {
        self.target = target
        self.onSave = onSave
        _proposedName = State(initialValue: target.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(target.kind.title)
                    .font(.title3.weight(.semibold))

                Text(target.kind.prompt)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.subheadline.weight(.medium))

                HStack(spacing: 8) {
                    TextField(target.kind.placeholder, text: $proposedName)
                        .textFieldStyle(.roundedBorder)
                        .focused($isNameFieldFocused)
                        .onSubmit {
                            submit()
                        }

                    if !target.pathExtension.isEmpty {
                        Text(".\(target.pathExtension)")
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedProposedName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            isNameFieldFocused = true
        }
    }

    private var trimmedProposedName: String {
        proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        do {
            try onSave(proposedName)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Welcome View

struct WelcomeView: View {
    let workspace: Workspace
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)

            Text("Markdown Editor")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Drop a markdown file here, or choose a folder.")
                .foregroundStyle(.secondary)

            Button("Open Folder\u{2026}") {
                workspace.pickVault()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(8)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, isMD(url) else { return false }
            workspace.importDroppedFile(url)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }
}

private func isMD(_ url: URL) -> Bool {
    ["md", "markdown", "mdown", "txt"].contains(url.pathExtension.lowercased())
}

private extension ContentView {
    func applyPreferredViewMode() {
        guard workspace.selectedFileIsMarkdown else { return }
        viewMode = preferences.defaultOpenViewMode
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

enum SidebarExpansionRestoreResult: Equatable {
    case deferred
    case restored(Set<URL>)
}

enum SidebarExpansionPersistence {
    static func restoreResult(
        storedPaths: [String],
        validFolderURLs: Set<URL>,
        isLoadingSnapshot: Bool
    ) -> SidebarExpansionRestoreResult {
        if isLoadingSnapshot && validFolderURLs.isEmpty && !storedPaths.isEmpty {
            return .deferred
        }

        return .restored(
            matchedFolderURLs(
                for: storedPaths,
                within: validFolderURLs
            )
        )
    }

    static func filteredExpandedFolderURLs(
        _ expandedFolderURLs: Set<URL>,
        validFolderURLs: Set<URL>
    ) -> Set<URL> {
        let validFoldersByPath = keyedByCanonicalPath(validFolderURLs)
        return Set(
            expandedFolderURLs.compactMap { validFoldersByPath[canonicalPath(for: $0)] }
        )
    }

    private static func matchedFolderURLs(
        for storedPaths: [String],
        within validFolderURLs: Set<URL>
    ) -> Set<URL> {
        let validFoldersByPath = keyedByCanonicalPath(validFolderURLs)
        return Set(
            storedPaths.compactMap { storedPath in
                validFoldersByPath[canonicalPath(forPath: storedPath)]
            }
        )
    }

    private static func keyedByCanonicalPath(_ urls: Set<URL>) -> [String: URL] {
        Dictionary(uniqueKeysWithValues: urls.map { (canonicalPath(for: $0), $0) })
    }

    private static func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func canonicalPath(forPath path: String) -> String {
        canonicalPath(for: URL(fileURLWithPath: path))
    }
}

private struct ImagePreview: View {
    private static let imageCache = NSCache<NSURL, NSImage>()

    let url: URL
    @State private var zoomScale: CGFloat = 1
    @State private var isShowingControls = false
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var image: NSImage?
    @State private var isLoadingImage = false

    var body: some View {
        Group {
            if let image {
                imageView(image)
            } else if isLoadingImage {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.18))
            } else {
                ContentUnavailableView(
                    "Image Unavailable",
                    systemImage: "photo",
                    description: Text("This image couldn't be loaded.")
                )
            }
        }
        .task(id: url) {
            await loadImage()
        }
        .onDisappear {
            controlsHideTask?.cancel()
        }
    }

    private var minimumZoomScale: CGFloat { 0.25 }
    private var maximumZoomScale: CGFloat { 4 }

    private func clampedZoom(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimumZoomScale), maximumZoomScale)
    }

    private func revealControls() {
        controlsHideTask?.cancel()
        isShowingControls = true
        scheduleControlsHide(after: .seconds(2))
    }

    private func scheduleControlsHide(after duration: Duration) {
        controlsHideTask?.cancel()
        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            isShowingControls = false
        }
    }

    private func imageView(_ image: NSImage) -> some View {
        ZoomableImageScrollView(image: image, zoomScale: $zoomScale)
            .padding(24)
            .overlay(alignment: .topTrailing) {
                zoomControls
                    .padding(16)
                    .opacity(isShowingControls ? 1 : 0)
                    .offset(y: isShowingControls ? 0 : -6)
                    .animation(.easeInOut(duration: 0.18), value: isShowingControls)
                    .allowsHitTesting(isShowingControls)
            }
            .onHover { isHovering in
                if isHovering {
                    revealControls()
                } else {
                    scheduleControlsHide(after: .milliseconds(900))
                }
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    revealControls()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.18))
    }

    @MainActor
    private func loadImage() async {
        let cacheKey = url as NSURL
        if let cachedImage = Self.imageCache.object(forKey: cacheKey) {
            image = cachedImage
            isLoadingImage = false
            return
        }

        image = nil
        isLoadingImage = true
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        guard !Task.isCancelled else { return }

        let loadedImage = data.flatMap(NSImage.init(data:))
        if let loadedImage {
            Self.imageCache.setObject(loadedImage, forKey: cacheKey)
        }

        image = loadedImage
        isLoadingImage = false
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button {
                revealControls()
                zoomScale = clampedZoom(zoomScale - 0.2)
            } label: {
                Image(systemName: "minus")
            }
            .help("Zoom Out")
            .disabled(zoomScale <= minimumZoomScale)

            Text("\(Int(zoomScale * 100))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44)

            Button {
                revealControls()
                zoomScale = clampedZoom(zoomScale + 0.2)
            } label: {
                Image(systemName: "plus")
            }
            .help("Zoom In")
            .disabled(zoomScale >= maximumZoomScale)

            Button("Reset") {
                revealControls()
                zoomScale = 1
            }
            .font(.caption)
            .help("Reset Zoom")
            .disabled(abs(zoomScale - 1) < 0.01)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }
}

private struct ZoomableImageScrollView: NSViewRepresentable {
    let image: NSImage
    @Binding var zoomScale: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomScale: $zoomScale)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 4
        scrollView.magnification = 1

        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)

        let documentView = FlippedDocumentView(frame: CGRect(origin: .zero, size: image.size))
        documentView.addSubview(imageView)
        scrollView.documentView = documentView

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleLiveMagnify(_:)),
            name: NSScrollView.willStartLiveMagnifyNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleEndMagnify(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let documentView = scrollView.documentView,
              let imageView = documentView.subviews.first as? NSImageView else {
            return
        }

        if imageView.image != image {
            imageView.image = image
        }

        if imageView.frame.size != image.size {
            imageView.frame = CGRect(origin: .zero, size: image.size)
        }

        if documentView.frame.size != image.size {
            documentView.frame = CGRect(origin: .zero, size: image.size)
        }

        let imageSize = image.size
        if context.coordinator.lastImageSize != imageSize {
            context.coordinator.lastImageSize = imageSize
            context.coordinator.didApplyInitialZoom = false
        }

        if !context.coordinator.didApplyInitialZoom {
            let visibleSize = scrollView.contentView.bounds.size
            if visibleSize.width > 0, visibleSize.height > 0 {
                let fittedScale = fittedZoomScale(for: imageSize, in: visibleSize)
                context.coordinator.didApplyInitialZoom = true
                if abs(zoomScale - fittedScale) > 0.001 {
                    zoomScale = fittedScale
                }
                scrollView.setMagnification(
                    fittedScale,
                    centeredAt: CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY)
                )
                return
            }
        }

        if abs(scrollView.magnification - zoomScale) > 0.001 {
            scrollView.setMagnification(zoomScale, centeredAt: CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY))
        }
    }

    private func fittedZoomScale(for imageSize: CGSize, in visibleSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let widthScale = visibleSize.width / imageSize.width
        let heightScale = visibleSize.height / imageSize.height
        return min(max(min(widthScale, heightScale), 0.25), 1)
    }

    @MainActor
    final class Coordinator: NSObject {
        @Binding private var zoomScale: CGFloat
        var didApplyInitialZoom = false
        var lastImageSize = CGSize.zero

        init(zoomScale: Binding<CGFloat>) {
            _zoomScale = zoomScale
        }

        @objc
        func handleEndMagnify(_ notification: Notification) {
            updateZoomScale(from: notification.object)
        }

        @objc
        func handleLiveMagnify(_ notification: Notification) {
            updateZoomScale(from: notification.object)
        }

        private func updateZoomScale(from object: Any?) {
            guard let scrollView = object as? NSScrollView else { return }
            let currentScale = scrollView.magnification
            if abs(zoomScale - currentScale) > 0.001 {
                zoomScale = currentScale
            }
        }
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)

        guard let documentSize = documentView?.frame.size else {
            return constrained
        }

        if documentSize.width < proposedBounds.width {
            constrained.origin.x = -(proposedBounds.width - documentSize.width) / 2
        }

        if documentSize.height < proposedBounds.height {
            constrained.origin.y = -(proposedBounds.height - documentSize.height) / 2
        }

        return constrained
    }
}

private struct SidebarBackgroundContextMenuHost: NSViewRepresentable {
    let onCreateFile: () -> Void
    let onCreateFolder: () -> Void
    let onDeleteSelection: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onCreateFile: onCreateFile,
            onCreateFolder: onCreateFolder,
            onDeleteSelection: onDeleteSelection
        )
    }

    func makeNSView(context: Context) -> SidebarBackgroundContextMenuView {
        let view = SidebarBackgroundContextMenuView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: SidebarBackgroundContextMenuView, context: Context) {
        context.coordinator.onCreateFile = onCreateFile
        context.coordinator.onCreateFolder = onCreateFolder
        context.coordinator.onDeleteSelection = onDeleteSelection
        nsView.coordinator = context.coordinator
    }

    @MainActor
    final class Coordinator: NSObject {
        var onCreateFile: () -> Void
        var onCreateFolder: () -> Void
        var onDeleteSelection: (() -> Void)?

        init(
            onCreateFile: @escaping () -> Void,
            onCreateFolder: @escaping () -> Void,
            onDeleteSelection: (() -> Void)?
        ) {
            self.onCreateFile = onCreateFile
            self.onCreateFolder = onCreateFolder
            self.onDeleteSelection = onDeleteSelection
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()

            let fileItem = NSMenuItem(
                title: "New File",
                action: #selector(createFile),
                keyEquivalent: ""
            )
            fileItem.target = self
            menu.addItem(fileItem)

            let folderItem = NSMenuItem(
                title: "New Folder",
                action: #selector(createFolder),
                keyEquivalent: ""
            )
            folderItem.target = self
            menu.addItem(folderItem)

            if onDeleteSelection != nil {
                menu.addItem(.separator())

                let deleteItem = NSMenuItem(
                    title: "Delete",
                    action: #selector(deleteSelection),
                    keyEquivalent: ""
                )
                deleteItem.target = self
                deleteItem.image = NSImage(
                    systemSymbolName: "trash",
                    accessibilityDescription: "Delete"
                )
                menu.addItem(deleteItem)
            }

            return menu
        }

        @objc private func createFile() {
            onCreateFile()
        }

        @objc private func createFolder() {
            onCreateFolder()
        }

        @objc private func deleteSelection() {
            onDeleteSelection?()
        }
    }
}

@MainActor
private final class SidebarBackgroundContextMenuView: NSView {
    weak var coordinator: SidebarBackgroundContextMenuHost.Coordinator?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard shouldActivateForCurrentEvent(at: point) else {
            return nil
        }

        return shouldHandleBlankSidebarArea(at: point) ? self : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let localPoint = convert(event.locationInWindow, from: nil)
        guard shouldHandleBlankSidebarArea(at: localPoint) else {
            return nil
        }

        return coordinator?.makeMenu()
    }

    private func shouldActivateForCurrentEvent(at point: NSPoint) -> Bool {
        guard bounds.contains(point), let event = NSApp.currentEvent else {
            return false
        }

        switch event.type {
        case .rightMouseDown:
            return true
        case .leftMouseDown:
            return event.modifierFlags.contains(.control)
        default:
            return false
        }
    }

    private func shouldHandleBlankSidebarArea(at point: NSPoint) -> Bool {
        guard let outlineView = enclosingOutlineView() else {
            return true
        }

        let pointInOutlineView = outlineView.convert(point, from: self)
        guard outlineView.bounds.contains(pointInOutlineView) else {
            return false
        }

        return outlineView.row(at: pointInOutlineView) == -1
    }

    private func enclosingOutlineView() -> NSOutlineView? {
        guard let containerView = superview else { return nil }
        return findOutlineView(in: containerView, excluding: self)
    }

    private func findOutlineView(in view: NSView, excluding excludedView: NSView) -> NSOutlineView? {
        for subview in view.subviews where subview !== excludedView {
            if let outlineView = subview as? NSOutlineView {
                return outlineView
            }

            if let outlineView = findOutlineView(in: subview, excluding: excludedView) {
                return outlineView
            }
        }

        return nil
    }
}

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
