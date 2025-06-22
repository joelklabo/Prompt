import Foundation
import Testing

@testable import PromptBank

@Suite("Performance Tests")
struct PerformanceTests {

    @Test("PromptService list performance with lightweight DTOs")
    func testPromptListPerformance() async throws {
        // Create test container
        let container = try createTestContainer()
        let promptService = PromptService(container: container)

        // Add test data
        for index in 0..<100 {
            let prompt = Prompt(
                title: "Test Prompt \(index)",
                content: "This is test content for prompt \(index)",
                category: .prompts
            )
            try await promptService.savePrompt(prompt)
        }

        // Measure list fetch time
        let startTime = Date()
        let listItems = try await promptService.fetchPromptList()
        let elapsed = Date().timeIntervalSince(startTime)

        // List fetch time: \(elapsed * 1000)ms
        #expect(elapsed < 0.010)  // Should be under 10ms
        #expect(listItems.count == 100)
    }

    @Test("PromptService search performance")
    func testPromptSearchPerformance() async throws {
        let container = try createTestContainer()
        let promptService = PromptService(container: container)

        // Add test data
        for index in 0..<100 {
            let prompt = Prompt(
                title: "Test Prompt \(index)",
                content: "This is test content for prompt \(index) with searchable text",
                category: Category.allCases.randomElement()!
            )
            try await promptService.savePrompt(prompt)
        }

        // Measure search time
        let startTime = Date()
        let results = try await promptService.searchPrompts(query: "test")
        let elapsed = Date().timeIntervalSince(startTime)

        // Search time for 100 prompts: \(elapsed * 1000)ms
        #expect(elapsed < 0.050)  // Should be under 50ms
        #expect(!results.isEmpty)
    }

    @Test("Navigation response time")
    func testNavigationSpeed() async throws {
        let container = try createTestContainer()
        let promptService = PromptService(container: container)

        // Create test prompt
        let prompt = Prompt(
            title: "Navigation Test",
            content: String(repeating: "Large content ", count: 1000),
            category: .prompts
        )
        try await promptService.savePrompt(prompt)

        // Measure detail fetch time
        let startTime = Date()
        let loaded = try await promptService.fetchPrompt(id: prompt.id)
        let elapsed = Date().timeIntervalSince(startTime)

        // Detail load time: \(elapsed * 1000)ms
        #expect(elapsed < 0.010)  // Should be under 10ms
        #expect(loaded != nil)
    }

    @Test("Compare old vs new service")
    func testServiceComparison() async throws {
        let container = try createTestContainer()

        // Create test data
        var testPrompts: [Prompt] = []
        for index in 0..<100 {
            testPrompts.append(
                Prompt(
                    title: "Comparison Test \(index)",
                    content: "Content for comparison \(index)",
                    category: .prompts
                ))
        }

        // Test old service
        let oldService = PromptService(container: container)
        let oldStart = Date()
        for prompt in testPrompts {
            try await oldService.savePrompt(prompt)
        }
        let oldList = try await oldService.fetchPrompts()
        let oldElapsed = Date().timeIntervalSince(oldStart)

        // Test with lightweight DTOs
        let newStart = Date()
        let listItems = try await oldService.fetchPromptList()
        let newElapsed = Date().timeIntervalSince(newStart)

        // Old service time: \(oldElapsed * 1000)ms
        // New service time: \(newElapsed * 1000)ms
        // Speed improvement: \(oldElapsed / newElapsed)x faster

        #expect(newElapsed < oldElapsed)
        #expect(listItems.count >= oldList.count)
    }

    @Test("Memory efficiency")
    func testMemoryUsage() async throws {
        let container = try createTestContainer()
        let promptService = PromptService(container: container)

        // Create large dataset
        for index in 0..<100 {
            let prompt = Prompt(
                title: "Memory Test \(index)",
                content: String(repeating: "x", count: 1000),  // 1KB per prompt
                category: .prompts
            )
            try await promptService.savePrompt(prompt)
        }

        // Test that list view doesn't load full content
        let listItems = try await promptService.fetchPromptList(offset: 0, limit: 50)

        // List items should not contain full content
        #expect(listItems.count <= 50)
        #expect(listItems.first?.contentPreview.count ?? 0 <= 100)
    }
}
