import SwiftUI

struct CreatePromptView: View {
    @Environment(\.dismiss) var dismiss
    @State private var title = ""
    @State private var content = ""
    @State private var category = Category.prompts
    @State private var tagInput = ""
    @State private var tags: [String] = []
    @FocusState private var isTagFieldFocused: Bool

    let onCreate: (String, String, Category, [String]) async -> Void

    // Optional initial values for pre-population
    var initialTitle: String?
    var initialContent: String?
    var initialCategory: Category?
    var initialTags: [String]?

    init(
        initialTitle: String? = nil,
        initialContent: String? = nil,
        initialCategory: Category? = nil,
        initialTags: [String]? = nil,
        onCreate: @escaping (String, String, Category, [String]) async -> Void
    ) {
        self.initialTitle = initialTitle
        self.initialContent = initialContent
        self.initialCategory = initialCategory
        self.initialTags = initialTags
        self.onCreate = onCreate

        // Set initial state values
        self._title = State(initialValue: initialTitle ?? "")
        self._content = State(initialValue: initialContent ?? "")
        self._category = State(initialValue: initialCategory ?? .prompts)
        self._tags = State(initialValue: initialTags ?? [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Basic Information") {
                    TextField("Title", text: $title)
                        .textFieldStyle(.plain)

                    Picker("Category", selection: $category) {
                        ForEach(Category.allCases, id: \.self) { cat in
                            Label(cat.rawValue, systemImage: cat.icon)
                                .tag(cat)
                        }
                    }
                    #if os(iOS)
                        .pickerStyle(.navigationLink)
                    #endif
                }

                Section("Content") {
                    TextEditor(text: $content)
                        .frame(minHeight: 200, maxHeight: 300)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Section("Tags") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            TextField("Add tag", text: $tagInput)
                                .textFieldStyle(.roundedBorder)
                                .focused($isTagFieldFocused)
                                .onSubmit {
                                    addTag()
                                }

                            Button("Add", action: addTag)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.regular)
                                .disabled(tagInput.isEmpty)
                                #if os(macOS)
                                    .help("Add this tag to the prompt")
                                #endif
                        }

                        if !tags.isEmpty {
                            FlowLayout(spacing: 8) {
                                ForEach(tags, id: \.self) { tag in
                                    HStack(spacing: 4) {
                                        Text(tag)
                                            .font(.caption)

                                        Button(
                                            action: {
                                                removeTag(tag)
                                            },
                                            label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        )
                                        .buttonStyle(.plain)
                                        #if os(macOS)
                                            .help("Remove this tag")
                                        #endif
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.blue.opacity(0.2))
                                    .foregroundStyle(.blue)
                                    .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tips for Great Prompts")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 4) {
                            bulletPoint("Be specific about your desired output")
                            bulletPoint("Include examples when helpful")
                            bulletPoint("Specify any constraints or requirements")
                            bulletPoint("Use clear, concise language")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New Prompt")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    #if os(macOS)
                        .help("Cancel without saving")
                    #endif
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await onCreate(title, content, category, tags)
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.isEmpty || content.isEmpty)
                    #if os(macOS)
                        .help("Create a new prompt with the provided information")
                    #endif
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 600, minHeight: 500)
        #endif
    }

    private func addTag() {
        let trimmedTag = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTag.isEmpty && !tags.contains(trimmedTag) {
            tags.append(trimmedTag)
            tagInput = ""
        }
    }

    private func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("•")
            Text(text)
        }
    }
}
