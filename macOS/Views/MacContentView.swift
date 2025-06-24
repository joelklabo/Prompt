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
                        selectedPromptID: Binding(
                            get: { appState.selectedPromptID },
                            set: { newID in
                                if let id = newID {
                                    Task {
                                        await appState.selectPrompt(id)
                                    }
                                }
                            }
                        ),
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
                    .navigationSplitViewColumnWidth(min: 300, ideal: 400)
                },
                detail: {
                    if let selectedID = appState.selectedPromptID {
                        PromptDetailView(
                            promptID: selectedID,
                            promptService: appState.promptService
                        )
                        .environment(appState)
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
