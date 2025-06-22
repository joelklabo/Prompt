import Foundation
import OSLog
import Testing

@testable import Prompt_macOS

@Suite("Columnar Storage Performance Benchmarks")
struct ColumnarBenchmarks {
    private static let logger = Logger(subsystem: "com.promptbank.tests", category: "ColumnarBenchmarks")

    // MARK: - Test Data Generation

    struct TestPromptData {
        let title: String
        let content: String
        let category: Category
    }

    static func generateTestPrompts(count: Int) -> [TestPromptData] {
        var prompts: [TestPromptData] = []

        let categories: [Category] = [.prompts, .configs, .commands, .context]
        let sampleContents = [
            "Write a comprehensive technical document about Swift concurrency",
            "Create a detailed analysis of machine learning algorithms",
            "Explain quantum computing principles in simple terms",
            "Design a scalable microservices architecture",
            "Implement a high-performance caching system"
        ]

        for index in 0..<count {
            let title = "Test Prompt \(index)"
            let content = sampleContents[index % sampleContents.count] + " - Instance \(index)"
            let category = categories[index % categories.count]
            prompts.append(TestPromptData(title: title, content: content, category: category))
        }

        return prompts
    }

    // MARK: - Insertion Benchmarks

    @Test("Single insertion performance - Target: <1µs")
    func testSingleInsertionPerformance() async {
        let storage = ColumnarStorage()

        // Warm up
        _ = storage.insert(
            id: UUID(),
            title: "Warmup",
            content: "Warmup content",
            category: .prompts
        )

        // Measure single insertion
        let measurements = await measureNanoTime(iterations: 1000) {
            _ = storage.insert(
                id: UUID(),
                title: "Test Prompt",
                content: "This is a test prompt content for measuring insertion performance",
                category: .prompts
            )
        }

        let avgNanos = measurements.reduce(0, +) / UInt64(measurements.count)
        let avgMicros = Double(avgNanos) / 1000.0

        Self.logger.info("Single insertion: \(avgMicros)µs (target: <1µs)")
        #expect(avgMicros < 1.0, "Single insertion should be under 1 microsecond")
    }

    @Test("Batch insertion performance - 10,000 prompts")
    func testBatchInsertionPerformance() async {
        let storage = ColumnarStorage()
        let testData = Self.generateTestPrompts(count: 10_000)

        let elapsed = await measureNanoTime {
            let prepared = testData.map { data in
                ColumnarStorage.BatchItem(
                    id: UUID(),
                    title: data.title,
                    content: data.content,
                    category: data.category
                )
            }
            storage.batchInsert(prepared)
        }

        let perItemNanos = elapsed / 10_000
        let perItemMicros = perItemNanos / 1000

        Self.logger.info("Batch insertion: \(perItemMicros)µs per item")
        #expect(perItemMicros < 0.5, "Batch insertion should be under 0.5µs per item")
    }

    // MARK: - Fetch Benchmarks

    @Test("Random access performance - Target: <100ns")
    func testRandomAccessPerformance() async {
        let storage = ColumnarStorage()

        // Insert test data
        let testData = Self.generateTestPrompts(count: 10_000)
        let prepared = testData.map { (UUID(), $0.title, $0.content, $0.category) }
        storage.batchInsert(prepared)

        // Generate random indices
        let indices = (0..<1000).map { _ in Int32.random(in: 0..<10_000) }

        // Measure fetch performance
        let measurements = await measureNanoTime(iterations: 1000) {
            for idx in indices {
                _ = storage.fetch(index: idx)
            }
        }

        let totalNanos = measurements.reduce(0, +) / UInt64(measurements.count)
        let avgNanos = Double(totalNanos) / Double(indices.count)

        Self.logger.info("Random access: \(avgNanos)ns (target: <100ns)")
        #expect(avgNanos < 100, "Random access should be under 100 nanoseconds")
    }

    // MARK: - Search Benchmarks

    @Test("Search performance - 100,000 prompts")
    func testSearchPerformance() async {
        let storage = ColumnarStorage()

        // Insert large dataset
        let testData = Self.generateTestPrompts(count: 100_000)
        let prepared = testData.map { (UUID(), $0.title, $0.content, $0.category) }
        storage.batchInsert(prepared)

        // Test various search queries
        let queries = ["swift", "machine", "quantum", "micro", "cache"]

        for query in queries {
            let elapsed = await measureNanoTime {
                _ = storage.search(query: query)
            }

            let elapsedMs = Double(elapsed) / 1_000_000
            Self.logger.info("Search '\(query)' in 100k prompts: \(elapsedMs)ms")
            #expect(elapsedMs < 100, "Search should complete in under 100ms")
        }
    }

    // MARK: - Filter Benchmarks

    @Test("Category filter performance - Target: <1µs")
    func testCategoryFilterPerformance() async {
        let storage = ColumnarStorage()

        // Insert balanced dataset
        let testData = Self.generateTestPrompts(count: 100_000)
        let prepared = testData.map { (UUID(), $0.title, $0.content, $0.category) }
        storage.batchInsert(prepared)

        // Measure filter performance for each category
        for category in Category.allCases {
            let elapsed = await measureNanoTime {
                _ = storage.filterByCategory(category)
            }

            let elapsedMicros = Double(elapsed) / 1000
            Self.logger.info("Filter by \(category.rawValue): \(elapsedMicros)µs")
            #expect(elapsedMicros < 1.0, "Category filter should be under 1 microsecond")
        }
    }

    // MARK: - Memory Benchmarks

    @Test("Memory efficiency - 10,000 prompts")
    func testMemoryEfficiency() async {
        let storage = ColumnarStorage()

        // Measure baseline memory
        let baselineMemory = memoryUsage()

        // Insert test data
        let testData = Self.generateTestPrompts(count: 10_000)
        let prepared = testData.map { (UUID(), $0.title, $0.content, $0.category) }
        storage.batchInsert(prepared)

        // Measure after insertion
        let afterMemory = memoryUsage()
        let memoryIncrease = afterMemory - baselineMemory
        let perPromptBytes = memoryIncrease / 10_000

        Self.logger.info("Memory per prompt: \(perPromptBytes) bytes")
        Self.logger.info("Total memory for 10k prompts: \(memoryIncrease / 1024 / 1024) MB")

        // Calculate theoretical minimum (UUID + minimal metadata)
        let theoreticalMin = MemoryLayout<UUID>.size + 50  // ~66 bytes
        let overhead = Double(perPromptBytes) / Double(theoreticalMin)

        Self.logger.info("Memory overhead: \(overhead)x theoretical minimum")
        #expect(overhead < 3.0, "Memory overhead should be less than 3x theoretical minimum")
    }

    // MARK: - Helper Functions

    func measureNanoTime(
        iterations: Int = 1,
        block: () async -> Void
    ) async -> UInt64 {
        let start = mach_absolute_time()
        for _ in 0..<iterations {
            await block()
        }
        let end = mach_absolute_time()
        return (end - start) / UInt64(iterations)
    }

    func measureNanoTime(block: () -> Void) async -> UInt64 {
        let start = mach_absolute_time()
        block()
        let end = mach_absolute_time()
        return end - start
    }

    func memoryUsage() -> Int {
        var info = mach_task_basic_info()
        var count =
            mach_msg_type_number_t(
                MemoryLayout<mach_task_basic_info>.size
            ) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count)
            }
        }

        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}
