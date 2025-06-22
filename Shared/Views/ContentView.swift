import os
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

struct ContentView: View {
    @State private var appState: AppState
    @State private var showingCreatePrompt = false
    @State private var isDropTargeted = false
    @State private var importedData: AppState.ImportedPromptData?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    private let logger = Logger(subsystem: "com.prompt.app", category: "ContentView")
    private let fileOperations = FileOperations()

    init(appState: AppState) {
        self._appState = State(initialValue: appState)
    }

    var body: some View {
        // Simple view for tests - the actual apps use their own ContentView implementations
        Text("Test ContentView")
            .progressOverlay(appState.progressState)
            .task {
                logger.info("ContentView appeared, loading prompts")
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
