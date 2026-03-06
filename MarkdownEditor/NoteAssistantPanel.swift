import SwiftUI

struct NoteAssistantPanel: View {
    @Bindable var assistant: NoteAssistant
    let settings: AssistantSettings
    let currentFileTitle: String
    let hasSelectedFile: Bool

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
            .frame(width: 56, height: 56)
            .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
        }
        .buttonStyle(.plain)
        .help("Open Note Assistant")
    }

    private var launcherContent: some View {
        ZStack(alignment: .bottomTrailing) {
            AssistantLauncherSurface()

            if !settings.isConfigured {
                Circle()
                    .fill(.orange)
                    .frame(width: 9, height: 9)
                    .overlay {
                        Circle()
                            .strokeBorder(.black.opacity(0.45), lineWidth: 2)
                    }
                    .offset(x: -6, y: -6)
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
        .frame(width: 360, height: 430)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 16)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Note Assistant")
                    .font(.headline)

                Text(hasSelectedFile ? currentFileTitle : "No note selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let errorMessage = assistant.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask about this note…", text: $assistant.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                            .frame(width: 34, height: 34)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(canSubmit ? Color.accentColor : Color.secondary)
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

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.accentColor.opacity(0.8))

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

private struct AssistantLauncherSurface: View {
    var body: some View {
        ZStack {
            BubbleLauncherShape()
                .fill(
                    .linearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.13, blue: 0.16),
                            Color(red: 0.06, green: 0.07, blue: 0.09)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(0.34), radius: 12, x: 0, y: 6)

            BubbleLauncherShape()
                .stroke(.white.opacity(0.16), lineWidth: 1)

            BubbleLauncherShape()
                .fill(
                    .linearGradient(
                        colors: [
                            .white.opacity(0.1),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            BubbleLauncherShape()
                .trim(from: 0.08, to: 0.42)
                .stroke(.white.opacity(0.18), lineWidth: 1)

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(.white.opacity(0.88))
                        .frame(width: 5, height: 5)
                }
            }
        }
    }
}

private struct BubbleLauncherShape: Shape {
    func path(in rect: CGRect) -> Path {
        let bubbleRect = CGRect(x: 7, y: 6, width: rect.width - 14, height: rect.height - 18)
        let radius: CGFloat = 12
        let tailWidth: CGFloat = 11
        let tailHeight: CGFloat = 9
        let tailMidX = rect.midX - 5

        var path = Path()
        path.addRoundedRect(in: bubbleRect, cornerSize: CGSize(width: radius, height: radius))
        path.move(to: CGPoint(x: tailMidX - tailWidth / 2, y: bubbleRect.maxY))
        path.addLine(to: CGPoint(x: tailMidX, y: bubbleRect.maxY + tailHeight))
        path.addLine(to: CGPoint(x: tailMidX + tailWidth / 2, y: bubbleRect.maxY))
        path.closeSubpath()
        return path
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
        .frame(maxWidth: 250, alignment: .leading)
        .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var backgroundStyle: some ShapeStyle {
        message.role == .assistant
            ? AnyShapeStyle(.white.opacity(0.06))
            : AnyShapeStyle(Color.accentColor.opacity(0.2))
    }
}
