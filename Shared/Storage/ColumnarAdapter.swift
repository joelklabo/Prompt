import Observation
import os
import SwiftUI

/// High-performance adapter that bridges columnar storage with SwiftUI
@Observable
@MainActor
final class ColumnarAdapter {
    // MARK: - Properties

    /// The underlying columnar storage
    private let storage = ColumnarStorage(memoryMapped: true)

    /// View state for SwiftUI
    var prompts: [PromptViewModel] = []
    var isLoading = false
    var searchQuery = ""
    var selectedCategory: Category?
    var stats = StorageStats()

    /// Performance monitoring
    private let logger = Logger(subsystem: "com.promptbank.columnar", category: "Adapter")

    /// Diff tracking for efficient updates
    private var lastIndices: Set<Int32> = []

    // MARK: - Initialization

    init() {
        Task {
            await loadInitialData()
        }
    }

    // MARK: - Public Methods

    /// Load all prompts with efficient batching
    func loadInitialData() async {
        isLoading = true
        defer { isLoading = false }

        let startTime = mach_absolute_time()

        await withTaskGroup(of: [PromptViewModel].self) { _ in
            var viewModels: [PromptViewModel] = []

            // Process in batches for memory efficiency
            storage.iterate(batchSize: 100) { promptData in
                viewModels.append(PromptViewModel(from: promptData))

                // Yield periodically to keep UI responsive
                if viewModels.count % 100 == 0 {
                    Task { @MainActor in
                        self.prompts = viewModels
                    }
                }

                return true  // Continue iteration
            }

            self.prompts = viewModels
        }

        // Update stats
        stats = storage.aggregateStats()

        let elapsed = mach_absolute_time() - startTime
        logger.info("Loaded \(self.prompts.count) prompts in \(elapsed) ns")
    }

    /// Create a new prompt
    func createPrompt(title: String, content: String, category: Category) async {
        let id = UUID()
        let index = storage.insert(
            id: id,
            title: title,
            content: content,
            category: category
        )

        // Update UI with zero allocation
        if let promptData = storage.fetch(index: index) {
            let viewModel = PromptViewModel(from: promptData)
            prompts.insert(viewModel, at: 0)  // Most recent first
        }

        // Update stats
        stats = storage.aggregateStats()
    }

    /// Update existing prompt
    func updatePrompt(id: UUID, title: String? = nil, content: String? = nil) async {
        guard let index = findIndex(for: id) else { return }

        storage.update(index: index, title: title, content: content)

        // Update view model
        if let promptData = storage.fetch(index: index),
            let vmIndex = prompts.firstIndex(where: { $0.id == id }) {
            prompts[vmIndex] = PromptViewModel(from: promptData)
        }
    }

    /// Delete prompt
    func deletePrompt(id: UUID) async {
        guard let vmIndex = prompts.firstIndex(where: { $0.id == id }) else { return }

        prompts.remove(at: vmIndex)
        // Note: In production, would mark as deleted in storage rather than hard delete

        stats = storage.aggregateStats()
    }

    /// Search with real-time updates
    func search(query: String) async {
        searchQuery = query

        if query.isEmpty {
            await loadInitialData()
            return
        }

        let indices = storage.search(query: query)
        await updateView(with: Set(indices))
    }

    /// Filter by category
    func filterByCategory(_ category: Category?) async {
        selectedCategory = category

        guard let category = category else {
            await loadInitialData()
            return
        }

        let indices = storage.filterByCategory(category)
        await updateView(with: Set(indices))
    }

    /// Batch import item structure
    struct BatchImportItem {
        let title: String
        let content: String
        let category: Category
    }

    /// Batch import with progress tracking
    func batchImport(_ items: [BatchImportItem]) async {
        let batchSize = 100

        for batch in items.chunked(into: batchSize) {
            let prepared = batch.map { item in
                ColumnarStorage.BatchItem(
                    id: UUID(),
                    title: item.title,
                    content: item.content,
                    category: item.category
                )
            }
            storage.batchInsert(prepared)

            // Update UI progressively
            await loadInitialData()
        }
    }

    // MARK: - Private Methods

    private func findIndex(for id: UUID) -> Int32? {
        // In production, would maintain a proper index
        for index in 0..<prompts.count {
            if let data = storage.fetch(index: Int32(index)), data.id == id {
                return Int32(index)
            }
        }
        return nil
    }

    private func updateView(with indices: Set<Int32>) async {
        // Efficient diff calculation
        let added = indices.subtracting(lastIndices)
        let removed = lastIndices.subtracting(indices)

        var newViewModels = prompts

        // Remove deleted items
        if !removed.isEmpty {
            newViewModels.removeAll { vm in
                removed.contains { index in
                    storage.fetch(index: index)?.id == vm.id
                }
            }
        }

        // Add new items
        for index in added {
            if let data = storage.fetch(index: index) {
                newViewModels.append(PromptViewModel(from: data))
            }
        }

        // Sort by modified date
        newViewModels.sort { $0.modifiedAt > $1.modifiedAt }

        prompts = newViewModels
        lastIndices = indices
    }
}

// MARK: - View Model

struct PromptViewModel: Identifiable {
    let id: UUID
    let title: String
    let content: String
    let category: Category
    let createdAt: Date
    let modifiedAt: Date
    let isFavorite: Bool
    let tags: [String]
    let hasAIAnalysis: Bool

    init(from data: PromptData) {
        self.id = data.id
        self.title = data.title
        self.content = data.content
        self.category = data.category
        self.createdAt = data.createdAt
        self.modifiedAt = data.modifiedAt
        self.isFavorite = data.metadata.isFavorite
        self.tags = data.tags
        self.hasAIAnalysis = data.aiAnalysis != nil
    }
}

// MARK: - Mach Time Helpers

// Helper function to get nanoseconds from mach time
func machTimeToNanoseconds() -> UInt64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let machTime = Darwin.mach_absolute_time()  // Call the system function explicitly
    return machTime * UInt64(info.numer) / UInt64(info.denom)
}
