import Foundation
import os
import SwiftData

// MARK: - Search Operations
extension PromptService {
    func searchPrompts(query: String) async throws -> [PromptSummary] {
        logger.info("Searching prompts with query: \(query, privacy: .public)")

        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let descriptor = FetchDescriptor<Prompt>(
            predicate: #Predicate<Prompt> { prompt in
                prompt.title.localizedStandardContains(query) || prompt.content.localizedStandardContains(query)
            },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        let prompts = try context.fetch(descriptor)
        return prompts.map { $0.toSummary() }
    }

    /// Search with lightweight results - uses contentPreview first for performance
    func searchPromptList(query: String, searchFullContent: Bool = false) async throws -> [PromptListItem] {
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
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let descriptor: FetchDescriptor<Prompt>

        if searchFullContent {
            // Full content search (slower but more thorough)
            descriptor = FetchDescriptor<Prompt>(
                predicate: #Predicate<Prompt> { prompt in
                    prompt.title.localizedStandardContains(query) || prompt.content.localizedStandardContains(query)
                        || prompt.contentPreview.localizedStandardContains(query)
                },
                sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
            )
        } else {
            // Preview-only search (faster)
            descriptor = FetchDescriptor<Prompt>(
                predicate: #Predicate<Prompt> { prompt in
                    prompt.title.localizedStandardContains(query)
                        || prompt.contentPreview.localizedStandardContains(query)
                },
                sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
            )
        }

        let prompts = try context.fetch(descriptor)

        return prompts.map { prompt in
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
    }

    func fetchPromptsByCategory(_ category: Category) async throws -> [PromptSummary] {
        logger.info("Fetching prompts for category: \(category.rawValue, privacy: .public)")

        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let descriptor = FetchDescriptor<Prompt>(
            predicate: #Predicate<Prompt> { prompt in
                prompt.category == category
            },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        let prompts = try context.fetch(descriptor)
        return prompts.map { $0.toSummary() }
    }
}
