import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

struct PromptListView: View {
    let promptSummaries: [PromptSummary]
    @Binding var selectedPromptID: UUID?
    let onDelete: (UUID) async -> Void
    let onToggleFavorite: (UUID) async -> Void
    let onLoadMore: (() async -> Void)?
    let hasMore: Bool
    let isLoadingMore: Bool

    @State private var deletingPromptID: UUID?

    init(
        promptSummaries: [PromptSummary],
        selectedPromptID: Binding<UUID?>,
        onDelete: @escaping (UUID) async -> Void,
        onToggleFavorite: @escaping (UUID) async -> Void,
        onLoadMore: (() async -> Void)? = nil,
        hasMore: Bool = false,
        isLoadingMore: Bool = false
    ) {
        self.promptSummaries = promptSummaries
        self._selectedPromptID = selectedPromptID
        self.onDelete = onDelete
        self.onToggleFavorite = onToggleFavorite
        self.onLoadMore = onLoadMore
        self.hasMore = hasMore
        self.isLoadingMore = isLoadingMore
    }

    var body: some View {
        List(selection: $selectedPromptID) {
            if promptSummaries.isEmpty {
                ContentUnavailableView(
                    "No Prompts",
                    systemImage: "doc.text",
                    description: Text("Create your first prompt to get started")
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(promptSummaries) { summary in
                    PromptRowView(
                        summary: summary,
                        isSelected: selectedPromptID == summary.id,
                        onToggleFavorite: {
                            Task {
                                await onToggleFavorite(summary.id)
                            }
                        }
                    )
                    .tag(summary.id)
                    #if os(iOS)
                        .onTapGesture {
                            selectedPromptID = summary.id
                        }
                    #else
                        .onTapGesture {
                            selectedPromptID = summary.id
                        }
                    #endif
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let summary = promptSummaries[index]
                        Task {
                            await onDelete(summary.id)
                        }
                    }
                }
            }

            // Load more indicator and trigger
            if hasMore && !promptSummaries.isEmpty {
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
    let summary: PromptSummary
    let isSelected: Bool
    let onToggleFavorite: () -> Void

    @Environment(\.modelContext) private var modelContext

    private func getCategoryIcon() -> String {
        // Safely access the category with a fallback
        return summary.category.icon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(summary.title, systemImage: getCategoryIcon())
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                if summary.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }

                if let confidence = summary.categoryConfidence {
                    ConfidenceBadge(confidence: confidence)
                }
            }

            Text(summary.contentPreview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if !summary.tagNames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(summary.tagNames, id: \.self) { tagName in
                            Text(tagName)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            HStack {
                Text(summary.modifiedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                if summary.viewCount > 0 {
                    Label("\(summary.viewCount)", systemImage: "eye")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if summary.copyCount > 0 {
                    Label("\(summary.copyCount)", systemImage: "doc.on.doc")
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
                        summary.isFavorite ? "Unfavorite" : "Favorite",
                        systemImage: summary.isFavorite ? "star.slash" : "star"
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

            if let shortLink = summary.shortLink {
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
                summary.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: summary.isFavorite ? "star.slash" : "star"
            ) {
                onToggleFavorite()
            }
            #if os(macOS)
                .help(summary.isFavorite ? "Remove from favorites" : "Add to favorites")
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
        // Duplication would need to be handled by the parent view
        // since PromptSummary doesn't contain full content
        // This could be passed as a callback or handled via the service layer
    }

    private func copyContent() {
        // Content copying would need to be handled by the parent view
        // since PromptSummary doesn't contain full content
        // This could be passed as a callback or handled via the service layer
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
            // Export would need to be handled by the parent view
            // since PromptSummary doesn't contain full content
            // This could be passed as a callback or handled via the service layer
        #endif
    }
}

struct TagChip: View {
    let tagDTO: TagDTO

    var body: some View {
        Text(tagDTO.name)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(hex: tagDTO.color).opacity(0.2))
            .foregroundStyle(Color(hex: tagDTO.color))
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
