import CryptoKit
import Foundation
import os

/// High-performance render cache with LRU eviction and memory-mapped storage
actor RenderCache {
    private let logger = Logger(subsystem: "com.prompt.app", category: "RenderCache")

    // In-memory cache with LRU eviction
    private var cache: RenderCacheLRU<String, RenderedContent>

    // Disk-backed cache using memory-mapped files
    private let diskCache: DiskCache

    // Render queue for batching
    private let renderQueue = DispatchQueue(label: "com.prompt.rendercache", attributes: .concurrent)

    // Cache statistics
    private var stats = CacheStatistics()

    init() async throws {
        self.cache = RenderCacheLRU(capacity: 1000)  // Keep 1000 most recent renders in memory
        self.diskCache = try DiskCache()

        logger.info("RenderCache initialized with capacity: 1000 items")
    }

    // MARK: - Public API

    func get(content: String) async -> RenderedContent? {
        let key = hashContent(content)
        stats.totalRequests += 1

        // Check in-memory cache first (fastest)
        if let cached = cache.get(key) {
            stats.memoryHits += 1
            return cached
        }

        // Check disk cache (slower but still fast with mmap)
        if let diskCached = try? await diskCache.get(key: key) {
            stats.diskHits += 1
            // Promote to memory cache
            cache.put(key, diskCached)
            return diskCached
        }

        stats.misses += 1
        return nil
    }

    func store(content: String, rendered: RenderedContent) async {
        let key = hashContent(content)

        // Store in memory cache
        cache.put(key, rendered)

        // Store on disk asynchronously
        Task.detached(priority: .background) { [weak self] in
            try? await self?.diskCache.store(key: key, content: rendered)
        }
    }

    func evictLRU(keepRatio: Double) async {
        let targetSize = Int(Double(cache.capacity) * keepRatio)
        cache.resize(to: targetSize)
        logger.info("Evicted cache entries, new size: \(targetSize)")
    }

    func preRenderBatch(_ contents: [String]) async {
        await withTaskGroup(of: (String, RenderedContent?).self) { group in
            for content in contents {
                group.addTask {
                    let rendered = await self.renderMarkdown(content)
                    return (content, rendered)
                }
            }

            for await (content, rendered) in group {
                if let rendered = rendered {
                    await self.store(content: content, rendered: rendered)
                }
            }
        }
    }

    // MARK: - Private Methods

    private func hashContent(_ content: String) -> String {
        let data = Data(content.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func renderMarkdown(_ content: String) async -> RenderedContent? {
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let rendered = try AttributedString(
                markdown: content,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )

            let renderTime = CFAbsoluteTimeGetCurrent() - startTime

            return RenderedContent(
                attributedString: rendered,
                renderTime: renderTime,
                isPlaceholder: false
            )
        } catch {
            logger.error("Failed to render markdown: \(error)")
            return nil
        }
    }

    // MARK: - Cache Statistics

    struct CacheStatistics {
        var totalRequests: Int = 0
        var memoryHits: Int = 0
        var diskHits: Int = 0
        var misses: Int = 0

        var hitRate: Double {
            guard totalRequests > 0 else { return 0 }
            return Double(memoryHits + diskHits) / Double(totalRequests)
        }

        var memoryHitRate: Double {
            guard totalRequests > 0 else { return 0 }
            return Double(memoryHits) / Double(totalRequests)
        }
    }
}

// MARK: - LRU Cache Implementation

private final class RenderCacheLRU<Key: Hashable, Value> {
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

    private var cache: [Key: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private let lock = NSLock()
    var capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func get(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }

        guard let node = cache[key] else { return nil }
        moveToHead(node)
        return node.value
    }

    func put(_ key: Key, _ value: Value) {
        lock.lock()
        defer { lock.unlock() }

        if let node = cache[key] {
            node.value = value
            moveToHead(node)
        } else {
            let newNode = Node(key: key, value: value)
            cache[key] = newNode
            addToHead(newNode)

            if cache.count > capacity {
                if let tail = removeTail() {
                    cache.removeValue(forKey: tail.key)
                }
            }
        }
    }

    func resize(to newCapacity: Int) {
        lock.lock()
        defer { lock.unlock() }

        capacity = newCapacity
        while cache.count > capacity {
            if let tail = removeTail() {
                cache.removeValue(forKey: tail.key)
            }
        }
    }

    private func addToHead(_ node: Node) {
        node.next = head
        node.prev = nil
        head?.prev = node
        head = node
        if tail == nil {
            tail = head
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

    private func moveToHead(_ node: Node) {
        guard node !== head else { return }
        removeNode(node)
        addToHead(node)
    }

    private func removeTail() -> Node? {
        guard let node = tail else { return nil }
        removeNode(node)
        return node
    }
}

// MARK: - Disk Cache with Memory-Mapped Files

private actor DiskCache {
    private let cacheURL: URL
    private let logger = Logger(subsystem: "com.prompt.app", category: "DiskCache")

    init() throws {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheURL = cacheDir.appendingPathComponent("com.prompt.rendercache")

        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    }

    func get(key: String) async throws -> RenderedContent? {
        let fileURL = cacheURL.appendingPathComponent("\(key).cache")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        // Use memory-mapped file for efficient reading
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return try JSONDecoder().decode(RenderedContent.self, from: data)
    }

    func store(key: String, content: RenderedContent) async throws {
        let fileURL = cacheURL.appendingPathComponent("\(key).cache")
        let data = try JSONEncoder().encode(content)

        // Write atomically to prevent corruption
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() async throws {
        let contents = try FileManager.default.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil)
        for file in contents {
            try FileManager.default.removeItem(at: file)
        }
    }
}

// Make RenderedContent codable for disk storage
extension RenderedContent: Codable {
    enum CodingKeys: String, CodingKey {
        case attributedString
        case renderTime
        case isPlaceholder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stringData = try container.decode(Data.self, forKey: .attributedString)
        if let nsAttributedString = try? NSAttributedString(
            data: stringData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            self.attributedString = AttributedString(nsAttributedString)
        } else {
            self.attributedString = AttributedString()
        }
        self.renderTime = try container.decode(TimeInterval.self, forKey: .renderTime)
        self.isPlaceholder = try container.decode(Bool.self, forKey: .isPlaceholder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let nsAttributedString = NSAttributedString(attributedString)
        let data = try nsAttributedString.data(
            from: NSRange(location: 0, length: nsAttributedString.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try container.encode(data, forKey: .attributedString)
        try container.encode(renderTime, forKey: .renderTime)
        try container.encode(isPlaceholder, forKey: .isPlaceholder)
    }
}
