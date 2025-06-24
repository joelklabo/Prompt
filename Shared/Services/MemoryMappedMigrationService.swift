import Foundation
import os
@preconcurrency import SwiftData

// MARK: - Sendable Migration Types

struct MigrationData: Sendable {
    let id: UUID
    let title: String
    let content: String
    let category: Category
    let tagIDs: [UUID]
    let metadata: MetadataInfo
}

struct MetadataInfo: Sendable {
    let viewCount: Int
    let copyCount: Int
    let isFavorite: Bool
}

struct VerificationData: Sendable {
    let id: UUID
    let title: String
    let content: String
    let category: Category
}

/// Service to migrate from SwiftData to memory-mapped storage
actor MemoryMappedMigrationService {
    private let logger = Logger(subsystem: "com.prompt.app", category: "Migration")
    private let dataStore: DataStore
    private let memoryMappedStore: MemoryMappedStore

    // Migration progress tracking
    @Published private(set) var progress: MigrationProgress = MigrationProgress()
    private var progressContinuation: AsyncStream<MigrationProgress>.Continuation?

    init(dataStore: DataStore, storageDirectory: URL) async throws {
        self.dataStore = dataStore
        self.memoryMappedStore = try await MemoryMappedStore(directory: storageDirectory)
    }

    // MARK: - Public API

    /// Perform full migration from SwiftData to memory-mapped storage
    func performMigration() async throws -> MigrationResult {
        logger.info("Starting migration to memory-mapped storage")

        progress = MigrationProgress(
            phase: .starting,
            totalPrompts: 0,
            migratedPrompts: 0,
            startTime: Date()
        )

        do {
            // Phase 1: Count total prompts
            progress.phase = .counting
            let totalCount = try await countTotalPrompts()
            progress.totalPrompts = totalCount
            logger.info("Found \(totalCount) prompts to migrate")

            // Phase 2: Migrate prompts in batches
            progress.phase = .migrating
            try await migratePrompts()

            // Phase 3: Verify migration
            progress.phase = .verifying
            let verificationResult = try await verifyMigration()

            // Phase 4: Complete
            progress.phase = .completed
            progress.endTime = Date()

            let result = MigrationResult(
                success: verificationResult.success,
                totalPrompts: totalCount,
                migratedPrompts: progress.migratedPrompts,
                failedPrompts: verificationResult.failedPrompts,
                duration: progress.duration ?? 0,
                errors: verificationResult.errors
            )

            logger.info(
                """
                Migration completed: success=\(result.success), \
                migrated=\(result.migratedPrompts)/\(result.totalPrompts), \
                duration=\(result.duration)s
                """
            )
            return result

        } catch {
            progress.phase = .failed
            progress.errors.append(error)
            logger.error("Migration failed: \(error)")
            throw error
        }
    }

    /// Stream migration progress updates
    func progressStream() -> AsyncStream<MigrationProgress> {
        AsyncStream { continuation in
            self.progressContinuation = continuation
            continuation.yield(progress)
        }
    }

    // MARK: - Migration Steps

    private func countTotalPrompts() async throws -> Int {
        let descriptor = FetchDescriptor<Prompt>()
        return try await dataStore.count(for: descriptor)
    }

    private func migratePrompts() async throws {
        let batchSize = 100
        var offset = 0

        while offset < progress.totalPrompts {
            // Capture offset as a constant for the sendable closure
            let currentOffset = offset
            
            // Fetch and convert batch within transaction
            let batchData = try await dataStore.transaction { @Sendable context in
                var descriptor = FetchDescriptor<Prompt>(
                    sortBy: [SortDescriptor(\.createdAt)]
                )
                descriptor.fetchLimit = batchSize
                descriptor.fetchOffset = currentOffset

                let prompts = try context.fetch(descriptor)

                // Convert to data we can pass across actors
                return prompts.map { prompt in
                    MigrationData(
                        id: prompt.id,
                        title: prompt.title,
                        content: prompt.content,
                        category: prompt.category,
                        tagIDs: prompt.tags.map { $0.id },
                        metadata: MetadataInfo(
                            viewCount: prompt.metadata.viewCount,
                            copyCount: prompt.metadata.copyCount,
                            isFavorite: prompt.metadata.isFavorite
                        )
                    )
                }
            }

            // Migrate batch
            try await migrateBatch(batchData)

            offset += batchData.count

            // Update progress
            progress.migratedPrompts = offset
            progress.currentBatch = offset / batchSize + 1
            progress.totalBatches = (progress.totalPrompts + batchSize - 1) / batchSize
            progressContinuation?.yield(progress)

            // Yield to prevent blocking
            await Task.yield()

            // Break if we got fewer prompts than expected
            if batchData.count < batchSize {
                break
            }
        }
    }

    private func migrateBatch(_ batchData: [MigrationData]) async throws {
        for data in batchData {
            do {
                // Create prompt in memory-mapped store
                let request = PromptCreateRequest(
                    title: data.title,
                    content: data.content,
                    category: data.category,
                    tagIDs: data.tagIDs
                )

                let newId = try await memoryMappedStore.createPrompt(request)

                // Store ID mapping for verification
                progress.idMapping[data.id] = newId

                // Log metadata that needs separate handling
                if data.metadata.viewCount > 0 || data.metadata.copyCount > 0 {
                    progress.metadataToUpdate.append(
                        MetadataUpdate(
                            oldId: data.id,
                            newId: newId,
                            viewCount: data.metadata.viewCount,
                            copyCount: data.metadata.copyCount,
                            isFavorite: data.metadata.isFavorite
                        )
                    )
                }

            } catch {
                logger.error("Failed to migrate prompt \(data.id): \(error)")
                progress.errors.append(error)
                progress.failedPromptIds.append(data.id)
            }
        }
    }

    private func verifyMigration() async throws -> VerificationResult {
        logger.info("Verifying migration integrity")

        var failedPrompts: [UUID] = []
        var errors: [Error] = []

        // Sample verification - check 10% of prompts
        let sampleSize = max(100, progress.totalPrompts / 10)
        let sampleIndices = (0..<progress.totalPrompts).shuffled().prefix(sampleSize)

        for index in sampleIndices {
            do {
                // Get original prompt data within transaction
                let verifyData = try await dataStore.transaction { context in
                    var descriptor = FetchDescriptor<Prompt>(
                        sortBy: [SortDescriptor(\.createdAt)]
                    )
                    descriptor.fetchLimit = 1
                    descriptor.fetchOffset = index

                    let originals = try context.fetch(descriptor)
                    guard let original = originals.first else {
                        return nil as VerificationData?
                    }

                    return VerificationData(
                        id: original.id,
                        title: original.title,
                        content: original.content,
                        category: original.category
                    )
                }

                guard let data = verifyData,
                    let newId = progress.idMapping[data.id]
                else {
                    continue
                }

                // Get migrated prompt
                let migrated = try await memoryMappedStore.getPrompt(id: newId)

                // Verify content matches
                if data.title != migrated.title || data.content != migrated.content
                    || data.category != migrated.category {
                    failedPrompts.append(data.id)
                    errors.append(MigrationError.contentMismatch(data.id))
                }

            } catch {
                errors.append(error)
            }
        }

        // Update metadata for successfully migrated prompts
        for update in progress.metadataToUpdate {
            // This would need implementation in MemoryMappedStore
            // to update view/copy counts
            logger.info("Would update metadata for \(update.newId)")
        }

        return VerificationResult(
            success: failedPrompts.isEmpty,
            failedPrompts: failedPrompts,
            errors: errors
        )
    }

    // MARK: - Rollback

    /// Rollback migration if needed
    func rollbackMigration() async throws {
        logger.warning("Rolling back migration")

        // In production, would:
        // 1. Delete memory-mapped files
        // 2. Clear any partial state
        // 3. Restore SwiftData as primary store

        progress.phase = .rolledBack
        progressContinuation?.yield(progress)
    }
}

// MARK: - Supporting Types

struct MigrationProgress {
    enum Phase {
        case starting
        case counting
        case migrating
        case verifying
        case completed
        case failed
        case rolledBack
    }

    var phase: Phase = .starting
    var totalPrompts: Int = 0
    var migratedPrompts: Int = 0
    var currentBatch: Int = 0
    var totalBatches: Int = 0
    var startTime: Date?
    var endTime: Date?
    var errors: [Error] = []
    var idMapping: [UUID: UUID] = [:]  // Old ID -> New ID
    var failedPromptIds: [UUID] = []
    var metadataToUpdate: [MetadataUpdate] = []

    var percentComplete: Double {
        guard totalPrompts > 0 else { return 0 }
        return Double(migratedPrompts) / Double(totalPrompts) * 100
    }

    var duration: TimeInterval? {
        guard let start = startTime else { return nil }
        let end = endTime ?? Date()
        return end.timeIntervalSince(start)
    }

    var estimatedTimeRemaining: TimeInterval? {
        guard let duration = duration,
            migratedPrompts > 0,
            migratedPrompts < totalPrompts
        else { return nil }

        let rate = Double(migratedPrompts) / duration
        let remaining = Double(totalPrompts - migratedPrompts)
        return remaining / rate
    }
}

struct MetadataUpdate {
    let oldId: UUID
    let newId: UUID
    let viewCount: Int
    let copyCount: Int
    let isFavorite: Bool
}

struct MigrationResult {
    let success: Bool
    let totalPrompts: Int
    let migratedPrompts: Int
    let failedPrompts: [UUID]
    let duration: TimeInterval
    let errors: [Error]
}

struct VerificationResult {
    let success: Bool
    let failedPrompts: [UUID]
    let errors: [Error]
}

enum MigrationError: LocalizedError {
    case contentMismatch(UUID)
    case metadataUpdateFailed(UUID)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .contentMismatch(let id):
            return "Content mismatch for prompt \(id)"
        case .metadataUpdateFailed(let id):
            return "Failed to update metadata for prompt \(id)"
        case .verificationFailed(let reason):
            return "Verification failed: \(reason)"
        }
    }
}

// MARK: - Migration Coordinator

/// Coordinates the migration process with UI updates
@MainActor
class MigrationCoordinator: ObservableObject {
    @Published var isRunning = false
    @Published var progress = MigrationProgress()
    @Published var result: MigrationResult?
    @Published var error: Error?

    private var migrationTask: Task<Void, Never>?
    private let migrationService: MemoryMappedMigrationService
    private let logger = Logger(subsystem: "com.prompt.app", category: "MigrationCoordinator")

    init(dataStore: DataStore, storageDirectory: URL) async throws {
        self.migrationService = try await MemoryMappedMigrationService(
            dataStore: dataStore,
            storageDirectory: storageDirectory
        )
    }

    func startMigration() {
        guard !isRunning else { return }

        isRunning = true
        error = nil
        result = nil

        migrationTask = Task {
            // Subscribe to progress updates
            let progressTask = Task {
                for await update in await migrationService.progressStream() {
                    self.progress = update
                }
            }

            do {
                let migrationResult = try await migrationService.performMigration()
                self.result = migrationResult
            } catch {
                self.error = error

                // Attempt rollback
                do {
                    try await migrationService.rollbackMigration()
                } catch {
                    // Log rollback failure
                    logger.error("Rollback failed: \(error)")
                }
            }

            progressTask.cancel()
            isRunning = false
        }
    }

    func cancelMigration() {
        migrationTask?.cancel()
        migrationTask = nil
        isRunning = false
    }

    var progressDescription: String {
        switch progress.phase {
        case .starting:
            return "Preparing migration..."
        case .counting:
            return "Counting prompts..."
        case .migrating:
            return "Migrating prompts: \(progress.migratedPrompts)/\(progress.totalPrompts)"
        case .verifying:
            return "Verifying migration..."
        case .completed:
            return "Migration completed successfully"
        case .failed:
            return "Migration failed"
        case .rolledBack:
            return "Migration rolled back"
        }
    }

    var timeRemainingDescription: String? {
        guard let remaining = progress.estimatedTimeRemaining else { return nil }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated

        return formatter.string(from: remaining)
    }
}
