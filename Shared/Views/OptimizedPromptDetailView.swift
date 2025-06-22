import Combine
import SwiftUI

/// Ultra-optimized prompt detail view with instant rendering using cached data
struct OptimizedPromptDetailView: View {
    let enhancedPrompt: EnhancedPrompt
    @Environment(\.modelContext) private var modelContext
    @State private var isEditing = false
    @State private var editedTitle: String = ""
    @State private var editedContent: String = ""
    @State private var showStats = false

    // Real-time updates
    @State private var pendingUpdates: [PromptUpdate] = []
    @State private var updateSubscription: AnyCancellable?

    // Service reference
    private let promptService: OptimizedPromptService

    init(enhancedPrompt: EnhancedPrompt, promptService: OptimizedPromptService) {
        self.enhancedPrompt = enhancedPrompt
        self.promptService = promptService
        self._editedTitle = State(initialValue: enhancedPrompt.prompt.title)
        self._editedContent = State(initialValue: enhancedPrompt.prompt.content)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header with instant stats
                headerView

                // Content with pre-rendered markdown
                contentView

                // Statistics overlay
                if showStats {
                    statsView
                        .transition(
                            .asymmetric(
                                insertion: .scale.combined(with: .opacity),
                                removal: .scale.combined(with: .opacity)
                            ))
                }
            }
            .padding()
        }
        .navigationTitle(enhancedPrompt.prompt.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        showStats.toggle()
                    }
                } label: {
                    Label("Statistics", systemImage: "chart.bar.xaxis")
                }

                Button {
                    isEditing = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            OptimizedEditView(
                prompt: enhancedPrompt.prompt,
                promptService: promptService,
                onSave: { newTitle, newContent in
                    Task {
                        if newTitle != enhancedPrompt.prompt.title {
                            try await promptService.updatePrompt(
                                enhancedPrompt.prompt,
                                field: .title,
                                newValue: newTitle
                            )
                        }
                        if newContent != enhancedPrompt.prompt.content {
                            try await promptService.updatePrompt(
                                enhancedPrompt.prompt,
                                field: .content,
                                newValue: newContent
                            )
                        }
                    }
                }
            )
        }
        .onAppear {
            setupUpdateSubscription()
        }
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                // Category with icon
                Label {
                    Text(enhancedPrompt.prompt.category.rawValue)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } icon: {
                    Image(systemName: enhancedPrompt.prompt.category.icon)
                }

                // Quick stats (instant from cache)
                if let stats = enhancedPrompt.statistics {
                    HStack(spacing: 16) {
                        StatBadge(
                            title: "Words",
                            value: "\(stats.wordCount)",
                            icon: "text.word.spacing"
                        )
                        StatBadge(
                            title: "Lines",
                            value: "\(stats.lineCount)",
                            icon: "text.alignleft"
                        )
                        StatBadge(
                            title: "Read Time",
                            value: formatReadingTime(stats.readingTime),
                            icon: "clock"
                        )
                    }
                }
            }

            Spacer()

            // Deduplication indicator
            if enhancedPrompt.contentReference.referenceCount > 1 {
                VStack(alignment: .trailing) {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.accentColor)
                    Text("\(enhancedPrompt.contentReference.referenceCount) refs")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var contentView: some View {
        Group {
            if let rendered = enhancedPrompt.renderedContent {
                // Instant display of pre-rendered content
                if rendered.isPlaceholder {
                    // Show placeholder immediately while full render happens
                    VStack(alignment: .leading, spacing: 12) {
                        Text(rendered.attributedString)
                            .textSelection(.enabled)
                            .opacity(0.8)

                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Rendering full content...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    // Full rendered content
                    Text(rendered.attributedString)
                        .textSelection(.enabled)
                        .animation(.easeInOut(duration: 0.2), value: rendered.attributedString)
                }
            } else {
                // Fallback to raw content
                Text(enhancedPrompt.prompt.content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding()
        #if os(macOS)
            .background(Color(NSColor.controlBackgroundColor))
        #else
            .background(Color(.secondarySystemBackground))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    }

    private var statsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Advanced Statistics")
                .font(.headline)

            if let stats = enhancedPrompt.statistics {
                VStack(spacing: 12) {
                    // Complexity metrics
                    ComplexityBar(
                        title: "Lexical Diversity",
                        value: stats.complexity.lexicalDiversity,
                        color: .blue
                    )
                    ComplexityBar(
                        title: "Technical Density",
                        value: stats.complexity.technicalTermRatio,
                        color: .purple
                    )
                    ComplexityBar(
                        title: "Sentence Complexity",
                        value: min(stats.complexity.avgSentenceLength / 30.0, 1.0),
                        color: .orange
                    )

                    Divider()

                    // Performance metrics
                    HStack {
                        Label("Render Time", systemImage: "timer")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if let rendered = enhancedPrompt.renderedContent {
                            Text("\(rendered.renderTime * 1000, specifier: "%.1f")ms")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(rendered.renderTime < 0.016 ? .green : .orange)
                        }
                    }
                }
            }
        }
        .padding()
        #if os(macOS)
            .background(Color(NSColor.windowBackgroundColor))
        #else
            .background(Color(.tertiarySystemBackground))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

}

// MARK: - Helper Methods

extension OptimizedPromptDetailView {
    private func setupUpdateSubscription() {
        // For now, disable update subscription due to actor isolation
        // This would need to be redesigned to work with actor isolation
        updateSubscription = nil
    }

    private func formatReadingTime(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else {
            let minutes = Int(seconds / 60)
            return "\(minutes)m"
        }
    }
}

// MARK: - Supporting Views

struct StatBadge: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .fontWeight(.medium)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

struct ComplexityBar: View {
    let title: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.2))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geometry.size.width * value, height: 8)
                        .animation(.spring(response: 0.5), value: value)
                }
            }
            .frame(height: 8)
        }
    }
}

struct OptimizedEditView: View {
    let prompt: Prompt
    let promptService: OptimizedPromptService
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var content: String
    @State private var liveStats: TextStatistics?
    @State private var statsTask: Task<Void, Never>?

    init(prompt: Prompt, promptService: OptimizedPromptService, onSave: @escaping (String, String) -> Void) {
        self.prompt = prompt
        self.promptService = promptService
        self.onSave = onSave
        self._title = State(initialValue: prompt.title)
        self._content = State(initialValue: prompt.content)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)

                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    #if os(macOS)
                        .background(Color(NSColor.controlBackgroundColor))
                    #else
                        .background(Color(.secondarySystemBackground))
                    #endif
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: content) { _, _ in
                        // Debounced stats update
                        statsTask?.cancel()
                        statsTask = Task {
                            try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
                            if !Task.isCancelled {
                                // This would use the cache engine in real implementation
                                // liveStats = await cacheEngine.getTextStats(for: newValue)
                            }
                        }
                    }

                // Live statistics
                if let stats = liveStats {
                    HStack {
                        StatBadge(title: "Words", value: "\(stats.wordCount)", icon: "text.word.spacing")
                        Spacer()
                        StatBadge(title: "Lines", value: "\(stats.lineCount)", icon: "text.alignleft")
                        Spacer()
                        StatBadge(title: "Chars", value: "\(stats.characterCount)", icon: "character")
                    }
                    .padding(.horizontal)
                }
            }
            .padding()
            .navigationTitle("Edit Prompt")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(title, content)
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
            }
        }
    }
}
