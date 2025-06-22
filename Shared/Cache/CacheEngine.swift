import Combine
import Foundation
import os
import SwiftData

/// High-performance caching engine inspired by John Carmack's approach to data locality and cache coherency
/// All operations are designed to meet the <16ms frame time requirement
actor CacheEngine {
    private let logger = Logger(subsystem: "com.prompt.app", category: "CacheEngine")

    // Sub-systems
    private let renderCache: RenderCache
    private let textIndexer: TextIndexer
    private let statsComputer: StatsComputer
    private let writeAheadLog: WriteAheadLog
    private let contentStore: ContentAddressableStore
    private let backgroundProcessor: BackgroundProcessor

    // Memory pressure handling
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    // Performance metrics
    private var metrics = PerformanceMetrics()

    init(modelContainer: ModelContainer) async throws {
        logger.info("Initializing CacheEngine with target frame time: 16ms")

        // Initialize sub-systems
        self.renderCache = try await RenderCache()
        self.textIndexer = try await TextIndexer()
        self.statsComputer = StatsComputer()
        self.writeAheadLog = try await WriteAheadLog()
        self.contentStore = try await ContentAddressableStore()
        self.backgroundProcessor = BackgroundProcessor()

        // Setup memory pressure monitoring
        await setupMemoryPressureHandling()

        // Start background processing
        await startBackgroundTasks(modelContainer: modelContainer)
    }

    // MARK: - Public API

    /// Get rendered markdown with guaranteed <16ms response time
    func getRenderedMarkdown(for content: String) async -> RenderedContent {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            metrics.recordRenderTime(elapsed)
            if elapsed > 16 {
                logger.warning("Render time exceeded frame budget: \(elapsed)ms")
            }
        }

        // Check cache first
        if let cached = await renderCache.get(content: content) {
            return cached
        }

        // Return placeholder immediately and queue background render
        let placeholder = RenderedContent.placeholder(for: content)
        await backgroundProcessor.queueRenderTask(content: content) { [weak self] rendered in
            await self?.renderCache.store(content: content, rendered: rendered)
        }

        return placeholder
    }

    /// Get text statistics with SIMD acceleration
    func getTextStats(for content: String) async -> TextStatistics {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            metrics.recordStatsTime(elapsed)
        }

        // Check cache first
        let contentHash = await contentStore.hash(content)
        if let cached = await statsComputer.getCached(hash: contentHash) {
            return cached
        }

        // Compute with SIMD
        let stats = await statsComputer.compute(content: content, hash: contentHash)
        return stats
    }

    /// Search with pre-built inverted index
    func search(query: String, in prompts: [Prompt]) async -> [SearchResult] {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            metrics.recordSearchTime(elapsed)
        }

        return await textIndexer.search(query: query, in: prompts)
    }

    /// Write-ahead log for instant UI updates
    func logUpdate(_ update: PromptUpdate) async -> UpdateToken {
        return await writeAheadLog.append(update)
    }

    /// Content-addressable storage for deduplication
    func deduplicateContent(_ content: String) async -> ContentReference {
        return await contentStore.store(content)
    }

    /// Subscribe to WAL updates
    func subscribe(_ handler: @escaping @Sendable (PromptUpdate) -> Void) async -> UUID {
        return await writeAheadLog.subscribe(handler)
    }

    /// Unsubscribe from WAL updates
    func unsubscribe(_ id: UUID) async {
        await writeAheadLog.unsubscribe(id)
    }

    // MARK: - Background Processing

    private func startBackgroundTasks(modelContainer: ModelContainer) async {
        // Pre-render markdown for all prompts
        await backgroundProcessor.startTask(
            name: "MarkdownPreRender",
            priority: .high
        ) { [weak self] in
            await self?.preRenderAllMarkdown(modelContainer: modelContainer)
        }

        // Build search index
        await backgroundProcessor.startTask(
            name: "SearchIndexBuilder",
            priority: .medium
        ) { [weak self] in
            await self?.buildSearchIndex(modelContainer: modelContainer)
        }

        // Compute statistics
        await backgroundProcessor.startTask(
            name: "StatsComputation",
            priority: .low
        ) { [weak self] in
            await self?.computeAllStats(modelContainer: modelContainer)
        }
    }

    private func preRenderAllMarkdown(modelContainer: ModelContainer) async {
        do {
            let prompts = try await fetchAllPrompts(from: modelContainer)

            await withTaskGroup(of: Void.self) { group in
                for prompt in prompts {
                    group.addTask { [weak self] in
                        _ = await self?.getRenderedMarkdown(for: prompt.content)
                    }
                }
            }

            logger.info("Pre-rendered \(prompts.count) prompts")
        } catch {
            logger.error("Failed to pre-render markdown: \(error)")
        }
    }

    private func buildSearchIndex(modelContainer: ModelContainer) async {
        do {
            let prompts = try await fetchAllPrompts(from: modelContainer)
            await textIndexer.buildIndex(for: prompts)
            logger.info("Built search index for \(prompts.count) prompts")
        } catch {
            logger.error("Failed to build search index: \(error)")
        }
    }

    private func computeAllStats(modelContainer: ModelContainer) async {
        do {
            let prompts = try await fetchAllPrompts(from: modelContainer)

            await withTaskGroup(of: Void.self) { group in
                for prompt in prompts {
                    group.addTask { [weak self] in
                        _ = await self?.getTextStats(for: prompt.content)
                    }
                }
            }

            logger.info("Computed statistics for \(prompts.count) prompts")
        } catch {
            logger.error("Failed to compute statistics: \(error)")
        }
    }

    private func fetchAllPrompts(from container: ModelContainer) async throws -> [Prompt] {
        return try await MainActor.run {
            let context = container.mainContext
            let descriptor = FetchDescriptor<Prompt>()
            return try context.fetch(descriptor)
        }
    }

    // MARK: - Memory Management

    private func setupMemoryPressureHandling() async {
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global())

        memoryPressureSource?
            .setEventHandler { @Sendable [weak self] in
                Task {
                    await self?.handleMemoryPressure()
                }
            }

        memoryPressureSource?.resume()
    }

    private func handleMemoryPressure() async {
        logger.warning("Memory pressure detected, clearing caches")
        await renderCache.evictLRU(keepRatio: 0.5)
        await textIndexer.compactIndex()
        await statsComputer.clearCache()
    }

    // MARK: - Performance Metrics

    struct PerformanceMetrics {
        var renderTimes: [Double] = []
        var statsTimes: [Double] = []
        var searchTimes: [Double] = []

        mutating func recordRenderTime(_ ms: Double) {
            renderTimes.append(ms)
            if renderTimes.count > 1000 {
                renderTimes.removeFirst()
            }
        }

        mutating func recordStatsTime(_ ms: Double) {
            statsTimes.append(ms)
            if statsTimes.count > 1000 {
                statsTimes.removeFirst()
            }
        }

        mutating func recordSearchTime(_ ms: Double) {
            searchTimes.append(ms)
            if searchTimes.count > 1000 {
                searchTimes.removeFirst()
            }
        }

        var averageRenderTime: Double {
            renderTimes.isEmpty ? 0 : renderTimes.reduce(0, +) / Double(renderTimes.count)
        }

        var averageStatsTime: Double {
            statsTimes.isEmpty ? 0 : statsTimes.reduce(0, +) / Double(statsTimes.count)
        }

        var averageSearchTime: Double {
            searchTimes.isEmpty ? 0 : searchTimes.reduce(0, +) / Double(searchTimes.count)
        }
    }
}

// MARK: - Supporting Types

struct RenderedContent: Sendable {
    let attributedString: AttributedString
    let renderTime: TimeInterval
    let isPlaceholder: Bool

    static func placeholder(for content: String) -> RenderedContent {
        // Return first 500 chars as placeholder for instant display
        let preview = String(content.prefix(500))
        return RenderedContent(
            attributedString: AttributedString(preview),
            renderTime: 0,
            isPlaceholder: true
        )
    }
}

struct TextStatistics: Sendable {
    let wordCount: Int
    let lineCount: Int
    let characterCount: Int
    let avgWordLength: Double
    let readingTime: TimeInterval  // in seconds
    let complexity: ComplexityScore

    struct ComplexityScore: Sendable {
        let lexicalDiversity: Double
        let avgSentenceLength: Double
        let technicalTermRatio: Double
    }
}

struct SearchResult: Sendable {
    let promptId: UUID
    let score: Double
    let highlights: [TextRange]

    struct TextRange: Sendable {
        let start: Int
        let end: Int
    }
}

struct PromptUpdate: Sendable {
    let promptId: UUID
    let field: UpdateField
    let oldValue: String
    let newValue: String
    let timestamp: Date

    enum UpdateField: String, Sendable {
        case title
        case content
        case category
    }
}

struct UpdateToken: Sendable {
    let id: UUID
    let timestamp: Date
    let committed: Bool
}

struct ContentReference: Sendable {
    let hash: String
    let size: Int
    let referenceCount: Int
}
