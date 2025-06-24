import Foundation
import os

/// Memory-mapped string pool for efficient string deduplication and storage
actor MappedStringPool {
    private let headerFile: MappedFile<StringPoolHeader>
    private let entryFile: MappedFile<StringEntry>
    private let dataFile: ContentMappedFile
    private nonisolated let logger = Logger(subsystem: "com.prompt.app", category: "MappedStringPool")

    // In-memory acceleration
    private var stringCache: [String: StringLocation] = [:]
    private var hashIndex: [UInt64: Int] = [:]  // String hash -> entry index

    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()

        // Initialize component files
        headerFile = try MappedFile<StringPoolHeader>(
            url: directory.appendingPathComponent("stringpool_header.idx"),
            initialSize: MemoryLayout<StringPoolHeader>.stride
        )

        entryFile = try MappedFile<StringEntry>(
            url: directory.appendingPathComponent("stringpool_entries.idx"),
            initialSize: 64 * 1024  // 64KB - ~1000 entries
        )

        dataFile = try ContentMappedFile(
            url: directory.appendingPathComponent("stringpool_data.dat"),
            initialSize: 1024 * 1024  // 1MB initial
        )

        // Load or initialize header
        if let header = headerFile.record(at: 0), header.version > 0 {
            // Valid header exists
            logger.info("Loaded string pool: \(header.stringCount) strings, \(header.totalSize) bytes")
        } else {
            // Initialize new header
            let header = StringPoolHeader(
                version: 1,
                stringCount: 0,
                totalSize: 0,
                hashSeed: UInt64.random(in: 0...UInt64.max)
            )
            try headerFile.update(at: 0, record: header)
        }

        // Build acceleration structures later when accessed
    }

    // MARK: - Public API

    /// Intern a string and return its location
    func intern(_ string: String) async throws -> StringLocation {

        // Check cache first
        if let cached = stringCache[string] {
            return cached
        }

        // Calculate hash
        let hash = hashString(string)

        // Check if already in pool
        if let entryIndex = hashIndex[hash],
            let entry = entryFile.record(at: entryIndex) {
            // Verify it's actually the same string
            if let pooledString = await getString(offset: entry.offset, length: UInt16(entry.length)),
                pooledString == string {
                // Update reference count
                var updatedEntry = entry
                updatedEntry.refCount = min(updatedEntry.refCount + 1, UInt32.max)
                try entryFile.update(at: entryIndex, record: updatedEntry)

                let location = StringLocation(offset: entry.offset, length: entry.length)
                stringCache[string] = location
                return location
            }
        }

        // Add new string
        let stringData = Data(string.utf8)
        let contentLocation = try dataFile.appendContent(stringData)

        // Create entry
        let entry = StringEntry(
            hash: hash,
            offset: UInt32(contentLocation.offset),
            length: UInt32(contentLocation.length),
            refCount: 1
        )

        let entryIndex = try entryFile.append(entry)
        hashIndex[hash] = entryIndex

        // Update header
        if var header = headerFile.record(at: 0) {
            header.stringCount += 1
            header.totalSize += UInt64(stringData.count)
            try headerFile.update(at: 0, record: header)
        }

        let location = StringLocation(offset: entry.offset, length: entry.length)
        stringCache[string] = location

        return location
    }

    /// Get string at location
    func getString(offset: UInt32, length: UInt16) async -> String? {
        do {
            var fullData = Data()
            let stream = try dataFile.streamContent(
                offset: UInt64(offset),
                length: UInt32(length),
                compressed: false
            )

            for try await chunk in stream {
                fullData.append(chunk)
            }

            return String(data: fullData, encoding: .utf8)
        } catch {
            logger.error("Failed to read string at offset \(offset): \(error)")
            return nil
        }
    }

    /// Update reference count
    func release(offset: UInt32) async throws {
        // Find entry by offset
        for (index, entry) in enumerateEntries() {
            if entry.offset == offset && entry.refCount > 0 {
                var updatedEntry = entry
                updatedEntry.refCount -= 1
                try entryFile.update(at: index, record: updatedEntry)

                // If refCount reaches 0, mark for garbage collection
                if updatedEntry.refCount == 0 {
                    logger.info("String at offset \(offset) eligible for GC")
                }
                break
            }
        }
    }

    /// Get pool statistics
    func getStatistics() -> StringPoolStatistics {
        guard let header = headerFile.record(at: 0) else {
            return StringPoolStatistics(
                totalStrings: 0,
                totalBytes: 0,
                uniqueStrings: 0,
                deduplicationRatio: 0
            )
        }

        let uniqueCount = hashIndex.count
        let deduplicationRatio =
            uniqueCount > 0
            ? 1.0 - (Double(uniqueCount) / Double(header.stringCount))
            : 0.0

        return StringPoolStatistics(
            totalStrings: Int(header.stringCount),
            totalBytes: Int(header.totalSize),
            uniqueStrings: uniqueCount,
            deduplicationRatio: deduplicationRatio
        )
    }

    // MARK: - Private Methods

    private func buildHashIndex() throws {
        for (index, entry) in enumerateEntries() where entry.hash != 0 {
            hashIndex[entry.hash] = index
        }

        logger.info("Built hash index with \(self.hashIndex.count) entries")
    }

    private func enumerateEntries() -> [(Int, StringEntry)] {
        var entries: [(Int, StringEntry)] = []

        for index in 0..<entryFile.recordCount {
            if let entry = entryFile.record(at: index), entry.hash != 0 {
                entries.append((index, entry))
            }
        }

        return entries
    }

    private func hashString(_ string: String) -> UInt64 {
        guard let header = headerFile.record(at: 0) else {
            return 0
        }

        // FNV-1a with seed
        var hash = header.hashSeed
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}

// MARK: - Supporting Types

struct StringPoolHeader {
    let version: UInt32  // 4 bytes
    var stringCount: UInt32  // 4 bytes
    var totalSize: UInt64  // 8 bytes
    let hashSeed: UInt64  // 8 bytes
    var lastCompactionTime: Int64 = 0  // 8 bytes
    var reserved: [UInt8] = Array(repeating: 0, count: 32)  // Pad to 64 bytes
}

struct StringEntry {
    let hash: UInt64  // 8 bytes
    let offset: UInt32  // 4 bytes
    let length: UInt32  // 4 bytes
    var refCount: UInt32  // 4 bytes
    var flags: UInt32 = 0  // 4 bytes
    var reserved: [UInt8] = Array(repeating: 0, count: 8)  // Pad to 32 bytes
}

struct StringPoolStatistics {
    let totalStrings: Int
    let totalBytes: Int
    let uniqueStrings: Int
    let deduplicationRatio: Double
}

// MARK: - Concurrent Access Manager

actor ConcurrentAccessManager {
    private var readLocks: [UUID: Int] = [:]  // Document ID -> read count
    private var writeLocks: Set<UUID> = []
    private var waitingWriters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func acquireReadLock(for id: UUID) async {
        // Wait if there's a write lock
        while writeLocks.contains(id) {
            await Task.yield()
        }

        readLocks[id, default: 0] += 1
    }

    func releaseReadLock(for id: UUID) {
        if let count = readLocks[id] {
            if count > 1 {
                readLocks[id] = count - 1
            } else {
                readLocks.removeValue(forKey: id)
            }
        }

        // Wake up waiting writers if no more readers
        if readLocks[id] == nil, let continuation = waitingWriters.removeValue(forKey: id) {
            continuation.resume()
        }
    }

    func acquireWriteLock(for id: UUID) async {
        // Wait for existing write lock
        while writeLocks.contains(id) {
            await Task.yield()
        }

        writeLocks.insert(id)

        // Wait for all readers to finish
        if readLocks[id] != nil {
            await withCheckedContinuation { continuation in
                waitingWriters[id] = continuation
            }
        }
    }

    func releaseWriteLock(for id: UUID) {
        writeLocks.remove(id)
    }
}

// MARK: - Transaction Log

actor TransactionLog {
    private let fileHandle: FileHandle
    private nonisolated let logger = Logger(subsystem: "com.prompt.app", category: "TransactionLog")

    enum Operation: Codable {
        case insert(promptId: UUID, metadataIndex: Int)
        case update(promptId: UUID, oldOffset: UInt64, newOffset: UInt64, newLength: UInt32)
        case delete(promptId: UUID, metadataIndex: Int)
    }

    struct Transaction: Codable {
        let id: UUID
        let timestamp: Date
        var status: Status
        var operations: [Operation] = []

        enum Status: String, Codable {
            case pending
            case committed
            case failed
        }
    }

    init(url: URL) throws {
        // Create log file if needed
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        fileHandle = try FileHandle(forUpdating: url)

        // Seek to end for appending
        try fileHandle.seekToEnd()
    }

    deinit {
        try? fileHandle.close()
    }

    func beginTransaction() async throws -> UUID {
        let transaction = Transaction(
            id: UUID(),
            timestamp: Date(),
            status: .pending
        )

        // No lock needed - actor provides isolation

        let data = try JSONEncoder().encode(transaction)
        let sizeData = withUnsafeBytes(of: UInt32(data.count)) { Data($0) }

        try fileHandle.write(contentsOf: sizeData)
        try fileHandle.write(contentsOf: data)
        try fileHandle.synchronize()

        logger.info("Started transaction: \(transaction.id)")
        return transaction.id
    }

    func logOperation(_ operation: Operation, txId: UUID) async throws {
        // No lock needed - actor provides isolation

        let entry = OperationEntry(transactionId: txId, operation: operation)
        let data = try JSONEncoder().encode(entry)
        let sizeData = withUnsafeBytes(of: UInt32(data.count)) { Data($0) }

        try fileHandle.write(contentsOf: sizeData)
        try fileHandle.write(contentsOf: data)
    }

    func commitTransaction(_ txId: UUID) async throws {
        // No lock needed - actor provides isolation

        let commit = CommitEntry(transactionId: txId, status: .committed)
        let data = try JSONEncoder().encode(commit)
        let sizeData = withUnsafeBytes(of: UInt32(data.count)) { Data($0) }

        try fileHandle.write(contentsOf: sizeData)
        try fileHandle.write(contentsOf: data)
        try fileHandle.synchronize()

        logger.info("Committed transaction: \(txId)")
    }

    func rollbackTransaction(_ txId: UUID) async throws {
        // No lock needed - actor provides isolation

        let rollback = CommitEntry(transactionId: txId, status: .failed)
        let data = try JSONEncoder().encode(rollback)
        let sizeData = withUnsafeBytes(of: UInt32(data.count)) { Data($0) }

        try fileHandle.write(contentsOf: sizeData)
        try fileHandle.write(contentsOf: data)
        try fileHandle.synchronize()

        logger.warning("Rolled back transaction: \(txId)")
    }

    func getPendingTransactions() async throws -> [Transaction] {
        // Read log from beginning to find pending transactions
        fileHandle.seek(toFileOffset: 0)

        var transactions: [UUID: Transaction] = [:]
        var operations: [UUID: [Operation]] = [:]

        while let entry = try readNextEntry() {
            switch entry {
            case .transaction(let tx):
                transactions[tx.id] = tx

            case .operation(let op):
                operations[op.transactionId, default: []].append(op.operation)

            case .commit(let commit):
                if var tx = transactions[commit.transactionId] {
                    tx.status = commit.status
                    transactions[tx.id] = tx
                }
            }
        }

        // Return only pending transactions
        return transactions.values
            .filter { $0.status == .pending }
            .map { tx in
                var transaction = tx
                transaction.operations = operations[tx.id] ?? []
                return transaction
            }
    }

    func markTransactionFailed(_ txId: UUID) async throws {
        try await rollbackTransaction(txId)
    }

    private enum LogEntry {
        case transaction(Transaction)
        case operation(OperationEntry)
        case commit(CommitEntry)
    }

    private struct OperationEntry: Codable {
        let transactionId: UUID
        let operation: Operation
    }

    private struct CommitEntry: Codable {
        let transactionId: UUID
        let status: Transaction.Status
    }

    private func readNextEntry() throws -> LogEntry? {
        // Read size
        guard let sizeData = try fileHandle.read(upToCount: 4),
            sizeData.count == 4
        else {
            return nil
        }

        let size = sizeData.withUnsafeBytes { $0.load(as: UInt32.self) }

        // Read data
        guard let data = try fileHandle.read(upToCount: Int(size)),
            data.count == size
        else {
            return nil
        }

        // Try to decode as different types
        if let transaction = try? JSONDecoder().decode(Transaction.self, from: data) {
            return .transaction(transaction)
        } else if let operation = try? JSONDecoder().decode(OperationEntry.self, from: data) {
            return .operation(operation)
        } else if let commit = try? JSONDecoder().decode(CommitEntry.self, from: data) {
            return .commit(commit)
        }

        return nil
    }
}
