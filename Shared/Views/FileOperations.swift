import Foundation
import os
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

@MainActor
struct FileOperations {
    private let logger = Logger(subsystem: "com.prompt.app", category: "FileOperations")

    func handleDroppedFiles(
        _ urls: [URL], appState: AppState, onImport: @escaping @Sendable (AppState.ImportedPromptData) -> Void
    ) {
        guard let firstURL = urls.first else { return }

        Task {
            do {
                let data = try await appState.importPromptFromFile(at: firstURL)
                await MainActor.run {
                    onImport(data)
                }
            } catch {
                logger.error("Failed to import file: \(error)")
            }
        }
    }

    func handleImportCommand(appState: AppState, onImport: @escaping @Sendable (AppState.ImportedPromptData) -> Void) {
        #if os(macOS)
            let openPanel = NSOpenPanel()
            openPanel.title = "Import Prompts"
            openPanel.message = "Choose markdown or text files to import"
            openPanel.allowsMultipleSelection = false
            openPanel.allowedContentTypes = DragDropUtils.supportedTypes

            openPanel.begin { response in
                if response == .OK {
                    Task { @MainActor in
                        if let url = openPanel.url {
                            handleDroppedFiles([url], appState: appState, onImport: onImport)
                        }
                    }
                }
            }
        #endif
    }

    func handleExportCommand(appState: AppState) {
        #if os(macOS)
            guard let selectedPromptDetail = appState.selectedPromptDetail else { return }

            let markdown = MarkdownParser.generateMarkdown(for: selectedPromptDetail)
            let filename = DragDropUtils.exportFilename(for: selectedPromptDetail)

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            savePanel.nameFieldStringValue = filename
            savePanel.title = "Export Prompt"
            savePanel.message = "Choose where to save the prompt"

            savePanel.begin { response in
                if response == .OK {
                    Task { @MainActor in
                        if let url = savePanel.url {
                            let operationId = appState.progressState.startOperation(
                                .exporting,
                                message: "Exporting \(selectedPromptDetail.title)..."
                            )

                            do {
                                // Perform file I/O on background thread
                                try await Task.detached(priority: .userInitiated) {
                                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                                }
                                .value

                                logger.info("Successfully exported prompt to: \(url.path)")
                                appState.progressState.completeOperation(operationId)
                            } catch {
                                logger.error("Failed to export prompt: \(error)")
                                appState.progressState.completeOperation(operationId)
                            }
                        }
                    }
                }
            }
        #endif
    }
}
