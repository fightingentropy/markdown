import SwiftUI

struct NoteAssistantPanel: View {
    @Bindable var assistant: NoteAssistant
    let settings: AssistantSettings
    let currentFileTitle: String
    let hasSelectedFile: Bool

    private var selectedModelName: String {
        AssistantSettings.model(for: settings.selectedModel)?.displayName ?? "Assistant"
    }

    var body: some View {
        Group {
            if assistant.isPresented {
                expandedPanel
            } else {
                launcherButton
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: assistant.isPresented)
    }

    private var launcherButton: some View {
        Button {
            assistant.isPresented = true
        } label: {
            launcherContent
                .frame(width: settings.launcherSize, height: settings.launcherSize)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
        }
        .buttonStyle(.plain)
        .help("Open Note Assistant")
    }

    private var launcherContent: some View {
        ZStack(alignment: .bottomTrailing) {
            AssistantLauncherSurface(settings: settings)

            if !settings.isConfigured && settings.showsLauncherStatusBadge {
                AssistantLauncherStatusBadge(settings: settings)
                    .offset(x: -6, y: -5)
            }
        }
    }

    private var expandedPanel: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content

            Divider()

            composer
        }
        .frame(width: 380, height: 456)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.22), radius: 28, y: 18)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: 34, height: 34)

                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Note Assistant")
                    .font(.headline.weight(.semibold))

                Text(hasSelectedFile ? currentFileTitle : "No note selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Label(selectedModelName, systemImage: "cpu")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.05), in: Capsule())
            }

            Spacer()

            if !assistant.messages.isEmpty {
                Button("New Chat") {
                    assistant.reset()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button {
                assistant.isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close Assistant")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            assistantPlaceholder(
                title: "Set your OpenCode API key",
                message: "Open Settings, paste your API key, and the assistant will use the current note as context for each question."
            ) {
                HStack(spacing: 10) {
                    SettingsLink {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)

                    Link("Get API key", destination: AssistantSettings.authURL)
                        .font(.subheadline)
                }
            }
        } else if !hasSelectedFile {
            assistantPlaceholder(
                title: "Open a note first",
                message: "The assistant answers questions about the file you currently have open."
            )
        } else if assistant.messages.isEmpty {
            assistantPlaceholder(
                title: "Ask about this note",
                message: "Try a summary, extract action items, rewrite a section, or ask for clarification."
            )
        } else {
            AssistantTranscriptView(messages: assistant.messages)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let errorMessage = assistant.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask about this note…", text: $assistant.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.05))
                    }
                    .disabled(!settings.isConfigured || !hasSelectedFile || assistant.isSending)
                    .onSubmit {
                        submit()
                    }

                Button {
                    submit()
                } label: {
                    if assistant.isSending {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 42, height: 42)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(canSubmit ? .white : .secondary)
                            .frame(width: 42, height: 42)
                            .background(canSubmit ? Color.accentColor : Color.white.opacity(0.05), in: Circle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .help("Send")
            }
        }
        .padding(14)
    }

    private var canSubmit: Bool {
        settings.isConfigured &&
        hasSelectedFile &&
        !assistant.isSending &&
        !assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        Task {
            await assistant.sendCurrentDraft(using: settings)
        }
    }

    private func assistantPlaceholder<Actions: View>(
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 14) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 58, height: 58)

                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.accentColor.opacity(0.9))
            }

            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            actions()

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func assistantPlaceholder(
        title: String,
        message: String
    ) -> some View {
        assistantPlaceholder(title: title, message: message) {
            EmptyView()
        }
    }
}

struct AssistantLauncherSurface: View {
    let settings: AssistantSettings

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: settings.launcherCornerRadius, style: .continuous)
                .fill(gray(settings.launcherBackgroundLevel))

            RoundedRectangle(cornerRadius: settings.launcherCornerRadius, style: .continuous)
                .inset(by: 1)
                .fill(gray(settings.launcherBackgroundLevel + 0.02).opacity(0.45))

            RoundedRectangle(cornerRadius: settings.launcherCornerRadius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.55), lineWidth: 1)

            RoundedRectangle(cornerRadius: settings.launcherCornerRadius, style: .continuous)
                .inset(by: 1.2)
                .strokeBorder(gray(settings.launcherBorderLevel).opacity(0.5), lineWidth: 1)

            Image(systemName: settings.launcherSymbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(gray(settings.launcherForegroundLevel))
        }
    }

    private func gray(_ level: Double) -> Color {
        let clamped = min(max(level, 0), 1)
        return Color(red: clamped, green: clamped, blue: min(clamped + 0.01, 1))
    }
}

private struct AssistantLauncherStatusBadge: View {
    let settings: AssistantSettings

    var body: some View {
        Circle()
            .fill(gray(max(settings.launcherBackgroundLevel - 0.03, 0.02)))
            .frame(width: 14, height: 14)
            .overlay {
                Circle()
                    .fill(gray(settings.launcherBorderLevel))
                    .padding(3)
            }
    }

    private func gray(_ level: Double) -> Color {
        let clamped = min(max(level, 0), 1)
        return Color(red: clamped, green: clamped, blue: min(clamped + 0.01, 1))
    }
}

private struct AssistantTranscriptView: View {
    let messages: [NoteAssistantMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        AssistantMessageBubble(message: message)
                            .id(message.id)
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
            .onAppear {
                scrollToBottom(using: proxy)
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(using: proxy)
            }
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        guard let lastID = messages.last?.id else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
}

private struct AssistantMessageBubble: View {
    let message: NoteAssistantMessage

    var body: some View {
        HStack {
            if message.role == .assistant {
                bubble
                Spacer(minLength: 28)
            } else {
                Spacer(minLength: 28)
                bubble
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .assistant ? "Assistant" : "You")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(message.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 262, alignment: .leading)
        .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(message.role == .assistant ? 0.05 : 0))
        }
    }

    private var backgroundStyle: some ShapeStyle {
        message.role == .assistant
            ? AnyShapeStyle(.white.opacity(0.06))
            : AnyShapeStyle(Color.accentColor.opacity(0.2))
    }
}
