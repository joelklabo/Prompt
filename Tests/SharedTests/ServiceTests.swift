import Foundation
import SwiftData
import Testing

@testable import Prompt_macOS

@Suite("Service Tests")
struct ServiceTests {
    let container: ModelContainer
    let promptService: PromptService
    let tagService: TagService

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

        self.promptService = PromptService(container: container)
        self.tagService = TagService(container: container)
    }

    @Test("Fetch prompts returns sorted list")
    func fetchPromptsSorted() async throws {
        // Create prompts with different dates
        let prompt1 = Prompt(title: "First", content: "Content 1", category: .prompts)
        let prompt2 = Prompt(title: "Second", content: "Content 2", category: .prompts)

        try await promptService.savePrompt(prompt1)

        // Ensure different modification times
        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second

        prompt2.modifiedAt = Date()
        try await promptService.savePrompt(prompt2)

        let prompts = try await promptService.fetchPrompts()

        #expect(prompts.count == 2)
        #expect(prompts.first?.title == "Second")  // Most recent first
        #expect(prompts.last?.title == "First")
    }

    @Test("Search prompts by content")
    func searchPrompts() async throws {
        let prompt1 = Prompt(
            title: "Swift Testing",
            content: "Learn about the new Swift Testing framework",
            category: .prompts
        )
        let prompt2 = Prompt(
            title: "SwiftUI Tips",
            content: "Best practices for SwiftUI development",
            category: .prompts
        )
        let prompt3 = Prompt(
            title: "Database Setup",
            content: "Configure PostgreSQL for production",
            category: .configs
        )

        try await promptService.savePrompt(prompt1)
        try await promptService.savePrompt(prompt2)
        try await promptService.savePrompt(prompt3)

        // Search for "Swift"
        let swiftResults = try await promptService.searchPrompts(query: "Swift")
        #expect(swiftResults.count == 2)

        // Search for "database"
        let dbResults = try await promptService.searchPrompts(query: "database")
        #expect(dbResults.count == 1)
        #expect(dbResults.first?.title == "Database Setup")

        // Search for "production"
        let prodResults = try await promptService.searchPrompts(query: "production")
        #expect(prodResults.count == 1)
    }

    @Test("Fetch prompts by category")
    func fetchByCategory() async throws {
        let prompt1 = Prompt(title: "Prompt 1", content: "Content", category: .prompts)
        let prompt2 = Prompt(title: "Config 1", content: "Content", category: .configs)
        let prompt3 = Prompt(title: "Command 1", content: "Content", category: .commands)
        let prompt4 = Prompt(title: "Prompt 2", content: "Content", category: .prompts)

        try await promptService.savePrompt(prompt1)
        try await promptService.savePrompt(prompt2)
        try await promptService.savePrompt(prompt3)
        try await promptService.savePrompt(prompt4)

        let promptResults = try await promptService.fetchPromptsByCategory(.prompts)
        #expect(promptResults.count == 2)

        let configResults = try await promptService.fetchPromptsByCategory(.configs)
        #expect(configResults.count == 1)

        let commandResults = try await promptService.fetchPromptsByCategory(.commands)
        #expect(commandResults.count == 1)
    }

    @Test("Toggle favorite status")
    func toggleFavorite() async throws {
        let prompt = Prompt(
            title: "Favorite Test",
            content: "Testing favorites",
            category: .prompts
        )

        #expect(prompt.metadata.isFavorite == false)

        try await promptService.savePrompt(prompt)
        try await promptService.toggleFavorite(for: prompt)

        #expect(prompt.metadata.isFavorite == true)

        try await promptService.toggleFavorite(for: prompt)
        #expect(prompt.metadata.isFavorite == false)
    }

    @Test("Create and manage tags")
    func tagManagement() async throws {
        // Create tag
        let tag = try await tagService.createTag(name: "swift", color: "#FF6B6B")
        #expect(tag.name == "swift")
        #expect(tag.color == "#FF6B6B")

        // Find or create existing tag
        let existingTag = try await tagService.findOrCreateTag(name: "swift")
        #expect(existingTag.id == tag.id)

        // Find or create new tag
        let newTag = try await tagService.findOrCreateTag(name: "testing")
        #expect(newTag.id != tag.id)
        #expect(newTag.name == "testing")

        // Fetch all tags
        let allTags = try await tagService.fetchAllTags()
        #expect(allTags.count == 2)
    }

    @Test("Add and remove tags from prompt")
    func promptTagOperations() async throws {
        let prompt = Prompt(
            title: "Tag Test",
            content: "Testing tags",
            category: .prompts
        )

        let tag1 = try await tagService.createTag(name: "tag1")
        let tag2 = try await tagService.createTag(name: "tag2")

        try await promptService.savePrompt(prompt)

        // Add tags
        try await promptService.addTag(tag1, to: prompt)
        try await promptService.addTag(tag2, to: prompt)

        #expect(prompt.tags.count == 2)

        // Remove tag
        try await promptService.removeTag(tag1, from: prompt)
        #expect(prompt.tags.count == 1)
        #expect(prompt.tags.first?.name == "tag2")
    }

    @Test("Create version history")
    func versionHistory() async throws {
        let prompt = Prompt(
            title: "Version Test",
            content: "Original content",
            category: .prompts
        )

        try await promptService.savePrompt(prompt)

        // Create first version
        try await promptService.createVersion(
            for: prompt,
            changeDescription: "Initial version"
        )

        #expect(prompt.versions.count == 1)
        #expect(prompt.versions.first?.versionNumber == 1)

        // Update and create another version
        prompt.content = "Updated content"
        try await promptService.createVersion(
            for: prompt,
            changeDescription: "Updated content"
        )

        #expect(prompt.versions.count == 2)
        #expect(prompt.versions.last?.versionNumber == 2)
        #expect(prompt.versions.last?.content == "Original content")
    }
}
