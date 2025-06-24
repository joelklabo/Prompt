import Foundation
import os
import SwiftData

actor TagService: ModelActor {
    let modelContainer: ModelContainer
    let modelExecutor: any ModelExecutor
    private let logger = Logger(subsystem: "com.prompt.app", category: "TagService")

    init(container: ModelContainer) {
        self.modelContainer = container
        let context = ModelContext(container)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }

    private func fetchTag(id: UUID) throws -> Tag? {
        let descriptor = FetchDescriptor<Tag>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first
    }

    func fetchAllTags() async throws -> [Tag] {
        logger.info("Fetching all tags")
        let context = modelContext
        let descriptor = FetchDescriptor<Tag>(
            sortBy: [SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor)
    }

    func fetchAllTagSummaries() async throws -> [TagSummary] {
        logger.info("Fetching all tag summaries")
        let tags = try await fetchAllTags()
        return tags.map { $0.toSummary() }
    }

    func getTagDetail(id: UUID) async throws -> TagDetail? {
        logger.info("Fetching tag detail for id: \(id)")
        guard let tag = try fetchTag(id: id) else { return nil }
        return tag.toDetail()
    }

    func createTag(name: String, color: String? = nil) async throws -> Tag {
        logger.info("Creating tag: \(name, privacy: .public)")
        let tag = Tag(name: name, color: color ?? generateRandomColor())
        let context = modelContext
        context.insert(tag)
        try context.save()
        return tag
    }

    func createTag(_ request: TagCreateRequest) async throws -> TagDetail {
        logger.info("Creating tag from request: \(request.name, privacy: .public)")
        guard request.isValid else {
            throw TagError.invalidRequest
        }
        let tag = Tag(name: request.name, color: request.color)
        let context = modelContext
        context.insert(tag)
        try context.save()
        return tag.toDetail()
    }

    func findOrCreateTag(name: String) async throws -> UUID {
        logger.info("Finding or creating tag: \(name, privacy: .public)")

        let context = modelContext
        let descriptor = FetchDescriptor<Tag>(
            predicate: #Predicate<Tag> { tag in
                tag.name == name
            }
        )
        let existingTag = try context.fetch(descriptor).first

        if let existingTag {
            logger.info("Found existing tag")
            return existingTag.id
        } else {
            logger.info("Creating new tag")
            let newTag = try await createTag(name: name)
            return newTag.id
        }
    }

    func deleteTag(_ tag: Tag) async throws {
        logger.info("Deleting tag: \(tag.name, privacy: .public)")
        let context = modelContext
        context.delete(tag)
        try context.save()
    }

    func deleteTag(id: UUID) async throws {
        logger.info("Deleting tag with id: \(id)")
        guard let tag = try fetchTag(id: id) else {
            throw TagError.notFound(id)
        }
        let context = modelContext
        context.delete(tag)
        try context.save()
    }

    func updateTag(_ tag: Tag, name: String? = nil, color: String? = nil) async throws {
        logger.info("Updating tag: \(tag.id)")
        if let name = name {
            tag.name = name
        }
        if let color = color {
            tag.color = color
        }
        let context = modelContext
        try context.save()
    }

    func updateTag(id: UUID, name: String? = nil, color: String? = nil) async throws -> TagSummary {
        logger.info("Updating tag with id: \(id)")
        guard let tag = try fetchTag(id: id) else {
            throw TagError.notFound(id)
        }
        if let name = name {
            tag.name = name
        }
        if let color = color {
            tag.color = color
        }
        let context = modelContext
        try context.save()
        return tag.toSummary()
    }

    func updateTag(_ request: TagUpdateRequest) async throws -> TagSummary {
        logger.info("Updating tag from request for id: \(request.id)")
        guard request.isValid else {
            throw TagError.invalidRequest
        }
        return try await updateTag(id: request.id, name: request.name, color: request.color)
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

    func getMostUsedTagSummaries(limit: Int = 10) async throws -> [TagSummary] {
        logger.info("Fetching most used tag summaries (limit: \(limit))")
        let tags = try await getMostUsedTags(limit: limit)
        return tags.map { $0.toSummary() }
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
