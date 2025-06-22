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
                prompts: appState.displayedPrompts.compactMap { item in
                    // Convert lightweight items to full prompts temporarily
                    let prompt = Prompt(
                        title: item.title,
                        content: item.contentPreview,
                        category: item.category
                    )
                    prompt.id = item.id
                    prompt.modifiedAt = item.modifiedAt
                    prompt.metadata.isFavorite = item.isFavorite
                    return prompt
                },
                selectedPrompt: .constant(nil),
                onDelete: { prompt in
                    await appState.deletePromptById(prompt.id)
                },
                onToggleFavorite: { prompt in
                    await appState.toggleFavorite(for: prompt.id)
                },
                onLoadMore: {
                    await appState.loadMorePrompts()
                },
                hasMore: appState.hasMorePrompts,
                isLoadingMore: appState.isLoadingMore
            )
            .navigationTitle("Prompts")
            .navigationDestination(for: Prompt.self) { prompt in
                PromptDetailView(
                    prompt: Binding(
                        get: { prompt },
                        set: { _ in }
                    ),
                    promptService: appState.promptService,
                    onUpdate: { title, content, category in
                        await appState.updatePrompt(
                            prompt,
                            title: title,
                            content: content,
                            category: category
                        )
                    },
                    onAnalyze: {
                        await appState.analyzePrompt(prompt)
                    },
                    onCopy: {
                        appState.copyPromptContent(prompt)
                    }
                )
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
