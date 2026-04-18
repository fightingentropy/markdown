import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct SidebarDragItem: Codable, Transferable {
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

extension UTType {
    static let sidebarDragItem = UTType(exportedAs: "com.md.markdown.sidebar-drag-item")
}

enum SidebarDropSupport {
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

// MARK: - Sidebar Node List

struct SidebarNodeList: View {
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

// MARK: - Sidebar Folder Row

struct SidebarFolderRow: View {
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

// MARK: - Sidebar Asset Row

struct SidebarAssetRow: View {
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

// MARK: - Sidebar File Row

struct SidebarFileRow: View {
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

let sidebarRowInsets = EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 10)

// MARK: - Sidebar Root Drop Area

struct SidebarRootDropArea: View {
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

// MARK: - Backlinks Section

struct BacklinksSection: View {
    let workspace: Workspace

    private var backlinks: [NoteGraphNode] {
        workspace.noteGraph.backlinks(to: workspace.selectedFileURL)
    }

    var body: some View {
        if !backlinks.isEmpty {
            Section {
                ForEach(backlinks) { node in
                    Button {
                        workspace.selectFile(node.url)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "link")
                                .foregroundStyle(.secondary)

                            Text(node.title)
                                .lineLimit(1)

                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(sidebarRowInsets)
                    .listRowBackground(Color.clear)
                }
            } header: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.left.up")
                        .font(.caption2)
                    Text("Backlinks")
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct TagsSection: View {
    let workspace: Workspace
    @State private var expandedTags: Set<String> = []

    private var tagGroups: [(tag: String, files: [FileItem])] {
        workspace.tagIndex()
    }

    var body: some View {
        if !tagGroups.isEmpty {
            Section {
                ForEach(tagGroups, id: \.tag) { group in
                    let isExpanded = expandedTags.contains(group.tag.lowercased())

                    Button {
                        toggleTag(group.tag)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            Image(systemName: "number")
                                .foregroundStyle(.secondary)
                            Text(group.tag)
                                .lineLimit(1)
                            Spacer()
                            Text("\(group.files.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(sidebarRowInsets)
                    .listRowBackground(Color.clear)

                    if isExpanded {
                        ForEach(group.files) { file in
                            Button {
                                workspace.selectFile(file.url)
                            } label: {
                                HStack(spacing: 8) {
                                    Spacer().frame(width: 22)
                                    Image(systemName: workspace.selectedFileURL == file.url
                                          ? "doc.text.fill"
                                          : "doc.text")
                                        .foregroundStyle(.secondary)
                                    Text(workspace.title(for: file))
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(sidebarRowInsets)
                            .listRowBackground(Color.clear)
                        }
                    }
                }
            } header: {
                HStack(spacing: 4) {
                    Image(systemName: "number")
                        .font(.caption2)
                    Text("Tags")
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private func toggleTag(_ tag: String) {
        let key = tag.lowercased()
        if expandedTags.contains(key) {
            expandedTags.remove(key)
        } else {
            expandedTags.insert(key)
        }
    }
}

// MARK: - Sidebar Background Context Menu

struct SidebarBackgroundContextMenuHost: NSViewRepresentable {
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
final class SidebarBackgroundContextMenuView: NSView {
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

// MARK: - Sidebar Expansion Persistence

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

func isMD(_ url: URL) -> Bool {
    ["md", "markdown", "mdown", "txt"].contains(url.pathExtension.lowercased())
}
