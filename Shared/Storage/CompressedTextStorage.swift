import Compression
import Foundation
import os

/// High-performance compressed text storage with parallel search
actor CompressedTextStorage {
    // MARK: - Storage

    /// Compressed chunks of text data
    private var chunks: ContiguousArray<CompressedChunk> = []

    /// Index for fast content location
    private var contentIndex: ContiguousArray<CompressedContentLocation> = []

    /// Decompression cache for frequently accessed content
    private var cache: LRUCache<Int, String> = LRUCache(capacity: 100)

    /// Compression settings
    private let algorithm = COMPRESSION_ZLIB
    private let chunkSize = 64 * 1024  // 64KB chunks

    /// Logger
    private let logger = Logger(subsystem: "com.prompt.app", category: "CompressedTextStorage")

    /// Parallel processing queue
    private let searchQueue = DispatchQueue(label: "compressed.search", attributes: .concurrent)

    /// Statistics
    private var totalUncompressed: Int = 0
    private var totalCompressed: Int = 0

    // MARK: - Operations

    /// Append content with automatic compression
    func append(_ content: String) {
        let data = Data(content.utf8)
        let uncompressedSize = data.count

        // Compress the data
        let compressed = compress(data: data)

        // Store in current chunk or create new one
        let location = storeCompressed(compressed, originalSize: uncompressedSize)
        contentIndex.append(location)

        // Update statistics
        totalUncompressed += uncompressedSize
        totalCompressed += compressed.count
    }

    /// Decompress content at index
    func decompress(at index: Int) -> String {
        guard index >= 0 && index < contentIndex.count else { return "" }

        // Check cache first
        if let cached = cache.get(index) {
            return cached
        }

        let location = contentIndex[index]
        let chunk = chunks[Int(location.chunkIndex)]

        // Extract data from chunk
        let start = Int(location.offset)
        let end = start + Int(location.compressedSize)
        let compressedData = chunk.data[start..<end]

        // Decompress
        let decompressed = decompress(
            data: Data(compressedData),
            originalSize: Int(location.originalSize)
        )

        guard let content = String(bytes: decompressed, encoding: .utf8) else {
            logger.error("Failed to decode decompressed data as UTF-8")
            return ""
        }

        // Cache the result
        cache.set(index, value: content)

        return content
    }

    /// Update content at index
    func update(at index: Int, with newContent: String) {
        guard index >= 0 && index < contentIndex.count else { return }

        // Remove from cache
        cache.remove(index)

        // Compress new content
        let data = Data(newContent.utf8)
        let compressed = compress(data: data)

        // Update location
        let location = storeCompressed(compressed, originalSize: data.count)
        contentIndex[index] = location
    }

    /// Parallel search across all content
    func parallelSearch(query: String) async -> Set<Int> {
        let queryLower = query.lowercased()
        let indexCount = contentIndex.count
        guard indexCount > 0 else { return [] }

        // Determine batch size for parallel processing
        let batchSize = max(100, indexCount / ProcessInfo.processInfo.activeProcessorCount)
        var results = Set<Int>()

        // Use TaskGroup for concurrent search (actor-safe)
        await withTaskGroup(of: Set<Int>.self) { group in
            let iterations = (indexCount + batchSize - 1) / batchSize

            for batchIndex in 0..<iterations {
                let start = batchIndex * batchSize
                let end = min(start + batchSize, indexCount)

                group.addTask {
                    var localResults = Set<Int>()

                    for idx in start..<end {
                        let content = await self.decompress(at: idx).lowercased()
                        if content.contains(queryLower) {
                            localResults.insert(idx)
                        }
                    }

                    return localResults
                }
            }

            // Collect results
            for await localResults in group {
                results.formUnion(localResults)
            }
        }

        return results
    }

    /// Calculate average content size
    func averageSize() -> Int {
        contentIndex.isEmpty ? 0 : totalUncompressed / contentIndex.count
    }

    /// Compression ratio
    func compressionRatio() -> Double {
        totalUncompressed > 0 ? Double(totalCompressed) / Double(totalUncompressed) : 1.0
    }

    // MARK: - Private Methods

    private func compress(data: Data) -> Data {
        guard let compressed = data.compressed(using: algorithm) else {
            // Fallback to uncompressed if compression fails
            return data
        }

        // Only use compressed if it's actually smaller
        return compressed.count < data.count ? compressed : data
    }

    private func decompress(data: Data, originalSize: Int) -> Data {
        if let decompressed = data.decompressed(using: algorithm) {
            return decompressed
        }
        // Data might be stored uncompressed
        return data
    }

    private func storeCompressed(_ data: Data, originalSize: Int) -> CompressedContentLocation {
        // Find or create chunk with enough space
        var chunkIndex = chunks.count - 1

        if chunkIndex < 0 || chunks[chunkIndex].remainingCapacity < data.count {
            // Create new chunk
            let newChunk = CompressedChunk(capacity: chunkSize)
            chunks.append(newChunk)
            chunkIndex = chunks.count - 1
        }

        // Store in chunk
        let chunk = chunks[chunkIndex]
        let offset = chunk.store(data)

        return CompressedContentLocation(
            chunkIndex: Int32(chunkIndex),
            offset: Int32(offset),
            compressedSize: Int32(data.count),
            originalSize: Int32(originalSize)
        )
    }
}

// MARK: - Supporting Types

class CompressedChunk {
    var data: Data
    private(set) var used: Int = 0
    let capacity: Int

    var remainingCapacity: Int { capacity - used }

    init(capacity: Int) {
        self.capacity = capacity
        self.data = Data(capacity: capacity)
    }

    func store(_ content: Data) -> Int {
        let offset = used
        data.replaceSubrange(offset..<(offset + content.count), with: content)
        used += content.count
        return offset
    }
}

struct CompressedContentLocation {
    let chunkIndex: Int32
    let offset: Int32
    let compressedSize: Int32
    let originalSize: Int32
}

// MARK: - LRU Cache

private class LRUCache<Key: Hashable, Value> {
    private class Node {
        var key: Key
        var value: Value
        var prev: Node?
        var next: Node?

        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    private let capacity: Int
    private var cache: [Key: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
    }

    func get(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }

        guard let node = cache[key] else { return nil }

        // Move to front
        removeNode(node)
        addToFront(node)

        return node.value
    }

    func set(_ key: Key, value: Value) {
        lock.lock()
        defer { lock.unlock() }

        if let node = cache[key] {
            // Update existing
            node.value = value
            removeNode(node)
            addToFront(node)
        } else {
            // Add new
            let node = Node(key: key, value: value)
            cache[key] = node
            addToFront(node)

            // Check capacity
            if cache.count > capacity {
                // Remove least recently used
                if let lru = tail {
                    removeNode(lru)
                    cache.removeValue(forKey: lru.key)
                }
            }
        }
    }

    func remove(_ key: Key) {
        lock.lock()
        defer { lock.unlock() }

        if let node = cache[key] {
            removeNode(node)
            cache.removeValue(forKey: key)
        }
    }

    private func removeNode(_ node: Node) {
        if node === head {
            head = node.next
        }
        if node === tail {
            tail = node.prev
        }
        node.prev?.next = node.next
        node.next?.prev = node.prev
    }

    private func addToFront(_ node: Node) {
        node.next = head
        node.prev = nil
        head?.prev = node
        head = node
        if tail == nil {
            tail = head
        }
    }
}

// MARK: - Data Extensions

extension Data {
    func compressed(using algorithm: compression_algorithm) -> Data? {
        return self.withUnsafeBytes { bytes in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
            defer { buffer.deallocate() }

            let compressedSize = compression_encode_buffer(
                buffer, count,
                bytes.bindMemory(to: UInt8.self).baseAddress!, count,
                nil, algorithm
            )

            guard compressedSize > 0 else { return nil }
            return Data(bytes: buffer, count: compressedSize)
        }
    }

    func decompressed(using algorithm: compression_algorithm) -> Data? {
        return self.withUnsafeBytes { bytes in
            // Allocate buffer 10x the compressed size as estimate
            let bufferSize = count * 10
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            let decompressedSize = compression_decode_buffer(
                buffer, bufferSize,
                bytes.bindMemory(to: UInt8.self).baseAddress!, count,
                nil, algorithm
            )

            guard decompressedSize > 0 else { return nil }
            return Data(bytes: buffer, count: decompressedSize)
        }
    }
}
