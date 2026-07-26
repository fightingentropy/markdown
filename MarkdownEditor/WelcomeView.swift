import SwiftUI

struct WelcomeView: View {
    let workspace: Workspace
    @State private var isDropTargeted = false
    @State private var recentVaults = RecentVaultStore()

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

            if !recentVaults.records.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Vaults")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    ForEach(recentVaults.records.prefix(5)) { record in
                        RecentVaultRow(
                            record: record,
                            onOpen: {
                                if workspace.openVault(record.url) {
                                    recentVaults.recordOpened(record.url, displayName: record.displayName)
                                }
                            },
                            onRemove: {
                                recentVaults.remove(record)
                            }
                        )
                    }
                }
                .frame(width: 460)
                .padding(.top, 8)
            }
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
        .onAppear {
            recentVaults.pruneUnavailable()
        }
    }
}

private struct RecentVaultRow: View {
    let record: RecentVaultRecord
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false
    @State private var isRemoveHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpen) {
                HStack {
                    Image(systemName: "folder")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.displayName)
                        Text(record.url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isRemoveHovering ? .primary : .secondary)
                        .frame(width: 18, height: 18)
                        .background {
                            if isRemoveHovering {
                                Circle().fill(Color.primary.opacity(0.12))
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { isRemoveHovering = $0 }
                .help("Remove from Recent Vaults")
                .accessibilityLabel("Remove \(record.displayName) from Recent Vaults")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.12), value: isRemoveHovering)
        .contextMenu {
            Button("Remove from Recent Vaults", action: onRemove)
        }
    }
}
