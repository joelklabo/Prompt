import Foundation
import os
import SwiftData

actor PromptService: ModelActor {
    let modelContainer: ModelContainer
    let modelExecutor: any ModelExecutor
    internal let logger = Logger(subsystem: "com.prompt.app", category: "PromptService")
    // TODO: Enable when HybridContentStore is added to Xcode project
    // private let contentStore: HybridContentStore?
    internal let contentStore: Any?  // Placeholder

    // Lightweight DTO for list views
    struct PromptListItem: Sendable {
        let id: UUID
        let title: String
        let category: Category
        let modifiedAt: Date
        let isFavorite: Bool
        let tagCount: Int
        let contentPreview: String
    }

    // In-memory cache for instant access
    internal var listCache: [PromptListItem] = []
    internal var cacheTimestamp: Date?
    internal let cacheLifetime: TimeInterval = 5.0
    internal var memoryIndex: [UUID: PromptListItem] = [:]

    // Cache for pre-rendered markdown content
    internal var markdownCache: [UUID: AttributedString] = [:]
    internal let cacheLimit = 100  // Keep last 100 rendered prompts in cache

    // TODO: Change back to HybridContentStore when added to project
    init(container: ModelContainer, contentStore: Any? = nil) {
        self.modelContainer = container
        let context = ModelContext(container)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.contentStore = contentStore
    }

    // MARK: - Public methods return DTOs (Sendable)

    func fetchPrompts(offset: Int = 0, limit: Int = 50) async throws -> [PromptSummary] {
        logger.info("Fetching prompts with offset: \(offset), limit: \(limit)")

        // Create background context - no MainActor blocking
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        var descriptor = FetchDescriptor<Prompt>(
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit

        let prompts = try context.fetch(descriptor)

        // Force load relationships while in background
        for prompt in prompts {
            _ = prompt.tags.count
            _ = prompt.metadata
        }

        // Convert to DTOs before returning
        return prompts.map { $0.toSummary() }
    }

    /// Fetch prompt summaries optimized for list views (excludes content)
    func fetchPromptSummaries() async throws -> [PromptSummary] {
        logger.info("Fetching prompt summaries with optimized query")

        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        // Note: SwiftData doesn't support propertiesToFetch directly
        // But we can minimize memory usage by not accessing content field
        let descriptor = FetchDescriptor<Prompt>(
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )

        let prompts = try context.fetch(descriptor)

        // Convert to summaries without accessing content field
        return prompts.map { prompt in
            PromptSummary(
                id: prompt.id,
                title: prompt.title,
                contentPreview: prompt.contentPreview,
                category: prompt.category,
                tagNames: prompt.tags.map(\.name),
                createdAt: prompt.createdAt,
                modifiedAt: prompt.modifiedAt,
                isFavorite: prompt.metadata.isFavorite,
                viewCount: Int16(min(prompt.metadata.viewCount, Int(Int16.max))),
                copyCount: Int16(min(prompt.metadata.copyCount, Int(Int16.max))),
                categoryConfidence: prompt.aiAnalysis?.categoryConfidence,
                shortLink: prompt.metadata.shortCode.flatMap { URL(string: "https://prompt.app/\($0)") }
            )
        }
    }


    func fetchPromptsCount() async throws -> Int {
        logger.info("Fetching total prompts count")

        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let descriptor = FetchDescriptor<Prompt>()
        return try context.fetchCount(descriptor)
    }

    // Internal method to fetch within actor context
    internal func fetchPrompt(id: UUID) throws -> Prompt? {
        let descriptor = FetchDescriptor<Prompt>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first
    }

    // Internal method that returns non-Sendable Prompt
    internal func fetchPromptInternal(id: UUID) async throws -> Prompt? {
        logger.info("Fetching prompt: \(id)")

        // Use background context
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let descriptor = FetchDescriptor<Prompt>(
            predicate: #Predicate<Prompt> { prompt in
                prompt.id == id
            }
        )

        let results = try context.fetch(descriptor)
        guard let prompt = results.first else { return nil }

        // Force load relationships while in background
        _ = prompt.tags.count
        _ = prompt.versions.count
        _ = prompt.aiAnalysis
        _ = prompt.metadata

        return prompt
    }

    // Public method returns DTO
    func getPromptDetail(id: UUID) async throws -> PromptDetail? {
        logger.info("Fetching prompt detail for id: \(id)")
        guard let prompt = try await fetchPromptInternal(id: id) else { return nil }
        return prompt.toDetail()
    }

    func getPromptSummary(id: UUID) async throws -> PromptSummary? {
        logger.info("Fetching prompt summary for id: \(id)")
        guard let prompt = try await fetchPromptInternal(id: id) else { return nil }
        return prompt.toSummary()
    }

    // MARK: - Lazy Loading Methods

    /// Load content for a prompt (from hybrid storage if needed)
    func loadContent(for prompt: Prompt) async throws -> String {
        // If content is already cached in the prompt, return it
        if let cached = prompt._cachedContent {
            return cached
        }

        // If using external storage, load from content store
        if prompt.storageType == .external,
            contentStore != nil,  // TODO: cast to HybridContentStore
            prompt.contentHash != nil {
            // TODO: Use HybridContentStore.ContentReference when added to project
            // For now, use the content directly from prompt
            let content = prompt.content
            // let content = try await contentStore.retrieve(reference)
            // TODO: Implement proper retrieval when HybridContentStore is in project
            // prompt._cachedContent = content
            prompt._cachedContent = prompt.content  // TODO: Use actual content from HybridContentStore
            return content
        }

        // Otherwise return the content from SwiftData
        return prompt.content
    }

    /// Load content if needed (only loads if not already cached)
    func loadContentIfNeeded(for prompt: Prompt) async throws {
        if prompt._cachedContent == nil && prompt.storageType == .external {
            _ = try await loadContent(for: prompt)
        }
    }
    
    /// Load content for a prompt by ID without exposing the Prompt object across actor boundaries
    func loadContentForPrompt(id: UUID) async throws -> String {
        logger.info("Loading content for prompt: \(id)")
        
        // Use background context
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        
        let descriptor = FetchDescriptor<Prompt>(
            predicate: #Predicate<Prompt> { prompt in
                prompt.id == id
            }
        )
        
        guard let prompt = try context.fetch(descriptor).first else {
            throw PromptError.notFound(id)
        }
        
        // If content is already cached in the prompt, return it
        if let cached = prompt._cachedContent {
            return cached
        }
        
        // If using external storage, load from content store
        if prompt.storageType == .external,
            contentStore != nil,  // TODO: cast to HybridContentStore
            prompt.contentHash != nil {
            // TODO: Use HybridContentStore.ContentReference when added to project
            return prompt.content
        }
        
        // Content should be stored inline
        return prompt.content
    }


    func createPrompt(_ request: PromptCreateRequest) async throws -> PromptDetail {
        logger.info("Creating prompt from request: \(request.title, privacy: .public)")
        guard request.isValid else {
            throw PromptError.invalidRequest
        }

        // If content store is available and content is large enough, use hybrid storage
        var storageType = StorageType.swiftData
        var contentHash: String?

        if contentStore != nil {  // TODO: cast to HybridContentStore
            // Store content externally
            // TODO: Enable when HybridContentStore is in project
            // let reference = try await contentStore.store(request.content)
            // contentHash = reference.hash
            contentHash = UUID().uuidString  // TODO: Use actual hash from HybridContentStore
            storageType = .external
        }

        let prompt = Prompt(
            title: request.title,
            // Don't store content in SwiftData if using external
            content: storageType == .external ? "" : request.content,
            category: request.category
        )

        // Update hybrid storage fields
        prompt.contentHash = contentHash
        prompt.storageType = storageType
        prompt.contentSize = request.content.utf8.count
        prompt.contentPreview = String(request.content.prefix(200))

        // Cache the content for immediate use
        if storageType == .external {
            prompt._cachedContent = request.content
        }

        // Add tags if provided
        if !request.tagIDs.isEmpty {
            for tagID in request.tagIDs {
                let descriptor = FetchDescriptor<Tag>(
                    predicate: #Predicate { $0.id == tagID }
                )
                if let tag = try modelContext.fetch(descriptor).first {
                    prompt.tags.append(tag)
                }
            }
        }

        // Pre-render markdown content
        await preRenderMarkdown(for: prompt)

        modelContext.insert(prompt)
        try modelContext.save()

        // Invalidate cache
        cacheTimestamp = nil

        return prompt.toDetail()
    }


    func analyzePrompt(id: UUID) async throws {
        logger.info("Analyzing prompt: \(id)")

        // Fetch the prompt
        guard let prompt = try await fetchPromptInternal(id: id) else {
            throw PromptError.notFound(id)
        }

        // Create a sendable representation of the prompt data
        let promptId = prompt.id
        let promptTitle = prompt.title
        let promptContent = prompt.content
        let promptCategory = prompt.category

        // Analyze using AIService on MainActor
        @MainActor
        func performAnalysis() async throws -> AIAnalysisDTO {
            let aiService = AIService()
            // Create a temporary prompt object for analysis
            let tempPrompt = Prompt(title: promptTitle, content: promptContent, category: promptCategory)
            tempPrompt.id = promptId
            let analysis = try await aiService.analyzePrompt(tempPrompt)

            // Convert to DTO
            return AIAnalysisDTO(
                suggestedTags: analysis.suggestedTags,
                category: analysis.category,
                categoryConfidence: analysis.categoryConfidence,
                summary: analysis.summary,
                enhancementSuggestions: analysis.enhancementSuggestions,
                analyzedAt: analysis.analyzedAt
            )
        }

        let analysisDTO = try await performAnalysis()

        // Create AIAnalysis from DTO
        let analysis = AIAnalysis(
            suggestedTags: analysisDTO.suggestedTags,
            category: analysisDTO.category,
            categoryConfidence: analysisDTO.categoryConfidence,
            summary: analysisDTO.summary,
            enhancementSuggestions: analysisDTO.enhancementSuggestions,
            relatedPromptIDs: []
        )

        // Update the prompt with analysis
        prompt.aiAnalysis = analysis
        try await updatePromptInternal(prompt)
    }


}
