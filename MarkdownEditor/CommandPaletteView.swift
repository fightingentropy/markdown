import SwiftUI

enum PaletteResult: Equatable {
    case file(URL)
}

private struct PaletteMatch: Identifiable {
    let file: FileItem
    let bodySnippet: String?

    var id: URL { file.id }
}

struct CommandPaletteView: View {
    let workspace: Workspace
    let onDismiss: () -> Void

    @State private var query = ""
    // Debounced mirror of `query` used by the result filter so that a single
    // keystroke doesn't force a full O(files * string-compare) rescan on
    // every character — visible as input lag on larger vaults.
    @State private var activeQuery = ""
    @FocusState private var isSearchFieldFocused: Bool

    private var filteredMatches: [PaletteMatch] {
        let files = workspace.sortedFiles
        if activeQuery.isEmpty {
            return files.map { PaletteMatch(file: $0, bodySnippet: nil) }
        }

        var titleMatches: [PaletteMatch] = []
        var bodyMatches: [PaletteMatch] = []

        for file in files {
            let title = workspace.title(for: file)
            let matchesTitle = title.localizedStandardContains(activeQuery) ||
                file.displayName.localizedStandardContains(activeQuery) ||
                file.name.localizedStandardContains(activeQuery)

            if matchesTitle {
                titleMatches.append(PaletteMatch(file: file, bodySnippet: nil))
                continue
            }

            guard let body = workspace.noteBody(for: file.url),
                  let snippet = Self.matchSnippet(in: body, for: activeQuery) else {
                continue
            }

            bodyMatches.append(PaletteMatch(file: file, bodySnippet: snippet))
        }

        return titleMatches + bodyMatches
    }

    private var primaryResult: PaletteResult? {
        if let match = filteredMatches.first {
            return .file(match.id)
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

                    TextField("Search notes\u{2026}", text: $query)
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
                    LazyVStack(alignment: .leading, spacing: 20) {
                        paletteSection("Notes") {
                            if filteredMatches.isEmpty {
                                Text("No matching notes")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            } else {
                                ForEach(filteredMatches) { match in
                                    paletteButton(
                                        title: workspace.title(for: match.file),
                                        subtitle: match.bodySnippet ?? workspace.relativePath(for: match.file),
                                        systemImage: match.file.url == workspace.selectedFileURL ? "doc.text.fill" : "doc.text",
                                        isSelected: primaryResult == .file(match.file.id)
                                    ) {
                                        workspace.selectFile(match.file.url)
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
        .task(id: query) {
            // Treat empty queries as immediate so the default file list
            // appears without flicker. Otherwise wait ~120ms so a burst of
            // keystrokes collapses into a single filter pass.
            if query.isEmpty {
                activeQuery = ""
                return
            }
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
            } catch {
                return
            }
            activeQuery = query
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
        onDismiss()
    }

    private func activatePrimaryResult() {
        switch primaryResult {
        case .file(let id):
            guard let match = filteredMatches.first(where: { $0.id == id }) else { return }
            workspace.selectFile(match.file.url)
            dismiss()
        case nil:
            break
        }
    }

    private static func matchSnippet(in body: String, for query: String) -> String? {
        guard !body.isEmpty, !query.isEmpty else { return nil }
        guard let matchRange = body.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }

        // Expand to the enclosing line so the snippet reads naturally.
        let lineRange = body.lineRange(for: matchRange)
        let rawLine = body[lineRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawLine.isEmpty else { return nil }

        let maxLength = 140
        guard rawLine.count > maxLength else { return rawLine }

        // Keep the match roughly centered in the snippet window.
        let matchOffset = body.distance(from: lineRange.lowerBound, to: matchRange.lowerBound)
        let windowStart = max(0, matchOffset - maxLength / 2)
        let startIndex = rawLine.index(rawLine.startIndex, offsetBy: min(windowStart, rawLine.count))
        let endIndex = rawLine.index(startIndex, offsetBy: min(maxLength, rawLine.distance(from: startIndex, to: rawLine.endIndex)))
        var snippet = String(rawLine[startIndex..<endIndex])

        if startIndex != rawLine.startIndex {
            snippet = "…" + snippet
        }
        if endIndex != rawLine.endIndex {
            snippet += "…"
        }
        return snippet
    }
}
