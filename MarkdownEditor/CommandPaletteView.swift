import SwiftUI

enum PaletteResult: Equatable {
    case file(URL)
}

struct CommandPaletteView: View {
    let workspace: Workspace
    let onDismiss: () -> Void

    @State private var query = ""
    // A `Sendable` snapshot of the searchable corpus, captured once when the
    // palette opens. Filtering reads only this — never `workspace` — so a
    // keystroke can't trigger a fresh O(files) walk of live model state.
    @State private var entries: [NoteSearchEntry] = []
    // The current result set, recomputed exactly once per (debounced) query
    // rather than on every view render / table row.
    @State private var results: [NoteSearchResult] = []
    @State private var selectedIndex = 0
    @FocusState private var isSearchFieldFocused: Bool

    private var primaryResult: PaletteResult? {
        guard results.indices.contains(selectedIndex) else {
            return results.first.map { .file($0.id) }
        }
        return .file(results[selectedIndex].id)
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
                        .accessibilityHidden(true)

                    TextField("Search notes\u{2026}", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($isSearchFieldFocused)
                        .accessibilityLabel("Search notes")
                        .onSubmit {
                            activatePrimaryResult()
                        }
                }
                .padding(20)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            paletteSection("Notes") {
                                if results.isEmpty {
                                    Text("No matching notes")
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                } else {
                                    ForEach(Array(results.enumerated()), id: \.element.id) { index, match in
                                        paletteButton(
                                            title: match.title,
                                            subtitle: match.subtitle,
                                            systemImage: match.url == workspace.selectedFileURL ? "doc.text.fill" : "doc.text",
                                            isSelected: index == selectedIndex
                                        ) {
                                            workspace.selectFile(match.url)
                                            dismiss()
                                        }
                                        .id(index)
                                    }
                                }
                            }
                        }
                        .padding(20)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: selectedIndex) { _, newValue in
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
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
            entries = workspace.makeSearchEntries()
            results = Workspace.search(entries, query: "")
        }
        .onExitCommand {
            dismiss()
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .task(id: query) {
            // Empty queries resolve immediately so the full list shows without
            // flicker; otherwise debounce ~120ms so a burst of keystrokes
            // collapses into one filter pass.
            if !query.isEmpty {
                do {
                    try await Task.sleep(nanoseconds: 120_000_000)
                } catch {
                    return
                }
            }

            let snapshot = entries
            let currentQuery = query
            // Filter off the main actor so large vaults don't stall typing.
            let filtered = await Task.detached(priority: .userInitiated) {
                Workspace.search(snapshot, query: currentQuery)
            }.value

            guard !Task.isCancelled else { return }
            results = filtered
            selectedIndex = 0
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
                    .accessibilityHidden(true)

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
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let next = selectedIndex + delta
        selectedIndex = min(max(next, 0), results.count - 1)
    }

    private func dismiss() {
        workspace.isCommandPalettePresented = false
        onDismiss()
    }

    private func activatePrimaryResult() {
        switch primaryResult {
        case .file(let id):
            guard let match = results.first(where: { $0.id == id }) else { return }
            workspace.selectFile(match.url)
            dismiss()
        case nil:
            break
        }
    }
}
