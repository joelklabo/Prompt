import SwiftUI

struct IOSContentView: View {
    let appState: AppState
    @Binding var showingCreatePrompt: Bool

    var body: some View {
        NavigationStack(
            path: Binding(
                get: { appState.navigationPath },
                set: { appState.navigationPath = $0 }
            )
        ) {
            PromptListView(
                promptSummaries: appState.displayedPrompts.map { item in
                    // Convert lightweight items to PromptSummary
                    PromptSummary(
                        id: item.id,
                        title: item.title,
                        contentPreview: item.contentPreview,
                        category: item.category,
                        tagNames: [],
                        createdAt: item.modifiedAt,  // Using modifiedAt as createdAt is not available
                        modifiedAt: item.modifiedAt,
                        isFavorite: item.isFavorite,
                        viewCount: 0,
                        copyCount: 0,
                        categoryConfidence: nil,
                        shortLink: nil
                    )
                },
                selectedPromptID: .constant(nil),
                onDelete: { promptID in
                    await appState.deletePromptById(promptID)
                },
                onToggleFavorite: { promptID in
                    await appState.toggleFavorite(for: promptID)
                },
                onLoadMore: {
                    await appState.loadMorePrompts()
                },
                hasMore: appState.hasMorePrompts,
                isLoadingMore: appState.isLoadingMore
            )
            .navigationTitle("Prompts")
            .navigationDestination(for: UUID.self) { promptID in
                PromptDetailView(
                    promptID: promptID,
                    promptService: appState.promptService
                )
                .environment(appState)
            }
            .searchable(
                text: Binding(
                    get: { appState.searchText },
                    set: { appState.searchText = $0 }
                )
            )
            .refreshable {
                await appState.refresh()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New", systemImage: "plus") {
                        showingCreatePrompt = true
                    }
                }
            }
        }
    }
}
