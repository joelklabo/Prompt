import Foundation
import os
import SwiftData

// MARK: - Tag Operations
extension PromptService {
    // Use tag IDs instead of direct models
    func addTag(tagId: UUID, to promptId: UUID) async throws {
        logger.info("Adding tag \(tagId) to prompt \(promptId)")

        guard let prompt = try await fetchPromptInternal(id: promptId) else {
            throw PromptError.notFound(promptId)
        }

        let descriptor = FetchDescriptor<Tag>(
            predicate: #Predicate { $0.id == tagId }
        )
        guard let tag = try modelContext.fetch(descriptor).first else {
            throw PromptError.tagNotFound(tagId)
        }

        prompt.tags.append(tag)
        prompt.modifiedAt = Date()

        try modelContext.save()

        // Invalidate cache
        cacheTimestamp = nil
    }

    func addTagInternal(_ tag: Tag, to prompt: Prompt) async throws {
        logger.info("Adding tag \(tag.name, privacy: .public) to prompt \(prompt.id)")
        prompt.tags.append(tag)
        prompt.modifiedAt = Date()

        let context = ModelContext(modelContainer)
        try context.save()

        // Invalidate cache
        cacheTimestamp = nil
    }

    // Use tag IDs instead of direct models
    func removeTag(tagId: UUID, from promptId: UUID) async throws {
        logger.info("Removing tag \(tagId) from prompt \(promptId)")

        guard let prompt = try await fetchPromptInternal(id: promptId) else {
            throw PromptError.notFound(promptId)
        }

        prompt.tags.removeAll { $0.id == tagId }
        prompt.modifiedAt = Date()

        try modelContext.save()

        // Invalidate cache
        cacheTimestamp = nil
    }

    func removeTagInternal(_ tag: Tag, from prompt: Prompt) async throws {
        logger.info("Removing tag \(tag.name, privacy: .public) from prompt \(prompt.id)")
        prompt.tags.removeAll { $0.id == tag.id }
        prompt.modifiedAt = Date()

        let context = ModelContext(modelContainer)
        try context.save()

        // Invalidate cache
        cacheTimestamp = nil
    }
}
