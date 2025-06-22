import Foundation
import OSLog
import SwiftData
import Testing

@testable import Prompt_macOS

@Suite("Cache Performance Tests")
struct CachePerformanceTests {
    private static let logger = Logger(subsystem: "com.promptbank.tests", category: "CachePerformance")

    @Test("Render cache achieves <16ms response time")
    func testRenderCachePerformance() async throws {
        // Setup
        let modelConfig = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Prompt.self, configurations: modelConfig)
        let cacheEngine = try await CacheEngine(modelContainer: container)

        // Test content of various sizes
        let testContents = [
            generateMarkdown(words: 100),  // Small
            generateMarkdown(words: 500),  // Medium
            generateMarkdown(words: 2000),  // Large
            generateMarkdown(words: 10000)  // Very large
        ]

        // Warm up cache
        for content in testContents {
            _ = await cacheEngine.getRenderedMarkdown(for: content)
        }

        // Measure cached access times
        var responseTimes: [Double] = []

        for content in testContents {
            let startTime = CFAbsoluteTimeGetCurrent()
            let result = await cacheEngine.getRenderedMarkdown(for: content)
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

            responseTimes.append(elapsed)

            #expect(result != nil, "Should return rendered content")
            #expect(elapsed < 16, "Response time (\(elapsed)ms) should be under 16ms")
        }

        let avgResponseTime = responseTimes.reduce(0, +) / Double(responseTimes.count)
        Self.logger.info("Average render cache response time: \(avgResponseTime)ms")
        #expect(avgResponseTime < 16, "Average response time should be under 16ms")
    }

    @Test("Text statistics computation with SIMD acceleration")
    func testStatsComputationPerformance() async throws {
        let statsComputer = StatsComputer()

        // Generate test content
        let testContent = generateMarkdown(words: 5000)
        let hash = "test-hash-\(UUID().uuidString)"

        // First computation (uncached)
        let firstStart = CFAbsoluteTimeGetCurrent()
        let stats1 = await statsComputer.compute(content: testContent, hash: hash)
        let firstTime = (CFAbsoluteTimeGetCurrent() - firstStart) * 1000

        Self.logger.info("First computation time: \(firstTime)ms")
        #expect(stats1.wordCount > 0, "Should compute word count")

        // Cached access (should be instant)
        let cachedStart = CFAbsoluteTimeGetCurrent()
        let stats2 = statsComputer.getCached(hash: hash)
        let cachedTime = (CFAbsoluteTimeGetCurrent() - cachedStart) * 1000

        #expect(stats2 != nil, "Should return cached stats")
        #expect(cachedTime < 1, "Cached access should be under 1ms")
        Self.logger.info("Cached access time: \(cachedTime)ms")
    }

    @Test("Search index performance with 10,000 prompts")
    func testSearchIndexPerformance() async throws {
        let textIndexer = try await TextIndexer()

        // Generate 10,000 test prompts
        let prompts = (0..<10_000)
            .map { index in
                let prompt = Prompt(
                    title: "Test Prompt \(index)",
                    content: generateSearchableContent(index: index),
                    category: .prompts
                )
                return prompt
            }

        // Build index
        let buildStart = CFAbsoluteTimeGetCurrent()
        await textIndexer.buildIndex(for: prompts)
        let buildTime = (CFAbsoluteTimeGetCurrent() - buildStart) * 1000
        Self.logger.info("Index build time for 10,000 prompts: \(buildTime)ms")

        // Test search performance
        let searchQueries = [
            "swift",
            "performance optimization",
            "async await",
            "test prompt 5000"
        ]

        var searchTimes: [Double] = []

        for query in searchQueries {
            let searchStart = CFAbsoluteTimeGetCurrent()
            let results = await textIndexer.search(query: query, in: prompts)
            let searchTime = (CFAbsoluteTimeGetCurrent() - searchStart) * 1000

            searchTimes.append(searchTime)
            Self.logger.info("Search for '\(query)': \(results.count) results in \(searchTime)ms")

            #expect(searchTime < 100, "Search should complete in under 100ms")
        }

        let avgSearchTime = searchTimes.reduce(0, +) / Double(searchTimes.count)
        Self.logger.info("Average search time: \(avgSearchTime)ms")
        #expect(avgSearchTime < 50, "Average search should be under 50ms")
    }

    @Test("Write-ahead log instant update performance")
    func testWALPerformance() async throws {
        let wal = try await WriteAheadLog()

        // Measure update latency
        var latencies: [Double] = []

        for updateIndex in 0..<100 {
            let update = PromptUpdate(
                promptId: UUID(),
                field: .content,
                oldValue: "Old content \(updateIndex)",
                newValue: "New content \(updateIndex)",
                timestamp: Date()
            )

            let startTime = CFAbsoluteTimeGetCurrent()
            let token = await wal.append(update)
            let latency = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

            latencies.append(latency)

            #expect(token.id != UUID(), "Should return valid token")
            #expect(latency < 1, "WAL append should be under 1ms")
        }

        let avgLatency = latencies.reduce(0, +) / Double(latencies.count)
        let maxLatency = latencies.max() ?? 0

        Self.logger.info("WAL Performance:")
        Self.logger.info("  Average latency: \(avgLatency)ms")
        Self.logger.info("  Max latency: \(maxLatency)ms")

        #expect(avgLatency < 0.5, "Average WAL latency should be under 0.5ms")
        #expect(maxLatency < 1, "Max WAL latency should be under 1ms")
    }

    @Test("Content deduplication efficiency")
    func testContentDeduplication() async throws {
        let cas = try await ContentAddressableStore()

        // Store same content multiple times
        let content = generateMarkdown(words: 1000)
        var references: [ContentReference] = []

        for _ in 0..<10 {
            let ref = await cas.store(content)
            references.append(ref)
        }

        // All should have same hash
        let hashes = Set(references.map { $0.hash })
        #expect(hashes.count == 1, "All references should have same hash")

        // Check deduplication stats
        let stats = await cas.getStatistics()
        #expect(stats.uniqueObjects == 1, "Should only store one unique object")
        #expect(stats.deduplicationRatio > 0.8, "Should have high deduplication ratio")

        Self.logger.info("Deduplication stats:")
        Self.logger.info("  Unique objects: \(stats.uniqueObjects)")
        Self.logger.info("  Total bytes: \(stats.totalBytes)")
        Self.logger.info("  Deduplicated bytes: \(stats.deduplicatedBytes)")
        Self.logger.info("  Deduplication ratio: \(stats.deduplicationRatio * 100)%")
    }

    @Test("Concurrent operations stress test")
    func testConcurrentPerformance() async throws {
        let modelConfig = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Prompt.self, configurations: modelConfig)
        let cacheEngine = try await CacheEngine(modelContainer: container)

        // Generate test data
        let contents = (0..<100)
            .map { contentIndex in
                generateMarkdown(words: 100 + contentIndex * 10)
            }

        // Measure concurrent operations
        let startTime = CFAbsoluteTimeGetCurrent()

        await withTaskGroup(of: Void.self) { group in
            // Render operations
            for content in contents {
                group.addTask {
                    _ = await cacheEngine.getRenderedMarkdown(for: content)
                }
            }

            // Stats operations
            for content in contents {
                group.addTask {
                    _ = await cacheEngine.getTextStats(for: content)
                }
            }

            // Search operations
            for searchIndex in 0..<50 {
                group.addTask {
                    _ = await cacheEngine.search(query: "test \(searchIndex)", in: [])
                }
            }
        }

        let totalTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        let operationCount = contents.count * 2 + 50
        let avgTime = totalTime / Double(operationCount)

        Self.logger.info("Concurrent operations performance:")
        Self.logger.info("  Total operations: \(operationCount)")
        Self.logger.info("  Total time: \(totalTime)ms")
        Self.logger.info("  Average per operation: \(avgTime)ms")

        #expect(avgTime < 16, "Average operation time should be under 16ms")
    }

    // MARK: - Helper Methods

    private func generateMarkdown(words: Int) -> String {
        let lorem = """
            Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor
            incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis
            nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.
            """

        let wordArray = lorem.split(separator: " ")
        var result = "# Test Document\n\n"

        for wordIndex in 0..<words {
            result += wordArray[wordIndex % wordArray.count] + " "
            if wordIndex % 20 == 19 {
                result += "\n\n"
            }
            if wordIndex % 100 == 99 {
                result += "## Section \(wordIndex / 100)\n\n"
            }
        }

        return result
    }

    private func generateSearchableContent(index: Int) -> String {
        let topics = ["swift", "performance", "optimization", "async", "await", "actor", "cache"]
        let topic = topics[index % topics.count]

        return """
            This is test prompt \(index) about \(topic) programming.

            It contains various keywords like \(topic), development, and testing.
            The content is designed to test search functionality with different terms.

            Additional technical terms: algorithm, database, API, function, variable.
            """
    }
}
