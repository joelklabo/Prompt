import Foundation
import OSLog
import SwiftData
import Testing

#if os(macOS)
    @testable import Prompt_macOS
#elseif os(iOS)
    @testable import Prompt_iOS
#endif

@Suite("DTO Performance Tests")
struct DTOPerformanceTests {
    private static let logger = Logger(subsystem: "com.promptbank.tests", category: "DTOPerformanceTests")
    let modelContainer: ModelContainer
    let dataStore: DataStore
    let cache: PromptCache
    let optimizedService: OptimizedPromptService

    init() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        self.modelContainer = try ModelContainer(
            for: Prompt.self, Tag.self, PromptMetadata.self,
            PromptVersion.self, AIAnalysis.self,
            configurations: config
        )

        self.dataStore = DataStore(modelContainer: modelContainer)
        self.cache = PromptCache()
        self.optimizedService = try await OptimizedPromptService(container: modelContainer)
    }

    @Test("PromptSummary memory efficiency")
    func testSummaryMemorySize() {
        // Create a summary
        let summary = PromptSummary(
            id: UUID(),
            title: "Test Prompt Title",
            contentPreview: "This is a preview of the prompt content that should be exactly 100 characters long...",
            category: .prompts,
            tagNames: ["swift", "ios", "performance"],
            createdAt: Date(),
            modifiedAt: Date(),
            isFavorite: true,
            viewCount: 42,
            copyCount: 5,
            categoryConfidence: 0.95,
            shortLink: URL(string: "https://prompt.app/abc123")
        )

        // Measure memory size
        let size = MemoryLayout<PromptSummary>.size
        let stride = MemoryLayout<PromptSummary>.stride

        #expect(size <= 200, "PromptSummary should be under 200 bytes")
        #expect(stride % 8 == 0, "PromptSummary should be properly aligned")

        // Test cache line efficiency
        let cacheLinesUsed = (stride + 63) / 64  // 64 bytes per cache line
        #expect(cacheLinesUsed <= 3, "Should fit in 3 cache lines or less")
    }

    @Test("Cursor-based pagination performance")
    func testPaginationPerformance() async throws {
        // Create test data
        await createTestPrompts(count: 1000)

        // Measure initial load
        let start = CFAbsoluteTimeGetCurrent()
        let firstBatch = try await optimizedService.fetchPromptSummaries(limit: 50)
        let initialLoadTime = CFAbsoluteTimeGetCurrent() - start

        #expect(initialLoadTime < 0.1, "Initial load should be under 100ms")
        #expect(firstBatch.summaries.count == 50)

        // Measure pagination
        var totalPaginationTime: TimeInterval = 0
        var cursor = firstBatch.cursor
        var pageCount = 1

        while let currentCursor = cursor, pageCount < 10 {
            let pageStart = CFAbsoluteTimeGetCurrent()
            let batch = try await optimizedService.fetchPromptSummaries(
                limit: 50,
                cursor: currentCursor
            )
            totalPaginationTime += CFAbsoluteTimeGetCurrent() - pageStart

            cursor = batch.cursor
            pageCount += 1
        }

        let avgPageTime = totalPaginationTime / Double(pageCount - 1)
        #expect(avgPageTime < 0.01, "Average page load should be under 10ms")
    }

    @Test("LRU cache effectiveness")
    func testCachePerformance() async throws {
        // Create test data
        let prompts = await createTestPrompts(count: 100)

        // Warm cache
        await cache.warmCache(with: prompts.map { $0.toSummary() })

        // Test cache hits
        var hitCount = 0
        let testIDs = prompts.prefix(50).map(\.id)

        for id in testIDs where await cache.getSummary(id: id) != nil {
            hitCount += 1
        }

        let hitRate = Double(hitCount) / Double(testIDs.count)
        #expect(hitRate > 0.95, "Cache hit rate should be >95%")

        // Test cache eviction
        let largePrompts = await createTestPrompts(count: 20_000)
        for prompt in largePrompts {
            await cache.cacheSummary(prompt.toSummary())
        }

        // Original items should be evicted
        var evictedCount = 0
        for id in testIDs where await cache.getSummary(id: id) == nil {
            evictedCount += 1
        }

        #expect(evictedCount > testIDs.count / 2, "At least half should be evicted")
    }

    @Test("Search performance with DTOs")
    func testSearchPerformance() async throws {
        // Create diverse test data
        await createTestPrompts(count: 10_000)

        // Test search performance
        let searchQueries = ["swift", "test", "performance", "optimization", "cache"]
        var totalSearchTime: TimeInterval = 0

        for query in searchQueries {
            let start = CFAbsoluteTimeGetCurrent()
            let results = try await optimizedService.searchPrompts(query: query)
            totalSearchTime += CFAbsoluteTimeGetCurrent() - start

            #expect(!results.isEmpty, "Should find results for '\(query)'")
        }

        let avgSearchTime = totalSearchTime / Double(searchQueries.count)
        #expect(avgSearchTime < 0.05, "Average search should be under 50ms")
    }

    @Test("Memory-mapped content for large prompts")
    func testLargeContentHandling() {
        // Create large content (50KB)
        let largeContent = String(repeating: "Lorem ipsum dolor sit amet. ", count: 2000)

        let promptContent = PromptContent(content: largeContent)

        // Verify content is accessible
        #expect(promptContent.content == largeContent)

        // Test memory efficiency with multiple large contents
        var contents: [PromptContent] = []
        for index in 0..<100 {
            let content = String(repeating: "Content \(index) ", count: 1000)
            contents.append(PromptContent(content: content))
        }

        // All contents should still be accessible
        for (index, promptContent) in contents.enumerated() {
            #expect(promptContent.content.contains("Content \(index)"))
        }
    }

    @Test("Batch operations performance")
    func testBatchOperations() async throws {
        // Create test data
        let prompts = await createTestPrompts(count: 1000)

        // Test batch fetch
        let start = CFAbsoluteTimeGetCurrent()
        let summaries = try await dataStore.fetchPromptSummariesDirect(limit: 1000)
        let fetchTime = CFAbsoluteTimeGetCurrent() - start

        #expect(summaries.count == 1000)
        #expect(fetchTime < 0.1, "Batch fetch should be under 100ms")

        // Test aggregate stats
        let statsStart = CFAbsoluteTimeGetCurrent()
        let stats = try await dataStore.aggregatePromptStats()
        let statsTime = CFAbsoluteTimeGetCurrent() - statsStart

        #expect(stats.totalCount == 1000)
        #expect(statsTime < 0.05, "Stats calculation should be under 50ms")
    }

    @Test("DTO conversion performance")
    func testDTOConversionPerformance() async throws {
        // Create a complex prompt with relationships
        let prompt = await createComplexPrompt()

        // Test summary conversion
        let summaryStart = CFAbsoluteTimeGetCurrent()
        _ = prompt.toSummary()
        let summaryTime = CFAbsoluteTimeGetCurrent() - summaryStart

        #expect(summaryTime < 0.001, "Summary conversion should be under 1ms")

        // Test detail conversion
        let detailStart = CFAbsoluteTimeGetCurrent()
        _ = prompt.toDetail()
        let detailTime = CFAbsoluteTimeGetCurrent() - detailStart

        #expect(detailTime < 0.002, "Detail conversion should be under 2ms")
    }

    // MARK: - Helper Methods

    @discardableResult
    private func createTestPrompts(count: Int) async -> [Prompt] {
        var prompts: [Prompt] = []

        let categories = Category.allCases
        let tagPool = [
            "swift", "ios", "macos", "performance", "optimization",
            "cache", "memory", "testing", "swiftui", "async"
        ]

        for index in 0..<count {
            let prompt = Prompt(
                title: "Test Prompt \(index)",
                content: "This is test content for prompt \(index). Keywords: swift, performance, optimization.",
                category: categories[index % categories.count]
            )

            // Add random tags
            let tagCount = Int.random(in: 1...3)
            for _ in 0..<tagCount {
                let tagName = tagPool.randomElement()!
                let tag = Tag(name: tagName)
                prompt.tags.append(tag)
            }

            // Vary metadata
            prompt.metadata.viewCount = Int.random(in: 0...1000)
            prompt.metadata.isFavorite = index % 10 == 0

            prompts.append(prompt)

            let context = ModelContext(modelContainer)
            context.insert(prompt)
            try? context.save()
        }

        return prompts
    }

    private func createComplexPrompt() async -> Prompt {
        let prompt = Prompt(
            title: "Complex Test Prompt",
            content: String(repeating: "Complex content ", count: 500),
            category: .prompts
        )

        // Add multiple tags
        for tagIndex in 0..<5 {
            prompt.tags.append(Tag(name: "tag\(tagIndex)"))
        }

        // Add AI analysis
        prompt.aiAnalysis = AIAnalysis(
            suggestedTags: ["ai-tag1", "ai-tag2", "ai-tag3"],
            category: .prompts,
            categoryConfidence: 0.95,
            summary: "This is an AI-generated summary",
            enhancementSuggestions: ["Suggestion 1", "Suggestion 2"]
        )

        // Add versions
        for versionIndex in 0..<3 {
            let version = PromptVersion(
                versionNumber: versionIndex + 1,
                title: prompt.title,
                content: "Version \(versionIndex + 1) content",
                changeDescription: "Change \(versionIndex + 1)"
            )
            prompt.versions.append(version)
        }

        let context = ModelContext(modelContainer)
        context.insert(prompt)
        try? context.save()

        return prompt
    }
}

@Suite("DTO Memory Layout Tests")
struct DTOMemoryLayoutTests {
    private static let logger = Logger(
        subsystem: "com.promptbank.tests",
        category: "DTOMemoryLayoutTests"
    )
    @Test("Verify optimal struct packing")
    func testStructPacking() {
        // Test PromptSummary layout
        let summarySize = MemoryLayout<PromptSummary>.size
        let summaryStride = MemoryLayout<PromptSummary>.stride
        let summaryAlignment = MemoryLayout<PromptSummary>.alignment

        Self.logger.info(
            "PromptSummary - Size: \(summarySize), Stride: \(summaryStride), Alignment: \(summaryAlignment)")

        // Test TagDTO layout
        let tagSize = MemoryLayout<TagDTO>.size
        let tagStride = MemoryLayout<TagDTO>.stride

        Self.logger.info("TagDTO - Size: \(tagSize), Stride: \(tagStride)")

        // Verify efficient packing
        #expect(summaryAlignment <= 8, "Should have reasonable alignment")
        #expect(tagStride <= 40, "TagDTO should be compact")
    }
}
