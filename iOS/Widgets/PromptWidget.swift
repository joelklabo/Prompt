import SwiftData
import SwiftUI
import WidgetKit

struct PromptWidget: Widget {
    let kind: String = "PromptWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            if #available(iOS 17.0, *) {
                PromptWidgetView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                PromptWidgetView(entry: entry)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("Quick Prompt")
        .description("Access your favorite prompts quickly")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), prompt: PromptInfo.placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        let entry = SimpleEntry(date: Date(), prompt: PromptInfo.placeholder)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // For now, use placeholder data synchronously
        let currentDate = Date()
        let entry = SimpleEntry(date: currentDate, prompt: PromptInfo.placeholder)
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(3600)))
        completion(timeline)
    }

    private func fetchRecentPrompts() async -> [PromptInfo] {
        // In a real implementation, this would fetch from the shared container
        // For now, return sample data
        return [
            PromptInfo(
                title: "Code Review",
                content: "Review this code for best practices",
                category: "Prompts",
                icon: "text.bubble"
            ),
            PromptInfo(
                title: "API Docs",
                content: "Generate API documentation",
                category: "Configs",
                icon: "gearshape"
            ),
            PromptInfo(
                title: "Git Commit",
                content: "Write a descriptive commit message",
                category: "Commands",
                icon: "terminal"
            )
        ]
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let prompt: PromptInfo
}

struct PromptInfo {
    let title: String
    let content: String
    let category: String
    let icon: String

    static let placeholder = PromptInfo(
        title: "Sample Prompt",
        content: "Your prompts will appear here",
        category: "Prompts",
        icon: "text.bubble"
    )
}

struct PromptWidgetView: View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallPromptWidget(prompt: entry.prompt)
        case .systemMedium:
            MediumPromptWidget(prompt: entry.prompt)
        case .systemLarge:
            LargePromptWidget(prompt: entry.prompt)
        case .systemExtraLarge:
            LargePromptWidget(prompt: entry.prompt)
        case .accessoryCircular:
            SmallPromptWidget(prompt: entry.prompt)
        case .accessoryRectangular:
            SmallPromptWidget(prompt: entry.prompt)
        case .accessoryInline:
            SmallPromptWidget(prompt: entry.prompt)
        @unknown default:
            SmallPromptWidget(prompt: entry.prompt)
        }
    }
}

struct SmallPromptWidget: View {
    let prompt: PromptInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: prompt.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(prompt.title)
                .font(.headline)
                .lineLimit(2)

            Spacer()

            Text(prompt.category)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .widgetURL(URL(string: "prompt://prompt/\(prompt.title)"))
    }
}

struct MediumPromptWidget: View {
    let prompt: PromptInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(prompt.title, systemImage: prompt.icon)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }

            Text(prompt.content)
                .font(.caption)
                .lineLimit(3)
                .foregroundStyle(.secondary)

            Spacer()

            HStack {
                Text(prompt.category)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())

                Spacer()

                Image(systemName: "arrow.forward.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
        .widgetURL(URL(string: "prompt://prompt/\(prompt.title)"))
    }
}

struct LargePromptWidget: View {
    let prompt: PromptInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(prompt.title, systemImage: prompt.icon)
                    .font(.title3)
                    .bold()
                Spacer()
            }

            Text(prompt.content)
                .font(.body)
                .lineLimit(6)
                .foregroundStyle(.secondary)

            Spacer()

            HStack {
                Text(prompt.category)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(.quaternary)
                    .clipShape(Capsule())

                Spacer()

                Button(
                    action: {},
                    label: {
                        Label("Open", systemImage: "arrow.forward.circle.fill")
                            .font(.caption)
                    }
                )
                .buttonStyle(.borderless)
            }
        }
        .widgetURL(URL(string: "prompt://prompt/\(prompt.title)"))
    }
}

// Widget Bundle for multiple widgets
#if WIDGET_EXTENSION
    @main
    struct PromptWidgetBundle: WidgetBundle {
        var body: some Widget {
            PromptWidget()
        }
    }
#endif
