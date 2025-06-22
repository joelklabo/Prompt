@preconcurrency import Combine
import Foundation
import SwiftData
import os

/// High-performance prompt service leveraging the cache engine for <16ms response times
actor OptimizedPromptService {
    private let modelContainer: ModelContainer
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

        // Enhance prompts in parallel with cached data
        let enhanced = await withTaskGroup(of: EnhancedPrompt?.self) { group in
            for prompt in prompts {
                group.addTask {
                    await self.enhancePrompt(prompt)
                }
            }

            var results: [EnhancedPrompt] = []
            for await enhanced in group {
                if let enhanced = enhanced {
                    results.append(enhanced)
                }
            }
            return results
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

        // Use cache engine's indexed search
        let searchResults = await cacheEngine.search(query: query, in: prompts)

        // Enhance search results with content
        let enhanced = await withTaskGroup(of: SearchResultWithContent?.self) { group in
            for result in searchResults {
                group.addTask {
                    guard let prompt = prompts.first(where: { $0.id == result.promptId }) else { return nil }
                    let enhanced = await self.enhancePrompt(prompt)

                    return SearchResultWithContent(
                        prompt: enhanced!,
                        score: result.score,
                        highlights: result.highlights
                    )
                }
            }

            var results: [SearchResultWithContent] = []
            for await enhanced in group {
                if let enhanced = enhanced {
                    results.append(enhanced)
                }
            }
            return results
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

        // Update in background
        Task.detached(priority: .high) { [weak self] in
            do {
                // Apply update to model
                switch field {
                case .title:
                    prompt.title = newValue
                case .content:
                    prompt.content = newValue
                    // Invalidate content caches
                    _ = await self?.cacheEngine.getRenderedMarkdown(for: newValue)
                    _ = await self?.cacheEngine.getTextStats(for: newValue)
                case .category:
                    if let category = Category(rawValue: newValue) {
                        prompt.category = category
                    }
                }

                prompt.modifiedAt = Date()

                // Persist to database
                try await self?.saveToDatabase(prompt)

                // Mark WAL entry as committed
                _ = await self?.cacheEngine.logUpdate(update)
            } catch {
                self?.logger.error("Failed to persist update: \(error)")
            }
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
        return try await MainActor.run {
            let context = modelContainer.mainContext
            let descriptor = FetchDescriptor<Prompt>(
                sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
            )
            return try context.fetch(descriptor)
        }
    }

    private func enhancePrompt(_ prompt: Prompt) async -> EnhancedPrompt? {
        // Get cached render and stats in parallel
        async let rendered = cacheEngine.getRenderedMarkdown(for: prompt.content)
        async let stats = cacheEngine.getTextStats(for: prompt.content)
        async let contentRef = cacheEngine.deduplicateContent(prompt.content)

        return EnhancedPrompt(
            prompt: prompt,
            renderedContent: await rendered,
            statistics: await stats,
            contentReference: await contentRef
        )
    }

    private func saveToDatabase(_ prompt: Prompt) async throws {
        try await MainActor.run {
            let context = modelContainer.mainContext
            context.insert(prompt)
            try context.save()
        }
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
        // For now, fetch all prompts and convert to summaries
        let prompts = try await dataStore.fetch(FetchDescriptor<Prompt>())

        // Apply filters
        var filtered = prompts
        if let category = category {
            filtered = filtered.filter { $0.category == category }
        }
        if let searchQuery = searchQuery, !searchQuery.isEmpty {
            filtered = filtered.filter {
                $0.title.localizedCaseInsensitiveContains(searchQuery)
                    || $0.content.localizedCaseInsensitiveContains(searchQuery)
            }
        }

        // Sort by modified date
        filtered.sort { $0.modifiedAt > $1.modifiedAt }

        // Apply pagination
        let startIndex: Int
        if let cursor = cursor {
            startIndex = filtered.firstIndex { $0.id == cursor.lastID } ?? 0
        } else {
            startIndex = 0
        }
        let endIndex = min(startIndex + limit, filtered.count)
        let page = Array(filtered[startIndex..<endIndex])

        // Convert to summaries
        let summaries: [PromptSummary] = page.map { prompt in
            let tagNames = prompt.tags.map { $0.name }
            let contentPreview = String(prompt.content.prefix(100))
            let isFavorite = prompt.metadata.isFavorite
            let viewCount = Int16(prompt.metadata.viewCount)

            return PromptSummary(
                id: prompt.id,
                title: prompt.title,
                contentPreview: contentPreview,
                category: prompt.category,
                tagNames: tagNames,
                createdAt: prompt.createdAt,
                modifiedAt: prompt.modifiedAt,
                isFavorite: isFavorite,
                viewCount: viewCount
            )
        }

        let nextCursor: PaginationCursor?
        if endIndex < filtered.count, let lastPrompt = page.last {
            nextCursor = PaginationCursor(
                lastID: lastPrompt.id,
                lastModifiedAt: lastPrompt.modifiedAt,
                direction: .forward
            )
        } else {
            nextCursor = nil
        }

        return PromptSummaryBatch(
            summaries: summaries,
            cursor: nextCursor,
            totalCount: filtered.count
        )
    }

    func fetchPromptDetail(id: UUID) async throws -> PromptDetail {
        var descriptor = FetchDescriptor<Prompt>(
            predicate: #Predicate<Prompt> { prompt in
                prompt.id == id
            })
        descriptor.fetchLimit = 1
        guard let prompt = try await dataStore.fetch(descriptor).first else {
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
        let prompts = try await dataStore.fetch(FetchDescriptor<Prompt>())
        logger.info("Warming cache with \(prompts.count) prompts")

        // Pre-compute enhanced prompts for the first batch
        let firstBatch = Array(prompts.prefix(50))
        await withTaskGroup(of: Void.self) { group in
            for prompt in firstBatch {
                group.addTask { [weak self] in
                    _ = await self?.enhancePrompt(prompt)
                }
            }
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

struct EnhancedPrompt: Sendable {
    let prompt: Prompt
    let renderedContent: RenderedContent?
    let statistics: TextStatistics?
    let contentReference: ContentReference
}

struct SearchResultWithContent: Sendable {
    let prompt: EnhancedPrompt
    let score: Double
    let highlights: [SearchResult.TextRange]
}
