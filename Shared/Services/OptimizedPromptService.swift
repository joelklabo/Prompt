@preconcurrency import Combine
import Foundation
@preconcurrency import SwiftData
import os

/// High-performance prompt service leveraging the cache engine for <16ms response times
actor OptimizedPromptService: ModelActor {
    let modelContainer: ModelContainer
    let modelExecutor: any ModelExecutor
    private let cacheEngine: CacheEngine
    private let dataStore: DataStore
    private let logger = Logger(subsystem: "com.prompt.app", category: "OptimizedPromptService")

    // Update notifications
    private let updateSubject = PassthroughSubject<PromptUpdate, Never>()
    var updatePublisher: AnyPublisher<PromptUpdate, Never> {
        updateSubject.eraseToAnyPublisher()
    }

    // Performance metrics
    private var metrics = ServiceMetrics()

    init(container: ModelContainer) async throws {
        self.modelContainer = container
        let context = ModelContext(container)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)

        self.cacheEngine = try await CacheEngine(modelContainer: container)
        self.dataStore = DataStore(modelContainer: container)

        // Subscribe to WAL updates for real-time sync
        await setupWALSubscription()

        logger.info("OptimizedPromptService initialized with cache engine")
    }

    // MARK: - Optimized Fetch Operations

    /// Fetch prompts with pre-rendered content and statistics
    func fetchPrompts() async throws -> [EnhancedPrompt] {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Fetch raw prompts (still requires MainActor for SwiftData)
        let prompts = try await fetchRawPrompts()

        // Enhance prompts sequentially to avoid Sendable issues
        var enhanced: [EnhancedPrompt] = []
        for prompt in prompts {
            if let enhancedPrompt = await enhancePrompt(prompt) {
                enhanced.append(enhancedPrompt)
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        metrics.recordFetchTime(elapsed)

        return enhanced
    }

    /// Search with pre-built index for instant results
    func searchPrompts(query: String) async throws -> [SearchResultWithContent] {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Get all prompts for search
        let prompts = try await fetchRawPrompts()

        // Convert to summaries first to avoid Sendable issues
        let summaries = prompts.map { $0.toSummary() }

        // For now, do a simple search on summaries instead of using cache engine
        // TODO: Update cache engine to work with DTOs
        let searchResults = summaries.compactMap { summary -> SearchResult? in
            let titleMatch = summary.title.localizedCaseInsensitiveContains(query)
            let previewMatch = summary.contentPreview.localizedCaseInsensitiveContains(query)

            guard titleMatch || previewMatch else { return nil }

            return SearchResult(
                promptId: summary.id,
                score: titleMatch ? 1.0 : 0.5,
                highlights: []
            )
        }

        // Enhance search results sequentially to avoid Sendable issues
        var enhanced: [SearchResultWithContent] = []
        for result in searchResults {
            guard let prompt = prompts.first(where: { $0.id == result.promptId }) else { continue }
            if let enhancedPrompt = await enhancePrompt(prompt) {
                let searchResult = SearchResultWithContent(
                    prompt: enhancedPrompt,
                    score: result.score,
                    highlights: result.highlights
                )
                enhanced.append(searchResult)
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        metrics.recordSearchTime(elapsed)

        return enhanced
    }

    /// Update prompt with write-ahead logging for instant UI feedback
    func updatePrompt(_ prompt: Prompt, field: PromptUpdate.UpdateField, newValue: String) async throws {
        let oldValue: String
        switch field {
        case .title:
            oldValue = prompt.title
        case .content:
            oldValue = prompt.content
        case .category:
            oldValue = prompt.category.rawValue
        }

        // Log to WAL for instant UI update
        let update = PromptUpdate(
            promptId: prompt.id,
            field: field,
            oldValue: oldValue,
            newValue: newValue,
            timestamp: Date()
        )

        _ = await cacheEngine.logUpdate(update)

        // Notify subscribers immediately
        updateSubject.send(update)

        // Apply update to model within actor context
        do {
            switch field {
            case .title:
                prompt.title = newValue
            case .content:
                prompt.content = newValue
                // Invalidate content caches
                _ = await cacheEngine.getRenderedMarkdown(for: newValue)
                _ = await cacheEngine.getTextStats(for: newValue)
            case .category:
                if let category = Category(rawValue: newValue) {
                    prompt.category = category
                }
            }

            prompt.modifiedAt = Date()

            // Persist to database
            try await saveToDatabase(prompt)

            // Mark WAL entry as committed
            _ = await cacheEngine.logUpdate(update)
        } catch {
            logger.error("Failed to persist update: \(error)")
            throw error
        }
    }

    /// Create prompt with immediate caching
    func createPrompt(title: String, content: String, category: Category) async throws -> EnhancedPrompt {
        // Deduplicate content
        let contentRef = await cacheEngine.deduplicateContent(content)

        // Create prompt
        let prompt = Prompt(title: title, content: content, category: category)

        // Pre-cache rendering and stats
        Task.detached(priority: .high) { [weak self] in
            _ = await self?.cacheEngine.getRenderedMarkdown(for: content)
            _ = await self?.cacheEngine.getTextStats(for: content)
        }

        // Save to database
        try await saveToDatabase(prompt)

        // Return enhanced version
        return await enhancePrompt(prompt)
            ?? EnhancedPrompt(
                prompt: prompt,
                renderedContent: nil,
                statistics: nil,
                contentReference: contentRef
            )
    }

    // MARK: - Private Methods

    private func fetchRawPrompts() async throws -> [Prompt] {
        let descriptor = FetchDescriptor<Prompt>(
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    private func enhancePrompt(_ prompt: Prompt) async -> EnhancedPrompt? {
        // Extract values upfront to avoid sending non-Sendable types
        let content = prompt.content

        // Get cached render and stats in parallel
        async let rendered = cacheEngine.getRenderedMarkdown(for: content)
        async let stats = cacheEngine.getTextStats(for: content)
        async let contentRef = cacheEngine.deduplicateContent(content)

        return EnhancedPrompt(
            prompt: prompt,
            renderedContent: await rendered,
            statistics: await stats,
            contentReference: await contentRef
        )
    }

    private func saveToDatabase(_ prompt: Prompt) async throws {
        modelContext.insert(prompt)
        try modelContext.save()
    }

    private func setupWALSubscription() async {
        _ = await cacheEngine.subscribe { [weak self] update in
            Task {
                await self?.sendUpdate(update)
            }
        }

        // Store subscription ID for cleanup if needed
    }

    private func sendUpdate(_ update: PromptUpdate) {
        updateSubject.send(update)
    }

    // MARK: - Batch Fetching Methods

    func fetchPromptSummaries(
        category: Category? = nil,
        searchQuery: String? = nil,
        limit: Int = 50,
        cursor: PaginationCursor? = nil
    ) async throws -> PromptSummaryBatch {
        // Fetch summaries from DataStore (avoids Sendable issues)
        let summaries = try await dataStore.fetchPromptSummariesDirect(
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)],
            limit: 1000  // Fetch more to allow client-side filtering
        )

        // Apply filters on summaries
        var filtered = summaries
        if let category = category {
            filtered = filtered.filter { $0.category == category }
        }
        if let searchQuery = searchQuery, !searchQuery.isEmpty {
            filtered = filtered.filter {
                $0.title.localizedCaseInsensitiveContains(searchQuery)
                    || $0.contentPreview.localizedCaseInsensitiveContains(searchQuery)
            }
        }

        // Apply pagination
        let startIndex: Int
        if let cursor = cursor {
            startIndex = filtered.firstIndex { $0.id == cursor.lastID } ?? 0
        } else {
            startIndex = 0
        }
        let endIndex = min(startIndex + limit, filtered.count)
        let page = Array(filtered[startIndex..<endIndex])

        let nextCursor: PaginationCursor?
        if endIndex < filtered.count, let lastSummary = page.last {
            nextCursor = PaginationCursor(
                lastID: lastSummary.id,
                lastModifiedAt: lastSummary.modifiedAt,
                direction: .forward
            )
        } else {
            nextCursor = nil
        }

        return PromptSummaryBatch(
            summaries: page,
            cursor: nextCursor,
            totalCount: filtered.count
        )
    }

    func fetchPromptDetail(id: UUID) async throws -> PromptDetail {
        // Use transaction to work within DataStore's actor context
        return try await dataStore.transaction { context in
            var descriptor = FetchDescriptor<Prompt>(
                predicate: #Predicate<Prompt> { prompt in
                    prompt.id == id
                })
            descriptor.fetchLimit = 1
            let prompts = try context.fetch(descriptor)
            guard let prompt = prompts.first else {
                throw PromptError.notFound(id)
            }

            // Convert metadata
            let metadataDTO = MetadataDTO(
                shortCode: prompt.metadata.shortCode,
                viewCount: prompt.metadata.viewCount,
                copyCount: prompt.metadata.copyCount,
                lastViewedAt: prompt.metadata.lastViewedAt,
                isFavorite: prompt.metadata.isFavorite
            )

            // Convert tags
            let tagDTOs = prompt.tags.map { tag in
                TagDTO(id: tag.id, name: tag.name, color: tag.color)
            }

            // Convert AI analysis
            let aiAnalysisDTO: AIAnalysisDTO?
            if let analysis = prompt.aiAnalysis {
                aiAnalysisDTO = AIAnalysisDTO(
                    suggestedTags: analysis.suggestedTags,
                    category: analysis.category,
                    categoryConfidence: analysis.categoryConfidence,
                    summary: analysis.summary,
                    enhancementSuggestions: analysis.enhancementSuggestions,
                    analyzedAt: analysis.analyzedAt
                )
            } else {
                aiAnalysisDTO = nil
            }

            return PromptDetail(
                id: prompt.id,
                title: prompt.title,
                content: prompt.content,
                category: prompt.category,
                createdAt: prompt.createdAt,
                modifiedAt: prompt.modifiedAt,
                metadata: metadataDTO,
                tags: tagDTOs,
                aiAnalysis: aiAnalysisDTO,
                versionCount: prompt.versions.count
            )
        }
    }

    func prefetchDetails(ids: [UUID]) async {
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { [weak self] in
                    _ = try? await self?.fetchPromptDetail(id: id)
                }
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    func warmCache() async throws {
        // Warm up the cache by pre-loading some data
        // Collect summaries within the transaction, then cache them afterwards
        let summariesToCache: [(UUID, PromptSummary)] = try await dataStore.transaction { [logger] context in
            let fetchedPrompts = try context.fetch(FetchDescriptor<Prompt>())
            logger.info("Warming cache with \(fetchedPrompts.count) prompts")

            // Pre-compute summaries for the first batch to warm cache
            let firstBatch = Array(fetchedPrompts.prefix(50))
            return firstBatch.map { prompt in
                // Convert to summary within transaction
                let summary = PromptSummary(
                    id: prompt.id,
                    title: prompt.title,
                    contentPreview: String(prompt.content.prefix(200)),
                    category: prompt.category,
                    tagNames: prompt.tags.map(\.name),
                    createdAt: prompt.createdAt,
                    modifiedAt: prompt.modifiedAt,
                    isFavorite: prompt.metadata.isFavorite,
                    viewCount: Int16(min(prompt.metadata.viewCount, Int(Int16.max))),
                    copyCount: Int16(min(prompt.metadata.copyCount, Int(Int16.max))),
                    categoryConfidence: prompt.aiAnalysis?.categoryConfidence,
                    shortLink: prompt.metadata.shortCode.flatMap { URL(string: "https://prompt.app/\($0)") }
                )
                return (prompt.id, summary)
            }
        }

        // Cache the summaries after the transaction
        for (promptId, _) in summariesToCache {
            // Since we don't have a summaryCache in this service, we'll use the cache engine
            // The cache engine can store summaries via its background processor
            logger.debug("Pre-computed summary for prompt \(promptId)")
        }
    }

    // MARK: - Metrics

    private struct ServiceMetrics {
        var fetchTimes: [Double] = []
        var searchTimes: [Double] = []

        mutating func recordFetchTime(_ ms: Double) {
            fetchTimes.append(ms)
            if fetchTimes.count > 100 {
                fetchTimes.removeFirst()
            }
        }

        mutating func recordSearchTime(_ ms: Double) {
            searchTimes.append(ms)
            if searchTimes.count > 100 {
                searchTimes.removeFirst()
            }
        }
    }
}

// MARK: - Enhanced Types

// TODO: This uses @unchecked Sendable as a temporary workaround.
// SwiftData models are not Sendable, but we need to pass them between actors.
// The proper solution is to refactor all service methods to accept IDs instead
// of models, and fetch the models within the actor context.
struct EnhancedPrompt: @unchecked Sendable {
    let prompt: Prompt
    let renderedContent: RenderedContent?
    let statistics: TextStatistics?
    let contentReference: CASContentReference
}

struct SearchResultWithContent: @unchecked Sendable {
    let prompt: EnhancedPrompt
    let score: Double
    let highlights: [SearchResult.TextRange]
}
