import Foundation
import os
import SwiftData

// Data store actor for thread-safe operations
actor DataStore: ModelActor {
    let modelContainer: ModelContainer
    let modelExecutor: any ModelExecutor
    private let logger = Logger(subsystem: "com.prompt.app", category: "DataStore")

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        let context = ModelContext(modelContainer)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }

    func insert<T: PersistentModel>(_ model: T) async throws {
        logger.info("Inserting model of type \(String(describing: T.self))")
        modelContext.insert(model)
        try modelContext.save()
    }

    func delete<T: PersistentModel>(_ model: T) async throws {
        logger.info("Deleting model of type \(String(describing: T.self))")
        modelContext.delete(model)
        try modelContext.save()
    }

    func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) async throws -> [T] {
        logger.info("Fetching models of type \(String(describing: T.self))")
        return try modelContext.fetch(descriptor)
    }

    func count<T: PersistentModel>(for descriptor: FetchDescriptor<T>) async throws -> Int {
        logger.info("Counting models of type \(String(describing: T.self))")
        return try modelContext.fetchCount(descriptor)
    }

    func save() async throws {
        logger.info("Saving context changes")
        try modelContext.save()
    }

    func transaction<T>(_ operation: @escaping (ModelContext) throws -> T) async throws -> T {
        logger.info("Executing transaction")
        return try operation(modelContext)
    }
}
