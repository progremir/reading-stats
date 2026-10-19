import SwiftUI
import WidgetKit

/// GitHub-style grid of daily reading: one column per week, Monday at the top.
private let levels: [Color] = [
    Color(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2A / 255),
    Color(red: 0x10 / 255, green: 0x42 / 255, blue: 0x81 / 255),
    Color(red: 0x1C / 255, green: 0x5C / 255, blue: 0xAB / 255),
    Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255),
    Color(red: 0x86 / 255, green: 0xB6 / 255, blue: 0xEF / 255),
]

private func level(_ seconds: Int) -> Int {
    switch seconds {
    case ..<60: 0
    case ..<900: 1
    case ..<1_800: 2
    case ..<3_600: 3
    default: 4
    }
}

/// Days grouped into Monday-first weeks, the last week ending today (later days are nil).
private func weeks(_ days: [Int], ending today: Date = .now) -> [[Int?]] {
    var cal = Calendar(identifier: .gregorian)
    cal.firstWeekday = 2
    let weekday = (cal.component(.weekday, from: today) + 5) % 7  // Monday = 0
    let padded: [Int?] = days.map { $0 } + Array(repeating: nil, count: 6 - weekday)
    let lead = (7 - padded.count % 7) % 7
    let cells: [Int?] = Array(repeating: nil, count: lead) + padded
    return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
}

struct HeatGrid: View {
    let days: [Int]
    var gap: CGFloat = 3
    /// Show every week, sized to the width; otherwise fill the height and show the weeks that fit.
    var allWeeks = false

    var body: some View {
        let all = weeks(days)
        if allWeeks {
            let n = CGFloat(all.count)
            GeometryReader { geo in
                grid(all, cell: (geo.size.width - gap * (n - 1)) / n)
            }
            .aspectRatio((n * 10 + (n - 1) * gap) / (70 + 6 * gap), contentMode: .fit)
        } else {
            GeometryReader { geo in
                let cell = (geo.size.height - gap * 6) / 7
                let fit = max(1, Int((geo.size.width + gap) / (cell + gap)))
                grid(Array(all.suffix(fit)), cell: cell)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
    }

    private func grid(_ shown: [[Int?]], cell: CGFloat) -> some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, week in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { d in
                        RoundedRectangle(cornerRadius: cell * 0.22)
                            .fill(week[d].map { levels[level($0)] } ?? .clear)
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
    }
}

struct HeatmapView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        let s = entry.snapshot
        let days = s.days ?? s.last7
        let readDays = days.filter { $0 >= 60 }.count
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
            HStack(alignment: .firstTextBaseline) {
                if family == .systemSmall {
                    Text(Format.durationText(s.today)).font(.system(size: 15, weight: .bold)).monospacedDigit()
                } else {
                    Text("Reading").font(.system(size: 15, weight: .semibold))
                    Text("\(readDays) days in 26 weeks")
                        .font(.system(size: 12)).foregroundStyle(Color(white: 0.56))
                }
                Spacer()
                Label("\(s.streak)", systemImage: "flame.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(s.streak > 0 ? .orange : Color(white: 0.56))
            }
            if family == .systemSmall {
                HeatGrid(days: days)
            } else {
                Spacer(minLength: 0)
                HeatGrid(days: days, gap: 3, allWeeks: true)
                Spacer(minLength: 0)
            }
            if family == .systemLarge {
                HStack {
                    stat(Format.durationText(s.today), "today")
                    stat(Format.durationText(s.week), "this week")
                    stat(Format.durationText(s.month), "this month")
                }
                if let book = s.book {
                    Divider().overlay(Color(white: 0.2))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(book.title).font(.system(size: 16, weight: .semibold, design: .serif)).lineLimit(1)
                            Spacer()
                            Text("\(Int((book.progress * 100).rounded()))%")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(white: 0.56))
                        }
                        Text(book.authors).font(.system(size: 12)).foregroundStyle(Color(white: 0.56)).lineLimit(1)
                        ProgressBar(value: book.progress)
                    }
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 17, weight: .bold)).monospacedDigit()
            Text(label).font(.system(size: 12)).foregroundStyle(Color(white: 0.56))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HeatmapWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ReadingHeatmap", provider: Provider()) { entry in
            HeatmapView(entry: entry)
                .foregroundStyle(.white)
                .containerBackground(for: .widget) { Color(white: 0.07) }
        }
        .configurationDisplayName("Reading calendar")
        .description("Every day you read, like a GitHub contribution graph.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemMedium) {
    HeatmapWidget()
} timeline: {
    Entry(date: .now, snapshot: .placeholder, stale: false)
}
