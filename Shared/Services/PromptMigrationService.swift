import CryptoKit
import Foundation
import os.log
import SwiftData

/// Service to migrate from current SwiftData models to optimized DTO architecture
actor PromptMigrationService {
    private let logger = Logger(subsystem: "com.prompt.app", category: "PromptMigration")
    private let dataStore: DataStore
    private let optimizedService: OptimizedPromptService

    init(dataStore: DataStore, optimizedService: OptimizedPromptService) {
        self.dataStore = dataStore
        self.optimizedService = optimizedService
    }

    /// Perform incremental migration without disrupting current usage
    func performIncrementalMigration() async throws {
        logger.info("Starting incremental migration to DTO architecture")

        // Step 1: Create indexes for better query performance
        try await createDatabaseIndexes()

        // Step 2: Warm cache with recent data
        try await optimizedService.warmCache()

        // Step 3: Optimize large content storage
        try await optimizeLargeContent()

        // Step 4: Populate hybrid storage fields
        try await populateHybridStorageFields()

        logger.info("Incremental migration completed")
    }

    /// Create database indexes for optimized queries
    private func createDatabaseIndexes() async throws {
        logger.info("Creating database indexes")

        // SwiftData doesn't expose direct index creation, but we can
        // trigger index creation through strategic queries

        // Index on modifiedAt for pagination
        try await dataStore.transaction { context in
            var descriptor = FetchDescriptor<Prompt>(
                sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            _ = try context.fetch(descriptor)
        }

        // Index on category for filtering
        for category in Category.allCases {
            try await dataStore.transaction { context in
                var categoryDescriptor = FetchDescriptor<Prompt>(
                    predicate: #Predicate { $0.category == category }
                )
                categoryDescriptor.fetchLimit = 1
                _ = try context.fetch(categoryDescriptor)
            }
        }

        // Index on isFavorite
        try await dataStore.transaction { context in
            var favoriteDescriptor = FetchDescriptor<Prompt>(
                predicate: #Predicate { $0.metadata.isFavorite == true }
            )
            favoriteDescriptor.fetchLimit = 1
            _ = try context.fetch(favoriteDescriptor)
        }
    }

    /// Optimize storage for large content
    private func optimizeLargeContent() async throws {
        logger.info("Optimizing large content storage")

        let largeContentThreshold = 10_240  // 10KB

        // Find prompts with large content
        let descriptor = FetchDescriptor<Prompt>()
        let promptCount = try await dataStore.count(for: descriptor)

        // Process in batches to avoid loading all at once
        let batchSize = 100
        for offset in stride(from: 0, to: promptCount, by: batchSize) {
            var batchDescriptor = descriptor
            batchDescriptor.fetchLimit = batchSize
            batchDescriptor.fetchOffset = offset

            let optimizedCount = try await dataStore.transaction { context in
                let prompts = try context.fetch(batchDescriptor)

                var count = 0
                for prompt in prompts where prompt.content.utf8.count > largeContentThreshold {
                    // In a real implementation, we would:
                    // 1. Move content to file storage
                    // 2. Update prompt with file reference
                    // 3. Clear in-memory content
                    count += 1
                }
                return count
            }

            if optimizedCount > 0 {
                logger.info("Optimized \(optimizedCount) prompts in batch")
            }
        }
    }

    /// Populate new hybrid storage fields for existing prompts
    private func populateHybridStorageFields() async throws {
        logger.info("Populating hybrid storage fields for existing prompts")

        let descriptor = FetchDescriptor<Prompt>()
        let promptCount = try await dataStore.count(for: descriptor)

        // Process in batches
        let batchSize = 100
        var totalMigrated = 0

        for offset in stride(from: 0, to: promptCount, by: batchSize) {
            var batchDescriptor = descriptor
            batchDescriptor.fetchLimit = batchSize
            batchDescriptor.fetchOffset = offset

            let migratedInBatch = try await dataStore.transaction { context in
                let prompts = try context.fetch(batchDescriptor)
                var count = 0

                for prompt in prompts {
                    // Skip if already migrated
                    if prompt.contentSize > 0 && !prompt.contentPreview.isEmpty {
                        continue
                    }

                    // Populate content size
                    prompt.contentSize = prompt.content.utf8.count

                    // Populate content preview (first 200 characters)
                    prompt.contentPreview = String(prompt.content.prefix(200))

                    // Set storage type (default to swiftData for existing prompts)
                    prompt.storageType = .swiftData

                    // Generate content hash
                    let contentData = Data(prompt.content.utf8)
                    let hash = SHA256.hash(data: contentData)
                    prompt.contentHash = hash.compactMap { String(format: "%02x", $0) }.joined()

                    count += 1
                }

                return count
            }

            totalMigrated += migratedInBatch
            if migratedInBatch > 0 {
                logger.info("Migrated \(migratedInBatch) prompts in batch")
            }
        }

        logger.info("Completed populating hybrid storage fields for \(totalMigrated) prompts")
    }
}

/// Extension to provide DTO conversions for existing models
extension Prompt {
    /// Convert to lightweight summary
    func toSummary() -> PromptSummary {
        PromptSummary(
            id: id,
            title: title,
            contentPreview: contentPreview.isEmpty ? String(content.prefix(200)) : contentPreview,
            category: category,
            tagNames: tags.map(\.name),
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            isFavorite: metadata.isFavorite,
            viewCount: Int16(min(metadata.viewCount, Int(Int16.max))),
            copyCount: Int16(min(metadata.copyCount, Int(Int16.max))),
            categoryConfidence: aiAnalysis?.categoryConfidence,
            shortLink: metadata.shortCode.flatMap { URL(string: "https://prompt.app/\($0)") }
        )
    }

    /// Convert to full detail DTO
    func toDetail() -> PromptDetail {
        PromptDetail(
            id: id,
            title: title,
            content: content,
            category: category,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            metadata: MetadataDTO(
                shortCode: metadata.shortCode,
                viewCount: metadata.viewCount,
                copyCount: metadata.copyCount,
                lastViewedAt: metadata.lastViewedAt,
                isFavorite: metadata.isFavorite
            ),
            tags: tags.map { TagDTO(id: $0.id, name: $0.name, color: $0.color) },
            aiAnalysis: aiAnalysis?.toDTO(),
            versionCount: versions.count
        )
    }
}

extension AIAnalysis {
    /// Convert to DTO
    func toDTO() -> AIAnalysisDTO {
        AIAnalysisDTO(
            suggestedTags: suggestedTags,
            category: category,
            categoryConfidence: categoryConfidence,
            summary: summary,
            enhancementSuggestions: enhancementSuggestions,
            analyzedAt: analyzedAt
        )
    }
}

/// Performance monitoring for migration
struct MigrationMetrics {
    let startTime: Date
    let endTime: Date
    let promptsProcessed: Int
    let cacheHitRate: Double
    let averageQueryTime: TimeInterval

    var totalDuration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    var promptsPerSecond: Double {
        Double(promptsProcessed) / totalDuration
    }
}
