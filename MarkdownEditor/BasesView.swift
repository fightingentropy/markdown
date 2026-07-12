import SwiftUI

struct BasesView: View {
    enum Layout: String, CaseIterable, Identifiable {
        case table = "Table"
        case list = "List"
        case cards = "Cards"

        var id: String { rawValue }
    }

    let workspace: Workspace
    let onOpenNote: (URL) -> Void
    @State private var layout: Layout = .table
    @State private var query = ""
    @State private var selectedProperty = ""
    @State private var selectedTag = ""

    private var rows: [BaseNoteRow] {
        workspace.files.compactMap { file -> BaseNoteRow? in
            guard let body = workspace.noteBody(for: file.url) else { return nil }
            let metadata = ObsidianMetadataParser.parse(body)
            return BaseNoteRow(
                url: file.url,
                title: metadata.title ?? workspace.title(for: file),
                path: workspace.relativePath(for: file) ?? file.url.lastPathComponent,
                tags: metadata.tags,
                properties: metadata.properties,
                modifiedAt: file.modificationDate
            )
        }
    }

    private var propertyNames: [String] {
        Set(rows.flatMap { $0.properties.keys }).sorted()
    }

    private var tagNames: [String] {
        Set(rows.flatMap(\.tags)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filteredRows: [BaseNoteRow] {
        rows.filter { row in
            let matchesQuery = query.isEmpty
                || row.title.localizedCaseInsensitiveContains(query)
                || row.path.localizedCaseInsensitiveContains(query)
                || row.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
            let matchesProperty = selectedProperty.isEmpty || row.properties[selectedProperty] != nil
            let matchesTag = selectedTag.isEmpty || row.tags.contains {
                $0.caseInsensitiveCompare(selectedTag) == .orderedSame
            }
            return matchesQuery && matchesProperty && matchesTag
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            if filteredRows.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                switch layout {
                case .table:
                    tableView
                case .list:
                    listView
                case .cards:
                    cardsView
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            TextField("Filter notes…", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 300)

            Picker("Property", selection: $selectedProperty) {
                Text("All properties").tag("")
                ForEach(propertyNames, id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 180)

            Picker("Tag", selection: $selectedTag) {
                Text("All tags").tag("")
                ForEach(tagNames, id: \.self) { Text("#\($0)").tag($0) }
            }
            .frame(maxWidth: 160)

            Spacer()

            Picker("Layout", selection: $layout) {
                ForEach(Layout.allCases) { layout in
                    Text(layout.rawValue).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)

            Text("\(filteredRows.count) notes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var tableView: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(spacing: 0) {
                HStack(spacing: 12) {
                    tableHeader("Name", width: 240)
                    tableHeader("Tags", width: 220)
                    tableHeader("Properties", width: 360)
                    tableHeader("Modified", width: 150)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)

                ForEach(filteredRows) { row in
                    Button {
                        onOpenNote(row.url)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).lineLimit(1)
                                Text(row.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 240, alignment: .leading)

                            Text(row.tags.map { "#\($0)" }.joined(separator: "  "))
                                .lineLimit(1)
                                .frame(width: 220, alignment: .leading)

                            Text(propertySummary(row.properties))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 360, alignment: .leading)

                            Text(row.modifiedAt, style: .relative)
                                .foregroundStyle(.secondary)
                                .frame(width: 150, alignment: .leading)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private var listView: some View {
        List(filteredRows) { row in
            Button {
                onOpenNote(row.url)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(row.title).font(.headline)
                        Spacer()
                        Text(row.modifiedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(row.path).font(.caption).foregroundStyle(.secondary)
                    if !row.tags.isEmpty {
                        Text(row.tags.map { "#\($0)" }.joined(separator: "  "))
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    if !row.properties.isEmpty {
                        Text(propertySummary(row.properties))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
    }

    private var cardsView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(filteredRows) { row in
                    Button {
                        onOpenNote(row.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(row.title).font(.headline).lineLimit(2)
                            Text(row.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if !row.tags.isEmpty {
                                Text(row.tags.map { "#\($0)" }.joined(separator: "  "))
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                    .lineLimit(2)
                            }
                            Text(propertySummary(row.properties))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                        .padding(14)
                        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
    }

    private func tableHeader(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }

    private func propertySummary(_ properties: [String: ObsidianPropertyValue]) -> String {
        properties.keys.sorted().map { key in
            "\(key): \(displayValue(properties[key]))"
        }.joined(separator: "   ·   ")
    }

    private func displayValue(_ value: ObsidianPropertyValue?) -> String {
        switch value {
        case .string(let value): value
        case .strings(let values): values.joined(separator: ", ")
        case .boolean(let value): value ? "true" : "false"
        case .number(let value): value.formatted()
        case .null: "—"
        case .raw(let value): value.replacingOccurrences(of: "\n", with: " ")
        case nil: ""
        }
    }
}

private struct BaseNoteRow: Identifiable {
    let url: URL
    let title: String
    let path: String
    let tags: [String]
    let properties: [String: ObsidianPropertyValue]
    let modifiedAt: Date
    var id: URL { url }
}
