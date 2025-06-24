import Foundation
import os.log

/// High-performance two-tier LRU cache for prompt data
actor PromptCache {
    private let logger = Logger(subsystem: "com.prompt.app", category: "PromptCache")

    // Cache configuration
    private let maxSummaryCount = 10_000
    private let maxDetailCount = 100
    private let maxContentCount = 50  // Separate limit for content
    private let maxMemoryBytes = 50 * 1024 * 1024  // 50MB

    // Two-tier cache system
    // Tier 1: Metadata cache - hot data
    private var metadataCache = PromptCacheLRU<UUID, PromptSummary>(capacity: 10_000)
    private var summaryBatches = PromptCacheLRU<String, PromptSummaryBatch>(capacity: 100)

    // Tier 2: Content cache - on-demand data
    private var contentCache = PromptCacheLRU<UUID, String>(capacity: 50)
    private var detailCache = PromptCacheLRU<UUID, PromptDetail>(capacity: 100)

    // Memory tracking
    private var currentMemoryUsage: Int = 0
    private var contentMemoryUsage: Int = 0

    // Access tracking for smart eviction
    private var accessCounts: [UUID: Int] = [:]
    private var lastAccessTime: [UUID: Date] = [:]

    // MARK: - Summary Operations

    func getSummary(id: UUID) -> PromptSummary? {
        updateAccessTracking(id)
        return metadataCache.get(id)
    }

    func cacheSummary(_ summary: PromptSummary) {
        let estimatedSize =
            MemoryLayout<PromptSummary>.size + summary.title.utf8.count + summary.contentPreview.utf8.count
            + summary.tagNames.reduce(0) { $0 + $1.utf8.count }

        if currentMemoryUsage + estimatedSize > maxMemoryBytes {
            evictOldestEntries()
        }

        metadataCache.set(summary.id, summary)
        currentMemoryUsage += estimatedSize
    }

    func cacheSummaryBatch(_ batch: PromptSummaryBatch, key: String) {
        summaryBatches.set(key, batch)

        // Also cache individual summaries
        for summary in batch.summaries {
            cacheSummary(summary)
        }
    }

    func getSummaryBatch(key: String) -> PromptSummaryBatch? {
        return summaryBatches.get(key)
    }

    // MARK: - Detail Operations

    func getDetail(id: UUID) -> PromptDetail? {
        return detailCache.get(id)
    }

    func cacheDetail(_ detail: PromptDetail) {
        let estimatedSize =
            MemoryLayout<PromptDetail>.size + detail.title.utf8.count + detail.content.utf8.count
            + detail.tags.reduce(0) { $0 + $1.name.utf8.count }

        if currentMemoryUsage + estimatedSize > maxMemoryBytes {
            evictOldestEntries()
        }

        detailCache.set(detail.id, detail)
        currentMemoryUsage += estimatedSize

        // Also update summary cache
        cacheSummary(detail.toSummary())
    }

    // MARK: - Content Operations (Two-tier cache)

    func getContent(for id: UUID) -> String? {
        updateAccessTracking(id)
        return contentCache.get(id)
    }

    func cacheContent(_ content: String, for id: UUID) {
        let contentSize = content.utf8.count

        // Only cache if content is reasonable size
        if contentSize > 1_000_000 {  // 1MB limit for individual content
            logger.debug("Content too large to cache: \(contentSize) bytes")
            return
        }

        if contentMemoryUsage + contentSize > maxMemoryBytes / 2 {
            evictContentCache()
        }

        contentCache.set(id, content)
        contentMemoryUsage += contentSize
    }

    func getCachedContent(for id: UUID) -> String? {
        return contentCache.get(id)
    }

    // MARK: - Batch Operations

    func warmCache(with summaries: [PromptSummary]) {
        logger.info("Warming cache with \(summaries.count) summaries")

        for summary in summaries {
            cacheSummary(summary)
        }
    }

    func invalidate(id: UUID) {
        metadataCache.remove(id)
        detailCache.remove(id)
        contentCache.remove(id)
        accessCounts.removeValue(forKey: id)
        lastAccessTime.removeValue(forKey: id)
    }

    func invalidateAll() {
        metadataCache.clear()
        summaryBatches.clear()
        detailCache.clear()
        contentCache.clear()
        currentMemoryUsage = 0
        contentMemoryUsage = 0
        accessCounts.removeAll()
        lastAccessTime.removeAll()
    }

    // MARK: - Private Methods

    private func updateAccessTracking(_ id: UUID) {
        accessCounts[id, default: 0] += 1
        lastAccessTime[id] = Date()
    }

    private func evictContentCache() {
        logger.debug("Evicting content cache, current usage: \(self.contentMemoryUsage) bytes")

        // Evict least recently used content
        let evictCount = max(1, contentCache.count / 5)
        for _ in 0..<evictCount {
            if let (id, _) = contentCache.removeLeastRecent() {
                // Update memory tracking
                contentMemoryUsage = max(0, contentMemoryUsage - (contentMemoryUsage / contentCache.count))
            }
        }
    }

    private func evictOldestEntries() {
        logger.debug("Evicting cache entries, current memory: \(self.currentMemoryUsage) bytes")

        // Smart eviction based on access patterns
        // 1. First evict content (largest items)
        if contentMemoryUsage > maxMemoryBytes / 4 {
            evictContentCache()
        }

        // 2. Then evict details
        let detailEvictCount = max(1, detailCache.count / 10)
        for _ in 0..<detailEvictCount {
            _ = detailCache.removeLeastRecent()
        }

        // 3. Finally evict metadata if needed
        if currentMemoryUsage > maxMemoryBytes * 9 / 10 {
            let summaryEvictCount = max(1, metadataCache.count / 20)
            for _ in 0..<summaryEvictCount {
                _ = metadataCache.removeLeastRecent()
            }
        }

        // Recalculate memory usage (simplified)
        currentMemoryUsage = currentMemoryUsage * 8 / 10
    }

    // Memory pressure handling
    func handleMemoryPressure() {
        logger.warning("Memory pressure detected, clearing caches")

        // Clear content cache first (largest items)
        contentCache.clear()
        contentMemoryUsage = 0

        // Keep metadata cache if possible
        if currentMemoryUsage > maxMemoryBytes / 2 {
            detailCache.clear()
            currentMemoryUsage /= 2
        }
    }
}

/// Generic LRU Cache implementation
private class PromptCacheLRU<Key: Hashable, Value> {
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

    var count: Int { cache.count }

    init(capacity: Int) {
        self.capacity = capacity
    }

    func get(_ key: Key) -> Value? {
        guard let node = cache[key] else { return nil }

        // Move to front
        removeNode(node)
        addToFront(node)

        return node.value
    }

    func set(_ key: Key, _ value: Value) {
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

            if cache.count > capacity {
                removeLeastRecent()
            }
        }
    }

    func remove(_ key: Key) {
        guard let node = cache[key] else { return }
        removeNode(node)
        cache.removeValue(forKey: key)
    }

    @discardableResult
    func removeLeastRecent() -> (Key, Value)? {
        guard let node = tail else { return nil }

        removeNode(node)
        cache.removeValue(forKey: node.key)
        return (node.key, node.value)
    }

    func clear() {
        cache.removeAll()
        head = nil
        tail = nil
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
}
