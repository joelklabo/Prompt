import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

// MARK: - Thread-Safe Box Helper

/// A thread-safe box for mutable values in concurrent contexts
private final class Box<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(_ value: T) {
        self._value = value
    }

    var value: T {
        get {
            lock.withLock { _value }
        }
        set {
            lock.withLock { _value = newValue }
        }
    }
}

// MARK: - Color Extensions

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let alpha: UInt64
        let red: UInt64
        let green: UInt64
        let blue: UInt64
        switch hex.count {
        case 3:  // RGB (12-bit)
            (alpha, red, green, blue) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  // RGB (24-bit)
            (alpha, red, green, blue) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  // ARGB (32-bit)
            (alpha, red, green, blue) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (alpha, red, green, blue) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

// MARK: - View Extensions

extension View {
    func hideKeyboard() {
        #if os(iOS)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let newPrompt = Notification.Name("newPrompt")
    static let quickSearch = Notification.Name("quickSearch")
    static let analyzeSelected = Notification.Name("analyzeSelected")
    static let exportSelected = Notification.Name("exportSelected")
    static let promptAdded = Notification.Name("promptAdded")
    static let analysisComplete = Notification.Name("analysisComplete")
    static let importPrompts = Notification.Name("importPrompts")
}

// MARK: - Error Extensions

extension Error {
    var userFriendlyMessage: String {
        if let promptError = self as? PromptError {
            return promptError.errorDescription ?? "An error occurred"
        }
        return self.localizedDescription
    }
}

// MARK: - Sample Data

extension Prompt {
    static var sample: Prompt {
        let prompt = Prompt(
            title: "Sample Prompt",
            content: "This is a sample prompt content for testing and development purposes.",
            category: .prompts
        )
        prompt.metadata.isFavorite = true
        prompt.metadata.viewCount = 42
        prompt.metadata.copyCount = 7
        return prompt
    }

    static var samples: [Prompt] {
        [
            Prompt(
                title: "Code Review Assistant",
                content: """
                    Please review the following code for best practices, potential bugs, and optimization opportunities.
                    Focus on readability, performance, and maintainability.
                    """,
                category: .prompts
            ),
            Prompt(
                title: "API Documentation Template",
                content: """
                    Generate comprehensive API documentation including endpoints, request/response formats, \
                    authentication requirements, and example usage.
                    """,
                category: .configs
            ),
            Prompt(
                title: "Git Commit Message",
                content: """
                    git commit -m "feat: add user authentication with JWT tokens

                    - Implement login/logout endpoints
                    - Add JWT token generation and validation
                    - Create middleware for protected routes"
                    """,
                category: .commands
            ),
            Prompt(
                title: "Project Architecture Context",
                content: """
                    You are working on a SwiftUI application using MVVM architecture with Combine for
                    reactive programming. The app uses Core Data for persistence and follows SOLID principles.
                    All network calls should use async/await. The project structure separates concerns into
                    Models, Views, ViewModels, Services, and Utilities.
                    """,
                category: .context
            )
        ]
    }
}

// MARK: - Date Extensions

extension Date {
    var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

// MARK: - Markdown Parser

struct MarkdownParser {
    struct ParsedMarkdown: Sendable {
        let frontmatter: [String: String]  // Changed from Any to String for Sendable conformance
        let content: String
        let title: String?
        let category: Category?
        let tags: [String]
        let createdDate: Date?
    }

    static func parse(_ text: String) -> ParsedMarkdown {
        var frontmatter: [String: String] = [:]
        var content = text
        var title: String?
        var category: Category?
        var tags: [String] = []
        var createdDate: Date?

        // Check for frontmatter
        if text.hasPrefix("---") {
            let components = text.components(separatedBy: "---")
            if components.count >= 3 {
                let result = extractFrontmatter(from: components)
                frontmatter = result.frontmatter
                content = result.content
                title = result.title
                category = result.category
                tags = result.tags
                createdDate = result.createdDate
            }
        }

        // Remove any markdown title from content if it matches the frontmatter title
        if let title = title, content.hasPrefix("# \(title)") {
            content =
                content
                .replacingOccurrences(of: "# \(title)", with: "", options: .anchored)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ParsedMarkdown(
            frontmatter: frontmatter,
            content: content,
            title: title,
            category: category,
            tags: tags,
            createdDate: createdDate
        )
    }

    private struct FrontmatterResult {
        let frontmatter: [String: String]
        let content: String
        let title: String?
        let category: Category?
        let tags: [String]
        let createdDate: Date?
    }

    private static func extractFrontmatter(from components: [String]) -> FrontmatterResult {
        let frontmatterText = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let frontmatter = parseFrontmatter(frontmatterText)

        let content = components.dropFirst(2)
            .joined(separator: "---")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var title: String?
        var category: Category?
        var tags: [String] = []
        var createdDate: Date?

        if let frontmatterTitle = frontmatter["title"] {
            title = frontmatterTitle
        }

        if let categoryString = frontmatter["category"],
            let parsedCategory = Category(rawValue: categoryString) {
            category = parsedCategory
        }

        if let tagString = frontmatter["tags"] {
            // Parse tags from string format [tag1, tag2] or just tag1, tag2
            let cleanedString =
                tagString
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            tags = cleanedString.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        if let createdString = frontmatter["created"] {
            createdDate = ISO8601DateFormatter().date(from: createdString)
        }

        return FrontmatterResult(
            frontmatter: frontmatter,
            content: content,
            title: title,
            category: category,
            tags: tags,
            createdDate: createdDate
        )
    }

    private static func parseFrontmatter(_ text: String) -> [String: String] {
        var result: [String: String] = [:]

        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }

            // Parse key: value pairs
            if let colonIndex = trimmedLine.firstIndex(of: ":") {
                let key = String(trimmedLine[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmedLine[trimmedLine.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespaces)

                // Store the value as-is (arrays will be stored as strings)
                result[key] = value
            }
        }

        return result
    }

    static func generateMarkdown(for prompt: Prompt) -> String {
        var markdown = "---\n"
        markdown += "title: \(prompt.title)\n"
        markdown += "category: \(prompt.category.rawValue)\n"
        if !prompt.tags.isEmpty {
            let tagNames = prompt.tags.map { $0.name }.joined(separator: ", ")
            markdown += "tags: [\(tagNames)]\n"
        }
        markdown += "created: \(ISO8601DateFormatter().string(from: prompt.createdAt))\n"
        markdown += "---\n\n"
        markdown += "# \(prompt.title)\n\n"
        markdown += prompt.content

        return markdown
    }
}

// MARK: - Drag Drop Utils

struct DragDropUtils {
    // Supported file types
    static let supportedTypes: [UTType] = [
        .plainText,
        .utf8PlainText,
        .text,
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "markdown") ?? .plainText,
        UTType(filenameExtension: "txt") ?? .plainText
    ]

    // Detect category based on content
    static func detectCategory(from content: String) -> Category {
        let lowercasedContent = content.lowercased()

        // Check for config file patterns
        if containsConfigPatterns(lowercasedContent) {
            return .configs
        }

        // Check for shell/command patterns
        if containsCommandPatterns(lowercasedContent) {
            return .commands
        }

        // Check for system/architecture descriptions
        if containsContextPatterns(lowercasedContent) {
            return .context
        }

        // Default to prompts
        return .prompts
    }

    private static func containsConfigPatterns(_ content: String) -> Bool {
        let configPatterns = [
            // JSON patterns
            "\":", ": {", ": [", "{\n", "[\n",
            // YAML patterns
            "---\n", "- ", "  - ", ": |", ": >",
            // Common config keywords
            "configuration", "settings", "options", "parameters",
            "api_key", "endpoint", "database", "connection",
            // File extensions mentioned
            ".json", ".yaml", ".yml", ".config", ".env"
        ]

        let jsonBraceCount = content.filter { $0 == "{" || $0 == "}" }.count
        let jsonBracketCount = content.filter { $0 == "[" || $0 == "]" }.count

        // Strong indicator of JSON
        if jsonBraceCount >= 4 || jsonBracketCount >= 4 {
            return true
        }

        return configPatterns.contains { content.contains($0) }
    }

    private static func containsCommandPatterns(_ content: String) -> Bool {
        let commandPatterns = [
            // Shell commands
            "#!/bin", "sudo ", "echo ", "export ", "source ",
            "cd ", "ls ", "mkdir ", "rm ", "cp ", "mv ",
            "git ", "npm ", "yarn ", "pip ", "brew ",
            "docker ", "kubectl ", "terraform ",
            // Command line indicators
            "$ ", "> ", ">> ", "| ", "&&", "||",
            // Common command keywords
            "command", "script", "bash", "shell", "terminal",
            "cli", "execute", "run"
        ]

        return commandPatterns.contains { content.contains($0) }
    }

    private static func containsContextPatterns(_ content: String) -> Bool {
        let contextPatterns = [
            // Architecture keywords
            "architecture", "system design", "infrastructure",
            "microservices", "database schema", "api design",
            // Context indicators
            "you are", "you're working on", "context:",
            "background:", "overview:", "description:",
            // Technical descriptions
            "the system", "the application", "the project",
            "components", "services", "layers", "modules",
            // Patterns
            "mvc", "mvvm", "clean architecture", "domain-driven"
        ]

        let wordCount = content.split(separator: " ").count
        let sentenceCount = content.split(whereSeparator: { ".!?".contains($0) }).count

        // Longer, descriptive content is likely context
        if wordCount > 100 && sentenceCount > 5 {
            let matchCount = contextPatterns.filter { content.contains($0) }.count
            return matchCount >= 2
        }

        return contextPatterns.filter { content.contains($0) }.count >= 3
    }

    // Sanitize filename for export
    static func sanitizeFilename(_ filename: String) -> String {
        // Remove or replace invalid characters
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let sanitized = filename.components(separatedBy: invalidCharacters).joined(separator: "-")

        // Limit length
        let maxLength = 255 - 3  // Leave room for .md extension
        let truncated = String(sanitized.prefix(maxLength))

        // Remove leading/trailing dots and spaces
        let trimmed = truncated.trimmingCharacters(in: CharacterSet(charactersIn: ". "))

        // If empty after sanitization, provide default
        return trimmed.isEmpty ? "prompt" : trimmed
    }

    // Generate export filename
    static func exportFilename(for prompt: Prompt) -> String {
        let sanitizedTitle = sanitizeFilename(prompt.title)
        return "\(sanitizedTitle).md"
    }
}

// MARK: - Drop Modifier for importing files

struct FileDropModifier: ViewModifier {
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    func body(content: Content) -> some View {
        content
            .onDrop(of: DragDropUtils.supportedTypes, isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
                return true
            }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        let urlsBox = Box<[URL]>([])
        let group = DispatchGroup()

        for provider in providers {
            // Try to load as file URL first
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data,
                        let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urlsBox.value.append(url)
                    }
                    group.leave()
                }
            }
            // Try to load as plain text
            else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    if let text = item as? String {
                        // Create temporary file for text content
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension("txt")
                        do {
                            try text.write(to: tempURL, atomically: true, encoding: .utf8)
                            urlsBox.value.append(tempURL)
                        } catch {
                            // Log error - would use Logger in production
                        }
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            if !urlsBox.value.isEmpty {
                onDrop(urlsBox.value)
            }
        }
    }
}
