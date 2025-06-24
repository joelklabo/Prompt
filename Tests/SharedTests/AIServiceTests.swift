import Foundation
import Testing

#if os(macOS)
    @testable import Prompt_macOS
#elseif os(iOS)
    @testable import Prompt_iOS
#endif

@Suite("AI Analysis Tests")
@MainActor
struct AIAnalysisTests {
    let aiService = AIService()

    @Test("Analyze prompt with mock AI", .serialized)
    func analyzePrompt() async throws {
        let prompt = Prompt(
            title: "Code Review Assistant",
            content: "Please review this code for best practices and potential improvements",
            category: .prompts
        )

        let analysis = try await aiService.analyzePrompt(prompt)

        #expect(!analysis.suggestedTags.isEmpty)
        #expect(analysis.suggestedTags.count <= 5)
        // Category is non-optional so always exists
        #expect(analysis.categoryConfidence >= 0.0)
        #expect(analysis.categoryConfidence <= 1.0)
        #expect(analysis.summary != nil)
        #expect(!analysis.summary!.isEmpty)
        #expect(!analysis.enhancementSuggestions.isEmpty)
    }

    @Test("Streaming analysis updates", .serialized)
    func streamingAnalysis() async throws {
        let prompt = Prompt.sample
        var partialResults: [AIService.StreamingAnalysis] = []

        try await aiService.streamAnalysis(for: prompt) { partial in
            partialResults.append(partial)
        }

        #expect(!partialResults.isEmpty)
        #expect(partialResults.last?.isComplete == true)

        // Verify progressive updates
        if partialResults.count >= 2 {
            #expect(partialResults[0].partialTags.count <= partialResults[1].partialTags.count)
        }
    }

    @Test(
        "Batch analysis performance",
        arguments: [2, 5, 10]
    )
    func batchAnalysisPerformance(count: Int) async throws {
        let prompts = (0..<count)
            .map { idx in
                Prompt(
                    title: "Test Prompt \(idx)",
                    content: "Content for prompt \(idx)",
                    category: .prompts
                )
            }

        let startTime = Date()
        let results = try await aiService.analyzeBatch(prompts)
        let duration = Date().timeIntervalSince(startTime)

        #expect(results.count == count)
        #expect(duration < Double(count) * 2.0)  // Max 2s per prompt

        // Verify all results are valid
        for analysis in results {
            #expect(!analysis.suggestedTags.isEmpty)
            #expect(analysis.categoryConfidence > 0)
        }
    }

    @Test("Category detection accuracy")
    func categoryDetection() async throws {
        struct TestCase {
            let title: String
            let content: String
            let expectedCategory: Category
        }

        let testCases = [
            TestCase(
                title: "Config Setup", content: "database_url: postgres://localhost config_file: app.yml",
                expectedCategory: .configs),
            TestCase(
                title: "Git Command", content: "git commit -m 'feat: add new feature' && git push origin main",
                expectedCategory: .commands),
            TestCase(
                title: "Writing Assistant", content: "Help me write a blog post about Swift Testing",
                expectedCategory: .prompts)
        ]

        for testCase in testCases {
            let prompt = Prompt(title: testCase.title, content: testCase.content, category: .prompts)
            let analysis = try await aiService.analyzePrompt(prompt)

            #expect(analysis.category == testCase.expectedCategory)
            #expect(analysis.categoryConfidence >= 0.5)  // At least 50% confidence
        }
    }

    @Test("Generate prompt improvement suggestions")
    func promptImprovement() async throws {
        let prompt = Prompt(
            title: "Vague Request",
            content: "Help me with code",
            category: .prompts
        )

        let improvement = try await aiService.generatePromptImprovement(prompt)

        #expect(!improvement.isEmpty)
        #expect(improvement.count > 20)  // Meaningful suggestion
    }
}
