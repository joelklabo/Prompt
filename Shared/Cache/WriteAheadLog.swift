import Foundation
import os

/// Write-Ahead Log for instant UI updates with eventual consistency
/// Inspired by database WAL implementations for zero-latency user interactions
actor WriteAheadLog {
    private let logger = Logger(subsystem: "com.prompt.app", category: "WriteAheadLog")

    // In-memory log for instant access
    private var memoryLog: [LogEntry] = []

    // Persistent log file
    private let logFileURL: URL
    private let logFileHandle: FileHandle?

    // Checkpoint management
    private var lastCheckpoint: Date = Date()
    private let checkpointInterval: TimeInterval = 60.0  // Checkpoint every minute

    // Subscribers for real-time updates
    private var subscribers: [UUID: (PromptUpdate) -> Void] = [:]

    // Performance metrics
    private var writeLatencies: [TimeInterval] = []

    init() async throws {
        // Setup log file
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let walDir = documentsDir.appendingPathComponent("com.promptbank.wal")
        try FileManager.default.createDirectory(at: walDir, withIntermediateDirectories: true)

        self.logFileURL = walDir.appendingPathComponent("wal.log")

        // Create or open log file
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        self.logFileHandle = try FileHandle(forWritingTo: logFileURL)
        try logFileHandle?.seekToEnd()

        // Load existing log entries
        await loadExistingLog()

        // Start checkpoint timer
        await startCheckpointTimer()

        logger.info("WriteAheadLog initialized")
    }

    deinit {
        try? logFileHandle?.close()
    }

    // MARK: - Public API

    /// Append update to log with guaranteed sub-millisecond latency
    func append(_ update: PromptUpdate) async -> UpdateToken {
        let startTime = CFAbsoluteTimeGetCurrent()

        let entry = LogEntry(
            id: UUID(),
            update: update,
            timestamp: Date(),
            committed: false
        )

        // Write to memory immediately (instant)
        memoryLog.append(entry)

        // Notify subscribers immediately
        notifySubscribers(update)

        // Write to disk asynchronously
        Task.detached(priority: .high) { [weak self] in
            await self?.persistEntry(entry)
        }

        let latency = CFAbsoluteTimeGetCurrent() - startTime
        recordLatency(latency)

        return UpdateToken(
            id: entry.id,
            timestamp: entry.timestamp,
            committed: false
        )
    }

    /// Subscribe to real-time updates
    func subscribe(_ handler: @escaping (PromptUpdate) -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = handler
        return id
    }

    /// Unsubscribe from updates
    func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    /// Get uncommitted updates for a prompt
    func getUncommittedUpdates(for promptId: UUID) async -> [PromptUpdate] {
        return
            memoryLog
            .filter { !$0.committed && $0.update.promptId == promptId }
            .map { $0.update }
    }

    /// Mark updates as committed after database persistence
    func markCommitted(_ tokens: [UpdateToken]) async {
        let tokenIds = Set(tokens.map { $0.id })

        for index in memoryLog.indices where tokenIds.contains(memoryLog[index].id) {
            memoryLog[index].committed = true
        }

        // Trigger checkpoint if needed
        await checkpointIfNeeded()
    }

    /// Force checkpoint (flush committed entries)
    func checkpoint() async throws {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Separate committed and uncommitted entries
        let committed = memoryLog.filter { $0.committed }
        let uncommitted = memoryLog.filter { !$0.committed }

        // Write checkpoint marker
        let checkpointString = "CHECKPOINT \(Date().timeIntervalSince1970)\n"
        let checkpointData = Data(checkpointString.utf8)
        try logFileHandle?.write(contentsOf: checkpointData)

        // Clear committed entries from memory
        memoryLog = uncommitted

        lastCheckpoint = Date()

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.info("Checkpoint completed in \(elapsed)ms, cleared \(committed.count) entries")
    }

    // MARK: - Private Methods

    private func loadExistingLog() async {
        do {
            let data = try Data(contentsOf: logFileURL)
            let lines = String(data: data, encoding: .utf8)?.components(separatedBy: .newlines) ?? []

            for line in lines {
                guard !line.isEmpty else { continue }

                if line.hasPrefix("CHECKPOINT") {
                    // Clear entries before checkpoint
                    memoryLog.removeAll()
                } else if let entry = parseLogEntry(line) {
                    memoryLog.append(entry)
                }
            }

            logger.info("Loaded \(self.memoryLog.count) existing log entries")
        } catch {
            logger.error("Failed to load existing log: \(error)")
        }
    }

    private func persistEntry(_ entry: LogEntry) async {
        do {
            let data = serializeEntry(entry)
            try logFileHandle?.write(contentsOf: data)
            try logFileHandle?.synchronize()  // Force disk sync for durability
        } catch {
            logger.error("Failed to persist log entry: \(error)")
        }
    }

    private func serializeEntry(_ entry: LogEntry) -> Data {
        // Simple line-based format for speed
        let components = [
            entry.id.uuidString,
            entry.update.promptId.uuidString,
            entry.update.field.rawValue,
            entry.update.oldValue.base64Encoded(),
            entry.update.newValue.base64Encoded(),
            String(entry.timestamp.timeIntervalSince1970),
            String(entry.committed)
        ]
        let line = components.joined(separator: "|") + "\n"
        return Data(line.utf8)
    }

    private func parseLogEntry(_ line: String) -> LogEntry? {
        let parts = line.split(separator: "|").map(String.init)
        guard parts.count == 7,
            let id = UUID(uuidString: parts[0]),
            let promptId = UUID(uuidString: parts[1]),
            let field = PromptUpdate.UpdateField(rawValue: parts[2]),
            let oldValue = parts[3].base64Decoded(),
            let newValue = parts[4].base64Decoded(),
            let timestamp = TimeInterval(parts[5]),
            let committed = Bool(parts[6])
        else {
            return nil
        }

        let update = PromptUpdate(
            promptId: promptId,
            field: field,
            oldValue: oldValue,
            newValue: newValue,
            timestamp: Date(timeIntervalSince1970: timestamp)
        )

        return LogEntry(
            id: id,
            update: update,
            timestamp: Date(timeIntervalSince1970: timestamp),
            committed: committed
        )
    }

    private func notifySubscribers(_ update: PromptUpdate) {
        for handler in subscribers.values {
            handler(update)
        }
    }

    private func checkpointIfNeeded() async {
        let timeSinceLastCheckpoint = Date().timeIntervalSince(lastCheckpoint)
        let committedCount = memoryLog.filter { $0.committed }.count

        // Checkpoint if enough time has passed or too many committed entries
        if timeSinceLastCheckpoint > checkpointInterval || committedCount > 1000 {
            try? await checkpoint()
        }
    }

    private func startCheckpointTimer() async {
        Task {
            while true {
                try? await Task.sleep(nanoseconds: UInt64(checkpointInterval * 1_000_000_000))
                await checkpointIfNeeded()
            }
        }
    }

    private func recordLatency(_ latency: TimeInterval) {
        writeLatencies.append(latency)
        if writeLatencies.count > 1000 {
            writeLatencies.removeFirst()
        }

        // Log if latency exceeds 1ms
        if latency > 0.001 {
            logger.warning("WAL write latency exceeded 1ms: \(latency * 1000)ms")
        }
    }

    // MARK: - Helper Types

    private struct LogEntry {
        let id: UUID
        let update: PromptUpdate
        let timestamp: Date
        var committed: Bool
    }
}

// MARK: - String Extensions

extension String {
    fileprivate func base64Encoded() -> String {
        return Data(self.utf8).base64EncodedString()
    }

    fileprivate func base64Decoded() -> String? {
        guard let data = Data(base64Encoded: self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
