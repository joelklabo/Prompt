import Compression
import CryptoKit
import Foundation
import os

/// Content-addressable storage with deduplication and zero-copy operations
/// Uses content hashing to eliminate duplicate storage and memory-mapped files for performance
actor ContentAddressableStore {
    private let logger = Logger(subsystem: "com.prompt.app", category: "ContentAddressableStore")

    // Storage directory
    private let storageURL: URL

    // Reference counting for garbage collection
    private var referenceCount: [String: Int] = [:]

    // Memory-mapped file cache
    private var mappedFiles: [String: NSData] = [:]

    // Compression settings
    private let compressionAlgorithm = COMPRESSION_ZLIB
    private let compressionThreshold = 1024  // Compress content larger than 1KB

    // Statistics
    private var stats = StorageStatistics()

    init() async throws {
        // Setup storage directory
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.storageURL = documentsDir.appendingPathComponent("com.promptbank.cas")

        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)

        // Load reference counts
        await loadReferenceCount()

        logger.info("ContentAddressableStore initialized")
    }

    // MARK: - Public API

    /// Store content and return reference (zero-copy when possible)
    func store(_ content: String) async -> ContentReference {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Calculate content hash
        let hash = self.hash(content)
        let size = content.utf8.count

        // Check if already stored
        if let existingCount = referenceCount[hash] {
            // Increment reference count
            referenceCount[hash] = existingCount + 1
            stats.deduplicatedBytes += size

            return ContentReference(
                hash: hash,
                size: size,
                referenceCount: existingCount + 1
            )
        }

        // Store new content
        let stored = await storeContent(content, hash: hash)

        // Update reference count
        referenceCount[hash] = 1
        stats.totalBytes += stored.compressedSize
        stats.uniqueObjects += 1

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.debug("Stored content in \(elapsed)ms, hash: \(hash)")

        return ContentReference(
            hash: hash,
            size: size,
            referenceCount: 1
        )
    }

    /// Retrieve content using zero-copy memory mapping
    func retrieve(_ reference: ContentReference) async throws -> String {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Check memory-mapped cache first
        if let mapped = mappedFiles[reference.hash] {
            let content = try decodeContent(from: mapped as Data)
            return content
        }

        // Load from disk with memory mapping
        let fileURL = storageURL.appendingPathComponent(reference.hash)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CASError.contentNotFound(reference.hash)
        }

        // Memory-map the file for zero-copy access
        let data = try NSData(contentsOf: fileURL, options: .mappedIfSafe)
        mappedFiles[reference.hash] = data

        // Decode content
        let content = try decodeContent(from: data as Data)

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.debug("Retrieved content in \(elapsed)ms, hash: \(reference.hash)")

        return content
    }

    /// Release reference (for garbage collection)
    func release(_ reference: ContentReference) async {
        guard let count = referenceCount[reference.hash] else { return }

        if count <= 1 {
            // Remove from storage
            referenceCount.removeValue(forKey: reference.hash)
            mappedFiles.removeValue(forKey: reference.hash)

            let fileURL = storageURL.appendingPathComponent(reference.hash)
            try? FileManager.default.removeItem(at: fileURL)

            stats.totalBytes -= reference.size
            stats.uniqueObjects -= 1

            logger.info("Removed unreferenced content: \(reference.hash)")
        } else {
            referenceCount[reference.hash] = count - 1
        }
    }

    /// Calculate hash for content
    func hash(_ content: String) -> String {
        let data = Data(content.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Get storage statistics
    func getStatistics() async -> StorageStatistics {
        return stats
    }

    /// Garbage collection for unreferenced content
    func garbageCollect() async throws {
        logger.info("Starting garbage collection")

        let contents = try FileManager.default.contentsOfDirectory(
            at: storageURL,
            includingPropertiesForKeys: [.fileSizeKey]
        )

        var cleaned = 0
        var freedBytes = 0

        for fileURL in contents {
            let hash = fileURL.lastPathComponent

            // Skip if still referenced
            if referenceCount[hash] != nil { continue }

            // Get file size before deletion
            let attributes = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            let size = attributes.fileSize ?? 0

            // Remove orphaned file
            try FileManager.default.removeItem(at: fileURL)
            cleaned += 1
            freedBytes += size
        }

        logger.info("Garbage collection completed: removed \(cleaned) files, freed \(freedBytes) bytes")
    }

    // MARK: - Private Methods

    private func storeContent(_ content: String, hash: String) async -> (originalSize: Int, compressedSize: Int) {
        let data = Data(content.utf8)
        let originalSize = data.count

        // Compress if above threshold
        let finalData: Data
        let isCompressed: Bool

        if originalSize > compressionThreshold {
            if let compressed = compress(data) {
                finalData = compressed
                isCompressed = true
            } else {
                finalData = data
                isCompressed = false
            }
        } else {
            finalData = data
            isCompressed = false
        }

        // Store with metadata
        let metadata = ContentMetadata(
            originalSize: originalSize,
            compressedSize: finalData.count,
            isCompressed: isCompressed,
            algorithm: isCompressed ? "zlib" : "none"
        )

        let storedData = encodeContent(finalData, metadata: metadata)

        // Write atomically
        let fileURL = storageURL.appendingPathComponent(hash)
        try? storedData.write(to: fileURL, options: .atomic)

        return (originalSize, storedData.count)
    }

    private func encodeContent(_ data: Data, metadata: ContentMetadata) -> Data {
        // Simple format: [metadata_length:4][metadata][content]
        var result = Data()

        guard let metadataData = try? JSONEncoder().encode(metadata) else {
            logger.error("Failed to encode metadata")
            return data
        }
        var length = UInt32(metadataData.count).littleEndian

        result.append(Data(bytes: &length, count: 4))
        result.append(metadataData)
        result.append(data)

        return result
    }

    private func decodeContent(from data: Data) throws -> String {
        guard data.count > 4 else {
            throw CASError.corruptedContent
        }

        // Read metadata length
        let lengthData = data.subdata(in: 0..<4)
        let metadataLength = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }

        guard data.count >= 4 + Int(metadataLength) else {
            throw CASError.corruptedContent
        }

        // Read metadata
        let metadataData = data.subdata(in: 4..<(4 + Int(metadataLength)))
        let metadata = try JSONDecoder().decode(ContentMetadata.self, from: metadataData)

        // Read content
        let contentData = data.subdata(in: (4 + Int(metadataLength))..<data.count)

        // Decompress if needed
        let finalData: Data
        if metadata.isCompressed {
            guard let decompressed = decompress(contentData) else {
                throw CASError.decompressionFailed
            }
            finalData = decompressed
        } else {
            finalData = contentData
        }

        guard let content = String(data: finalData, encoding: .utf8) else {
            throw CASError.encodingFailed
        }

        return content
    }

    private func compress(_ data: Data) -> Data? {
        return data.withUnsafeBytes { bytes in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            defer { buffer.deallocate() }

            let compressedSize = compression_encode_buffer(
                buffer, data.count,
                bytes.bindMemory(to: UInt8.self).baseAddress!, data.count,
                nil, compressionAlgorithm
            )

            guard compressedSize > 0 && compressedSize < data.count else {
                return nil  // Compression not beneficial
            }

            return Data(bytes: buffer, count: compressedSize)
        }
    }

    private func decompress(_ data: Data) -> Data? {
        return data.withUnsafeBytes { bytes in
            // Allocate buffer with 10x original size (conservative estimate)
            let bufferSize = data.count * 10
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            let decompressedSize = compression_decode_buffer(
                buffer, bufferSize,
                bytes.bindMemory(to: UInt8.self).baseAddress!, data.count,
                nil, compressionAlgorithm
            )

            guard decompressedSize > 0 else { return nil }

            return Data(bytes: buffer, count: decompressedSize)
        }
    }

}

// MARK: - Persistence Methods

extension ContentAddressableStore {
    private func loadReferenceCount() async {
        let referenceFile = storageURL.appendingPathComponent("references.json")

        guard FileManager.default.fileExists(atPath: referenceFile.path),
            let data = try? Data(contentsOf: referenceFile),
            let refs = try? JSONDecoder().decode([String: Int].self, from: data)
        else {
            return
        }

        referenceCount = refs
        logger.info("Loaded \(refs.count) reference counts")
    }

    private func saveReferenceCount() async {
        let referenceFile = storageURL.appendingPathComponent("references.json")

        guard let data = try? JSONEncoder().encode(referenceCount) else { return }
        try? data.write(to: referenceFile, options: .atomic)
    }
}

// MARK: - Helper Types

extension ContentAddressableStore {
    private struct ContentMetadata: Codable {
        let originalSize: Int
        let compressedSize: Int
        let isCompressed: Bool
        let algorithm: String
    }

    enum CASError: LocalizedError {
        case contentNotFound(String)
        case corruptedContent
        case decompressionFailed
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .contentNotFound(let hash):
                return "Content not found: \(hash)"
            case .corruptedContent:
                return "Content data is corrupted"
            case .decompressionFailed:
                return "Failed to decompress content"
            case .encodingFailed:
                return "Failed to encode content as UTF-8"
            }
        }
    }
}

// MARK: - Storage Statistics

struct StorageStatistics: Sendable {
    var totalBytes: Int = 0
    var uniqueObjects: Int = 0
    var deduplicatedBytes: Int = 0

    var deduplicationRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(deduplicatedBytes) / Double(totalBytes + deduplicatedBytes)
    }

    var averageObjectSize: Int {
        guard uniqueObjects > 0 else { return 0 }
        return totalBytes / uniqueObjects
    }
}
