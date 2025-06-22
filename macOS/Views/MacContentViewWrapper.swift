import SwiftUI
import os

struct MacContentViewWrapper: View {
    @State private var appState: AppState
    @State private var showingCreatePrompt = false
    @State private var isDropTargeted = false
    @State private var importedData: AppState.ImportedPromptData?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    private let logger = Logger(subsystem: "com.prompt.app", category: "MacContentViewWrapper")
    private let fileOperations = FileOperations()

    init(appState: AppState) {
        self._appState = State(initialValue: appState)
    }

    var body: some View {
        MacContentView(
            appState: appState,
            columnVisibility: $columnVisibility,
            showingCreatePrompt: $showingCreatePrompt,
            isDropTargeted: isDropTargeted
        )
        .progressOverlay(appState.progressState)
        .task {
            logger.info("MacContentView appeared, loading prompts")
            await appState.loadPrompts()
        }
        .sheet(isPresented: $showingCreatePrompt) {
            createPromptView
        }
        .fileDroppable(isTargeted: $isDropTargeted) { urls in
            handleDroppedFiles(urls)
        }
        .onReceive(NotificationCenter.default.publisher(for: .importPrompts)) { _ in
            handleImportCommand()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportSelected)) { _ in
            fileOperations.handleExportCommand(appState: appState)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newPrompt)) { _ in
            showingCreatePrompt = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickSearch)) { _ in
            // Focus search field
            appState.searchText = ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .analyzeSelected)) { _ in
            Task {
                if let selectedPrompt = appState.selectedPrompt {
                    await appState.analyzePrompt(selectedPrompt)
                }
            }
        }
    }

    @ViewBuilder
    private var createPromptView: some View {
        if let data = importedData {
            CreatePromptView(
                initialTitle: data.title,
                initialContent: data.content,
                initialCategory: data.category,
                initialTags: data.tags
            ) { title, content, category, tags in
                await appState.createPrompt(
                    title: title,
                    content: content,
                    category: category,
                    tags: tags
                )
                importedData = nil
            }
        } else {
            CreatePromptView { title, content, category, tags in
                await appState.createPrompt(
                    title: title,
                    content: content,
                    category: category,
                    tags: tags
                )
            }
        }
    }

    private func handleDroppedFiles(_ urls: [URL]) {
        fileOperations.handleDroppedFiles(urls, appState: appState) { data in
            Task { @MainActor in
                importedData = data
                showingCreatePrompt = true
            }
        }
    }

    private func handleImportCommand() {
        fileOperations.handleImportCommand(appState: appState) { data in
            Task { @MainActor in
                importedData = data
                showingCreatePrompt = true
            }
        }
    }
}