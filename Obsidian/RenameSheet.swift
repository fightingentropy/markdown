import SwiftUI

enum RenameItemKind {
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

struct RenameRequest: Identifiable {
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

struct RenameItemSheet: View {
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
