import SwiftUI
import WidgetKit

/// Daily reading as cross stitch on linen: one column per week, Monday at the top.

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

/// The calendar on a piece of linen in a thin wooden frame.
struct Sampler: View {
    let days: [Int]
    var allWeeks = false

    var body: some View {
        HeatGrid(days: days, gap: 1, allWeeks: allWeeks)
            .frame(maxWidth: .infinity)
            .padding(6)
            .background(Theme.linen, in: RoundedRectangle(cornerRadius: 8))
            .padding(3)
            .background(Theme.wood, in: RoundedRectangle(cornerRadius: 11))
    }
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
        let step = cell + gap
        return Canvas { ctx, _ in
            for (w, week) in shown.enumerated() {
                for d in 0..<7 {
                    guard let seconds = week[d] else { continue }
                    let rect = CGRect(x: CGFloat(w) * step, y: CGFloat(d) * step, width: cell, height: cell)
                    let l = level(seconds)
                    if l == 0 {
                        ctx.fill(Path(ellipseIn: rect.insetBy(dx: cell * 0.42, dy: cell * 0.42)), with: .color(.black.opacity(0.18)))
                    } else {
                        crossStitch(ctx, in: rect, color: Theme.threads[l])
                    }
                }
            }
        }
        .frame(width: CGFloat(shown.count) * step - gap, height: 7 * step - gap)
    }

    /// Two legs of floss, the second crossing over the first, with a soft shadow and a sheen.
    private func crossStitch(_ ctx: GraphicsContext, in r: CGRect, color: Color) {
        let inset = r.width * 0.1, width = r.width * 0.3
        let a = r.insetBy(dx: inset, dy: inset)
        let legs = [(CGPoint(x: a.minX, y: a.maxY), CGPoint(x: a.maxX, y: a.minY)),
                    (CGPoint(x: a.minX, y: a.minY), CGPoint(x: a.maxX, y: a.maxY))]
        for (from, to) in legs {
            var leg = Path()
            leg.move(to: from)
            leg.addLine(to: to)
            let shadow = leg.offsetBy(dx: width * 0.25, dy: width * 0.3)
            ctx.stroke(shadow, with: .color(.black.opacity(0.18)), style: StrokeStyle(lineWidth: width, lineCap: .round))
            ctx.stroke(leg, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            ctx.stroke(leg, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: width * 0.3, lineCap: .round))
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
                    Text(Format.durationText(s.today)).font(.system(size: 16, weight: .semibold, design: .serif)).monospacedDigit()
                } else {
                    Text("Reading").font(.system(size: 16, weight: .semibold, design: .serif))
                    Text("\(readDays) days in 26 weeks")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Label("\(s.streak)", systemImage: "flame.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(s.streak > 0 ? Theme.flame : Theme.muted)
            }
            if family == .systemSmall {
                Sampler(days: days)
            } else {
                Spacer(minLength: 0)
                Sampler(days: days, allWeeks: true)
                Spacer(minLength: 0)
            }
            if family == .systemLarge {
                HStack {
                    stat(Format.durationText(s.today), "today")
                    stat(Format.durationText(s.week), "this week")
                    stat(Format.durationText(s.month), "this month")
                }
                if let book = s.book {
                    Divider().overlay(Theme.stitch)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(book.title).font(.system(size: 16, weight: .semibold, design: .serif)).lineLimit(1)
                            Spacer()
                            Text("\(Int((book.progress * 100).rounded()))%")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                        }
                        Text(book.authors).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        ProgressBar(value: book.progress)
                    }
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 18, weight: .semibold, design: .serif)).monospacedDigit().foregroundStyle(Theme.cream)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HeatmapWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ReadingHeatmap", provider: Provider()) { entry in
            HeatmapView(entry: entry)
                .foregroundStyle(Theme.text)
                .containerBackground(for: .widget) { ClothBackground() }
        }
        .configurationDisplayName("Reading calendar")
        .description("Every day you read, one cross stitch per day.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemMedium) {
    HeatmapWidget()
} timeline: {
    Entry(date: .now, snapshot: .placeholder, stale: false)
}
