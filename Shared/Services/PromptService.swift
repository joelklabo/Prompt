import Foundation
import os
import SwiftData

actor PromptService {
    private let modelContainer: ModelContainer
    private let logger = Logger(subsystem: "com.prompt.app", category: "PromptService")

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
    private var listCache: [PromptListItem] = []
    private var cacheTimestamp: Date?
    private let cacheLifetime: TimeInterval = 5.0
    private var memoryIndex: [UUID: PromptListItem] = [:]

    // Cache for pre-rendered markdown content
    private var markdownCache: [UUID: AttributedString] = [:]
    private let cacheLimit = 100  // Keep last 100 rendered prompts in cache

    init(container: ModelContainer) {
        self.modelContainer = container
    }

    func fetchPrompts(offset: Int = 0, limit: Int = 50) async throws -> [Prompt] {
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

        return prompts
    }

    /// Fetch lightweight list items - extremely fast
    func fetchPromptList(offset: Int = 0, limit: Int = 50) async throws -> [PromptListItem] {
        // Check cache first
        if let cacheTimestamp = cacheTimestamp,
            Date().timeIntervalSince(cacheTimestamp) < cacheLifetime,
            !listCache.isEmpty {
            let startIndex = min(offset, listCache.count)
            let endIndex = min(offset + limit, listCache.count)
            return Array(listCache[startIndex..<endIndex])
        }

        // Use background context
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        var descriptor = FetchDescriptor<Prompt>(
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )

        let prompts = try context.fetch(descriptor)

        // Convert to lightweight DTOs
        listCache = prompts.map { prompt in
            PromptListItem(
                id: prompt.id,
                title: prompt.title,
                category: prompt.category,
                modifiedAt: prompt.modifiedAt,
                isFavorite: prompt.metadata.isFavorite,
                tagCount: prompt.tags.count,
                contentPreview: String(prompt.content.prefix(100))
            )
        }

        // Update memory index
        memoryIndex.removeAll()
        for item in listCache {
            memoryIndex[item.id] = item
        }

        cacheTimestamp = Date()

        // Return requested slice
        let startIndex = min(offset, listCache.count)
        let endIndex = min(offset + limit, listCache.count)
        return Array(listCache[startIndex..<endIndex])
    }

    func fetchPromptsCount() async throws -> Int {
        logger.info("Fetching total prompts count")

        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let descriptor = FetchDescriptor<Prompt>()
        return try context.fetchCount(descriptor)
    }

    func fetchPrompt(id: UUID) async throws -> Prompt? {
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

    func savePrompt(_ prompt: Prompt) async throws {
        logger.info("Saving prompt: \(prompt.title, privacy: .public)")

        // Pre-render markdown content in background
        await preRenderMarkdown(for: prompt)

        // Use background context
        let context = ModelContext(modelContainer)
        context.insert(prompt)
        try context.save()

        // Invalidate cache
        cacheTimestamp = nil
    }

    func updatePrompt(_ prompt: Prompt) async throws {
        logger.info("Updating prompt: \(prompt.id)")
        prompt.modifiedAt = Date()

        // Pre-render markdown content if content changed
        await preRenderMarkdown(for: prompt)

        let context = ModelContext(modelContainer)
        try context.save()

        // Invalidate cache
        cacheTimestamp = nil
    }

    func deletePrompt(_ prompt: Prompt) async throws {
        logger.info("Deleting prompt: \(prompt.id)")

        let context = ModelContext(modelContainer)
        context.delete(prompt)
        try context.save()

        // Invalidate cache
        cacheTimestamp = nil
    }

    func deletePromptById(_ id: UUID) async throws {
        logger.info("Deleting prompt by id: \(id)")

        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Prompt>(
            predicate: #Predicate<Prompt> { prompt in
                prompt.id == id
            }
        )

        if let prompt = try context.fetch(descriptor).first {
            context.delete(prompt)
            try context.save()

            // Invalidate cache
            cacheTimestamp = nil
        }
    }

    func searchPrompts(query: String) async throws -> [Prompt] {
        logger.info("Searching prompts with query: \(query, privacy: .public)")

        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let descriptor = FetchDescriptor<Prompt>(
            predicate: #Predicate<Prompt> { prompt in
                prompt.title.localizedStandardContains(query) || prompt.content.localizedStandardContains(query)
            },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Search with lightweight results
    func searchPromptList(query: String) async throws -> [PromptListItem] {
        let normalizedQuery = query.lowercased()

        // First check cache if available
        if cacheTimestamp != nil, !listCache.isEmpty {
            let filtered = listCache.filter { item in
                item.title.lowercased().contains(normalizedQuery)
                    || item.contentPreview.lowercased().contains(normalizedQuery)
            }
            if !filtered.isEmpty {
                return filtered
            }
        }

        // Otherwise fetch from database
        let prompts = try await searchPrompts(query: query)

        return prompts.map { prompt in
            PromptListItem(
                id: prompt.id,
                title: prompt.title,
                category: prompt.category,
                modifiedAt: prompt.modifiedAt,
                isFavorite: prompt.metadata.isFavorite,
                tagCount: prompt.tags.count,
                contentPreview: String(prompt.content.prefix(100))
            )
        }
    }

    func fetchPromptsByCategory(_ category: Category) async throws -> [Prompt] {
        logger.info("Fetching prompts for category: \(category.rawValue, privacy: .public)")

        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let descriptor = FetchDescriptor<Prompt>(
            predicate: #Predicate<Prompt> { prompt in
                prompt.category == category
            },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func addTag(_ tag: Tag, to prompt: Prompt) async throws {
        logger.info("Adding tag \(tag.name, privacy: .public) to prompt \(prompt.id)")
        prompt.tags.append(tag)
        prompt.modifiedAt = Date()

        let context = ModelContext(modelContainer)
        try context.save()

        // Invalidate cache
        cacheTimestamp = nil
    }

    func removeTag(_ tag: Tag, from prompt: Prompt) async throws {
        logger.info("Removing tag \(tag.name, privacy: .public) from prompt \(prompt.id)")
        prompt.tags.removeAll { $0.id == tag.id }
        prompt.modifiedAt = Date()

        let context = ModelContext(modelContainer)
        try context.save()

        // Invalidate cache
        cacheTimestamp = nil
    }

    func toggleFavorite(for prompt: Prompt) async throws {
        logger.info("Toggling favorite for prompt \(prompt.id)")
        prompt.metadata.isFavorite.toggle()
        prompt.modifiedAt = Date()

        let context = ModelContext(modelContainer)
        try context.save()

        // Invalidate cache
        cacheTimestamp = nil
    }

    func toggleFavoriteById(_ id: UUID) async throws {
        guard let prompt = try await fetchPrompt(id: id) else { return }
        try await toggleFavorite(for: prompt)
    }

    func createVersion(for prompt: Prompt, changeDescription: String? = nil) async throws {
        logger.info("Creating version for prompt \(prompt.id)")
        let versionNumber = prompt.versions.count + 1
        let version = PromptVersion(
            versionNumber: versionNumber,
            title: prompt.title,
            content: prompt.content,
            changeDescription: changeDescription
        )
        prompt.versions.append(version)

        let context = ModelContext(modelContainer)
        try context.save()
    }

    // MARK: - Markdown Caching

    func getRenderedMarkdown(for prompt: Prompt) async -> AttributedString? {
        // Check cache first
        if let cached = markdownCache[prompt.id] {
            logger.debug("Returning cached markdown for prompt: \(prompt.id)")
            return cached
        }

        // If not cached, render it
        let rendered = await renderMarkdown(prompt.content)
        if let rendered = rendered {
            await cacheRenderedMarkdown(rendered, for: prompt.id)
        }
        return rendered
    }

    private func preRenderMarkdown(for prompt: Prompt) async {
        logger.debug("Pre-rendering markdown for prompt: \(prompt.id)")
        if let rendered = await renderMarkdown(prompt.content) {
            await cacheRenderedMarkdown(rendered, for: prompt.id)
        }
    }

    private func renderMarkdown(_ content: String) async -> AttributedString? {
        do {
            return try AttributedString(
                markdown: content,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
        } catch {
            // Fallback to plain text if markdown parsing fails
            return AttributedString(content)
        }
    }

    private func cacheRenderedMarkdown(_ rendered: AttributedString, for promptId: UUID) async {
        markdownCache[promptId] = rendered

        // Implement simple LRU eviction if cache is too large
        if markdownCache.count > cacheLimit {
            // Remove oldest entries (this is simplified - in production use proper LRU)
            let entriesToRemove = markdownCache.count - cacheLimit
            let keysToRemove = Array(markdownCache.keys.prefix(entriesToRemove))
            for key in keysToRemove {
                markdownCache.removeValue(forKey: key)
            }
        }
    }

    func clearMarkdownCache() async {
        logger.info("Clearing markdown cache")
        markdownCache.removeAll()
    }

    /// Invalidate list cache
    func invalidateCache() {
        cacheTimestamp = nil
        listCache.removeAll()
        memoryIndex.removeAll()
    }

    /// Prefetch adjacent prompts for instant navigation
    func prefetchAdjacentPrompts(currentId: UUID) async {
        guard let currentIndex = listCache.firstIndex(where: { $0.id == currentId }) else { return }

        let prefetchIndices = [
            currentIndex - 1,
            currentIndex + 1
        ]
        .filter { $0 >= 0 && $0 < listCache.count }

        for index in prefetchIndices {
            let item = listCache[index]
            Task {
                _ = try? await self.fetchPrompt(id: item.id)
            }
        }
    }
}
