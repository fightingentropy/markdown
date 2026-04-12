import SwiftUI

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
