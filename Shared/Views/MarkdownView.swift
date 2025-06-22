import SwiftUI

struct MarkdownView: View {
    let content: String
    let promptId: UUID?
    let promptService: PromptService?

    @State private var showRawMarkdown = false
    @State private var renderedContent: AttributedString?
    @State private var isLoading = true

    init(content: String, promptId: UUID? = nil, promptService: PromptService? = nil) {
        self.content = content
        self.promptId = promptId
        self.promptService = promptService
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Content")
                    .font(.headline)

                Spacer()

                Toggle(isOn: $showRawMarkdown) {
                    Label(
                        showRawMarkdown ? "Raw" : "Preview",
                        systemImage: showRawMarkdown ? "doc.plaintext" : "doc.richtext"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                #if os(macOS)
                    .help(showRawMarkdown ? "Show markdown preview" : "Show raw markdown")
                #endif
            }

            Group {
                if showRawMarkdown {
                    ScrollView {
                        Text(content)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    if isLoading {
                        ProgressView("Rendering markdown...")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else if let rendered = renderedContent {
                        ScrollView {
                            Text(rendered)
                                .textSelection(.enabled)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text("Failed to render markdown")
                            .foregroundColor(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(minHeight: 200)
        }
        .task {
            await renderMarkdown()
        }
        .onChange(of: content) { _, _ in
            Task {
                await renderMarkdown()
            }
        }
    }

    private func renderMarkdown() async {
        // Try to get cached content first if we have promptId and service
        if let promptId = promptId, let promptService = promptService {
            // Create a temporary prompt object to pass to the service
            let tempPrompt = Prompt(title: "", content: content, category: .prompts)
            tempPrompt.id = promptId

            if let cached = await promptService.getRenderedMarkdown(for: tempPrompt) {
                await MainActor.run {
                    self.renderedContent = cached
                    self.isLoading = false
                }
                return
            }
        }

        // Fall back to rendering if no cache available
        isLoading = true

        await Task.detached(priority: .userInitiated) {
            do {
                let rendered = try AttributedString(
                    markdown: content,
                    options: AttributedString.MarkdownParsingOptions(
                        interpretedSyntax: .inlineOnlyPreservingWhitespace
                    )
                )

                await MainActor.run {
                    self.renderedContent = rendered
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    // Fallback to plain text if markdown parsing fails
                    self.renderedContent = AttributedString(content)
                    self.isLoading = false
                }
            }
        }
        .value
    }
}
