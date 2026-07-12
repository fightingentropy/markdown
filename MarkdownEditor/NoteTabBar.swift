import SwiftUI

struct NoteTabBar: View {
    let workspace: Workspace
    let session: WorkspaceSession

    var body: some View {
        if !session.tabs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(session.tabs, id: \.self) { url in
                        tab(for: url)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
    }

    private func tab(for url: URL) -> some View {
        let isSelected = workspace.selectedFileURL?.standardizedFileURL == url.standardizedFileURL
        let isPinned = session.isPinned(url)

        return HStack(spacing: 6) {
            Button {
                workspace.selectFile(url)
            } label: {
                HStack(spacing: 6) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(workspace.tabTitle(for: url))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Button {
                closeTab(url)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(workspace.tabTitle(for: url))")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.055))
        )
        .contextMenu {
            Button(isPinned ? "Unpin" : "Pin") {
                session.togglePinned(url)
            }
            Button("Close") {
                closeTab(url)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func closeTab(_ url: URL) {
        NoteTabCoordinator.close(url, workspace: workspace, session: session)
    }
}

@MainActor
enum NoteTabCoordinator {
    @discardableResult
    static func close(_ url: URL, workspace: Workspace, session: WorkspaceSession) -> Bool {
        let wasSelected = workspace.selectedFileURL?.standardizedFileURL == url.standardizedFileURL

        // Save before mutating the tab model. If the save fails or conflicts,
        // the visible tab and editor remain exactly as they were.
        if wasSelected, !workspace.saveCurrentFile().allowsTransition {
            return false
        }

        let replacement = session.close(url, selectedURL: workspace.selectedFileURL)
        guard wasSelected else { return true }

        let transitionSucceeded: Bool
        if let replacement {
            transitionSucceeded = workspace.selectFile(replacement)
        } else {
            transitionSucceeded = workspace.clearSelection()
        }

        if !transitionSucceeded {
            session.noteSelected(url)
        }
        return transitionSucceeded
    }
}

private extension Workspace {
    func tabTitle(for url: URL) -> String {
        if let file = files.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            return title(for: file)
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
