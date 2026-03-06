import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var workspace: Workspace
    @State private var controller = EditorController()
    @State private var showPreview = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var expandedFolderURLs: Set<URL> = []
    @State private var restoredVaultKey: String?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
                .focusedValue(\.editorController, controller)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(workspace.selectedFileName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 2) {
                    Button { workspace.createNewFile() } label: {
                        Image(systemName: "plus")
                    }
                    .help("New File")

                    Button { showPreview.toggle() } label: {
                        Image(systemName: showPreview ? "pencil" : "eye")
                    }
                    .help(showPreview ? "Show Editor" : "Show Preview")
                    .disabled(workspace.selectedFileURL == nil)
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .keyboardShortcut("b")
                .help(columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(WindowToolbarConfigurator())
        .overlay {
            if workspace.isCommandPalettePresented {
                CommandPaletteView(workspace: workspace)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .onAppear {
            restoreExpandedFoldersIfNeeded()
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
        .onChange(of: expandedFolderURLs) { _, _ in
            persistExpandedFolders()
        }
        .onChange(of: workspace.text) { _, _ in
            workspace.scheduleAutosave()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
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
                        expandedFolderURLs: $expandedFolderURLs
                    )
                }
                .listStyle(.sidebar)
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
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, isMD(url) else { return false }
            workspace.importDroppedFile(url)
            return true
        }
        .toolbar(removing: .sidebarToggle)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if workspace.selectedFileURL != nil {
            if showPreview {
                MarkdownPreview(markdown: workspace.text)
                    .id(workspace.selectedFileURL)
            } else {
                SourceEditorView(text: $workspace.text, controller: controller)
            }
        } else {
            ContentUnavailableView(
                "No File Selected",
                systemImage: "doc.text",
                description: Text("Select a file from the sidebar or create a new one.")
            )
        }
    }
}

private struct CommandPaletteView: View {
    let workspace: Workspace

    @State private var query = ""
    @FocusState private var isSearchFieldFocused: Bool

    private var filteredFiles: [FileItem] {
        if query.isEmpty {
            return workspace.sortedFiles
        }

        return workspace.sortedFiles.filter { file in
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
                    VStack(alignment: .leading, spacing: 20) {
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

    var body: some View {
        ForEach(nodes) { node in
            if node.isFolder {
                DisclosureGroup(isExpanded: expansionBinding(for: node.url)) {
                    SidebarNodeList(
                        nodes: node.children,
                        workspace: workspace,
                        expandedFolderURLs: $expandedFolderURLs
                    )
                } label: {
                    Label(node.name, systemImage: "folder")
                }
            } else if let file = workspace.fileItem(for: node.url) {
                SidebarFileRow(file: file, workspace: workspace)
            }
        }
    }

    private func expansionBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { expandedFolderURLs.contains(url) },
            set: { isExpanded in
                if isExpanded {
                    expandedFolderURLs.insert(url)
                } else {
                    expandedFolderURLs.remove(url)
                }
            }
        )
    }
}

private struct SidebarFileRow: View {
    let file: FileItem
    let workspace: Workspace

    var body: some View {
        Button {
            workspace.selectFile(file.url)
        } label: {
            HStack(spacing: 8) {
                Label(workspace.title(for: file), systemImage: file.url == workspace.selectedFileURL ? "doc.text.fill" : "doc.text")
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
        .contextMenu {
            Button("Delete", role: .destructive) {
                workspace.deleteFile(file.url)
            }
        }
        .listRowBackground(file.url == workspace.selectedFileURL ? Color.accentColor.opacity(0.14) : Color.clear)
    }
}

private enum PaletteResult: Equatable {
    case file(URL)
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

        guard force || restoredVaultKey != storageKey else {
            let validFolderURLs = folderURLs(in: workspace.sidebarNodes)
            let filteredURLs = expandedFolderURLs.intersection(validFolderURLs)
            if filteredURLs != expandedFolderURLs {
                expandedFolderURLs = filteredURLs
                persistExpandedFolders()
            }
            return
        }

        let storedPaths = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        let validFolderURLs = folderURLs(in: workspace.sidebarNodes)
        let restoredURLs = Set(storedPaths.map(URL.init(fileURLWithPath:)))
            .intersection(validFolderURLs)

        expandedFolderURLs = restoredURLs
        restoredVaultKey = storageKey
    }

    func persistExpandedFolders() {
        guard let storageKey = sidebarExpansionStorageKey else { return }
        let paths = expandedFolderURLs
            .map { $0.standardizedFileURL.path }
            .sorted()
        UserDefaults.standard.set(paths, forKey: storageKey)
        UserDefaults.standard.synchronize()
    }

    var sidebarExpansionStorageKey: String? {
        guard let vaultURL = workspace.vaultURL else { return nil }
        return "sidebarExpandedFolders::" + vaultURL.standardizedFileURL.path
    }

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
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
