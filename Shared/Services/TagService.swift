import Foundation
import os
import SwiftData

actor TagService {
    private let modelContainer: ModelContainer
    private let logger = Logger(subsystem: "com.prompt.app", category: "TagService")

    init(container: ModelContainer) {
        self.modelContainer = container
    }

    func fetchAllTags() async throws -> [Tag] {
        logger.info("Fetching all tags")
        return try await MainActor.run {
            let context = modelContainer.mainContext
            let descriptor = FetchDescriptor<Tag>(
                sortBy: [SortDescriptor(\.name)]
            )
            return try context.fetch(descriptor)
        }
    }

    func createTag(name: String, color: String? = nil) async throws -> Tag {
        logger.info("Creating tag: \(name, privacy: .public)")
        let tag = Tag(name: name, color: color ?? generateRandomColor())
        try await MainActor.run {
            let context = modelContainer.mainContext
            context.insert(tag)
            try context.save()
        }
        return tag
    }

    func findOrCreateTag(name: String) async throws -> Tag {
        logger.info("Finding or creating tag: \(name, privacy: .public)")

        let existingTag = try await MainActor.run {
            let context = modelContainer.mainContext
            let descriptor = FetchDescriptor<Tag>(
                predicate: #Predicate<Tag> { tag in
                    tag.name == name
                }
            )
            return try context.fetch(descriptor).first
        }

        if let existingTag {
            logger.info("Found existing tag")
            return existingTag
        } else {
            logger.info("Creating new tag")
            return try await createTag(name: name)
        }
    }

    func deleteTag(_ tag: Tag) async throws {
        logger.info("Deleting tag: \(tag.name, privacy: .public)")
        try await MainActor.run {
            let context = modelContainer.mainContext
            context.delete(tag)
            try context.save()
        }
    }

    func updateTag(_ tag: Tag, name: String? = nil, color: String? = nil) async throws {
        logger.info("Updating tag: \(tag.id)")
        if let name = name {
            tag.name = name
        }
        if let color = color {
            tag.color = color
        }
        try await MainActor.run {
            let context = modelContainer.mainContext
            try context.save()
        }
    }

    func getMostUsedTags(limit: Int = 10) async throws -> [Tag] {
        logger.info("Fetching most used tags (limit: \(limit))")
        let tags = try await fetchAllTags()
        return
            tags
            .sorted { $0.prompts.count > $1.prompts.count }
            .prefix(limit)
            .map { $0 }
    }

    private func generateRandomColor() -> String {
        let colors = [
            "#FF6B6B", "#4ECDC4", "#45B7D1", "#96CEB4", "#FECA57",
            "#48DBFB", "#FF9FF3", "#54A0FF", "#FD79A8", "#A29BFE",
            "#6C5CE7", "#00D2D3", "#FFA502", "#FF6348", "#12CBC4"
        ]
        return colors.randomElement() ?? "#007AFF"
    }
}
