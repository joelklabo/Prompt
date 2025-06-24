import Foundation
import os
import SwiftData

/// High-performance memory-mapped storage for prompts
/// Provides O(1) metadata access and efficient streaming for large content
actor MemoryMappedStore {
    private let logger = Logger(subsystem: "com.prompt.app", category: "MemoryMappedStore")

    // Memory-mapped files
    private var metadataFile: MappedFile<MetadataRecord>?
    private var contentFile: ContentMappedFile?
    private var searchIndex: MappedSearchIndex?
    private var stringPool: MappedStringPool?

    // Access control
    private let accessManager = ConcurrentAccessManager()
    private let transactionLog: TransactionLog

    // Configuration
    private let directory: URL
    private let pageSize: Int

    // Statistics
    private var stats = StorageStatistics()

    init(directory: URL) async throws {
        self.directory = directory
        self.pageSize = 4096  // Use standard page size

        // Ensure directory exists
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        // Initialize transaction log
        self.transactionLog = try TransactionLog(
            url: directory.appendingPathComponent("transaction.log")
        )

        // Initialize memory-mapped files
        try await initializeFiles()

        logger.info("MemoryMappedStore initialized at: \(directory.path)")
    }

    // MARK: - Initialization

    private func initializeFiles() async throws {
        // Metadata index
        let metadataURL = directory.appendingPathComponent("metadata.idx")
        metadataFile = try MappedFile<MetadataRecord>(
            url: metadataURL,
            initialSize: pageSize * 100  // ~25KB for 100 records
        )

        // Content storage
        let contentURL = directory.appendingPathComponent("content.dat")
        contentFile = try ContentMappedFile(
            url: contentURL,
            initialSize: pageSize * 1000  // ~4MB initial
        )

        // Search index
        let searchURL = directory.appendingPathComponent("search.idx")
        searchIndex = try MappedSearchIndex(url: searchURL)

        // String pool
        let stringPoolURL = directory.appendingPathComponent("stringpool.dat")
        stringPool = try MappedStringPool(url: stringPoolURL)

        // Recover from any incomplete transactions
        try await recoverFromTransactionLog()
    }

    // MARK: - Public API

    /// Read prompt metadata without loading content
    func getMetadata(id: UUID) async throws -> PromptSummary? {
        let index = try await findMetadataIndex(for: id)
        guard let record = metadataFile?.record(at: index) else { return nil }

        // Return a DTO instead of SwiftData model
        let title =
            await stringPool?
            .getString(
                offset: record.titleOffset,
                length: record.titleLength
            ) ?? ""

        return PromptSummary(
            id: id,
            title: title,
            contentPreview: "",  // Not stored in metadata
            category: Category(categoryCode: record.category) ?? .prompts,
            tagNames: [],  // Load separately
            createdAt: Date(timeIntervalSince1970: TimeInterval(record.createdAt)),
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(record.modifiedAt)),
            isFavorite: record.flags & MetadataFlags.favorite.rawValue != 0,
            viewCount: Int16(record.viewCount),
            copyCount: Int16(record.copyCount),
            categoryConfidence: nil,
            shortLink: nil
        )
    }

    /// Stream content for efficient large file handling
    func streamContent(id: UUID) async throws -> AsyncThrowingStream<Data, Error> {
        let index = try await findMetadataIndex(for: id)
        guard let record = metadataFile?.record(at: index) else {
            throw PromptError.notFound(id)
        }

        await accessManager.acquireReadLock(for: id)

        return AsyncThrowingStream { continuation in
            Task {
                defer {
                    Task { await self.accessManager.releaseReadLock(for: id) }
                    continuation.finish()
                }

                do {
                    let chunks = try await self.contentFile?
                        .streamContent(
                            offset: record.contentOffset,
                            length: record.contentLength,
                            compressed: record.compressedLength > 0
                        )

                    if let chunks = chunks {
                        for try await chunk in chunks {
                            continuation.yield(chunk)
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Get full prompt detail
    func getPrompt(id: UUID) async throws -> PromptDetail {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            stats.recordReadTime(elapsed)
        }

        // Get metadata
        guard let metadata = try await getMetadata(id: id) else {
            throw PromptError.notFound(id)
        }

        // Stream and collect content
        var content = Data()
        for try await chunk in try await streamContent(id: id) {
            content.append(chunk)
        }

        let contentString = String(data: content, encoding: .utf8) ?? ""

        return PromptDetail(
            id: id,
            title: metadata.title,
            content: contentString,
            category: metadata.category,
            createdAt: metadata.createdAt,
            modifiedAt: metadata.modifiedAt,
            metadata: MetadataDTO(
                shortCode: nil,
                viewCount: Int(metadata.viewCount),
                copyCount: Int(metadata.copyCount),
                lastViewedAt: nil,
                isFavorite: metadata.isFavorite
            ),
            tags: [],  // Load separately
            aiAnalysis: nil,  // Load separately
            versionCount: 0  // Load separately
        )
    }

    /// Create new prompt
    func createPrompt(_ request: PromptCreateRequest) async throws -> UUID {
        let promptId = UUID()
        let txId = try await transactionLog.beginTransaction()

        await accessManager.acquireWriteLock(for: promptId)
        defer {
            Task { await self.accessManager.releaseWriteLock(for: promptId) }
        }

        do {
            // Intern title
            let titleLocation = try await stringPool?.intern(request.title) ?? StringLocation(offset: 0, length: 0)

            // Write content
            let contentData = request.content.data(using: .utf8) ?? Data()
            let contentLocation =
                try await contentFile?.appendContent(contentData)
                ?? ContentLocation(offset: 0, length: 0, compressedLength: 0)

            // Create metadata record
            let now = Date()
            let metadata = MetadataRecord(
                promptId: promptId,
                contentOffset: contentLocation.offset,
                contentLength: contentLocation.length,
                compressedLength: contentLocation.compressedLength,
                titleOffset: titleLocation.offset,
                titleLength: UInt16(titleLocation.length),
                category: request.category.categoryCode,
                flags: 0,
                createdAt: Int64(now.timeIntervalSince1970),
                modifiedAt: Int64(now.timeIntervalSince1970),
                viewCount: 0,
                copyCount: 0,
                tagCount: 0
            )

            // Append metadata
            let metadataIndex = try await metadataFile?.append(metadata) ?? 0

            // Update search index
            if let searchIndex = searchIndex {
                try await searchIndex.indexDocument(
                    id: promptId,
                    index: metadataIndex,
                    title: request.title,
                    content: request.content
                )
            }

            // Log operation
            try await transactionLog.logOperation(
                .insert(promptId: promptId, metadataIndex: metadataIndex),
                txId: txId
            )

            // Commit transaction
            try await transactionLog.commitTransaction(txId)

            stats.totalPrompts += 1
            logger.info("Created prompt \(promptId)")

            return promptId
        } catch {
            try await transactionLog.rollbackTransaction(txId)
            throw error
        }
    }

    /// Update prompt content
    func updatePrompt(id: UUID, content: String) async throws {
        let txId = try await transactionLog.beginTransaction()

        await accessManager.acquireWriteLock(for: id)
        defer {
            Task { await self.accessManager.releaseWriteLock(for: id) }
        }

        do {
            // Find existing metadata
            let index = try await findMetadataIndex(for: id)
            guard var metadata = metadataFile?.record(at: index) else {
                throw PromptError.notFound(id)
            }

            // Write new content
            let contentData = content.data(using: .utf8) ?? Data()
            let newLocation =
                try await contentFile?.appendContent(contentData)
                ?? ContentLocation(offset: 0, length: 0, compressedLength: 0)

            // Log old location for rollback
            try await transactionLog.logOperation(
                .update(
                    promptId: id,
                    oldOffset: metadata.contentOffset,
                    newOffset: newLocation.offset,
                    newLength: newLocation.length
                ),
                txId: txId
            )

            // Update metadata
            metadata.contentOffset = newLocation.offset
            metadata.contentLength = newLocation.length
            metadata.compressedLength = newLocation.compressedLength
            metadata.modifiedAt = Int64(Date().timeIntervalSince1970)

            try await metadataFile?.update(at: index, record: metadata)

            // Update search index
            if let searchIndex = searchIndex {
                try await searchIndex.reindexDocument(
                    id: id,
                    index: index,
                    title: nil,  // Keep existing title
                    content: content
                )
            }

            // Commit
            try await transactionLog.commitTransaction(txId)

            logger.info("Updated prompt \(id)")
        } catch {
            try await transactionLog.rollbackTransaction(txId)
            throw error
        }
    }

    /// Search prompts using inverted index
    func search(query: String, limit: Int = 100) async throws -> [SearchResult] {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            stats.recordSearchTime(elapsed)
        }

        guard let searchIndex = searchIndex else { return [] }

        // Get search results from index
        let indexResults = try await searchIndex.search(query: query, limit: limit)

        // Map to full results with metadata
        var results: [SearchResult] = []
        for indexResult in indexResults {
            if let metadata = metadataFile?.record(at: indexResult.metadataIndex) {
                let title =
                    await stringPool?
                    .getString(
                        offset: metadata.titleOffset,
                        length: metadata.titleLength
                    ) ?? ""

                results.append(
                    SearchResult(
                        promptId: indexResult.documentId,
                        score: indexResult.score,
                        highlights: indexResult.highlights
                    ))
            }
        }

        return results
    }

    /// Delete prompt
    func deletePrompt(id: UUID) async throws {
        let txId = try await transactionLog.beginTransaction()

        await accessManager.acquireWriteLock(for: id)
        defer {
            Task { await self.accessManager.releaseWriteLock(for: id) }
        }

        do {
            // Find metadata
            let index = try await findMetadataIndex(for: id)
            guard var metadata = metadataFile?.record(at: index) else {
                throw PromptError.notFound(id)
            }

            // Log for rollback
            try await transactionLog.logOperation(
                .delete(promptId: id, metadataIndex: index),
                txId: txId
            )

            // Mark as deleted (soft delete)
            metadata.flags |= MetadataFlags.deleted.rawValue
            try await metadataFile?.update(at: index, record: metadata)

            // Remove from search index
            if let searchIndex = searchIndex {
                try await searchIndex.removeDocument(id: id)
            }

            // Commit
            try await transactionLog.commitTransaction(txId)

            stats.totalPrompts -= 1
            logger.info("Deleted prompt \(id)")
        } catch {
            try await transactionLog.rollbackTransaction(txId)
            throw error
        }
    }

    // MARK: - Private Methods

    private func findMetadataIndex(for id: UUID) async throws -> Int {
        // In production, maintain a hash table for O(1) lookup
        // For now, linear search (would be replaced with proper index)
        guard let metadataFile = metadataFile else {
            throw StorageError.fileNotInitialized
        }

        for index in 0..<metadataFile.recordCount {
            if let record = metadataFile.record(at: index),
                record.promptId == id,
                record.flags & MetadataFlags.deleted.rawValue == 0 {
                return index
            }
        }

        throw PromptError.notFound(id)
    }

    private func recoverFromTransactionLog() async throws {
        let pendingTransactions = try await transactionLog.getPendingTransactions()

        for transaction in pendingTransactions {
            logger.warning("Recovering transaction: \(transaction.id)")

            // Rollback incomplete transactions
            for operation in transaction.operations.reversed() {
                switch operation {
                case let .insert(promptId, metadataIndex):
                    // Remove the inserted record
                    if var metadata = metadataFile?.record(at: metadataIndex) {
                        metadata.flags |= MetadataFlags.deleted.rawValue
                        try await metadataFile?.update(at: metadataIndex, record: metadata)
                    }

                case let .update(promptId, oldOffset, _, _):
                    // Restore old content offset
                    if let index = try? await findMetadataIndex(for: promptId),
                        var metadata = metadataFile?.record(at: index) {
                        metadata.contentOffset = oldOffset
                        try await metadataFile?.update(at: index, record: metadata)
                    }

                case let .delete(promptId, metadataIndex):
                    // Restore deleted record
                    if var metadata = metadataFile?.record(at: metadataIndex) {
                        metadata.flags &= ~MetadataFlags.deleted.rawValue
                        try await metadataFile?.update(at: metadataIndex, record: metadata)
                    }
                }
            }

            try await transactionLog.markTransactionFailed(transaction.id)
        }
    }

    // MARK: - Statistics

    func getStatistics() -> StorageStatistics {
        stats
    }
}

// MARK: - Supporting Types

struct MetadataRecord {
    let promptId: UUID  // 16 bytes
    var contentOffset: UInt64  // 8 bytes
    var contentLength: UInt32  // 4 bytes
    var compressedLength: UInt32  // 4 bytes
    var titleOffset: UInt32  // 4 bytes
    var titleLength: UInt16  // 2 bytes
    var category: UInt8  // 1 byte
    var flags: UInt8  // 1 byte
    var createdAt: Int64  // 8 bytes
    var modifiedAt: Int64  // 8 bytes
    var viewCount: UInt32  // 4 bytes
    var copyCount: UInt32  // 4 bytes
    var tagCount: UInt16  // 2 bytes
    var reserved: [UInt8] = Array(repeating: 0, count: 194)  // Pad to 256 bytes

    init(
        promptId: UUID,
        contentOffset: UInt64,
        contentLength: UInt32,
        compressedLength: UInt32,
        titleOffset: UInt32,
        titleLength: UInt16,
        category: UInt8,
        flags: UInt8,
        createdAt: Int64,
        modifiedAt: Int64,
        viewCount: UInt32,
        copyCount: UInt32,
        tagCount: UInt16
    ) {
        self.promptId = promptId
        self.contentOffset = contentOffset
        self.contentLength = contentLength
        self.compressedLength = compressedLength
        self.titleOffset = titleOffset
        self.titleLength = titleLength
        self.category = category
        self.flags = flags
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.viewCount = viewCount
        self.copyCount = copyCount
        self.tagCount = tagCount
    }
}

struct MetadataFlags: OptionSet {
    let rawValue: UInt8

    static let favorite = MetadataFlags(rawValue: 1 << 0)
    static let deleted = MetadataFlags(rawValue: 1 << 1)
    static let compressed = MetadataFlags(rawValue: 1 << 2)
}

struct StorageStatistics {
    var totalPrompts: Int = 0
    var totalSize: Int64 = 0
    var compressionRatio: Double = 1.0
    private var readTimes: [Double] = []
    private var writeTimes: [Double] = []
    private var searchTimes: [Double] = []

    mutating func recordReadTime(_ ms: Double) {
        readTimes.append(ms)
        if readTimes.count > 1000 { readTimes.removeFirst() }
    }

    mutating func recordWriteTime(_ ms: Double) {
        writeTimes.append(ms)
        if writeTimes.count > 1000 { writeTimes.removeFirst() }
    }

    mutating func recordSearchTime(_ ms: Double) {
        searchTimes.append(ms)
        if searchTimes.count > 1000 { searchTimes.removeFirst() }
    }

    var averageReadTime: Double {
        readTimes.isEmpty ? 0 : readTimes.reduce(0, +) / Double(readTimes.count)
    }

    var averageWriteTime: Double {
        writeTimes.isEmpty ? 0 : writeTimes.reduce(0, +) / Double(writeTimes.count)
    }

    var averageSearchTime: Double {
        searchTimes.isEmpty ? 0 : searchTimes.reduce(0, +) / Double(searchTimes.count)
    }
}

enum StorageError: LocalizedError {
    case fileNotInitialized
    case invalidOffset
    case corruptedData
    case insufficientSpace

    var errorDescription: String? {
        switch self {
        case .fileNotInitialized:
            return "Storage file not initialized"
        case .invalidOffset:
            return "Invalid file offset"
        case .corruptedData:
            return "Data corruption detected"
        case .insufficientSpace:
            return "Insufficient storage space"
        }
    }
}

// Extension to make Category work with UInt8
extension Category {
    var categoryCode: UInt8 {
        switch self {
        case .prompts: return 0
        case .configs: return 1
        case .commands: return 2
        case .context: return 3
        }
    }

    init?(categoryCode: UInt8) {
        switch categoryCode {
        case 0: self = .prompts
        case 1: self = .configs
        case 2: self = .commands
        case 3: self = .context
        default: return nil
        }
    }
}
