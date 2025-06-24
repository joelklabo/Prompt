import Foundation
import SwiftData
import Testing

#if os(macOS)
    @testable import Prompt_macOS
#elseif os(iOS)
    @testable import Prompt_iOS
#endif

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
        // Create prompts in local context
        let context = ModelContext(container)
        
        let prompt1 = Prompt(title: "First", content: "Content 1", category: .prompts)
        context.insert(prompt1)
        try context.save()

        // Ensure different modification times
        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second

        let prompt2 = Prompt(title: "Second", content: "Content 2", category: .prompts)
        prompt2.modifiedAt = Date()
        context.insert(prompt2)
        try context.save()

        let prompts = try await promptService.fetchPrompts()

        #expect(prompts.count == 2)
        #expect(prompts.first?.title == "Second")  // Most recent first
        #expect(prompts.last?.title == "First")
    }

    @Test("Search prompts by content")
    func searchPrompts() async throws {
        // Create prompts in local context
        let context = ModelContext(container)
        
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

        context.insert(prompt1)
        context.insert(prompt2)
        context.insert(prompt3)
        try context.save()

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
        // Create prompts in local context
        let context = ModelContext(container)
        
        let prompt1 = Prompt(title: "Prompt 1", content: "Content", category: .prompts)
        let prompt2 = Prompt(title: "Config 1", content: "Content", category: .configs)
        let prompt3 = Prompt(title: "Command 1", content: "Content", category: .commands)
        let prompt4 = Prompt(title: "Prompt 2", content: "Content", category: .prompts)

        context.insert(prompt1)
        context.insert(prompt2)
        context.insert(prompt3)
        context.insert(prompt4)
        try context.save()

        let promptResults = try await promptService.fetchPromptsByCategory(.prompts)
        #expect(promptResults.count == 2)

        let configResults = try await promptService.fetchPromptsByCategory(.configs)
        #expect(configResults.count == 1)

        let commandResults = try await promptService.fetchPromptsByCategory(.commands)
        #expect(commandResults.count == 1)
    }

    @Test("Update prompt fields")
    func updatePromptFields() async throws {
        // Create prompt in local context to avoid passing across actor boundary
        let promptId = UUID()
        let context = ModelContext(container)
        let prompt = Prompt(
            title: "Update Test",
            content: "Testing updates",
            category: .prompts
        )
        prompt.id = promptId
        context.insert(prompt)
        try context.save()
        
        // Update title
        let updatedPrompt = try await promptService.updatePrompt(
            PromptUpdateRequest(id: promptId, field: .title, value: "Updated Title")
        )
        #expect(updatedPrompt.title == "Updated Title")
        
        // Update category
        let categoryUpdated = try await promptService.updatePrompt(
            PromptUpdateRequest(id: promptId, field: .category, value: Category.commands.rawValue)
        )
        #expect(categoryUpdated.category == .commands)
    }

    @Test("Create and manage tags")
    func tagManagement() async throws {
        // Create tag using request
        let tagRequest = TagCreateRequest(name: "swift", color: "#FF6B6B")
        let tagDetail = try await tagService.createTag(tagRequest)
        #expect(tagDetail.name == "swift")
        #expect(tagDetail.color == "#FF6B6B")

        // Find or create existing tag
        let existingTagId = try await tagService.findOrCreateTag(name: "swift")
        #expect(existingTagId == tagDetail.id)

        // Find or create new tag
        let newTagId = try await tagService.findOrCreateTag(name: "testing")
        #expect(newTagId != tagDetail.id)

        // Fetch all tags as summaries (Sendable)
        let allTags = try await tagService.fetchAllTagSummaries()
        #expect(allTags.count == 2)
    }

    @Test("Add and remove tags from prompt")
    func promptTagOperations() async throws {
        let prompt = Prompt(
            title: "Tag Test",
            content: "Testing tags",
            category: .prompts
        )

        let tag1 = try await tagService.createTag(TagCreateRequest(name: "tag1", color: "#007AFF"))
        let tag2 = try await tagService.createTag(TagCreateRequest(name: "tag2", color: "#007AFF"))

        // Save prompt in local context
        let promptId = prompt.id
        let context = ModelContext(container)
        context.insert(prompt)
        try context.save()

        // Add tags
        try await promptService.addTag(tagId: tag1.id, to: promptId)
        try await promptService.addTag(tagId: tag2.id, to: promptId)

        // Check tags through DTO
        let promptDetail1 = try await promptService.getPromptDetail(id: promptId)
        #expect(promptDetail1?.tags.count == 2)

        // Remove tag
        try await promptService.removeTag(tagId: tag1.id, from: promptId)
        
        // Check tags again through DTO
        let promptDetail2 = try await promptService.getPromptDetail(id: promptId)
        #expect(promptDetail2?.tags.count == 1)
        #expect(promptDetail2?.tags.first?.name == "tag2")
    }

    @Test("Create version history")
    func versionHistory() async throws {
        let prompt = Prompt(
            title: "Version Test",
            content: "Original content",
            category: .prompts
        )

        // Save prompt in local context
        let promptId = prompt.id
        let context = ModelContext(container)
        context.insert(prompt)
        try context.save()

        // Create first version
        try await promptService.createVersion(
            promptID: promptId,
            changeDescription: "Initial version"
        )

        // Fetch versions to see updated versions
        let versions1 = try await promptService.getPromptVersionSummaries(promptID: promptId)
        #expect(versions1.count == 1)
        #expect(versions1.first?.versionNumber == 1)

        // Update content through service and create another version
        _ = try await promptService.updatePrompt(
            PromptUpdateRequest(id: promptId, field: .content, value: "Updated content")
        )
        
        try await promptService.createVersion(
            promptID: promptId,
            changeDescription: "Updated content"
        )

        // Fetch versions again to check final state
        let versions2 = try await promptService.getPromptVersionSummaries(promptID: promptId)
        #expect(versions2.count == 2)
        // Versions are sorted descending, so last version is first
        #expect(versions2.first?.versionNumber == 2)
        // Verify the version was created with a description
        #expect(versions2.first?.changeDescription == "Updated content")
    }
}
