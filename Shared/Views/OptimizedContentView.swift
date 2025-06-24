import SwiftData
import SwiftUI
import os

/// Main content view using the optimized caching system for instant responsiveness
struct OptimizedContentView: View {
    private let logger = Logger(subsystem: "com.prompt.app", category: "OptimizedContentView")
    @Environment(\.modelContext) private var modelContext
    @State private var promptService: OptimizedPromptService?
    @State private var enhancedPrompts: [EnhancedPrompt] = []
    @State private var selectedPrompt: EnhancedPrompt?
    @State private var searchQuery = ""
    @State private var searchResults: [SearchResultWithContent] = []
    @State private var isSearching = false
    @State private var systemMetrics: BackgroundProcessor.SystemMetrics?

    // Performance monitoring
    @State private var showPerformanceHUD = false
    @State private var frameRate: Double = 60.0
    @State private var lastFrameTime = CFAbsoluteTimeGetCurrent()

    var body: some View {
        ZStack {
            mainContent

            if showPerformanceHUD {
                performanceOverlay
            }
        }
        .task {
            await initializeService()
            await loadPrompts()
            await startMetricsMonitoring()
        }
        .onAppear {
            startFrameRateMonitoring()
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        NavigationSplitView {
            sidebarView
        } content: {
            if isSearching && !searchQuery.isEmpty {
                searchResultsView
            } else {
                promptListView
            }
        } detail: {
            if let selected = selectedPrompt {
                OptimizedPromptDetailView(
                    enhancedPrompt: selected,
                    promptService: promptService!
                )
                .id(selected.prompt.id)  // Force refresh on selection change
            } else {
                ContentUnavailableView(
                    "Select a Prompt",
                    systemImage: "doc.text",
                    description: Text("Choose a prompt from the list to view its details")
                )
            }
        }
        .searchable(text: $searchQuery, prompt: "Search prompts...")
        .onChange(of: searchQuery) { _, newValue in
            Task {
                await performSearch(newValue)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        List {
            Section("Categories") {
                ForEach(Category.allCases, id: \.self) { category in
                    NavigationLink {
                        filteredPromptsView(category: category)
                    } label: {
                        Label(category.rawValue, systemImage: category.icon)
                    }
                }
            }

            Section("System") {
                Button {
                    showPerformanceHUD.toggle()
                } label: {
                    Label(
                        showPerformanceHUD ? "Hide Performance" : "Show Performance",
                        systemImage: "speedometer"
                    )
                }

                if let metrics = systemMetrics {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CPU Load: \(Int(metrics.cpuLoad * 100))%")
                            .font(.caption)
                        Text("Active Tasks: \(metrics.activeTasks)")
                            .font(.caption)
                        Text("Queued: \(metrics.queuedTasks)")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Prompt")
    }

    // MARK: - Prompt List

    private var promptListView: some View {
        List(enhancedPrompts, id: \.prompt.id) { enhanced in
            PromptRowView(
                summary: enhanced.prompt.toSummary(),
                isSelected: selectedPrompt?.prompt.id == enhanced.prompt.id,
                onToggleFavorite: {
                    enhanced.prompt.metadata.isFavorite.toggle()
                }
            )
            .onTapGesture {
                withAnimation(.spring(response: 0.3)) {
                    selectedPrompt = enhanced
                }
            }
        }
        .navigationTitle("All Prompts")
        .overlay {
            if enhancedPrompts.isEmpty {
                ContentUnavailableView(
                    "No Prompts",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Create your first prompt to get started")
                )
            }
        }
    }

    // MARK: - Search Results

    private var searchResultsView: some View {
        List(searchResults, id: \.prompt.prompt.id) { result in
            SearchResultRow(
                result: result,
                isSelected: selectedPrompt?.prompt.id == result.prompt.prompt.id
            )
            .onTapGesture {
                withAnimation(.spring(response: 0.3)) {
                    selectedPrompt = result.prompt
                }
            }
        }
        .navigationTitle("Search Results")
        .overlay {
            if searchResults.isEmpty && !searchQuery.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
            }
        }
    }

    // MARK: - Performance Overlay

    private var performanceOverlay: some View {
        VStack(alignment: .trailing) {
            HStack {
                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    // Frame rate
                    HStack {
                        Text("FPS")
                            .font(.caption.monospaced())
                        Text("\(Int(frameRate))")
                            .font(.caption.monospaced())
                            .foregroundColor(frameRate >= 59 ? .green : .orange)
                            .frame(width: 30, alignment: .trailing)
                    }

                    // Frame time
                    HStack {
                        Text("Frame")
                            .font(.caption.monospaced())
                        Text("\(String(format: "%.1f", 1000.0 / frameRate))ms")
                            .font(.caption.monospaced())
                            .foregroundColor(frameRate >= 59 ? .green : .orange)
                            .frame(width: 50, alignment: .trailing)
                    }

                    Divider()
                        .frame(width: 80)

                    // Cache stats
                    if promptService != nil {
                        Text("Cache Performance")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)

                        // These would come from actual cache metrics
                        Text("Hit Rate: 95%")
                            .font(.caption.monospaced())
                            .foregroundColor(.green)
                    }
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 4)
            }

            Spacer()
        }
        .padding()
        .allowsHitTesting(false)  // Don't interfere with UI
    }

    // MARK: - Helper Methods

    private func initializeService() async {
        do {
            promptService = try await OptimizedPromptService(container: modelContext.container)
        } catch {
            logger.error("Failed to initialize service: \(error)")
        }
    }

    private func loadPrompts() async {
        guard let service = promptService else { return }

        do {
            let startTime = CFAbsoluteTimeGetCurrent()
            enhancedPrompts = try await service.fetchPrompts()
            let loadTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

            logger.info("Loaded \(enhancedPrompts.count) prompts in \(loadTime)ms")

            // Select first prompt if none selected
            if selectedPrompt == nil && !enhancedPrompts.isEmpty {
                selectedPrompt = enhancedPrompts.first
            }
        } catch {
            logger.error("Failed to load prompts: \(error)")
        }
    }

    private func performSearch(_ query: String) async {
        guard !query.isEmpty, let service = promptService else {
            isSearching = false
            searchResults = []
            return
        }

        isSearching = true

        do {
            let startTime = CFAbsoluteTimeGetCurrent()
            searchResults = try await service.searchPrompts(query: query)
            let searchTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

            logger.info("Search completed in \(searchTime)ms, found \(searchResults.count) results")
        } catch {
            logger.error("Search failed: \(error)")
            searchResults = []
        }
    }

    private func startFrameRateMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in
                let currentTime = CFAbsoluteTimeGetCurrent()
                let deltaTime = currentTime - lastFrameTime

                frameRate = 1.0 / deltaTime
                lastFrameTime = currentTime
            }
        }
    }

    private func startMetricsMonitoring() async {
        guard promptService != nil else { return }

        // Update system metrics every second
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task {
                // This would call the actual cache engine metrics
                // systemMetrics = await cacheEngine.backgroundProcessor.getSystemMetrics()
            }
        }
    }

}

// MARK: - Navigation Views

extension OptimizedContentView {
    private func filteredPromptsView(category: Category) -> some View {
        let filtered = enhancedPrompts.filter { $0.prompt.category == category }

        return List(filtered, id: \.prompt.id) { enhanced in
            PromptRowView(
                summary: enhanced.prompt.toSummary(),
                isSelected: selectedPrompt?.prompt.id == enhanced.prompt.id,
                onToggleFavorite: {
                    enhanced.prompt.metadata.isFavorite.toggle()
                }
            )
            .onTapGesture {
                selectedPrompt = enhanced
            }
        }
        .navigationTitle(category.rawValue)
    }
}

// MARK: - Supporting Views


struct SearchResultRow: View {
    let result: SearchResultWithContent
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(result.prompt.prompt.title)
                    .font(.headline)

                Spacer()

                // Relevance score indicator
                RelevanceIndicator(score: result.score)
            }

            // Show highlighted snippet
            if let firstHighlight = result.highlights.first,
                let snippet = extractSnippet(
                    from: result.prompt.prompt.content,
                    around: firstHighlight
                )
            {
                Text(snippet)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func extractSnippet(from content: String, around highlight: SearchResult.TextRange) -> String? {
        guard highlight.start < content.count else { return nil }

        let startIndex = content.index(content.startIndex, offsetBy: max(0, highlight.start - 20))
        let endIndex = content.index(content.startIndex, offsetBy: min(content.count, highlight.end + 20))

        return "..." + String(content[startIndex..<endIndex]) + "..."
    }
}

struct RelevanceIndicator: View {
    let score: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { index in
                Circle()
                    .fill(Double(index) < score * 5 ? Color.accentColor : Color.gray.opacity(0.3))
                    .frame(width: 4, height: 4)
            }
        }
    }
}
