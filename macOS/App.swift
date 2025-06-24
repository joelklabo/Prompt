import SwiftData
import SwiftUI

@main
struct PromptMacApp: App {
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
                isStoredInMemoryOnly: false
            )

            self.modelContainer = try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )

            // Start with SwiftData storage, hybrid storage can be added later
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
            MacContentViewWrapper(appState: appState)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .modelContainer(modelContainer)
        .commands {
            PromptCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

struct PromptCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Prompt") {
                NotificationCenter.default.post(name: .newPrompt, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command])
            .help("Create a new prompt (⌘N)")

            Divider()

            Button("Quick Search") {
                NotificationCenter.default.post(name: .quickSearch, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command])
            .help("Open quick search (⌘K)")
        }

        CommandMenu("Prompts") {
            Button("Analyze Selected") {
                NotificationCenter.default.post(name: .analyzeSelected, object: nil)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .help("Analyze selected prompt with AI (⌘⇧A)")

            Button("Export Selected") {
                NotificationCenter.default.post(name: .exportSelected, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command])
            .help("Export selected prompt as markdown (⌘E)")

            Divider()

            Button("Import Prompts...") {
                NotificationCenter.default.post(name: .importPrompts, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command])
            .help("Import prompts from files (⌘I)")
        }

        #if DEBUG
            CommandMenu("Development") {
                Button("Populate Test Data") {
                    NotificationCenter.default.post(name: .populateTestData, object: nil)
                }
                .help("Create test prompts for performance testing")

                Button("Clear All Data") {
                    NotificationCenter.default.post(name: .clearAllData, object: nil)
                }
                .help("Delete all prompts and start fresh")

                Divider()

                Button("Show Performance Stats") {
                    NotificationCenter.default.post(name: .showPerformanceStats, object: nil)
                }
                .help("Show app performance metrics")
            }
        #endif
    }
}

struct SettingsView: View {
    @AppStorage("defaultCategory") private var defaultCategoryRawValue = Category.prompts.rawValue
    @AppStorage("enableAutoAnalysis") private var enableAutoAnalysis = false
    @AppStorage("showRecentPrompts") private var showRecentPrompts = true
    @AppStorage("promptsPerPage") private var promptsPerPage = 50

    var body: some View {
        TabView {
            GeneralSettingsView(
                defaultCategoryRawValue: $defaultCategoryRawValue,
                showRecentPrompts: $showRecentPrompts,
                promptsPerPage: $promptsPerPage
            )
            .tabItem {
                Label("General", systemImage: "gear")
            }

            AISettingsView(
                enableAutoAnalysis: $enableAutoAnalysis
            )
            .tabItem {
                Label("AI", systemImage: "sparkle")
            }

            SyncSettingsView()
                .tabItem {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .frame(width: 500, height: 300)
    }
}

struct GeneralSettingsView: View {
    @Binding var defaultCategoryRawValue: String
    @Binding var showRecentPrompts: Bool
    @Binding var promptsPerPage: Int

    private var defaultCategory: Binding<Category> {
        Binding(
            get: { Category(rawValue: defaultCategoryRawValue) ?? .prompts },
            set: { defaultCategoryRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Picker("Default Category", selection: defaultCategory) {
                ForEach(Category.allCases, id: \.self) { category in
                    Label(category.rawValue, systemImage: category.icon)
                        .tag(category)
                }
            }

            Toggle("Show Recent Prompts", isOn: $showRecentPrompts)

            Stepper("Prompts per page: \(promptsPerPage)", value: $promptsPerPage, in: 10...200, step: 10)
        }
        .padding()
    }
}

struct AISettingsView: View {
    @Binding var enableAutoAnalysis: Bool

    var body: some View {
        Form {
            Toggle("Enable Auto-Analysis", isOn: $enableAutoAnalysis)
                .help("Automatically analyze new prompts with AI")

            Text("AI analysis helps categorize and tag your prompts automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

struct SyncSettingsView: View {
    @State private var iCloudEnabled = true
    @State private var lastSyncDate = Date()

    var body: some View {
        Form {
            Toggle("Enable iCloud Sync", isOn: $iCloudEnabled)

            HStack {
                Text("Last Sync:")
                Text(lastSyncDate.formatted())
                    .foregroundStyle(.secondary)
            }

            Button("Sync Now") {
                // Trigger manual sync
            }
            .help("Manually sync with iCloud")
        }
        .padding()
    }
}
