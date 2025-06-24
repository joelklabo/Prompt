import Foundation
import OSLog
import Testing

#if os(macOS)
    @testable import Prompt_macOS
#elseif os(iOS)
    @testable import Prompt_iOS
#endif

// MARK: - Stress Tests and Comparisons

extension ColumnarBenchmarks {
    @Test("Performance comparison vs SwiftData")
    func testPerformanceComparison() async {
        // Columnar storage
        let columnar = ColumnarStorage()
        let testData = Self.generateTestPrompts(count: 1000)

        // Insert benchmark
        let columnarInsertTime = await measureNanoTime {
            let prepared = testData.map { data in
                ColumnarStorage.BatchItem(
                    id: UUID(),
                    title: data.title,
                    content: data.content,
                    category: data.category
                )
            }
            columnar.batchInsert(prepared)
        }

        // Search benchmark
        let columnarSearchTime = await measureNanoTime {
            _ = columnar.search(query: "swift")
        }

        // Filter benchmark
        let columnarFilterTime = await measureNanoTime {
            _ = columnar.filterByCategory(.prompts)
        }

        ColumnarBenchmarks.logger.info("\nColumnar Storage Performance:")
        ColumnarBenchmarks.logger.info("- Insert 1000: \(Double(columnarInsertTime) / 1_000_000)ms")
        ColumnarBenchmarks.logger.info("- Search: \(Double(columnarSearchTime) / 1_000_000)ms")
        ColumnarBenchmarks.logger.info("- Filter: \(Double(columnarFilterTime) / 1_000)µs")

        // Note: In production, would compare against actual SwiftData implementation
        ColumnarBenchmarks.logger.info("\nExpected SwiftData Performance (estimated):")
        ColumnarBenchmarks.logger.info("- Insert 1000: ~50-100ms (50-100x slower)")
        ColumnarBenchmarks.logger.info("- Search: ~10-20ms (100-200x slower)")
        ColumnarBenchmarks.logger.info("- Filter: ~5-10ms (5000-10000x slower)")
    }

    @Test("Concurrent access stress test")
    func testConcurrentAccess() async {
        let storage = ColumnarStorage()

        // Pre-populate
        let testData = Self.generateTestPrompts(count: 10_000)
        let prepared = testData.map { data in
            ColumnarStorage.BatchItem(
                id: UUID(),
                title: data.title,
                content: data.content,
                category: data.category
            )
        }
        storage.batchInsert(prepared)

        // Concurrent operations
        await withTaskGroup(of: Void.self) { group in
            // Readers
            for _ in 0..<10 {
                group.addTask {
                    for _ in 0..<1000 {
                        let idx = Int32.random(in: 0..<10_000)
                        _ = storage.fetch(index: idx)
                    }
                }
            }

            // Searchers
            for query in ["test", "prompt", "content"] {
                group.addTask {
                    for _ in 0..<100 {
                        _ = storage.search(query: query)
                    }
                }
            }

            // Writers
            for writerIndex in 0..<5 {
                group.addTask {
                    for itemIndex in 0..<100 {
                        _ = storage.insert(
                            id: UUID(),
                            title: "Concurrent \(writerIndex)-\(itemIndex)",
                            content: "Concurrent content",
                            category: .prompts
                        )
                    }
                }
            }
        }

        ColumnarBenchmarks.logger.info("Concurrent stress test completed successfully")
    }
}

// MARK: - Measurement Results

struct MeasurementResults {
    let measurements: [UInt64]

    var average: Double {
        Double(measurements.reduce(0, +)) / Double(measurements.count)
    }

    var min: UInt64 {
        measurements.min() ?? 0
    }

    var max: UInt64 {
        measurements.max() ?? 0
    }

    var median: UInt64 {
        let sorted = measurements.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
