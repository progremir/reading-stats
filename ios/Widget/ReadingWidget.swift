import SwiftUI
import WidgetKit

private let accent = Theme.tan
private let muted = Theme.muted

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: ReadingSnapshot
    let stale: Bool
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: .placeholder, stale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (Entry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { completion(await load()) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<Entry>) -> Void) {
        Task {
            let entry = await load()
            let next = Calendar.current.date(byAdding: .minute, value: entry.stale ? 10 : 30, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func load() async -> Entry {
        if let snapshot = try? await ReadingAPI.fetch() {
            Cache.save(snapshot)
            return Entry(date: .now, snapshot: snapshot, stale: false)
        }
        return Entry(date: .now, snapshot: Cache.load() ?? .placeholder, stale: true)
    }
}

/// Last good response, so the widget keeps showing numbers when offline.
enum Cache {
    private static let key = "lastSnapshot"

    static func save(_ snapshot: ReadingSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> ReadingSnapshot? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ReadingSnapshot.self, from: $0) }
    }
}

// MARK: - Pieces

/// Night blue cloth with a running stitch just inside the edge, like a sewn on patch.
struct ClothBackground: View {
    var body: some View {
        ZStack {
            Theme.cloth
            ContainerRelativeShape()
                .inset(by: 6)
                .stroke(Theme.stitch, style: Theme.runningStitch)
        }
    }
}

struct BigDuration: View {
    let seconds: Int
    var size: CGFloat = 40

    var body: some View {
        let d = Format.duration(seconds)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(d.value).font(.system(size: size, weight: .semibold, design: .serif)).monospacedDigit()
            Text(d.unit).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(muted)
        }
        .minimumScaleFactor(0.6)
        .lineLimit(1)
    }
}

struct WeekBars: View {
    let values: [Int]

    var body: some View {
        let top = max(values.max() ?? 0, 1_800)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(value > 0 ? accent.opacity(index == values.count - 1 ? 1 : 0.7) : Theme.surface)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, CGFloat(value) / CGFloat(top) * 34))
            }
        }
        .frame(height: 34, alignment: .bottom)
    }
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface)
                Capsule().fill(accent).frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

struct StreakLabel: View {
    let streak: Int

    var body: some View {
        Label("\(streak)", systemImage: "flame.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(streak > 0 ? Theme.flame : muted)
            .labelStyle(.titleAndIcon)
    }
}

// MARK: - Families

struct SmallView: View {
    let entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Today").font(.system(size: 13, weight: .semibold)).foregroundStyle(muted)
                Spacer()
                StreakLabel(streak: entry.snapshot.streak)
            }
            BigDuration(seconds: entry.snapshot.today)
            Spacer(minLength: 4)
            WeekBars(values: entry.snapshot.last7)
            Text("\(Format.durationText(entry.snapshot.week)) this week")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                .padding(.top, 5)
        }
    }
}

struct MediumView: View {
    let entry: Entry

    var body: some View {
        let s = entry.snapshot
        HStack(spacing: 16) {
            Link(destination: URL(string: "reading://")!) { SmallView(entry: entry) }
            VStack(alignment: .leading, spacing: 6) {
                if let book = s.book {
                    Text("Reading").font(.system(size: 13, weight: .semibold)).foregroundStyle(muted)
                    Text(book.title)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .lineLimit(3)
                    Text(book.authors).font(.system(size: 12)).foregroundStyle(muted).lineLimit(1)
                    Spacer(minLength: 0)
                    ProgressBar(value: book.progress)
                    Text("\(Int((book.progress * 100).rounded()))% read")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                } else {
                    Text("This month").font(.system(size: 13, weight: .semibold)).foregroundStyle(muted)
                    BigDuration(seconds: s.month, size: 30)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(s.book.map { URL(string: "reading://book/\($0.id)")! })
        }
    }
}

struct CircularView: View {
    let entry: Entry

    var body: some View {
        let d = Format.duration(entry.snapshot.today)
        let goal = 30.0 * 60
        Gauge(value: min(Double(entry.snapshot.today), goal), in: 0...goal) {
            Image(systemName: "book.fill")
        } currentValueLabel: {
            VStack(spacing: -2) {
                Text(d.value).font(.system(size: 16, weight: .bold)).monospacedDigit()
                Text(d.unit).font(.system(size: 9))
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }
}

struct RectangularView: View {
    let entry: Entry

    var body: some View {
        let s = entry.snapshot
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "book.fill")
                Text("\(Format.durationText(s.today)) today").font(.headline)
            }
            Text("\(Format.durationText(s.week)) this week · \(s.streak)d streak").font(.caption)
            if let book = s.book {
                Text("\(book.title) · \(Int((book.progress * 100).rounded()))%").font(.caption).lineLimit(1)
            }
        }
        .widgetAccentable()
    }
}

struct ReadingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        switch family {
        case .systemMedium: MediumView(entry: entry)
        case .accessoryCircular: CircularView(entry: entry)
        case .accessoryRectangular: RectangularView(entry: entry)
        case .accessoryInline:
            Label("\(Format.durationText(entry.snapshot.today)) read today", systemImage: "book.fill")
        default: SmallView(entry: entry)
        }
    }
}

struct ReadingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ReadingWidget", provider: Provider()) { entry in
            ReadingWidgetView(entry: entry)
                .foregroundStyle(Theme.text)
                .containerBackground(for: .widget) { ClothBackground() }
        }
        .configurationDisplayName("Readstreak")
        .description("Today's reading time, streak and current book.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct ReadingWidgetBundle: WidgetBundle {
    var body: some Widget {
        ReadingWidget()
        HeatmapWidget()
    }
}

#Preview(as: .systemMedium) {
    ReadingWidget()
} timeline: {
    Entry(date: .now, snapshot: .placeholder, stale: false)
}
