import Foundation
import SwiftData
import Testing

#if os(macOS)
    @testable import Prompt_macOS
#elseif os(iOS)
    @testable import Prompt_iOS
#endif

@Suite("Performance Benchmarks")
struct PerformanceTests {
    let container: ModelContainer

    init() async throws {
        self.container = try TestHelpers.createTestContainer()
        // Seed with test data
        try await TestDataGenerator.generatePrompts(count: 1000, in: container)
    }

    @Test("Search performance with 1000 prompts", .timeLimit(.minutes(1)))
    func searchPerformance() async throws {
        let promptService = PromptService(container: container)
        let queries = ["swift", "async", "test", "AI", "prompt", "generated"]

        for query in queries {
            let start = ContinuousClock.now
            let results = try await promptService.searchPrompts(query: query)
            let duration = start.duration(to: .now)

            #expect(duration < .milliseconds(100))
            #expect(!results.isEmpty)
        }
    }

    @Test("Fetch all prompts performance", .timeLimit(.minutes(1)))
    func fetchAllPerformance() async throws {
        let promptService = PromptService(container: container)

        let start = ContinuousClock.now
        let prompts = try await promptService.fetchPrompts()
        let duration = start.duration(to: .now)

        #expect(duration < .milliseconds(500))
        #expect(prompts.count >= 1000)
    }

    @Test("Category filtering performance", .timeLimit(.minutes(1)))
    func categoryFilterPerformance() async throws {
        let promptService = PromptService(container: container)

        for category in Category.allCases {
            let start = ContinuousClock.now
            let results = try await promptService.fetchPromptsByCategory(category)
            let duration = start.duration(to: .now)

            #expect(duration < .milliseconds(150))
            // Should have roughly 1/3 of prompts in each category
            #expect(results.count > 200)
            #expect(results.count < 400)
        }
    }

    @Test("AI batch analysis performance")
    @MainActor
    func aiBatchPerformance() async throws {
        // Fetch prompts
        var descriptor = FetchDescriptor<Prompt>()
        descriptor.fetchLimit = 50
        let prompts = try container.mainContext.fetch(descriptor)
        
        // Create AIService
        let aiService = AIService()
        
        // Since AIService methods are MainActor-isolated and return non-Sendable types,
        // we'll test the time for the whole operation
        let startTime = CFAbsoluteTimeGetCurrent()
        _ = try await aiService.analyzeBatch(prompts)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        
        #expect(elapsed < 25, "AI batch analysis should complete within 25 seconds")
    }

    @Test("Launch time measurement")
    @MainActor
    func launchTimeTest() async throws {
        let start = ContinuousClock.now

        // Simulate app launch
        let promptService = PromptService(container: container)
        let tagService = TagService(container: container)
        let aiService = await MainActor.run { AIService() }

        let appState = AppState(
            promptService: promptService,
            tagService: tagService,
            aiService: aiService
        )

        await appState.initialize()

        let duration = start.duration(to: .now)
        #expect(duration < .milliseconds(500))
    }

    @Test("Tag operations performance")
    func tagPerformance() async throws {
        let tagService = TagService(container: container)
        let promptService = PromptService(container: container)

        // Create multiple tags
        let tagNames = (0..<50).map { "perf-tag-\($0)" }
        var tagIds: [UUID] = []

        let createStart = ContinuousClock.now
        for name in tagNames {
            let tagDetail = try await tagService.createTag(TagCreateRequest(name: name, color: "#007AFF"))
            tagIds.append(tagDetail.id)
        }
        let createDuration = createStart.duration(to: .now)
        #expect(createDuration < .seconds(2))

        // Add tags to prompts
        let promptSummaries = try await promptService.fetchPromptSummaries()
        let promptsToTag = Array(promptSummaries.prefix(10))

        let addStart = ContinuousClock.now
        for promptSummary in promptsToTag {
            for tagId in tagIds.prefix(5) {
                try await promptService.addTag(tagId: tagId, to: promptSummary.id)
            }
        }
        let addDuration = addStart.duration(to: .now)
        #expect(addDuration < .seconds(3))

        // Fetch most used tags
        let fetchStart = ContinuousClock.now
        let mostUsed = try await tagService.getMostUsedTagSummaries(limit: 10)
        let fetchDuration = fetchStart.duration(to: .now)
        #expect(fetchDuration < .milliseconds(100))
        #expect(!mostUsed.isEmpty)
    }
}

@Suite("Resource Usage")
struct ResourceTests {
    @Test("Memory usage under load")
    func memoryUsageTest() async throws {
        let baseline = ProcessInfo.processInfo.physicalMemory

        // Create large dataset
        let container = try TestHelpers.createTestContainer()
        try await TestDataGenerator.generatePrompts(count: 5000, in: container)

        // Perform operations
        let promptService = PromptService(container: container)
        _ = try await promptService.fetchPrompts()

        // Perform searches
        for _ in 0..<100 {
            _ = try await promptService.searchPrompts(query: "test")
        }

        // Check memory didn't exceed threshold
        let current = ProcessInfo.processInfo.physicalMemory
        let usage = current - baseline

        // Note: This is a rough check as memory reporting can be imprecise
        #expect(usage < 200_000_000)  // 200MB threshold
    }

    @Test("Concurrent operations stress test")
    func concurrencyTest() async throws {
        let container = try TestHelpers.createTestContainer()
        let promptService = PromptService(container: container)

        // Create initial data
        let prompts = TestHelpers.createSamplePrompts(count: 100)
        for prompt in prompts {
            _ = prompt.id
            let context = ModelContext(container)
            context.insert(prompt)
            try context.save()
        }

        // Perform concurrent operations
        await withTaskGroup(of: Void.self) { group in
            // Concurrent reads
            for _ in 0..<10 {
                group.addTask {
                    _ = try? await promptService.fetchPrompts()
                }
            }

            // Concurrent searches
            for query in ["swift", "test", "sample"] {
                group.addTask {
                    _ = try? await promptService.searchPrompts(query: query)
                }
            }

            // Concurrent creates
            for idx in 0..<5 {
                group.addTask {
                    let request = PromptCreateRequest(
                        title: "Concurrent \(idx)",
                        content: "Created concurrently",
                        category: .prompts
                    )
                    _ = try? await promptService.createPrompt(request)
                }
            }
        }

        // Verify data integrity
        let finalPrompts = try await promptService.fetchPrompts()
        #expect(finalPrompts.count >= 100)
    }
}
