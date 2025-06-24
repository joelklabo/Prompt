import Foundation
import os
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@MainActor
@Observable
final class AppState {
    // Lightweight list items for fast UI
    var promptList: [PromptService.PromptListItem] = []
    var selectedPromptID: UUID?
    var selectedPromptDetail: PromptDetail?
    var viewState: ViewState = .idle
    var searchText = "" {
        didSet {
            if searchText != oldValue {
                Task { await updateFilteredResults() }
            }
        }
    }
    var selectedCategory: Category? {
        didSet {
            if selectedCategory != oldValue {
                Task { await updateFilteredResults() }
            }
        }
    }
    var navigationPath = NavigationPath()
    let progressState = ProgressState()

    // Cached filtered results
    private var filteredListCache: [PromptService.PromptListItem] = []
    private var cacheGeneration = 0

    // Pagination state
    var currentPage = 0
    let pageSize = 50
    var hasMorePrompts = true
    var isLoadingMore = false
    var totalPromptsCount = 0

    let promptService: PromptService
    private let tagService: TagService
    private let aiService: AIService
    private let logger = Logger(subsystem: "com.prompt.app", category: "AppState")

    var displayedPrompts: [PromptService.PromptListItem] {
        filteredListCache
    }

    var favoritePrompts: [PromptService.PromptListItem] {
        promptList.filter { $0.isFavorite }
    }

    var recentPrompts: [PromptService.PromptListItem] {
        Array(promptList.prefix(10))
    }

    init(promptService: PromptService, tagService: TagService, aiService: AIService) {
        self.promptService = promptService
        self.tagService = tagService
        self.aiService = aiService
    }

    func initialize() async {
        await loadPrompts()
    }

    func loadPrompts() async {
        let operationId = progressState.startOperation(.loading)
        viewState = .loading
        currentPage = 0
        hasMorePrompts = true

        do {
            // Get total count
            totalPromptsCount = try await promptService.fetchPromptsCount()

            // Load lightweight list items
            let items = try await promptService.fetchPromptList(offset: 0, limit: pageSize)
            promptList = items
            hasMorePrompts = items.count < totalPromptsCount

            // Update filtered results
            await updateFilteredResults()

            viewState = .loaded
            logger.info("Loaded \(items.count) of \(self.totalPromptsCount) prompts")
        } catch {
            viewState = .error(error)
            logger.error("Failed to load prompts: \(error)")
        }
        progressState.completeOperation(operationId)
    }

    func loadMorePrompts() async {
        guard hasMorePrompts && !isLoadingMore else { return }

        isLoadingMore = true
        let nextOffset = promptList.count

        do {
            let moreItems = try await promptService.fetchPromptList(offset: nextOffset, limit: pageSize)
            promptList.append(contentsOf: moreItems)
            hasMorePrompts = promptList.count < totalPromptsCount

            // Update filtered results
            await updateFilteredResults()

            logger.info("Loaded \(moreItems.count) more prompts, total: \(self.promptList.count)")
        } catch {
            logger.error("Failed to load more prompts: \(error)")
        }

        isLoadingMore = false
    }

    func refresh() async {
        logger.info("Refreshing prompts")
        await promptService.invalidateCache()
        await loadPrompts()
    }

    /// Update filtered results asynchronously
    private func updateFilteredResults() async {
        cacheGeneration += 1
        let generation = cacheGeneration

        // Capture values for concurrent filtering
        let currentList = promptList
        let currentSearch = searchText
        let currentCategory = selectedCategory

        // Perform filtering concurrently without detached task
        let filtered = await withTaskGroup(of: [PromptService.PromptListItem].self) { group in
            group.addTask {
                self.filterPrompts(currentList, searchText: currentSearch, category: currentCategory)
            }

            if let result = await group.next() {
                return result
            }
            return []
        }

        // Only update if this is still the latest request
        if generation == cacheGeneration {
            filteredListCache = filtered
        }
    }

    /// Filter prompts efficiently
    private nonisolated func filterPrompts(
        _ items: [PromptService.PromptListItem],
        searchText: String,
        category: Category?
    ) -> [PromptService.PromptListItem] {
        var filtered = items

        // Apply search filter
        if !searchText.isEmpty {
            let normalizedSearch = searchText.lowercased()
            filtered = filtered.filter { item in
                item.title.lowercased().contains(normalizedSearch)
                    || item.contentPreview.lowercased().contains(normalizedSearch)
            }
        }

        // Apply category filter
        if let category = category {
            filtered = filtered.filter { $0.category == category }
        }

        return filtered
    }

    func createPrompt(title: String, content: String, category: Category, tags: [String] = []) async {
        logger.info("Creating new prompt")
        let operationId = progressState.startOperation(.saving, message: "Creating new prompt...")
        do {
            // Get tag IDs
            var tagIDs: [UUID] = []
            for tagName in tags {
                let tagID = try await tagService.findOrCreateTag(name: tagName)
                tagIDs.append(tagID)
            }

            // Create request
            let request = PromptCreateRequest(
                title: title,
                content: content,
                category: category,
                tagIDs: tagIDs
            )

            let promptDetail = try await promptService.createPrompt(request)
            await loadPrompts()

            // Select the new prompt
            selectedPromptID = promptDetail.id
            selectedPromptDetail = promptDetail

            logger.info("Successfully created prompt: \(promptDetail.id)")
        } catch {
            logger.error("Failed to create prompt: \(error)")
            viewState = .error(error)
        }
        progressState.completeOperation(operationId)
    }

    func updatePrompt(id: UUID, title: String? = nil, content: String? = nil, category: Category? = nil) async {
        logger.info("Updating prompt: \(id)")
        let operationId = progressState.startOperation(.saving, message: "Updating prompt...")
        do {
            // Update each field that changed
            if let title = title {
                _ = try await promptService.updatePrompt(
                    id: id,
                    field: .title,
                    newValue: title
                )
            }
            if let content = content {
                _ = try await promptService.updatePrompt(
                    id: id,
                    field: .content,
                    newValue: content
                )
            }
            if let category = category {
                _ = try await promptService.updatePrompt(
                    id: id,
                    field: .category,
                    newValue: category.rawValue
                )
            }

            // Reload prompt detail if it's the selected one
            if selectedPromptID == id {
                selectedPromptDetail = try await promptService.getPromptDetail(id: id)
            }

            await loadPrompts()

            logger.info("Successfully updated prompt")
        } catch {
            logger.error("Failed to update prompt: \(error)")
            viewState = .error(error)
        }
        progressState.completeOperation(operationId)
    }

    func deletePrompt(id: UUID) async {
        logger.info("Deleting prompt: \(id)")
        let operationId = progressState.startOperation(.deleting)
        do {
            try await promptService.deletePrompt(id: id)
            if selectedPromptID == id {
                selectedPromptDetail = nil
                selectedPromptID = nil
            }
            await loadPrompts()
            logger.info("Successfully deleted prompt")
        } catch {
            logger.error("Failed to delete prompt: \(error)")
            viewState = .error(error)
        }
        progressState.completeOperation(operationId)
    }

    func toggleFavorite(for promptId: UUID) async {
        logger.info("Toggling favorite for prompt: \(promptId)")
        do {
            try await promptService.toggleFavoriteById(promptId)

            // Update local cache immediately for instant UI update
            if let index = promptList.firstIndex(where: { $0.id == promptId }) {
                let item = promptList[index]
                let newItem = PromptService.PromptListItem(
                    id: item.id,
                    title: item.title,
                    category: item.category,
                    modifiedAt: Date(),
                    isFavorite: !item.isFavorite,
                    tagCount: item.tagCount,
                    contentPreview: item.contentPreview
                )
                promptList[index] = newItem
                await updateFilteredResults()
            }
        } catch {
            logger.error("Failed to toggle favorite: \(error)")
        }
    }

    func deletePromptById(_ id: UUID) async {
        logger.info("Deleting prompt: \(id)")
        let operationId = progressState.startOperation(.deleting)
        do {
            try await promptService.deletePromptById(id)
            if selectedPromptID == id {
                selectedPromptDetail = nil
                selectedPromptID = nil
            }

            // Remove from local cache immediately
            promptList.removeAll { $0.id == id }
            await updateFilteredResults()

            logger.info("Successfully deleted prompt")
        } catch {
            logger.error("Failed to delete prompt: \(error)")
            viewState = .error(error)
        }
        progressState.completeOperation(operationId)
    }

    func analyzePrompt(id: UUID) async {
        logger.info("Analyzing prompt: \(id)")
        let operationId = progressState.startOperation(.analyzing, message: "Analyzing prompt with AI...")
        do {
            // Get the full prompt for analysis (AIService requires Prompt object)
            guard let detail = try await promptService.getPromptDetail(id: id) else {
                throw PromptError.notFound(id)
            }

            // Convert detail to prompt for AIService (which expects a Prompt object)
            // We need to fetch the actual prompt for analysis
            // For now, we'll update through the service directly
            try await promptService.analyzePrompt(id: id)

            await loadPrompts()

            // Update selected prompt detail if needed
            if selectedPromptID == id {
                selectedPromptDetail = try await promptService.getPromptDetail(id: id)
            }

            logger.info("AI analysis completed successfully")
        } catch {
            logger.error("Failed to analyze prompt: \(error)")
            viewState = .error(error)
        }
        progressState.completeOperation(operationId)
    }

}

// MARK: - UI Actions

extension AppState {
    func selectPrompt(_ promptId: UUID) async {
        selectedPromptID = promptId

        // Prefetch adjacent prompts for instant navigation
        await promptService.prefetchAdjacentPrompts(currentId: promptId)

        // Load full prompt details
        do {
            let promptDetail = try await promptService.getPromptDetail(id: promptId)
            selectedPromptDetail = promptDetail

            // Update metadata in background
            if promptDetail != nil {
                Task {
                    // Note: This would need a service method to update view count
                    // For now, the service should handle this internally
                }
            }
        } catch {
            logger.error("Failed to load prompt details: \(error)")
        }
    }

    func copyPromptContent(id: UUID) async {
        do {
            guard let promptDetail = try await promptService.getPromptDetail(id: id) else {
                logger.error("Prompt not found: \(id)")
                return
            }

            #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(promptDetail.content, forType: .string)
            #else
                UIPasteboard.general.string = promptDetail.content
            #endif

            // Note: Update copy count through service
            // This would need a service method like incrementCopyCount

            logger.info("Copied prompt content to clipboard")
        } catch {
            logger.error("Failed to copy prompt content: \(error)")
        }
    }
}

// MARK: - Import/Export

extension AppState {
    struct ImportedPromptData {
        let title: String
        let content: String
        let category: Category
        let tags: [String]
    }

    func importPromptFromFile(
        at url: URL
    ) async throws -> ImportedPromptData {
        logger.info("Importing prompt from file: \(url.lastPathComponent)")
        let operationId = progressState.startOperation(.importing, message: "Importing \(url.lastPathComponent)...")
        defer { progressState.completeOperation(operationId) }

        // Read file contents without blocking UI
        let fileContent = try String(contentsOf: url, encoding: .utf8)

        // Parse markdown
        let parsed = MarkdownParser.parse(fileContent)
        let filename = url.deletingPathExtension().lastPathComponent

        // Determine title
        let title = parsed.title ?? filename

        // Determine category
        let category = parsed.category ?? DragDropUtils.detectCategory(from: parsed.content)

        // Clean tags
        let tags = parsed.tags.filter { !$0.isEmpty }

        logger.info("Parsed prompt - Title: \(title), Category: \(category.rawValue), Tags: \(tags.count)")

        return ImportedPromptData(title: title, content: parsed.content, category: category, tags: tags)
    }
}

enum ViewState {
    case idle
    case loading
    case loaded
    case error(Error)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var error: Error? {
        if case .error(let error) = self { return error }
        return nil
    }
}
