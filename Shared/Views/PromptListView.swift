import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

struct PromptListView: View {
    let prompts: [Prompt]
    @Binding var selectedPrompt: Prompt?
    let onDelete: (Prompt) async -> Void
    let onToggleFavorite: (Prompt) async -> Void
    let onLoadMore: (() async -> Void)?
    let hasMore: Bool
    let isLoadingMore: Bool

    @State private var deletingPrompt: Prompt?

    init(
        prompts: [Prompt],
        selectedPrompt: Binding<Prompt?>,
        onDelete: @escaping (Prompt) async -> Void,
        onToggleFavorite: @escaping (Prompt) async -> Void,
        onLoadMore: (() async -> Void)? = nil,
        hasMore: Bool = false,
        isLoadingMore: Bool = false
    ) {
        self.prompts = prompts
        self._selectedPrompt = selectedPrompt
        self.onDelete = onDelete
        self.onToggleFavorite = onToggleFavorite
        self.onLoadMore = onLoadMore
        self.hasMore = hasMore
        self.isLoadingMore = isLoadingMore
    }

    var body: some View {
        List(selection: $selectedPrompt) {
            if prompts.isEmpty {
                ContentUnavailableView(
                    "No Prompts",
                    systemImage: "doc.text",
                    description: Text("Create your first prompt to get started")
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(prompts) { prompt in
                    PromptRowView(
                        prompt: prompt,
                        isSelected: selectedPrompt?.id == prompt.id,
                        onToggleFavorite: {
                            Task {
                                await onToggleFavorite(prompt)
                            }
                        }
                    )
                    .tag(prompt)
                    #if os(macOS)
                        .promptDraggable(prompt)
                    #endif
                    #if os(iOS)
                        .onTapGesture {
                            selectedPrompt = prompt
                        }
                    #endif
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let prompt = prompts[index]
                        Task {
                            await onDelete(prompt)
                        }
                    }
                }
            }

            // Load more indicator and trigger
            if hasMore && !prompts.isEmpty {
                HStack {
                    Spacer()
                    if isLoadingMore {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.8)
                    } else {
                        Button("Load More") {
                            if let onLoadMore = onLoadMore {
                                Task {
                                    await onLoadMore()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .padding(.vertical, 8)
                .onAppear {
                    // Auto-load when scrolling near the bottom
                    if let onLoadMore = onLoadMore, !isLoadingMore {
                        Task {
                            await onLoadMore()
                        }
                    }
                }
            }
        }
        .navigationTitle("Prompts")
        #if os(macOS)
            .listStyle(.sidebar)
        #else
            .listStyle(.insetGrouped)
        #endif
    }
}

struct PromptRowView: View {
    let prompt: Prompt
    let isSelected: Bool
    let onToggleFavorite: () -> Void

    @Environment(\.modelContext) private var modelContext

    private func getCategoryIcon() -> String {
        // Safely access the category with a fallback
        return prompt.category.icon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(prompt.title, systemImage: getCategoryIcon())
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                if prompt.metadata.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }

                if let confidence = prompt.aiAnalysis?.categoryConfidence {
                    ConfidenceBadge(confidence: confidence)
                }
            }

            Text(prompt.content)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if !prompt.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(prompt.tags) { tag in
                            TagChip(tag: tag)
                        }
                    }
                }
            }

            HStack {
                Text(prompt.modifiedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                if prompt.metadata.viewCount > 0 {
                    Label("\(prompt.metadata.viewCount)", systemImage: "eye")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if prompt.metadata.copyCount > 0 {
                    Label("\(prompt.metadata.copyCount)", systemImage: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
        #if os(macOS)
            .contextMenu {
                contextMenuItems
            }
        #else
            .swipeActions(edge: .trailing) {
                swipeActions
            }
            .swipeActions(edge: .leading) {
                Button(action: onToggleFavorite) {
                    Label(
                        prompt.metadata.isFavorite ? "Unfavorite" : "Favorite",
                        systemImage: prompt.metadata.isFavorite ? "star.slash" : "star"
                    )
                }
                .tint(.yellow)
            }
        #endif
    }

    #if os(macOS)
        @ViewBuilder
        private var contextMenuItems: some View {
            Button("Analyze with AI", systemImage: "sparkle") {
                // Action handled by parent
            }
            #if os(macOS)
                .help("Analyze this prompt with AI for insights")
            #endif

            Button("Duplicate", systemImage: "doc.on.doc") {
                duplicatePrompt()
            }
            #if os(macOS)
                .help("Create a copy of this prompt")
            #endif

            Button("Copy Content", systemImage: "doc.on.clipboard") {
                copyContent()
            }
            #if os(macOS)
                .help("Copy prompt content to clipboard")
            #endif

            if let shortLink = prompt.shortLink {
                Button("Copy Link", systemImage: "link") {
                    copyLink(shortLink)
                }
                #if os(macOS)
                    .help("Copy shareable link to clipboard")
                #endif
            }

            Button("Export as Markdown", systemImage: "square.and.arrow.up") {
                exportPrompt()
            }
            #if os(macOS)
                .help("Export prompt as a markdown file")
            #endif

            Divider()

            Button(
                prompt.metadata.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: prompt.metadata.isFavorite ? "star.slash" : "star"
            ) {
                onToggleFavorite()
            }
            #if os(macOS)
                .help(prompt.metadata.isFavorite ? "Remove from favorites" : "Add to favorites")
            #endif

            Divider()

            Button("Delete", systemImage: "trash", role: .destructive) {
                // Deletion handled by parent
            }
            #if os(macOS)
                .help("Delete this prompt permanently")
            #endif
        }
    #endif

    #if os(iOS)
        @ViewBuilder
        private var swipeActions: some View {
            Button("Delete", systemImage: "trash", role: .destructive) {
                // Deletion handled by parent
            }
            #if os(macOS)
                .help("Delete this prompt permanently")
            #endif

            Button("Analyze", systemImage: "sparkle") {
                // Action handled by parent
            }
        }
    #endif

    private func duplicatePrompt() {
        let duplicate = Prompt(
            title: "\(prompt.title) (Copy)",
            content: prompt.content,
            category: prompt.category
        )
        duplicate.tags = prompt.tags
        modelContext.insert(duplicate)
    }

    private func copyContent() {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt.content, forType: .string)
        #else
            UIPasteboard.general.string = prompt.content
        #endif
    }

    private func copyLink(_ url: URL) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #else
            UIPasteboard.general.url = url
        #endif
    }

    private func exportPrompt() {
        #if os(macOS)
            let markdown = MarkdownParser.generateMarkdown(for: prompt)
            let filename = DragDropUtils.exportFilename(for: prompt)

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            savePanel.nameFieldStringValue = filename
            savePanel.title = "Export Prompt"
            savePanel.message = "Choose where to save the prompt"

            savePanel.begin { response in
                if response == .OK {
                    Task { @MainActor in
                        if let url = savePanel.url {
                            do {
                                try markdown.write(to: url, atomically: true, encoding: .utf8)
                            } catch {
                                // Log error - would use Logger in production
                            }
                        }
                    }
                }
            }
        #endif
    }
}

struct TagChip: View {
    let tag: Tag

    var body: some View {
        Text(tag.name)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(hex: tag.color).opacity(0.2))
            .foregroundStyle(Color(hex: tag.color))
            .clipShape(Capsule())
    }
}

struct ConfidenceBadge: View {
    let confidence: Double

    var body: some View {
        Text("\(Int(confidence * 100))%")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(confidenceColor.opacity(0.2))
            .foregroundStyle(confidenceColor)
            .clipShape(Capsule())
    }

    private var confidenceColor: Color {
        if confidence >= 0.8 {
            return .green
        } else if confidence >= 0.6 {
            return .orange
        } else {
            return .red
        }
    }
}
