import SwiftUI

struct TemplateCreationSheet: View {
    let vaultURL: URL
    let template: TemplateDescriptor
    let templateConfiguration: TemplateLibraryConfiguration
    let onCreated: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var destinationFolder = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Note from Template")
                .font(.title2.weight(.semibold))

            Text(template.displayName)
                .foregroundStyle(.secondary)

            TextField("Note title", text: $title)
                .textFieldStyle(.roundedBorder)

            TextField("Destination folder (optional)", text: $destinationFolder)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            title = template.displayName
        }
    }

    private func create() {
        do {
            let url = try TemplateNoteService().create(
                in: vaultURL,
                title: title,
                template: template,
                templateConfiguration: templateConfiguration,
                destinationFolderPath: destinationFolder
            )
            onCreated(url)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
