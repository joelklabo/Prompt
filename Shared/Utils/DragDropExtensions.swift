import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag Modifier for exporting prompts

struct PromptDragModifier: ViewModifier {
    let prompt: Prompt

    func body(content: Content) -> some View {
        content
            .draggable(prompt) {
                // Drag preview
                VStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(prompt.title)
                        .font(.caption)
                        .lineLimit(1)
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .onDrag {
                createItemProvider()
            }
    }

    private func createItemProvider() -> NSItemProvider {
        let provider = NSItemProvider()

        // Register the prompt as draggable
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            visibility: .all
        ) { completion in
            let markdown = MarkdownParser.generateMarkdown(for: prompt)
            let data = markdown.data(using: .utf8) ?? Data()
            completion(data, nil)
            return nil
        }

        // Register as file promise for exporting
        let filename = DragDropUtils.exportFilename(for: prompt)
        provider.suggestedName = filename

        provider.registerFileRepresentation(
            forTypeIdentifier: UTType(filenameExtension: "md")?.identifier ?? UTType.plainText.identifier,
            fileOptions: [], visibility: .all
        ) { completion in
            let markdown = MarkdownParser.generateMarkdown(for: prompt)

            // Create temporary file
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(filename)

            do {
                try markdown.write(to: tempURL, atomically: true, encoding: .utf8)
                completion(tempURL, true, nil)
            } catch {
                completion(nil, false, error)
            }

            return nil
        }

        return provider
    }
}

// MARK: - View Extensions for Drag and Drop

extension View {
    func fileDroppable(isTargeted: Binding<Bool>, onDrop: @escaping ([URL]) -> Void) -> some View {
        modifier(FileDropModifier(isTargeted: isTargeted, onDrop: onDrop))
    }

    func promptDraggable(_ prompt: Prompt) -> some View {
        modifier(PromptDragModifier(prompt: prompt))
    }
}

// MARK: - Drop Zone Visual Feedback

struct DropZoneOverlay: View {
    let isTargeted: Bool

    var body: some View {
        if isTargeted {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [10, 5]))
                .foregroundStyle(.blue)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.blue.opacity(0.1))
                )
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc")
                            .font(.largeTitle)
                            .foregroundStyle(.blue)
                        Text("Drop files here to import")
                            .font(.headline)
                            .foregroundStyle(.blue)
                        Text("Accepts .md, .markdown, and .txt files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                )
                .animation(.easeInOut(duration: 0.2), value: isTargeted)
        }
    }
}

// MARK: - Prompt Transferable Conformance

extension Prompt: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { prompt in
            let markdown = MarkdownParser.generateMarkdown(for: prompt)
            return markdown.data(using: .utf8) ?? Data()
        }

        FileRepresentation(exportedContentType: UTType(filenameExtension: "md") ?? .plainText) { prompt in
            let markdown = MarkdownParser.generateMarkdown(for: prompt)
            let filename = DragDropUtils.exportFilename(for: prompt)

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(filename)

            try markdown.write(to: tempURL, atomically: true, encoding: .utf8)

            return SentTransferredFile(tempURL)
        }
    }
}
