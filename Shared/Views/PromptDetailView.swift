import os
import SwiftUI

struct PromptDetailView: View {
    @Binding var prompt: Prompt
    let promptService: PromptService?
    let onUpdate: (String, String, Category) async -> Void
    let onAnalyze: () async -> Void
    let onCopy: () -> Void

    @State private var isEditing = false
    @State private var editedTitle: String
    @State private var editedContent: String
    @State private var editedCategory: Category
    @State private var isAnalyzing = false
    @State private var showingVersionHistory = false

    private let logger = Logger(subsystem: "com.prompt.app", category: "PromptDetailView")

    init(
        prompt: Binding<Prompt>,
        promptService: PromptService? = nil,
        onUpdate: @escaping (String, String, Category) async -> Void,
        onAnalyze: @escaping () async -> Void,
        onCopy: @escaping () -> Void
    ) {
        self._prompt = prompt
        self.promptService = promptService
        self.onUpdate = onUpdate
        self.onAnalyze = onAnalyze
        self.onCopy = onCopy
        self._editedTitle = State(initialValue: prompt.wrappedValue.title)
        self._editedContent = State(initialValue: prompt.wrappedValue.content)
        self._editedCategory = State(initialValue: prompt.wrappedValue.category)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    if isEditing {
                        TextField("Title", text: $editedTitle)
                            .textFieldStyle(.roundedBorder)
                            .font(.title2)
                    } else {
                        Text(prompt.title)
                            .font(.title2)
                            .bold()
                            .textSelection(.enabled)
                    }

                    HStack {
                        if isEditing {
                            Picker("Category", selection: $editedCategory) {
                                ForEach(Category.allCases, id: \.self) { category in
                                    Label(category.rawValue, systemImage: category.icon)
                                        .tag(category)
                                }
                            }
                            .pickerStyle(.menu)
                        } else {
                            Label(prompt.category.rawValue, systemImage: prompt.category.icon)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.tertiary)
                                .clipShape(Capsule())
                        }

                        Spacer()

                        Text("Modified \(prompt.modifiedAt.formatted())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Content
                if isEditing {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Content")
                            .font(.headline)

                        TextEditor(text: $editedContent)
                            .font(.body)
                            .frame(minHeight: 200)
                            .padding(8)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    MarkdownView(
                        content: prompt.content,
                        promptId: prompt.id,
                        promptService: promptService
                    )
                }

                // Tags
                if !prompt.tags.isEmpty || isEditing {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tags")
                            .font(.headline)

                        FlowLayout(spacing: 8) {
                            ForEach(prompt.tags) { tag in
                                TagChip(tag: tag)
                            }

                            if isEditing {
                                Button(
                                    action: {
                                        // Add tag functionality
                                    },
                                    label: {
                                        Label("Add Tag", systemImage: "plus")
                                            .font(.caption)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(.tertiary)
                                            .clipShape(Capsule())
                                    }
                                )
                                #if os(macOS)
                                    .help("Add a new tag to this prompt")
                                #endif
                            }
                        }
                    }
                }

                // AI Analysis
                if let analysis = prompt.aiAnalysis {
                    AIAnalysisView(analysis: analysis)
                }

                // File Statistics
                FileStatsView(prompt: prompt)

                // Metadata
                MetadataView(metadata: prompt.metadata)

                // Version History
                if !prompt.versions.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Version History")
                                .font(.headline)

                            Spacer()

                            Button("Show All") {
                                showingVersionHistory = true
                            }
                            .font(.caption)
                            #if os(macOS)
                                .help("View complete version history")
                            #endif
                        }

                        if let latestVersion = prompt.versions.last {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Version \(latestVersion.versionNumber)")
                                    .font(.subheadline)
                                Text(latestVersion.createdAt.formatted())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let description = latestVersion.changeDescription {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.tertiary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(isEditing ? "Edit Prompt" : "Prompt Details")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "Save" : "Edit") {
                    if isEditing {
                        saveChanges()
                    }
                    isEditing.toggle()
                }
                #if os(macOS)
                    .help(isEditing ? "Save changes to this prompt" : "Edit this prompt")
                #endif
            }

            ToolbarItemGroup(placement: .secondaryAction) {
                Button("Copy", systemImage: "doc.on.clipboard") {
                    onCopy()
                }
                #if os(macOS)
                    .help("Copy prompt content to clipboard")
                #endif

                Button("Analyze", systemImage: "sparkle") {
                    Task {
                        isAnalyzing = true
                        await onAnalyze()
                        isAnalyzing = false
                    }
                }
                .disabled(isAnalyzing)
                #if os(macOS)
                    .help("Analyze this prompt with AI for insights and suggestions")
                #endif

                if prompt.metadata.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
            }
        }
        .sheet(isPresented: $showingVersionHistory) {
            VersionHistoryView(versions: prompt.versions)
        }
    }

}

// MARK: - Private Methods

extension PromptDetailView {
    private func saveChanges() {
        Task {
            await onUpdate(editedTitle, editedContent, editedCategory)
            prompt.title = editedTitle
            prompt.content = editedContent
            prompt.category = editedCategory
        }
    }
}

// MARK: - Supporting Views

struct AIAnalysisView: View {
    let analysis: AIAnalysis
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI Analysis", systemImage: "sparkle")
                    .font(.headline)

                Spacer()

                Button(
                    action: { isExpanded.toggle() },
                    label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                )
                #if os(macOS)
                    .help(isExpanded ? "Collapse AI analysis" : "Expand AI analysis")
                #endif
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    // Confidence
                    HStack {
                        Text("Category Confidence")
                            .font(.subheadline)
                        Spacer()
                        ConfidenceBadge(confidence: analysis.categoryConfidence)
                    }

                    // Summary
                    if let summary = analysis.summary {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Summary")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(summary)
                                .font(.caption)
                        }
                    }

                    // Suggested Tags
                    if !analysis.suggestedTags.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Suggested Tags")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            FlowLayout(spacing: 4) {
                                ForEach(analysis.suggestedTags, id: \.self) { tagName in
                                    Text(tagName)
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.2))
                                        .foregroundStyle(.blue)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }

                    // Enhancement Suggestions
                    if !analysis.enhancementSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Enhancement Suggestions")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            ForEach(analysis.enhancementSuggestions, id: \.self) { suggestion in
                                HStack(alignment: .top, spacing: 4) {
                                    Text("•")
                                        .font(.caption)
                                    Text(suggestion)
                                        .font(.caption)
                                }
                            }
                        }
                    }

                    Text("Analyzed \(analysis.analyzedAt.formatted())")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct MetadataView: View {
    let metadata: PromptMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statistics")
                .font(.headline)

            HStack(spacing: 20) {
                VStack(alignment: .leading) {
                    Text("Views")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(metadata.viewCount)")
                        .font(.title3)
                        .bold()
                }

                VStack(alignment: .leading) {
                    Text("Copies")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(metadata.copyCount)")
                        .font(.title3)
                        .bold()
                }

                if let lastViewed = metadata.lastViewedAt {
                    VStack(alignment: .leading) {
                        Text("Last Viewed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(lastViewed.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                    }
                }
            }
        }
    }
}

struct VersionHistoryView: View {
    let versions: [PromptVersion]
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List(versions) { version in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Version \(version.versionNumber)")
                            .font(.headline)
                        Spacer()
                        Text(version.createdAt.formatted())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let description = version.changeDescription {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(version.title)
                            .font(.subheadline)
                            .bold()
                        Text(version.content)
                            .font(.caption)
                            .lineLimit(3)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Version History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    #if os(macOS)
                        .help("Close version history")
                    #endif
                }
            }
        }
    }
}

// Flow Layout for tags
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            subviews: subviews,
            spacing: spacing
        )
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
        )
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: result.positions[index].x + bounds.minX,
                    y: result.positions[index].y + bounds.minY),
                proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var xPos: CGFloat = 0
            var yPos: CGFloat = 0
            var maxHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if xPos + size.width > maxWidth && xPos > 0 {
                    xPos = 0
                    yPos += maxHeight + spacing
                    maxHeight = 0
                }
                positions.append(CGPoint(x: xPos, y: yPos))
                xPos += size.width + spacing
                maxHeight = max(maxHeight, size.height)
            }

            self.size = CGSize(width: maxWidth, height: yPos + maxHeight)
        }
    }
}
