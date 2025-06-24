import Foundation
import os.log

#if canImport(SwiftUI)
    import SwiftUI
#endif

/// Simple performance monitoring utility
@MainActor
class PerformanceMonitor: ObservableObject {
    private let logger = Logger(subsystem: "com.prompt.app", category: "Performance")

    @Published var listLoadTime: TimeInterval = 0
    @Published var searchTime: TimeInterval = 0
    @Published var detailLoadTime: TimeInterval = 0
    @Published var memoryUsage: String = "0 MB"

    private var startTime: CFAbsoluteTime = 0

    func startMeasuring() {
        startTime = CFAbsoluteTimeGetCurrent()
    }

    func endMeasuring(for operation: String) -> TimeInterval {
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000  // Convert to ms
        logger.info("\(operation) completed in \(elapsed)ms")

        switch operation {
        case "list_load":
            listLoadTime = elapsed
        case "search":
            searchTime = elapsed
        case "detail_load":
            detailLoadTime = elapsed
        default:
            break
        }

        return elapsed
    }

    func updateMemoryUsage() {
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

        if result == KERN_SUCCESS {
            let usedMemory = Double(info.resident_size) / 1024.0 / 1024.0
            memoryUsage = String(format: "%.1f MB", usedMemory)
        }
    }

    func generateTestData(count: Int, promptService: PromptService) async {
        logger.info("Generating \(count) test prompts")

        let categories = Category.allCases
        let contentSizes = [100, 500, 1000, 5000, 10000]  // Various content lengths

        for index in 0..<count {
            let contentLength = contentSizes.randomElement() ?? 1000
            let content = generateLongContent(length: contentLength)

            let request = PromptCreateRequest(
                title: "Test Prompt #\(index + 1)",
                content: content,
                category: categories.randomElement() ?? .prompts,
                tagIDs: []
            )

            do {
                _ = try await promptService.createPrompt(request)

                if (index + 1) % 100 == 0 {
                    logger.info("Created \(index + 1) test prompts")
                }
            } catch {
                logger.error("Failed to create test prompt: \(error)")
            }
        }

        logger.info("Finished generating \(count) test prompts")
    }

    private func generateLongContent(length: Int) -> String {
        let loremIpsum = """
            Lorem ipsum dolor sit amet, consectetur adipiscing elit.
            Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.
            Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.
            Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.
            Excepteur sint occaecat cupidatat non proident,
            sunt in culpa qui officia deserunt mollit anim id est laborum.

            """

        var content = ""
        while content.count < length {
            content += loremIpsum
        }

        return String(content.prefix(length))
    }
}

#if canImport(SwiftUI)
    /// Performance stats view for development
    struct PerformanceStatsView: View {
        @StateObject private var monitor = PerformanceMonitor()
        @Environment(\.dismiss) var dismiss

        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("Performance Metrics")
                    .font(.title2)
                    .bold()

                GroupBox("Load Times") {
                    VStack(alignment: .leading, spacing: 12) {
                        MetricRow(label: "List Load", value: "\(Int(monitor.listLoadTime))ms", target: "<16ms")
                        MetricRow(label: "Search", value: "\(Int(monitor.searchTime))ms", target: "<50ms")
                        MetricRow(label: "Detail Load", value: "\(Int(monitor.detailLoadTime))ms", target: "<100ms")
                    }
                }

                GroupBox("Memory") {
                    HStack {
                        Text("Current Usage")
                        Spacer()
                        Text(monitor.memoryUsage)
                            .monospacedDigit()
                    }
                }

                HStack {
                    Button("Refresh") {
                        monitor.updateMemoryUsage()
                    }

                    Spacer()

                    Button("Close") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 400, height: 300)
            .onAppear {
                monitor.updateMemoryUsage()
            }
        }
    }

    struct MetricRow: View {
        let label: String
        let value: String
        let target: String

        var body: some View {
            HStack {
                Text(label)
                Spacer()
                Text(value)
                    .monospacedDigit()
                    .foregroundColor(meetsTarget ? .green : .orange)
                Text("(target: \(target))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }

        private var meetsTarget: Bool {
            guard let numericValue = Int(value.replacingOccurrences(of: "ms", with: "")),
                let numericTarget = Int(
                    target.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: "ms", with: ""))
            else {
                return true
            }
            return numericValue < numericTarget
        }
    }
#endif
