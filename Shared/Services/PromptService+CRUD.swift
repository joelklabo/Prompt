import Foundation
import os
import SwiftData

// MARK: - CRUD Operations
extension PromptService {
    func savePrompt(_ prompt: Prompt) async throws {
        logger.info("Saving prompt: \(prompt.title, privacy: .public)")

        // Pre-render markdown content in background
        await preRenderMarkdown(for: prompt)

        // Use background context
        let context = ModelContext(modelContainer)
        context.insert(prompt)
        try context.save()

        // Invalidate cache
        cacheTimestamp = nil
    }

    func updatePrompt(id: UUID, field: PromptUpdateRequest.UpdateField, newValue: String) async throws -> PromptSummary {
        logger.info("Updating prompt \(id) field \(field.rawValue)")

        guard let prompt = try await fetchPromptInternal(id: id) else {
            throw PromptError.notFound(id)
        }

        switch field {
        case .title:
            prompt.title = newValue
        case .content:
            // If using hybrid storage, update external content
            if contentStore != nil, prompt.storageType == .external {  // TODO: cast to HybridContentStore
                // TODO: Enable when HybridContentStore is in project
                // let reference = try await contentStore.store(newValue)
                // prompt.contentHash = reference.hash
                prompt.contentHash = UUID().uuidString  // TODO: Use actual hash
                prompt.contentSize = newValue.utf8.count
                prompt.contentPreview = String(newValue.prefix(200))
                prompt._cachedContent = newValue
                // Keep content empty in SwiftData for external storage
                prompt.content = ""
            } else {
                // Traditional storage
                prompt.content = newValue
                prompt.contentSize = newValue.utf8.count
                prompt.contentPreview = String(newValue.prefix(200))
            }
            await preRenderMarkdown(for: prompt)
        case .category:
            guard let category = Category(rawValue: newValue) else {
                throw PromptError.invalidCategory(newValue)
            }
            prompt.category = category
        }

        prompt.modifiedAt = Date()
        try modelContext.save()

        // Invalidate cache
        cacheTimestamp = nil

        return prompt.toSummary()
    }

    func updatePrompt(_ request: PromptUpdateRequest) async throws -> PromptSummary {
        logger.info("Updating prompt from request for id: \(request.id)")
        guard request.isValid else {
            throw PromptError.invalidRequest
        }
        return try await updatePrompt(id: request.id, field: request.field, newValue: request.value)
    }

    func deletePrompt(id: UUID) async throws {
        logger.info("Deleting prompt with id: \(id)")
        guard let prompt = try await fetchPromptInternal(id: id) else {
            throw PromptError.notFound(id)
        }
        modelContext.delete(prompt)
        try modelContext.save()

        // Invalidate cache
        cacheTimestamp = nil
    }

    func deletePromptById(_ id: UUID) async throws {
        logger.info("Deleting prompt by id: \(id)")

        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Prompt>(
            predicate: #Predicate<Prompt> { prompt in
                prompt.id == id
            }
        )

        if let prompt = try context.fetch(descriptor).first {
            context.delete(prompt)
            try context.save()

            // Invalidate cache
            cacheTimestamp = nil
        }
    }

    func deletePrompts(_ request: PromptBatchDeleteRequest) async throws {
        logger.info("Deleting \(request.promptIDs.count) prompts")
        guard request.isValid else {
            throw PromptError.invalidRequest
        }

        for id in request.promptIDs {
            if let prompt = try await fetchPromptInternal(id: id) {
                modelContext.delete(prompt)
            }
        }

        try modelContext.save()

        // Invalidate cache
        cacheTimestamp = nil
    }

    func toggleFavoriteById(_ id: UUID) async throws {
        guard let prompt = try await fetchPromptInternal(id: id) else { return }
        try await toggleFavoriteInternal(for: prompt)
    }

    func incrementCopyCount(id: UUID) async throws {
        logger.info("Incrementing copy count for prompt: \(id)")

        guard let prompt = try await fetchPromptInternal(id: id) else {
            logger.error("Prompt not found: \(id)")
            throw PromptError.notFound(id)
        }

        prompt.metadata.copyCount += 1
        prompt.modifiedAt = Date()

        try modelContext.save()

        // Invalidate cache
        cacheTimestamp = nil
        logger.info("Copy count incremented for prompt: \(id)")
    }

    // Internal helpers
    func updatePromptInternal(_ prompt: Prompt) async throws {
        logger.info("Updating prompt: \(prompt.id)")
        prompt.modifiedAt = Date()

        // Pre-render markdown content if content changed
        await preRenderMarkdown(for: prompt)

        let context = ModelContext(modelContainer)
        try context.save()

        // Invalidate cache
        cacheTimestamp = nil
    }

    func deletePromptInternal(_ prompt: Prompt) async throws {
        logger.info("Deleting prompt: \(prompt.id)")

        let context = ModelContext(modelContainer)
        context.delete(prompt)
        try context.save()

        // Invalidate cache
        cacheTimestamp = nil
    }

    func toggleFavoriteInternal(for prompt: Prompt) async throws {
        logger.info("Toggling favorite for prompt \(prompt.id)")
        prompt.metadata.isFavorite.toggle()
        prompt.modifiedAt = Date()

        let context = ModelContext(modelContainer)
        try context.save()

        // Invalidate cache
        cacheTimestamp = nil
    }
}
