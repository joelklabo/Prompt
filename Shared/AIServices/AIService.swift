import Foundation
import os

// Note: Foundation Models framework is iOS 26/macOS 26 only
// This is a mock implementation for development
// Will be replaced with real implementation when Foundation Models is available

@MainActor
final class AIService: ObservableObject {
    private let logger = Logger(subsystem: "com.prompt.app", category: "AIService")
    @Published var isAnalyzing = false

    func analyzePrompt(_ prompt: Prompt) async throws -> AIAnalysis {
        logger.info("Starting AI analysis for prompt: \(prompt.id)")
        isAnalyzing = true
        defer { isAnalyzing = false }

        // Mock implementation - replace with Foundation Models when available
        try await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5 second delay

        // Generate mock analysis based on prompt content
        let suggestedTags = generateMockTags(for: prompt)
        let category = detectCategory(for: prompt)
        let confidence = Double.random(in: 0.7...0.95)
        let summary = generateSummary(for: prompt)
        let suggestions = generateSuggestions(for: prompt)

        let analysis = AIAnalysis(
            suggestedTags: suggestedTags,
            category: category,
            categoryConfidence: confidence,
            summary: summary,
            enhancementSuggestions: suggestions,
            relatedPromptIDs: []
        )

        logger.info("AI analysis completed with \(analysis.suggestedTags.count) tags")
        return analysis
    }

    func analyzeBatch(_ prompts: [Prompt]) async throws -> [AIAnalysis] {
        logger.info("Starting batch analysis for \(prompts.count) prompts")

        return try await withThrowingTaskGroup(of: AIAnalysis.self) { group in
            for prompt in prompts {
                group.addTask { [self] in
                    try await self.analyzePrompt(prompt)
                }
            }

            var results: [AIAnalysis] = []
            for try await analysis in group {
                results.append(analysis)
            }

            logger.info("Batch analysis completed")
            return results
        }
    }

    func generatePromptImprovement(_ prompt: Prompt) async throws -> String {
        logger.info("Generating improvement for prompt: \(prompt.id)")
        isAnalyzing = true
        defer { isAnalyzing = false }

        try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second delay

        // Mock improvement generation
        let improvements = [
            "Consider adding more specific context about the desired output format.",
            "Include examples to make the prompt more concrete.",
            "Specify any constraints or requirements more clearly.",
            "Break down complex instructions into numbered steps.",
            "Add information about the expected tone or style."
        ]

        return improvements.randomElement() ?? "No specific improvements suggested."
    }

    // MARK: - Mock Helpers

    private func generateMockTags(for prompt: Prompt) -> [String] {
        var tags: [String] = []

        // Analyze content for keywords
        let content = prompt.title.lowercased() + " " + prompt.content.lowercased()

        if content.contains("code") || content.contains("programming") {
            tags.append("coding")
        }
        if content.contains("write") || content.contains("writing") {
            tags.append("writing")
        }
        if content.contains("analyze") || content.contains("analysis") {
            tags.append("analysis")
        }
        if content.contains("create") || content.contains("generate") {
            tags.append("creative")
        }
        if content.contains("help") || content.contains("assist") {
            tags.append("assistant")
        }
        if content.contains("data") || content.contains("database") {
            tags.append("data")
        }
        if content.contains("api") || content.contains("integration") {
            tags.append("integration")
        }
        if content.contains("test") || content.contains("debug") {
            tags.append("testing")
        }

        // Add some general tags
        let generalTags = ["productivity", "workflow", "automation", "task", "template"]
        if tags.count < 3 {
            tags.append(contentsOf: generalTags.shuffled().prefix(3 - tags.count))
        }

        return Array(tags.prefix(5))
    }

    private func detectCategory(for prompt: Prompt) -> Category {
        let content = prompt.content.lowercased()

        if content.contains("config") || content.contains("setting") || content.contains("preference") {
            return .configs
        } else if content.contains("command") || content.contains("cli") || content.contains("terminal") {
            return .commands
        } else {
            return .prompts
        }
    }

    private func generateSummary(for prompt: Prompt) -> String {
        let templates = [
            "A prompt for \(prompt.category.rawValue.lowercased()) that helps with workflow optimization",
            "This prompt provides guidance for \(prompt.category.rawValue.lowercased()) tasks",
            "An automated template for handling \(prompt.category.rawValue.lowercased()) operations",
            "A structured approach to \(prompt.category.rawValue.lowercased()) management",
            "Useful for streamlining \(prompt.category.rawValue.lowercased()) processes"
        ]

        return templates.randomElement() ?? "A useful prompt template"
    }

    private func generateSuggestions(for prompt: Prompt) -> [String] {
        let allSuggestions = [
            "Add more specific examples to illustrate the use case",
            "Include expected output format for clarity",
            "Consider adding edge case handling",
            "Specify any prerequisites or requirements",
            "Add version or compatibility information",
            "Include troubleshooting tips",
            "Consider breaking into smaller, focused prompts",
            "Add tags for better organization"
        ]

        return Array(allSuggestions.shuffled().prefix(Int.random(in: 1...3)))
    }
}

// MARK: - Streaming Support (for future implementation)

extension AIService {
    struct StreamingAnalysis {
        var partialTags: [String] = []
        var partialSummary: String = ""
        var isComplete: Bool = false
    }

    func streamAnalysis(for prompt: Prompt, update: @escaping (StreamingAnalysis) -> Void) async throws {
        logger.info("Starting streaming analysis")

        var analysis = StreamingAnalysis()

        // Simulate streaming by updating in chunks
        for index in 0..<3 {
            try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 second

            if index == 0 {
                analysis.partialTags = Array(generateMockTags(for: prompt).prefix(2))
            } else if index == 1 {
                analysis.partialTags = generateMockTags(for: prompt)
                analysis.partialSummary = String(generateSummary(for: prompt).prefix(20)) + "..."
            } else {
                analysis.partialSummary = generateSummary(for: prompt)
                analysis.isComplete = true
            }

            await MainActor.run {
                update(analysis)
            }
        }

        logger.info("Streaming analysis completed")
    }
}
