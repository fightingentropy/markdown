import SwiftUI

@main
struct MarkdownEditorApp: App {
    @State private var workspace = Workspace()
    @State private var appUpdater = AppUpdater()
    @FocusedValue(\.editorController) private var editorController

    var body: some Scene {
        WindowGroup {
            Group {
                if workspace.hasVault {
                    ContentView(workspace: workspace)
                } else {
                    WelcomeView(workspace: workspace)
                }
            }
            .frame(minWidth: 600, minHeight: 400)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New File") { workspace.createNewFile() }
                    .keyboardShortcut("n")
                    .disabled(!workspace.hasVault)
                Button("New Folder") { workspace.createNewFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!workspace.hasVault)
                Divider()
                Button("Choose Folder…") { workspace.pickVault() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { workspace.saveCurrentFile() }
                    .keyboardShortcut("s")
                    .disabled(workspace.selectedFileURL == nil)
            }
            CommandGroup(after: .newItem) {
                Button("Search Notes") { workspace.isCommandPalettePresented.toggle() }
                    .keyboardShortcut("k")
                    .disabled(!workspace.hasVault)
            }
            CommandGroup(after: .help) {
                Divider()
                Button("Check for Updates…") { appUpdater.checkForUpdates() }
                    .disabled(!appUpdater.canCheckForUpdates)
            }
            formatMenu
        }
    }

    // MARK: - Format Menu

    @CommandsBuilder
    private var formatMenu: some Commands {
        CommandMenu("Format") {
            Button("Bold") { editorController?.applyBold() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Italic") { editorController?.applyItalic() }
                .keyboardShortcut("i")
            Button("Inline Code") { editorController?.applyCode() }
                .keyboardShortcut("e")
            Button("Link") { editorController?.applyLink() }
                .keyboardShortcut("k", modifiers: [.command, .shift])

            Divider()

            Menu("Heading") {
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") { editorController?.applyHeading(level) }
                }
            }

            Divider()

            Button("Blockquote") { editorController?.applyBlockquote() }
            Button("Bullet List") { editorController?.applyUnorderedList() }
            Button("Numbered List") { editorController?.applyOrderedList() }
            Button("Code Block") { editorController?.applyCodeBlock() }
        }
    }
}
