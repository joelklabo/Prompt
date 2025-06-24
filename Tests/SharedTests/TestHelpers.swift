import Foundation
import SwiftData
import Testing

#if os(macOS)
    @testable import Prompt_macOS
#elseif os(iOS)
    @testable import Prompt_iOS
#endif

enum TestHelpers {
    static var isCIEnvironment: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    static func createTestContainer() throws -> ModelContainer {
        let schema = Schema([
            Prompt.self,
            Tag.self,
            PromptMetadata.self,
            PromptVersion.self,
            AIAnalysis.self
        ])

        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )

        return try ModelContainer(
            for: schema,
            configurations: [config]
        )
    }

    static func createSamplePrompts(count: Int = 10) -> [Prompt] {
        (0..<count)
            .map { index in
                let categories = Category.allCases
                let category = categories[index % categories.count]

                let prompt = Prompt(
                    title: "Sample Prompt \(index)",
                    content: """
                        This is sample content for prompt \(index). \
                        It contains various keywords for testing search functionality.
                        """,
                    category: category
                )

                // Add some metadata
                prompt.metadata.viewCount = Int.random(in: 0...100)
                prompt.metadata.copyCount = Int.random(in: 0...20)
                prompt.metadata.isFavorite = index % 3 == 0

                if index % 2 == 0 {
                    prompt.metadata.lastViewedAt = Date().addingTimeInterval(TimeInterval(-index * 3600))
                }

                return prompt
            }
    }

    static func createSampleTags() -> [Tag] {
        let tagNames = ["swift", "ios", "macos", "testing", "ai", "productivity", "automation", "template"]
        let colors = ["#FF6B6B", "#4ECDC4", "#45B7D1", "#96CEB4", "#FECA57", "#48DBFB", "#FF9FF3", "#54A0FF"]

        return tagNames.enumerated()
            .map { index, name in
                Tag(name: name, color: colors[index % colors.count])
            }
    }

    static func measureTime<T>(
        expectedDuration: Duration = .seconds(1),
        operation: () async throws -> T
    ) async throws -> T {
        let start = ContinuousClock.now
        let result = try await operation()
        let duration = start.duration(to: .now)

        #expect(duration <= expectedDuration)
        return result
    }
}

// Test data generator
struct TestDataGenerator {
    static func generatePrompts(count: Int, in container: ModelContainer) async throws {
        try await MainActor.run {
            let context = container.mainContext
            let tags = TestHelpers.createSampleTags()

            // Insert tags first
            for tag in tags {
                context.insert(tag)
            }

            // Generate prompts
            for idx in 0..<count {
                let prompt = TestHelpers.createSamplePrompts(count: 1).first!
                prompt.title = "Generated Prompt \(idx)"

                // Add random tags
                let tagCount = Int.random(in: 0...3)
                for _ in 0..<tagCount {
                    if let randomTag = tags.randomElement() {
                        prompt.tags.append(randomTag)
                    }
                }

                // Add AI analysis for some prompts
                if idx % 5 == 0 {
                    let analysis = AIAnalysis(
                        suggestedTags: ["generated", "test", "sample"],
                        category: prompt.category,
                        categoryConfidence: Double.random(in: 0.7...0.95),
                        summary: "Auto-generated test prompt for performance testing",
                        enhancementSuggestions: ["Add more context", "Include examples"],
                        relatedPromptIDs: []
                    )
                    prompt.aiAnalysis = analysis
                    context.insert(analysis)
                }

                context.insert(prompt)

                // Save in batches to improve performance
                if idx % 100 == 0 {
                    try context.save()
                }
            }

            try context.save()
        }
    }
}
