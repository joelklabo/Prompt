import SwiftUI

#if os(macOS)
    struct PromptSidebar: View {
        let appState: AppState
        @State private var selectedSection: SidebarSection = .all

        enum SidebarSection: String, CaseIterable {
            case all = "All Prompts"
            case favorites = "Favorites"
            case recent = "Recent"
            case categories = "Categories"
            case tags = "Tags"

            var icon: String {
                switch self {
                case .all: return "tray.full"
                case .favorites: return "star"
                case .recent: return "clock"
                case .categories: return "folder"
                case .tags: return "tag"
                }
            }
        }

        var body: some View {
            List(selection: $selectedSection) {
                Section("Library") {
                    ForEach(SidebarSection.allCases.prefix(3), id: \.self) { section in
                        Label(section.rawValue, systemImage: section.icon)
                            .tag(section)
                    }
                }

                Section("Organize") {
                    Label("Categories", systemImage: "folder")
                        .tag(SidebarSection.categories)

                    if selectedSection == .categories {
                        ForEach(Category.allCases, id: \.self) { category in
                            Label(category.rawValue, systemImage: category.icon)
                                .padding(.leading)
                                .tag(category)
                                .onTapGesture {
                                    appState.selectedCategory = category
                                }
                        }
                    }

                    Label("Tags", systemImage: "tag")
                        .tag(SidebarSection.tags)
                }

                Section("Statistics") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Total Prompts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(appState.promptList.count)")
                                .font(.title3)
                                .bold()
                        }

                        Spacer()

                        VStack(alignment: .leading) {
                            Text("Favorites")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(appState.favoritePrompts.count)")
                                .font(.title3)
                                .bold()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Prompt Bank")
            .frame(minWidth: 200)
            .onChange(of: selectedSection) { _, newValue in
                handleSectionChange(newValue)
            }
        }

        private func handleSectionChange(_ section: SidebarSection) {
            switch section {
            case .all:
                appState.selectedCategory = nil
            case .favorites:
                // Filter will be handled by computed property
                appState.selectedCategory = nil
            case .recent:
                // Filter will be handled by computed property
                appState.selectedCategory = nil
            case .categories:
                // Expand categories
                break
            case .tags:
                // Show tags view
                break
            }
        }
    }
#endif
