import Foundation
import SwiftData
import Testing

#if os(macOS)
    @testable import Prompt_macOS
#elseif os(iOS)
    @testable import Prompt_iOS
#endif

@Suite("Prompt Management")
struct PromptManagementTests {
    let container: ModelContainer

    init() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let schema = Schema([
            Prompt.self,
            Tag.self,
            PromptMetadata.self,
            PromptVersion.self,
            AIAnalysis.self
        ])
        self.container = try ModelContainer(
            for: schema,
            configurations: config
        )
    }

    @Test("Create and save prompt")
    func createPrompt() async throws {
        let prompt = Prompt(
            title: "Test Prompt",
            content: "Test content",
            category: .prompts
        )

        try await MainActor.run {
            let context = container.mainContext
            context.insert(prompt)
            try context.save()

            let descriptor = FetchDescriptor<Prompt>()
            let prompts = try context.fetch(descriptor)
            #expect(prompts.count == 1)
            #expect(prompts.first?.title == "Test Prompt")
        }
    }

    @Test("Validate prompt categories")
    func validateCategories() {
        for category in Category.allCases {
            #expect(!category.rawValue.isEmpty)
            #expect(!category.icon.isEmpty)
        }
    }

    @Test("Prompt metadata initialization")
    func promptMetadata() {
        let prompt = Prompt(
            title: "Test",
            content: "Content",
            category: .prompts
        )

        #expect(prompt.metadata.isFavorite == false)
        #expect(prompt.metadata.viewCount == 0)
        #expect(prompt.metadata.copyCount == 0)
    }
}
