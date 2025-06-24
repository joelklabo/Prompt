import Compression
import CryptoKit
import Foundation
import os.log
import SQLite3

/// Reference to stored content
struct ContentReference: Sendable {
    let hash: String
    let storageType: ContentStorageType
    let size: Int

    enum ContentStorageType: String, Sendable {
        case sqlite
        case file
    }
}

/// Hybrid content store that uses SQLite for small content and files for large content
actor HybridContentStore {
    private let logger = Logger(subsystem: "com.prompt.app", category: "HybridContentStore")
    private let sqliteDB: SQLiteContentDB
    private let fileStore: ContentAddressableStore

    // Threshold for SQLite vs file storage
    private let sqliteThreshold = 100 * 1024  // 100KB

    init(databaseURL: URL) async throws {
        self.sqliteDB = try await SQLiteContentDB(url: databaseURL)
        self.fileStore = try await ContentAddressableStore()
    }

    /// Synchronous factory method for app initialization
    static func createSync(databaseURL: URL) -> HybridContentStore? {
        // Create directories synchronously
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            // Can't use instance logger in static method
            let staticLogger = Logger(subsystem: "com.prompt.app", category: "HybridContentStore")
            staticLogger.error("Failed to create directories: \(error)")
            return nil
        }

        // The actual async initialization will happen on first use
        // For now, return nil to use PromptService without content store
        return nil
    }

    /// Store content and return a reference
    func store(_ content: String) async throws -> ContentReference {
        let contentData = Data(content.utf8)
        let hash = contentData.sha256Hash()
        let size = contentData.count

        // Check if content already exists
        if let existingRef = try await findExisting(hash: hash) {
            return existingRef
        }

        // Determine storage type based on size
        let storageType: ContentReference.ContentStorageType = size < sqliteThreshold ? .sqlite : .file

        // Compress content
        let compressedData = try compress(contentData)

        // Store based on type
        switch storageType {
        case .sqlite:
            try await sqliteDB.store(hash: hash, data: compressedData)
        case .file:
            // ContentAddressableStore handles strings, not compressed data
            _ = await fileStore.store(content)
        }

        logger.info(
            "Stored: hash=\(hash), size=\(size), compressed=\(compressedData.count), type=\(storageType.rawValue)")

        return ContentReference(hash: hash, storageType: storageType, size: size)
    }

    /// Retrieve content by reference
    func retrieve(_ reference: ContentReference) async throws -> String {
        let compressedData: Data

        switch reference.storageType {
        case .sqlite:
            guard let data = try await sqliteDB.retrieve(hash: reference.hash) else {
                throw ContentStoreError.contentNotFound(hash: reference.hash)
            }
            compressedData = data
        case .file:
            // Retrieve from ContentAddressableStore
            let casRef = CASContentReference(
                hash: reference.hash,
                size: reference.size,
                referenceCount: 1
            )
            let retrievedContent = try await fileStore.retrieve(casRef)
            // ContentAddressableStore returns decompressed content
            return retrievedContent
        }

        // Only decompress for SQLite storage
        let decompressedData = try decompress(compressedData)

        guard let content = String(data: decompressedData, encoding: .utf8) else {
            throw ContentStoreError.invalidContent
        }

        return content
    }

    /// Delete content by reference
    func delete(_ reference: ContentReference) async throws {
        switch reference.storageType {
        case .sqlite:
            try await sqliteDB.delete(hash: reference.hash)
        case .file:
            // ContentAddressableStore uses reference counting
            // TODO: Implement release method in ContentAddressableStore
            logger.info("Would release content with hash: \(reference.hash)")
        }

        logger.info("Deleted content: hash=\(reference.hash)")
    }

    /// Find existing content by hash
    private func findExisting(hash: String) async throws -> ContentReference? {
        // Check SQLite first
        if try await sqliteDB.exists(hash: hash) {
            let size = try await sqliteDB.getSize(hash: hash) ?? 0
            return ContentReference(hash: hash, storageType: .sqlite, size: size)
        }

        // ContentAddressableStore doesn't provide exists check
        // For now, return nil if not in SQLite
        // TODO: Add exists method to ContentAddressableStore

        return nil
    }

    /// Compress data using zlib
    private func compress(_ data: Data) throws -> Data {
        return try (data as NSData).compressed(using: .zlib) as Data
    }

    /// Decompress data using zlib
    private func decompress(_ data: Data) throws -> Data {
        return try (data as NSData).decompressed(using: .zlib) as Data
    }
    
    /// Close the database connections
    func close() async {
        await sqliteDB.close()
    }
}

/// SQLite backend for small content storage
actor SQLiteContentDB {
    private let logger = Logger(subsystem: "com.prompt.app", category: "SQLiteContentDB")
    private var db: OpaquePointer?
    private let url: URL

    init(url: URL) async throws {
        self.url = url

        // Ensure directory exists
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Open database
        guard
            sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
                == SQLITE_OK
        else {
            throw ContentStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }

        // Create table
        let createTable = """
                CREATE TABLE IF NOT EXISTS content (
                    hash TEXT PRIMARY KEY,
                    data BLOB NOT NULL,
                    size INTEGER NOT NULL,
                    created_at INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_created_at ON content(created_at);
            """

        guard sqlite3_exec(db, createTable, nil, nil, nil) == SQLITE_OK else {
            throw ContentStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }

        logger.info("SQLite content database initialized at: \(url.path)")
    }

    // Clean up method to be called before deallocation
    func close() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    deinit {
        // Note: We can't access actor-isolated state from deinit in Swift 6
        // Cleanup should be done by calling close() before the actor is deallocated
    }

    func store(hash: String, data: Data) async throws {
        let sql = "INSERT OR REPLACE INTO content (hash, data, size, created_at) VALUES (?, ?, ?, ?)"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, hash, -1, nil)
        sqlite3_bind_blob(statement, 2, (data as NSData).bytes, Int32(data.count), nil)
        sqlite3_bind_int64(statement, 3, Int64(data.count))
        sqlite3_bind_int64(statement, 4, Int64(Date().timeIntervalSince1970))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    func retrieve(hash: String) async throws -> Data? {
        let sql = "SELECT data FROM content WHERE hash = ?"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, hash, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let dataPointer = sqlite3_column_blob(statement, 0)
        let dataSize = sqlite3_column_bytes(statement, 0)

        guard let dataPointer = dataPointer else {
            return nil
        }

        return Data(bytes: dataPointer, count: Int(dataSize))
    }

    func exists(hash: String) async throws -> Bool {
        let sql = "SELECT 1 FROM content WHERE hash = ? LIMIT 1"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, hash, -1, nil)

        return sqlite3_step(statement) == SQLITE_ROW
    }

    func getSize(hash: String) async throws -> Int? {
        let sql = "SELECT size FROM content WHERE hash = ?"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, hash, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return Int(sqlite3_column_int64(statement, 0))
    }

    func delete(hash: String) async throws {
        let sql = "DELETE FROM content WHERE hash = ?"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, hash, -1, nil)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentStoreError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }
}

/// Errors for content store operations
enum ContentStoreError: LocalizedError {
    case contentNotFound(hash: String)
    case invalidContent
    case databaseError(String)
    case compressionError

    var errorDescription: String? {
        switch self {
        case .contentNotFound(let hash):
            return "Content not found: \(hash)"
        case .invalidContent:
            return "Invalid content format"
        case .databaseError(let message):
            return "Database error: \(message)"
        case .compressionError:
            return "Compression/decompression failed"
        }
    }
}

// Extension to compute SHA256 hash
extension Data {
    func sha256Hash() -> String {
        let hash = SHA256.hash(data: self)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
