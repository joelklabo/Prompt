import Foundation
import SwiftData
import Testing

#if os(macOS)
    @testable import Prompt_macOS
#elseif os(iOS)
    @testable import Prompt_iOS
#endif

@Suite("Prompt Model Tests")
struct PromptModelTests {
    let container: ModelContainer

    init() async throws {
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
            #expect(prompts.first?.category == .prompts)
        }
    }

    @Test("Update prompt maintains version history")
    func updatePromptVersioning() async throws {
        let prompt = Prompt(
            title: "Original Title",
            content: "Original content",
            category: .prompts
        )

        try await MainActor.run {
            let context = container.mainContext
            context.insert(prompt)

            // Create a version
            let version = PromptVersion(
                versionNumber: 1,
                title: prompt.title,
                content: prompt.content,
                changeDescription: "Initial version"
            )
            prompt.versions.append(version)

            // Update prompt
            prompt.title = "Updated Title"
            prompt.content = "Updated content"
            prompt.modifiedAt = Date()

            try context.save()

            #expect(prompt.versions.count == 1)
            #expect(prompt.versions.first?.title == "Original Title")
            #expect(prompt.title == "Updated Title")
        }
    }

    @Test(
        "Validate prompt categories",
        arguments: Category.allCases
    )
    func validateCategory(category: Category) {
        #expect(!category.rawValue.isEmpty)
        #expect(!category.icon.isEmpty)

        switch category {
        case .prompts:
            #expect(category.icon == "text.bubble")
        case .configs:
            #expect(category.icon == "gearshape")
        case .commands:
            #expect(category.icon == "terminal")
        case .context:
            #expect(category.icon == "doc.text.fill")
        }
    }

    @Test("Prompt metadata tracking")
    func promptMetadata() async throws {
        let prompt = Prompt(
            title: "Metadata Test",
            content: "Testing metadata",
            category: .prompts
        )

        // Test initial state
        #expect(prompt.metadata.viewCount == 0)
        #expect(prompt.metadata.copyCount == 0)
        #expect(prompt.metadata.isFavorite == false)
        #expect(prompt.metadata.lastViewedAt == nil)

        // Update metadata
        prompt.metadata.viewCount += 1
        prompt.metadata.copyCount += 1
        prompt.metadata.isFavorite = true
        prompt.metadata.lastViewedAt = Date()

        try await MainActor.run {
            let context = container.mainContext
            context.insert(prompt)
            try context.save()

            let fetched = try context.fetch(FetchDescriptor<Prompt>()).first
            #expect(fetched?.metadata.viewCount == 1)
            #expect(fetched?.metadata.copyCount == 1)
            #expect(fetched?.metadata.isFavorite == true)
            #expect(fetched?.metadata.lastViewedAt != nil)
        }
    }

    @Test("Prompt relationships")
    func promptRelationships() async throws {
        try await MainActor.run {
            let context = container.mainContext
            
            let prompt = Prompt(
                title: "Relationship Test",
                content: "Testing relationships",
                category: .prompts
            )

            let tag1 = Tag(name: "swift", color: "#FF6B6B")
            let tag2 = Tag(name: "testing", color: "#4ECDC4")

            prompt.tags.append(tag1)
            prompt.tags.append(tag2)

            context.insert(prompt)
            context.insert(tag1)
            context.insert(tag2)
            try context.save()

            #expect(prompt.tags.count == 2)
            #expect(tag1.prompts.contains { $0.id == prompt.id })
            #expect(tag2.prompts.contains { $0.id == prompt.id })
        }
    }
}
