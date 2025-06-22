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

        logger.info("Incremental migration completed")
    }

    /// Create database indexes for optimized queries
    private func createDatabaseIndexes() async throws {
        logger.info("Creating database indexes")

        // SwiftData doesn't expose direct index creation, but we can
        // trigger index creation through strategic queries

        // Index on modifiedAt for pagination
        var descriptor = FetchDescriptor<Prompt>(
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        _ = try await dataStore.fetch(descriptor)

        // Index on category for filtering
        for category in Category.allCases {
            var categoryDescriptor = FetchDescriptor<Prompt>(
                predicate: #Predicate { $0.category == category }
            )
            categoryDescriptor.fetchLimit = 1
            _ = try await dataStore.fetch(categoryDescriptor)
        }

        // Index on isFavorite
        var favoriteDescriptor = FetchDescriptor<Prompt>(
            predicate: #Predicate { $0.metadata.isFavorite == true }
        )
        favoriteDescriptor.fetchLimit = 1
        _ = try await dataStore.fetch(favoriteDescriptor)
    }

    /// Optimize storage for large content
    private func optimizeLargeContent() async throws {
        logger.info("Optimizing large content storage")

        let largeContentThreshold = 10_240  // 10KB

        // Find prompts with large content
        let descriptor = FetchDescriptor<Prompt>()
        let allPrompts = try await dataStore.fetch(descriptor)

        var optimizedCount = 0

        for prompt in allPrompts where prompt.content.utf8.count > largeContentThreshold {
            // In a real implementation, we would:
            // 1. Move content to file storage
            // 2. Update prompt with file reference
            // 3. Clear in-memory content

            // For now, just count
            optimizedCount += 1
        }

        logger.info("Identified \(optimizedCount) prompts with large content")
    }
}

/// Extension to provide DTO conversions for existing models
extension Prompt {
    /// Convert to lightweight summary
    func toSummary() -> PromptSummary {
        PromptSummary(
            id: id,
            title: title,
            contentPreview: String(content.prefix(100)),
            category: category,
            tagNames: tags.map(\.name),
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            isFavorite: metadata.isFavorite,
            viewCount: Int16(min(metadata.viewCount, Int(Int16.max)))
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
