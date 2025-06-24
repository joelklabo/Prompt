import Foundation
import os
import SwiftData

// MARK: - Cache Management
extension PromptService {
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

        let descriptor = FetchDescriptor<Prompt>(
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
                contentPreview: prompt.contentPreview.isEmpty
                    ? String(prompt.content.prefix(200)) : prompt.contentPreview
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

    func preRenderMarkdown(for prompt: Prompt) async {
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
                if let prompt = try? await self.fetchPromptInternal(id: item.id) {
                    // Prefetch content for external storage
                    if prompt.storageType == .external {
                        _ = try? await self.loadContent(for: prompt)
                    }
                }
            }
        }
    }

    /// Prefetch content for multiple prompts
    func prefetchContent(for promptIds: [UUID]) async {
        for id in promptIds {
            if let prompt = try? await fetchPromptInternal(id: id),
                prompt.storageType == .external {
                _ = try? await loadContent(for: prompt)
            }
        }
    }
}
