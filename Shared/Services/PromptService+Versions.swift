import Foundation
import os
import SwiftData

// MARK: - Version Management
extension PromptService {
    func getPromptVersionSummaries(promptID: UUID) async throws -> [PromptVersionSummary] {
        logger.info("Fetching version summaries for prompt: \(promptID)")

        guard let prompt = try await fetchPromptInternal(id: promptID) else {
            logger.error("Prompt not found: \(promptID)")
            throw PromptError.notFound(promptID)
        }

        // Ensure versions are loaded
        _ = prompt.versions

        // Convert to summaries and sort by version number descending
        let summaries = prompt.versions
            .map { $0.toSummary() }
            .sorted { $0.versionNumber > $1.versionNumber }

        logger.info("Found \(summaries.count) versions for prompt: \(promptID)")
        return summaries
    }

    func createVersionInternal(for prompt: Prompt, changeDescription: String? = nil) async throws {
        logger.info("Creating version for prompt \(prompt.id)")
        let versionNumber = prompt.versions.count + 1
        let version = PromptVersion(
            versionNumber: versionNumber,
            title: prompt.title,
            content: prompt.content,
            changeDescription: changeDescription
        )
        prompt.versions.append(version)

        let context = ModelContext(modelContainer)
        try context.save()
    }

    func createVersion(promptID: UUID, changeDescription: String? = nil) async throws {
        logger.info("Creating version for prompt ID: \(promptID)")

        guard let prompt = try await fetchPromptInternal(id: promptID) else {
            logger.error("Prompt not found: \(promptID)")
            throw PromptError.notFound(promptID)
        }

        let versionNumber = prompt.versions.count + 1
        let version = PromptVersion(
            versionNumber: versionNumber,
            title: prompt.title,
            content: prompt.content,
            changeDescription: changeDescription
        )
        prompt.versions.append(version)
        prompt.modifiedAt = Date()

        try modelContext.save()

        // Invalidate cache
        cacheTimestamp = nil
        logger.info("Created version \(versionNumber) for prompt: \(promptID)")
    }
}
