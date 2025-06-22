import SwiftUI

struct MacContentView: View {
    let appState: AppState
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var showingCreatePrompt: Bool
    let isDropTargeted: Bool

    var body: some View {
        ZStack {
            NavigationSplitView(
                columnVisibility: $columnVisibility,
                sidebar: {
                    PromptSidebar(appState: appState)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
                },
                content: {
                    PromptListView(
                        prompts: appState.displayedPrompts.compactMap { item in
                            // Convert lightweight items to full prompts for now
                            // This is temporary until we update PromptListView
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
                        selectedPrompt: Binding(
                            get: { appState.selectedPrompt },
                            set: { appState.selectedPrompt = $0 }
                        ),
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
                    .navigationSplitViewColumnWidth(min: 300, ideal: 400)
                },
                detail: {
                    if let selectedPrompt = appState.selectedPrompt {
                        PromptDetailView(
                            prompt: Binding(
                                get: { selectedPrompt },
                                set: { _ in }
                            ),
                            promptService: appState.promptService,
                            onUpdate: { title, content, category in
                                await appState.updatePrompt(
                                    selectedPrompt,
                                    title: title,
                                    content: content,
                                    category: category
                                )
                            },
                            onAnalyze: {
                                await appState.analyzePrompt(selectedPrompt)
                            },
                            onCopy: {
                                appState.copyPromptContent(selectedPrompt)
                            }
                        )
                    } else {
                        ContentUnavailableView(
                            "Select a Prompt",
                            systemImage: "doc.text",
                            description: Text("Choose a prompt from the list to view details")
                        )
                    }
                }
            )
            .searchable(
                text: Binding(
                    get: { appState.searchText },
                    set: { appState.searchText = $0 }
                ), placement: .sidebar
            )
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        withAnimation {
                            if columnVisibility == .all {
                                columnVisibility = .doubleColumn
                            } else {
                                columnVisibility = .all
                            }
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help("Toggle sidebar visibility")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button("New Prompt", systemImage: "plus") {
                        showingCreatePrompt = true
                    }
                    .help("Create a new prompt")
                }
            }

            // Drop zone overlay
            if isDropTargeted {
                DropZoneOverlay(isTargeted: isDropTargeted)
                    .allowsHitTesting(false)
                    .padding()
            }
        }
    }
}
