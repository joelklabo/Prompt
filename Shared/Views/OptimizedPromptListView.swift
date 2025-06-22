import os.log
import SwiftUI

#if os(iOS)
    import UIKit
#endif

// MARK: - PromptFilter
enum PromptFilter: Hashable {
    case all
    case category(Category)
    case favorite
    case recent
}

/// High-performance prompt list view using DTOs
struct OptimizedPromptListView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: ViewModel

    init(optimizedService: OptimizedPromptService) {
        self._viewModel = State(initialValue: ViewModel(service: optimizedService))
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(viewModel.summaries) { summary in
                    OptimizedPromptRow(
                        summary: summary,
                        isSelected: viewModel.selectedID == summary.id
                    )
                    .onTapGesture {
                        viewModel.selectPrompt(summary.id)
                    }
                    .onAppear {
                        viewModel.onRowAppear(summary)
                    }
                    .id(summary.id)
                }

                // Load more indicator
                if viewModel.hasMore {
                    LoadMoreView()
                        .onAppear {
                            Task {
                                await viewModel.loadMore()
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: viewModel.scrollToID) { _, newID in
                if let id = newID {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .searchable(text: $viewModel.searchQuery)
        .task {
            await viewModel.loadInitialData()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }
}

/// Optimized row view with minimal overhead
struct OptimizedPromptRow: View {
    let summary: PromptSummary
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(summary.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                if summary.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                        .font(.caption)
                }
            }

            Text(summary.contentPreview)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)

            HStack {
                Label(summary.category.rawValue, systemImage: summary.category.icon)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !summary.tagNames.isEmpty {
                    Text("• \(summary.tagDisplay)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(summary.displayDate)
                    .font(.caption2)
                    .foregroundColor(Color.secondary)
            }
        }
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
    }
}

/// Load more indicator
struct LoadMoreView: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
            Spacer()
        }
        .padding()
    }
}

/// View model using @Observable for efficient updates
@Observable
@MainActor
final class ViewModel {
    private let logger = Logger(subsystem: "com.prompt.app", category: "OptimizedListView")
    private let service: OptimizedPromptService

    // UI State
    var summaries: [PromptSummary] = []
    var selectedID: UUID?
    var searchQuery = ""
    var isLoading = false
    var hasMore = true
    var scrollToID: UUID?

    // Pagination
    private var currentCursor: PaginationCursor?
    private var currentFilter: PromptFilter?

    // Prefetching
    private let prefetchDistance = 10
    private var prefetchTask: Task<Void, Never>?

    init(service: OptimizedPromptService) {
        self.service = service
    }

    func loadInitialData() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let batch = try await service.fetchPromptSummaries(
                category: nil,
                searchQuery: searchQuery.isEmpty ? nil : searchQuery,
                limit: 50
            )

            await MainActor.run {
                self.summaries = batch.summaries
                self.currentCursor = batch.cursor
                self.hasMore = batch.cursor != nil
            }

            logger.info("Loaded \(batch.summaries.count) summaries")
        } catch {
            logger.error("Failed to load summaries: \(error)")
        }
    }

    func loadMore() async {
        guard !isLoading, hasMore, let cursor = currentCursor else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let batch = try await service.fetchPromptSummaries(
                category: nil,
                searchQuery: searchQuery.isEmpty ? nil : searchQuery,
                limit: 50,
                cursor: cursor
            )

            await MainActor.run {
                self.summaries.append(contentsOf: batch.summaries)
                self.currentCursor = batch.cursor
                self.hasMore = batch.cursor != nil
            }

            logger.info("Loaded \(batch.summaries.count) more summaries")
        } catch {
            logger.error("Failed to load more: \(error)")
        }
    }

    func refresh() async {
        currentCursor = nil
        await loadInitialData()
    }

    func selectPrompt(_ id: UUID) {
        selectedID = id

        // Prefetch detail
        Task {
            _ = try? await service.fetchPromptDetail(id: id)
        }
    }

    func onRowAppear(_ summary: PromptSummary) {
        // Prefetch nearby details
        guard let index = summaries.firstIndex(where: { $0.id == summary.id }) else {
            return
        }

        let startIndex = max(0, index - prefetchDistance)
        let endIndex = min(summaries.count - 1, index + prefetchDistance)

        let idsToPrefetech = summaries[startIndex...endIndex].map(\.id)

        // Cancel previous prefetch
        prefetchTask?.cancel()

        // Start new prefetch
        prefetchTask = Task {
            await service.prefetchDetails(ids: Array(idsToPrefetech))
        }
    }

    // Search handling with debouncing
    func performSearch() {
        // Implement search with debouncing
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms debounce

            // For now, we'll just use search query in the fetch method
            // currentFilter would be used for category/favorite filtering

            await loadInitialData()
        }
    }
}

// MARK: - Performance Monitoring Extension

extension OptimizedPromptListView {
    /// Monitor scrolling performance
    func measureScrollPerformance() -> some View {
        #if os(iOS)
            self.onReceive(
                NotificationCenter.default.publisher(for: .init("UIScrollViewDidEndDeceleratingNotification"))
            ) { _ in
                let logger = Logger(subsystem: "com.prompt.app", category: "Performance")
                logger.info("Scroll deceleration completed")
            }
        #else
            self
        #endif
    }
}
