import Foundation
import os.log

/// High-performance LRU cache for prompt data
actor PromptCache {
    private let logger = Logger(subsystem: "com.prompt.app", category: "PromptCache")

    // Cache configuration
    private let maxSummaryCount = 10_000
    private let maxDetailCount = 100
    private let maxMemoryBytes = 50 * 1024 * 1024  // 50MB

    // Summary cache - hot data
    private var summaryCache = PromptCacheLRU<UUID, PromptSummary>(capacity: 10_000)
    private var summaryBatches = PromptCacheLRU<String, PromptSummaryBatch>(capacity: 100)

    // Detail cache - on-demand data
    private var detailCache = PromptCacheLRU<UUID, PromptDetail>(capacity: 100)

    // Memory tracking
    private var currentMemoryUsage: Int = 0

    // MARK: - Summary Operations

    func getSummary(id: UUID) -> PromptSummary? {
        return summaryCache.get(id)
    }

    func cacheSummary(_ summary: PromptSummary) {
        let estimatedSize =
            MemoryLayout<PromptSummary>.size + summary.title.utf8.count + summary.contentPreview.utf8.count
            + summary.tagNames.reduce(0) { $0 + $1.utf8.count }

        if currentMemoryUsage + estimatedSize > maxMemoryBytes {
            evictOldestEntries()
        }

        summaryCache.set(summary.id, summary)
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

    // MARK: - Batch Operations

    func warmCache(with summaries: [PromptSummary]) {
        logger.info("Warming cache with \(summaries.count) summaries")

        for summary in summaries {
            cacheSummary(summary)
        }
    }

    func invalidate(id: UUID) {
        summaryCache.remove(id)
        detailCache.remove(id)
    }

    func invalidateAll() {
        summaryCache.clear()
        summaryBatches.clear()
        detailCache.clear()
        currentMemoryUsage = 0
    }

    // MARK: - Private Methods

    private func evictOldestEntries() {
        logger.debug("Evicting cache entries, current memory: \(self.currentMemoryUsage) bytes")

        // Evict 10% of detail cache first (larger items)
        let detailEvictCount = max(1, detailCache.count / 10)
        for _ in 0..<detailEvictCount {
            _ = detailCache.removeLeastRecent()
        }

        // Then evict summary cache if needed
        if currentMemoryUsage > maxMemoryBytes * 9 / 10 {
            let summaryEvictCount = max(1, summaryCache.count / 20)
            for _ in 0..<summaryEvictCount {
                _ = summaryCache.removeLeastRecent()
            }
        }

        // Recalculate memory usage (simplified)
        currentMemoryUsage = currentMemoryUsage * 8 / 10
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
