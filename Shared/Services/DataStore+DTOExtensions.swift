import Foundation
import os.log
import SwiftData

extension DataStore {
    /// Count objects matching a descriptor
    func count<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) async throws -> Int {
        // SwiftData doesn't have a native count, so we optimize with minimal fetch
        var countDescriptor = descriptor
        countDescriptor.propertiesToFetch = []  // Don't load any properties

        let results = try await fetch(countDescriptor)
        return results.count
    }

    /// Batch fetch with optimized property loading
    func fetchBatch<T: PersistentModel>(
        _ type: T.Type,
        predicate: Predicate<T>? = nil,
        sortBy: [SortDescriptor<T>] = [],
        offset: Int,
        limit: Int,
        propertiesToFetch: [PartialKeyPath<T>] = []
    ) async throws -> [T] {
        var descriptor = FetchDescriptor<T>(
            predicate: predicate,
            sortBy: sortBy
        )

        // Configure for batch loading
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit

        // Only load specified properties for performance
        if !propertiesToFetch.isEmpty {
            descriptor.propertiesToFetch = propertiesToFetch
        }

        return try await fetch(descriptor)
    }

    /// Exists check without loading the object
    func exists<T: PersistentModel>(
        _ type: T.Type,
        matching predicate: Predicate<T>
    ) async throws -> Bool {
        var descriptor = FetchDescriptor<T>(predicate: predicate)
        descriptor.fetchLimit = 1
        descriptor.propertiesToFetch = []  // Don't load any properties

        let results = try await fetch(descriptor)
        return !results.isEmpty
    }

    /// Fetch only IDs for efficient operations
    func fetchIDs<T: PersistentModel>(
        _ type: T.Type,
        matching predicate: Predicate<T>? = nil,
        sortBy: [SortDescriptor<T>] = []
    ) async throws -> [UUID] where T: Identifiable, T.ID == UUID {
        var descriptor = FetchDescriptor<T>(
            predicate: predicate,
            sortBy: sortBy
        )

        // We need at least the ID property
        // Note: This is safe because T: Identifiable guarantees id property exists
        let idKeyPath = \T.id as PartialKeyPath<T>
        descriptor.propertiesToFetch = [idKeyPath]

        let results = try await fetch(descriptor)
        return results.map(\.id)
    }
}

/// Optimized batch operations for DTOs
extension DataStore {
    /// Convert prompts to summaries in batches
    func fetchPromptSummariesDirect(
        predicate: Predicate<Prompt>? = nil,
        sortBy: [SortDescriptor<Prompt>] = [],
        limit: Int = 50
    ) async throws -> [PromptSummary] {
        var descriptor = FetchDescriptor<Prompt>(
            predicate: predicate,
            sortBy: sortBy
        )
        descriptor.fetchLimit = limit

        let prompts = try await fetch(descriptor)

        // Convert in parallel for better performance
        return await withTaskGroup(of: PromptSummary.self) { group in
            for prompt in prompts {
                group.addTask {
                    prompt.toSummary()
                }
            }

            var summaries: [PromptSummary] = []
            for await summary in group {
                summaries.append(summary)
            }

            // Maintain original order
            return summaries.sorted { first, second in
                prompts.firstIndex(where: { $0.id == first.id })! < prompts.firstIndex(where: { $0.id == second.id })!
            }
        }
    }

    /// Efficient aggregate operations
    func aggregatePromptStats() async throws -> PromptStats {
        let logger = Logger(subsystem: "com.prompt.app", category: "DataStore")
        logger.info("Computing aggregate stats")

        // Fetch all prompts with minimal properties
        var descriptor = FetchDescriptor<Prompt>()
        descriptor.propertiesToFetch = [
            \Prompt.category,
            \Prompt.createdAt,
            \Prompt.metadata
        ]

        let prompts = try await fetch(descriptor)

        // Compute stats
        var categoryCount: [Category: Int] = [:]
        var totalFavorites = 0
        var totalViews = 0
        let oldestDate = prompts.min(by: { $0.createdAt < $1.createdAt })?.createdAt

        for prompt in prompts {
            categoryCount[prompt.category, default: 0] += 1
            if prompt.metadata.isFavorite {
                totalFavorites += 1
            }
            totalViews += prompt.metadata.viewCount
        }

        return PromptStats(
            totalCount: prompts.count,
            categoryBreakdown: categoryCount,
            favoriteCount: totalFavorites,
            totalViewCount: totalViews,
            oldestPromptDate: oldestDate
        )
    }
}

/// Statistics for prompts
struct PromptStats: Sendable {
    let totalCount: Int
    let categoryBreakdown: [Category: Int]
    let favoriteCount: Int
    let totalViewCount: Int
    let oldestPromptDate: Date?

    var averageViewsPerPrompt: Double {
        totalCount > 0 ? Double(totalViewCount) / Double(totalCount) : 0
    }

    var favoritePercentage: Double {
        totalCount > 0 ? Double(favoriteCount) / Double(totalCount) * 100 : 0
    }
}

/// Batch update operations
extension DataStore {
    /// Update multiple prompts efficiently
    func batchUpdate<T: PersistentModel>(
        _ type: T.Type,
        matching predicate: Predicate<T>,
        update: @escaping (T) -> Void
    ) async throws {
        let objects = try await fetch(FetchDescriptor<T>(predicate: predicate))

        // Update in batches to avoid overwhelming memory
        let batchSize = 100
        for batch in objects.chunked(into: batchSize) {
            for object in batch {
                update(object)
            }

            // Save after each batch
            try await save()
        }
    }
}

// MARK: - Helper Extensions

extension Array {
    /// Split array into chunks of specified size
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size)
            .map {
                Array(self[$0..<Swift.min($0 + size, count)])
            }
    }
}
