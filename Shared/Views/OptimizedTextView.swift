import SwiftUI

struct OptimizedTextView: View {
    let content: String
    let isEditing: Bool
    @Binding var editedContent: String

    @State private var displayedContent: String = ""
    @State private var isLoadingContent = false

    // For large content, we'll chunk the display
    private let maxInitialCharacters = 5000

    var body: some View {
        Group {
            if isEditing {
                TextEditor(text: $editedContent)
                    .font(.body)
                    .frame(minHeight: 200)
                    .padding(8)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if isLoadingContent {
                        ProgressView("Loading content...")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else {
                        Text(displayedContent)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if content.count > maxInitialCharacters && displayedContent.count < content.count {
                        Button("Show More") {
                            withAnimation {
                                displayedContent = content
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal)
                        #if os(macOS)
                            .help("Display the complete content")
                        #endif
                    }
                }
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .task {
            await loadContent()
        }
    }

    private func loadContent() async {
        isLoadingContent = true

        // Load content asynchronously to prevent UI blocking
        await Task.detached(priority: .userInitiated) {
            let contentToDisplay =
                content.count > maxInitialCharacters
                ? String(content.prefix(maxInitialCharacters)) + "..."
                : content

            await MainActor.run {
                displayedContent = contentToDisplay
                isLoadingContent = false
            }
        }
        .value
    }
}
