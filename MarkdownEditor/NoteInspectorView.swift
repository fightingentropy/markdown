import SwiftUI

struct NoteInspectorView: View {
    enum Section: String, CaseIterable, Identifiable {
        case outline = "Outline"
        case links = "Links"
        case properties = "Properties"

        var id: String { rawValue }
    }

    let workspace: Workspace
    let controller: EditorController
    @State private var section: Section = .outline
    @State private var draftTitle = ""
    @State private var draftTags = ""
    @State private var draftAliases = ""
    @State private var newPropertyKey = ""
    @State private var newPropertyValue = ""

    private var metadata: ObsidianDocumentMetadata {
        ObsidianMetadataParser.parse(workspace.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)

            Divider()

            switch section {
            case .outline:
                outlineView
            case .links:
                linksView
            case .properties:
                propertiesView
            }
        }
        .frame(minWidth: 270, idealWidth: 320)
        .onAppear { synchronizePropertyDrafts() }
        .onChange(of: workspace.selectedFileURL) { _, _ in synchronizePropertyDrafts() }
    }

    private var outlineView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if metadata.outline.isEmpty {
                    emptyState("No headings", systemImage: "list.bullet.indent")
                } else {
                    ForEach(flattenedOutline, id: \.id) { item in
                        Button {
                            controller.jumpToLine(item.node.lineNumber)
                        } label: {
                            Text(item.node.title)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, CGFloat(item.depth) * 14)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Jump to line \(item.node.lineNumber)")
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var linksView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                inspectorSection("Backlinks") {
                    let backlinks = workspace.noteGraph.backlinks(to: workspace.selectedFileURL)
                    if backlinks.isEmpty {
                        Text("No linked mentions")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(backlinks) { node in
                            Button {
                                workspace.selectFile(node.url)
                            } label: {
                                Label(node.title, systemImage: "link")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                inspectorSection("Unlinked mentions") {
                    if unlinkedMentions.isEmpty {
                        Text("No unlinked mentions")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(unlinkedMentions) { mention in
                            VStack(alignment: .leading, spacing: 6) {
                                Button(mention.sourceTitle) {
                                    workspace.selectFile(mention.sourceURL)
                                }
                                .buttonStyle(.plain)
                                .font(.headline)

                                Text(mention.snippet)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)

                                Button("Link mention") {
                                    link(mention)
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var propertiesView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !metadata.tags.isEmpty {
                    inspectorSection("Tags") {
                        FlowLayout(spacing: 6) {
                            ForEach(metadata.tags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                            }
                        }
                    }
                }

                inspectorSection("Properties") {
                    if metadata.properties.isEmpty {
                        Text("No YAML properties")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(metadata.properties.keys.sorted(), id: \.self) { key in
                            HStack(alignment: .firstTextBaseline) {
                                Text(key)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                Text(displayValue(metadata.properties[key]))
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                            .font(.callout)
                        }
                    }
                }

                if !metadata.aliases.isEmpty {
                    inspectorSection("Aliases") {
                        ForEach(metadata.aliases, id: \.self) { alias in
                            Text(alias)
                        }
                    }
                }

                inspectorSection("Edit common properties") {
                    TextField("Title", text: $draftTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { setProperty("title", values: [draftTitle]) }
                    TextField("Tags, comma separated", text: $draftTags)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { setProperty("tags", values: commaSeparated(draftTags)) }
                    TextField("Aliases, comma separated", text: $draftAliases)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { setProperty("aliases", values: commaSeparated(draftAliases)) }
                    Button("Save common properties") {
                        setProperty("title", values: [draftTitle])
                        setProperty("tags", values: commaSeparated(draftTags))
                        setProperty("aliases", values: commaSeparated(draftAliases))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                inspectorSection("Add property") {
                    TextField("Property name", text: $newPropertyKey)
                        .textFieldStyle(.roundedBorder)
                    TextField("Value", text: $newPropertyValue)
                        .textFieldStyle(.roundedBorder)
                    Button("Add Property") {
                        setProperty(newPropertyKey, values: [newPropertyValue])
                        newPropertyKey = ""
                        newPropertyValue = ""
                    }
                    .disabled(newPropertyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .controlSize(.small)
                }
            }
            .padding(12)
        }
    }

    private var unlinkedMentions: [UnlinkedMention] {
        guard let selectedURL = workspace.selectedFileURL else { return [] }
        let names = [workspace.selectedFileName, metadata.title].compactMap { $0 } + metadata.aliases
        let sources = workspace.files.compactMap { file -> (url: URL, title: String, body: String)? in
            guard let body = workspace.noteBody(for: file.url) else { return nil }
            return (file.url, workspace.title(for: file), body)
        }
        return UnlinkedMentionFinder.find(
            targetNames: names,
            sources: sources,
            excluding: selectedURL
        )
    }

    private var flattenedOutline: [OutlineItem] {
        func flatten(_ nodes: [ObsidianOutlineNode], depth: Int) -> [OutlineItem] {
            nodes.flatMap { node in
                [OutlineItem(node: node, depth: depth)] + flatten(node.children, depth: depth + 1)
            }
        }
        return flatten(metadata.outline, depth: 0)
    }

    private func link(_ mention: UnlinkedMention) {
        guard let replacement = UnlinkedMentionFinder.replacingMention(mention, in: mention.expectedBody) else {
            NSSound.beep()
            return
        }

        if workspace.selectedFileURL?.standardizedFileURL == mention.sourceURL.standardizedFileURL {
            workspace.text = replacement
            return
        }

        guard let current = try? String(contentsOf: mention.sourceURL, encoding: .utf8),
              current == mention.expectedBody else {
            NSSound.beep()
            return
        }
        do {
            try Data(replacement.utf8).write(to: mention.sourceURL, options: .atomic)
            workspace.refreshFiles()
        } catch {
            NSSound.beep()
        }
    }

    private func displayValue(_ value: ObsidianPropertyValue?) -> String {
        switch value {
        case .string(let value): value
        case .strings(let values): values.joined(separator: ", ")
        case .boolean(let value): value ? "true" : "false"
        case .number(let value): value.formatted()
        case .null: "—"
        case .raw(let value): value
        case nil: ""
        }
    }

    private func synchronizePropertyDrafts() {
        let current = ObsidianMetadataParser.parse(workspace.text)
        draftTitle = current.title ?? ""
        draftTags = current.frontmatterTags.joined(separator: ", ")
        draftAliases = current.aliases.joined(separator: ", ")
    }

    private func commaSeparated(_ source: String) -> [String] {
        source.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private func setProperty(_ key: String, values: [String]) {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { return }
        let cleanValues = values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let value: ObsidianPropertyValue?
        if cleanValues.isEmpty {
            value = nil
        } else if cleanKey.caseInsensitiveCompare("title") == .orderedSame {
            value = .string(cleanValues[0])
        } else if cleanValues.count == 1 {
            value = .string(cleanValues[0])
        } else {
            value = .strings(cleanValues)
        }
        do {
            workspace.text = try ObsidianPropertyEditor.setting(
                key: cleanKey,
                value: value,
                in: workspace.text
            )
        } catch {
            NSSound.beep()
        }
    }

    private func emptyState(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OutlineItem: Identifiable {
    let node: ObsidianOutlineNode
    let depth: Int
    var id: String { "\(node.lineNumber):\(node.level):\(node.title)" }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let width = proposal.width ?? 300
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var points: [CGPoint] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}
