import Foundation
import os

/// Sophisticated background task processor with priority queues and adaptive scheduling
/// Inspired by game engine job systems for maximum CPU utilization
final class BackgroundProcessor: Sendable {
    private let logger = Logger(subsystem: "com.prompt.app", category: "BackgroundProcessor")

    // Priority queues for different task types
    private let highPriorityQueue = DispatchQueue(
        label: "com.prompt.high", qos: .userInteractive, attributes: .concurrent)
    private let mediumPriorityQueue = DispatchQueue(
        label: "com.prompt.medium", qos: .userInitiated, attributes: .concurrent)
    private let lowPriorityQueue = DispatchQueue(label: "com.prompt.low", qos: .background, attributes: .concurrent)

    // Task tracking
    private let taskTracker = TaskTracker()

    // CPU monitoring for adaptive scheduling
    private let cpuMonitor = CPUMonitor()

    // Render task batching
    private let renderBatcher = RenderBatcher()

    init() {
        logger.info("BackgroundProcessor initialized with \(ProcessInfo.processInfo.processorCount) CPU cores")
    }

    // MARK: - Public API

    /// Queue a render task with automatic batching
    func queueRenderTask(content: String, completion: @escaping @Sendable (RenderedContent) async -> Void) async {
        await renderBatcher.addTask(content: content, completion: completion)
    }

    /// Start a named background task with priority
    func startTask(name: String, priority: Priority, task: @escaping @Sendable () async -> Void) async {
        let taskId = UUID()
        await taskTracker.register(taskId: taskId, name: name)

        let queue = selectQueue(for: priority)

        queue.async { [weak self] in
            Task {
                let startTime = CFAbsoluteTimeGetCurrent()

                await task()

                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                await self?.taskTracker.complete(taskId: taskId, duration: elapsed)

                self?.logger.debug("Task '\(name)' completed in \(elapsed)ms")
            }
        }
    }

    /// Execute tasks with CPU-aware scheduling
    func executeWithCPUAwareness<T: Sendable>(_ tasks: [@Sendable () async -> T]) async -> [T] {
        let cpuLoad = await cpuMonitor.getCurrentLoad()
        let concurrency = determineConcurrency(cpuLoad: cpuLoad)

        return await withTaskGroup(of: T.self) { group in
            // Limit concurrent tasks based on CPU load
            let semaphore = AsyncSemaphore(limit: concurrency)

            for task in tasks {
                group.addTask {
                    await semaphore.wait()
                    let result = await task()
                    await semaphore.signal()
                    return result
                }
            }

            var results: [T] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    /// Get current system load metrics
    func getSystemMetrics() async -> SystemMetrics {
        return SystemMetrics(
            cpuLoad: await cpuMonitor.getCurrentLoad(),
            activeTasks: await taskTracker.activeCount(),
            queuedTasks: await renderBatcher.queuedCount()
        )
    }

    // MARK: - Private Methods

    private func selectQueue(for priority: Priority) -> DispatchQueue {
        switch priority {
        case .high:
            return highPriorityQueue
        case .medium:
            return mediumPriorityQueue
        case .low:
            return lowPriorityQueue
        }
    }

    private func determineConcurrency(cpuLoad: Double) -> Int {
        let coreCount = ProcessInfo.processInfo.processorCount

        // Adaptive concurrency based on CPU load
        switch cpuLoad {
        case 0..<0.3:
            return coreCount * 2  // Low load, use hyperthreading
        case 0.3..<0.7:
            return coreCount  // Medium load, one task per core
        case 0.7..<0.9:
            return max(coreCount / 2, 1)  // High load, reduce concurrency
        default:
            return max(coreCount / 4, 1)  // Very high load, minimal concurrency
        }
    }

    // MARK: - Task Priority

    enum Priority {
        case high  // User-visible operations
        case medium  // Pre-computation
        case low  // Background maintenance
    }

    // MARK: - System Metrics

    struct SystemMetrics: Sendable {
        let cpuLoad: Double
        let activeTasks: Int
        let queuedTasks: Int
    }
}

// MARK: - Task Tracker

private actor TaskTracker {
    private var activeTasks: [UUID: TaskInfo] = [:]
    private var completedTasks: [CompletedTask] = []

    struct TaskInfo {
        let name: String
        let startTime: Date
    }

    struct CompletedTask {
        let name: String
        let duration: Double
        let completedAt: Date
    }

    func register(taskId: UUID, name: String) {
        activeTasks[taskId] = TaskInfo(name: name, startTime: Date())
    }

    func complete(taskId: UUID, duration: Double) {
        guard let info = activeTasks.removeValue(forKey: taskId) else { return }

        let completed = CompletedTask(
            name: info.name,
            duration: duration,
            completedAt: Date()
        )

        completedTasks.append(completed)

        // Keep only recent history
        if completedTasks.count > 1000 {
            completedTasks.removeFirst()
        }
    }

    func activeCount() -> Int {
        return activeTasks.count
    }

    func averageCompletionTime() -> Double {
        guard !completedTasks.isEmpty else { return 0 }
        let total = completedTasks.reduce(0) { $0 + $1.duration }
        return total / Double(completedTasks.count)
    }
}

// MARK: - CPU Monitor

private actor CPUMonitor {
    private var lastSample: CPUSample?

    struct CPUSample {
        let user: Double
        let system: Double
        let idle: Double
        let timestamp: Date
    }

    func getCurrentLoad() -> Double {
        // Get current CPU usage
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0.5 }  // Default to medium load

        // Calculate CPU percentage (simplified)
        let total = info.user_time.totalSeconds + info.system_time.totalSeconds
        return min(total / ProcessInfo.processInfo.systemUptime, 1.0)
    }
}

// MARK: - Render Batcher

private actor RenderBatcher {
    private var pendingTasks: [(content: String, completion: @Sendable (RenderedContent) async -> Void)] = []
    private var batchTimer: Task<Void, Never>?

    private let batchSize = 50
    private let batchDelay: TimeInterval = 0.1  // 100ms

    func addTask(content: String, completion: @escaping @Sendable (RenderedContent) async -> Void) {
        pendingTasks.append((content, completion))

        // Start batch timer if not running
        if batchTimer == nil {
            batchTimer = Task {
                try? await Task.sleep(nanoseconds: UInt64(batchDelay * 1_000_000_000))
                await processBatch()
            }
        }

        // Process immediately if batch is full
        if pendingTasks.count >= batchSize {
            Task {
                await processBatch()
            }
        }
    }

    func queuedCount() -> Int {
        return pendingTasks.count
    }

    private func processBatch() async {
        guard !pendingTasks.isEmpty else { return }

        let batch = pendingTasks
        pendingTasks.removeAll()
        batchTimer = nil

        // Process batch in parallel
        await withTaskGroup(of: Void.self) { group in
            for (content, completion) in batch {
                group.addTask { @Sendable in
                    let rendered = await self.renderContent(content)
                    await completion(rendered)
                }
            }
        }
    }

    private func renderContent(_ content: String) async -> RenderedContent {
        // Simulate rendering (would use actual markdown renderer)
        do {
            let attributed = try AttributedString(
                markdown: content,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )

            return RenderedContent(
                attributedString: attributed,
                renderTime: 0.01,
                isPlaceholder: false
            )
        } catch {
            // Return plain text on error
            return RenderedContent(
                attributedString: AttributedString(content),
                renderTime: 0,
                isPlaceholder: true
            )
        }
    }
}

// MARK: - Async Semaphore

private actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.count = limit
    }

    func wait() async {
        if count > 0 {
            count -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            count += 1
        }
    }
}

// MARK: - Time Extensions

extension time_value_t {
    fileprivate var totalSeconds: Double {
        return Double(self.seconds) + Double(self.microseconds) / 1_000_000
    }
}
