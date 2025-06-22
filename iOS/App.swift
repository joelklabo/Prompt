import SwiftData
import SwiftUI

@main
struct PromptiOSApp: App {
    let modelContainer: ModelContainer
    let appState: AppState

    init() {
        do {
            let schema = Schema([
                Prompt.self,
                Tag.self,
                PromptMetadata.self,
                PromptVersion.self,
                AIAnalysis.self
            ])

            let modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .automatic
            )

            self.modelContainer = try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )

            let promptService = PromptService(container: modelContainer)
            let tagService = TagService(container: modelContainer)
            let aiService = AIService()

            self.appState = AppState(
                promptService: promptService,
                tagService: tagService,
                aiService: aiService
            )
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
        }
        .modelContainer(modelContainer)
    }
}
