import os
import SwiftUI

struct PromptDetailView: View {
    let promptID: UUID
    let promptService: PromptService?
    @Environment(AppState.self) var appState

    @State private var promptDetail: PromptDetail?
    @State private var isLoading = true
    @State private var loadError: Error?
    @State private var isEditing = false
    @State private var editedTitle: String = ""
    @State private var editedContent: String = ""
    @State private var editedCategory: Category = .prompts
    @State private var isAnalyzing = false
    @State private var showingVersionHistory = false
    @State private var isSaving = false

    // Lazy loading states
    @State private var content: String?
    @State private var isLoadingContent = false
    @State private var contentLoadError: Error?

    private let logger = Logger(subsystem: "com.prompt.app", category: "PromptDetailView")

    init(
        promptID: UUID,
        promptService: PromptService? = nil
    ) {
        self.promptID = promptID
        self.promptService = promptService
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
                        Text(promptDetail?.title ?? "Loading...")
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
                            Label(promptDetail?.category.rawValue ?? "", systemImage: promptDetail?.category.icon ?? "")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.tertiary)
                                .clipShape(Capsule())
                        }

                        Spacer()

                        Text("Modified \(promptDetail?.modifiedAt.formatted() ?? "")")
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
                    Group {
                        if let content = content {
                            MarkdownView(
                                content: content,
                                promptId: promptID,
                                promptService: promptService
                            )
                        } else if isLoadingContent {
                            VStack {
                                ProgressView("Loading content...")
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .padding()
                            }
                            .frame(maxWidth: .infinity, minHeight: 200)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            ContentPreviewView(
                                preview: promptDetail.map { String($0.content.prefix(200)) } ?? "No preview available"
                            )
                            .onTapGesture {
                                Task {
                                    await loadContent()
                                }
                            }
                        }
                    }
                }

                // Tags
                if !(promptDetail?.tags.isEmpty ?? true) || isEditing {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tags")
                            .font(.headline)

                        FlowLayout(spacing: 8) {
                            ForEach(promptDetail?.tags ?? []) { tag in
                                TagChip(tagDTO: tag)
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
                if let analysis = promptDetail?.aiAnalysis {
                    AIAnalysisView(analysisDTO: analysis)
                }

                // File Statistics
                if let detail = promptDetail {
                    FileStatsView(promptDetail: detail)
                }

                // Metadata
                if let metadata = promptDetail?.metadata {
                    MetadataView(metadataDTO: metadata)
                }

                // Version History
                if let versionCount = promptDetail?.versionCount, versionCount > 0 {
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

                        if let versionCount = promptDetail?.versionCount, versionCount > 0 {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(versionCount) version\(versionCount == 1 ? "" : "s")")
                                    .font(.subheadline)
                                Text("View history for details")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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

                if promptDetail?.metadata.isFavorite == true {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
            }
        }
        .sheet(isPresented: $showingVersionHistory) {
            if let promptID = promptDetail?.id {
                VersionHistoryView(promptID: promptID, promptService: promptService)
            }
        }
        .task {
            await loadPromptDetail()
            // Auto-load content for external storage
            // Load content if needed
            await loadContent()
        }
        .onChange(of: promptDetail) { newValue in
            if let detail = newValue {
                editedTitle = detail.title
                editedCategory = detail.category
                // Load content
                editedContent = detail.content
                content = detail.content
            }
        }
    }

}

// MARK: - Private Methods

extension PromptDetailView {
    private func saveChanges() {
        guard let service = promptService else { return }

        Task {
            isSaving = true
            do {
                // Update each field that changed
                if editedTitle != promptDetail?.title {
                    _ = try await service.updatePrompt(
                        id: promptID,
                        field: .title,
                        newValue: editedTitle
                    )
                }

                if editedContent != promptDetail?.content {
                    _ = try await service.updatePrompt(
                        id: promptID,
                        field: .content,
                        newValue: editedContent
                    )
                }

                if editedCategory != promptDetail?.category {
                    _ = try await service.updatePrompt(
                        id: promptID,
                        field: .category,
                        newValue: editedCategory.rawValue
                    )
                }

                // Reload the detail
                await loadPromptDetail()
                isEditing = false
            } catch {
                logger.error("Failed to save changes: \(error)")
            }
            isSaving = false
        }
    }

    private func loadPromptDetail() async {
        isLoading = true
        loadError = nil

        do {
            if let service = promptService {
                promptDetail = try await service.getPromptDetail(id: promptID)
            }
        } catch {
            loadError = error
            logger.error("Failed to load prompt detail: \(error)")
        }

        isLoading = false
    }

    private func loadContent() async {
        guard let service = promptService else { return }

        isLoadingContent = true
        contentLoadError = nil

        do {
            // Load content directly by ID without passing Prompt across actor boundaries
            let loadedContent = try await service.loadContentForPrompt(id: promptID)
            content = loadedContent
            editedContent = loadedContent
        } catch {
            contentLoadError = error
            logger.error("Failed to load content: \(error)")
        }

        isLoadingContent = false
    }

    private func onCopy() {
        // Use lazy-loaded content if available, otherwise load it first
        guard let contentToCopy = content else {
            Task {
                await loadContent()
                if let loadedContent = content {
                    copyToClipboard(loadedContent)
                }
            }
            return
        }

        copyToClipboard(contentToCopy)

        // Increment copy count
        if let service = promptService {
            Task {
                // Note: This would need a method to increment copy count
                // For now, we'll just reload to get updated metadata
                await loadPromptDetail()
            }
        }
    }

    private func onAnalyze() async {
        guard let service = promptService else { return }

        isAnalyzing = true
        do {
            // Note: This would need an analyze method in the service
            // For now, just reload the detail which might have analysis
            await loadPromptDetail()
        } catch {
            logger.error("Failed to analyze prompt: \(error)")
        }
        isAnalyzing = false
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #else
            UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Supporting Views

struct AIAnalysisView: View {
    let analysisDTO: AIAnalysisDTO
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
                        ConfidenceBadge(confidence: analysisDTO.categoryConfidence)
                    }

                    // Summary
                    if let summary = analysisDTO.summary {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Summary")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(summary)
                                .font(.caption)
                        }
                    }

                    // Suggested Tags
                    if !analysisDTO.suggestedTags.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Suggested Tags")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            FlowLayout(spacing: 4) {
                                ForEach(analysisDTO.suggestedTags, id: \.self) { tagName in
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
                    if !analysisDTO.enhancementSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Enhancement Suggestions")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            ForEach(analysisDTO.enhancementSuggestions, id: \.self) { suggestion in
                                HStack(alignment: .top, spacing: 4) {
                                    Text("•")
                                        .font(.caption)
                                    Text(suggestion)
                                        .font(.caption)
                                }
                            }
                        }
                    }

                    Text("Analyzed \(analysisDTO.analyzedAt.formatted())")
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
    let metadataDTO: MetadataDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statistics")
                .font(.headline)

            HStack(spacing: 20) {
                VStack(alignment: .leading) {
                    Text("Views")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(metadataDTO.viewCount)")
                        .font(.title3)
                        .bold()
                }

                VStack(alignment: .leading) {
                    Text("Copies")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(metadataDTO.copyCount)")
                        .font(.title3)
                        .bold()
                }

                if let lastViewed = metadataDTO.lastViewedAt {
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
    let promptID: UUID
    let promptService: PromptService?
    @State private var versions: [PromptVersionSummary] = []
    @State private var isLoading = true
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List(versions) { version in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(version.formattedVersionNumber)
                            .font(.headline)
                        Spacer()
                        Text(version.formattedCreatedAt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(version.displayDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(version.contentPreview)
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
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
        }
        .task {
            await loadVersions()
        }
    }

    private func loadVersions() async {
        guard let service = promptService else { return }
        isLoading = true

        // Note: This would need a method to fetch version summaries
        // For now, we'll simulate with empty array
        // In a real implementation:
        // versions = try? await service.getPromptVersionSummaries(promptID: promptID)

        versions = []
        isLoading = false
    }
}

// Content Preview View for lazy loading
struct ContentPreviewView: View {
    let preview: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Content Preview")
                    .font(.headline)
                Spacer()
                Image(systemName: "hand.tap")
                    .foregroundStyle(.secondary)
            }

            Text(preview)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(5)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("Tap to load full content")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
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
