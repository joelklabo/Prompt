import SwiftUI

struct FileStatsView: View {
    let promptDetail: PromptDetail

    // Cached values to prevent recalculation on every render
    @State private var wordCount: Int = 0
    @State private var lineCount: Int = 0
    @State private var isCalculating = false

    private var contentSize: String {
        let bytes = promptDetail.content.utf8.count
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("File Statistics")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Label("Size", systemImage: "doc.text")
                        .foregroundColor(.secondary)
                    Text(contentSize)
                        .fontWeight(.medium)
                }

                GridRow {
                    Label("Words", systemImage: "textformat")
                        .foregroundColor(.secondary)
                    Text("\(wordCount)")
                        .fontWeight(.medium)
                }

                GridRow {
                    Label("Lines", systemImage: "list.number")
                        .foregroundColor(.secondary)
                    Text("\(lineCount)")
                        .fontWeight(.medium)
                }

                GridRow {
                    Label("Created", systemImage: "calendar")
                        .foregroundColor(.secondary)
                    Text(promptDetail.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .fontWeight(.medium)
                }

                GridRow {
                    Label("Modified", systemImage: "clock")
                        .foregroundColor(.secondary)
                    Text(promptDetail.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        .fontWeight(.medium)
                }

                GridRow {
                    Label("Views", systemImage: "eye")
                        .foregroundColor(.secondary)
                    Text("\(promptDetail.metadata.viewCount)")
                        .fontWeight(.medium)
                }

                GridRow {
                    Label("Copies", systemImage: "doc.on.clipboard")
                        .foregroundColor(.secondary)
                    Text("\(promptDetail.metadata.copyCount)")
                        .fontWeight(.medium)
                }

                if let lastViewed = promptDetail.metadata.lastViewedAt {
                    GridRow {
                        Label("Last Viewed", systemImage: "clock.arrow.circlepath")
                            .foregroundColor(.secondary)
                        Text(lastViewed.formatted(.relative(presentation: .named)))
                            .fontWeight(.medium)
                    }
                }

                GridRow {
                    Label("Versions", systemImage: "clock.arrow.2.circlepath")
                        .foregroundColor(.secondary)
                    Text("\(promptDetail.versionCount)")
                        .fontWeight(.medium)
                }
            }
            .padding()
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .onAppear {
            calculateStats()
        }
        .onChange(of: promptDetail.content) { _, _ in
            calculateStats()
        }
    }

    private func calculateStats() {
        // Prevent redundant calculations
        guard !isCalculating else { return }
        isCalculating = true

        // Calculate in background to avoid blocking UI
        Task.detached(priority: .userInitiated) {
            let words = promptDetail.content.split(whereSeparator: \.isWhitespace).count
            let lines = promptDetail.content.components(separatedBy: .newlines).count

            await MainActor.run {
                self.wordCount = words
                self.lineCount = lines
                self.isCalculating = false
            }
        }
    }
}
