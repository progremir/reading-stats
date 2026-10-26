import SwiftUI
import WidgetKit

/// Daily reading as cross stitch: one column per week, Monday at the top.

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

/// Stitches rendered by the landing page's shader (Assets: Stitch1...4), one per reading level, dull to vivid amber.
/// Each image is the stitch plus a margin for its shadow, a sixth of the cell on every side.
func stitchImage(_ level: Int) -> Image { Image("Stitch\(level)") }
let stitchMargin: CGFloat = 16.0 / 96.0

/// The holes of the aida cloth over a cols x rows area, so empty cells still read as cloth waiting for thread.
func drawHoles(_ ctx: GraphicsContext, cols: Int, rows: Int, cell: CGFloat) {
    let r = cell * 0.07
    for c in 0...cols {
        for row in 0...rows {
            ctx.fill(Path(ellipseIn: CGRect(x: CGFloat(c) * cell - r, y: CGFloat(row) * cell - r, width: 2 * r, height: 2 * r)),
                     with: .color(.black.opacity(0.3)))
        }
    }
}

/// One stitch image in the cell at (col, row), drawn a little larger so its shadow fits.
func drawStitch(_ ctx: GraphicsContext, _ stitch: GraphicsContext.ResolvedImage, col: Int, row: Int, cell: CGFloat) {
    let m = cell * stitchMargin
    ctx.draw(stitch, in: CGRect(x: CGFloat(col) * cell - m, y: CGFloat(row) * cell - m, width: cell + 2 * m, height: cell + 2 * m))
}

/// The calendar stitched straight onto the cloth, cell against cell like real cross stitch.
struct HeatGrid: View {
    let days: [Int]
    /// Show every week, sized to the width; otherwise fill the height and show the weeks that fit.
    var allWeeks = false

    var body: some View {
        let all = weeks(days)
        if allWeeks {
            let n = CGFloat(all.count)
            GeometryReader { geo in
                grid(all, cell: min(geo.size.width / n, geo.size.height / 7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .aspectRatio(n / 7, contentMode: .fit)
        } else {
            GeometryReader { geo in
                let cell = geo.size.height / 7
                let fit = max(1, Int(geo.size.width / cell))
                grid(Array(all.suffix(fit)), cell: cell)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func grid(_ shown: [[Int?]], cell: CGFloat) -> some View {
        Canvas { ctx, _ in
            let stitches = (1...4).map { ctx.resolve(stitchImage($0)) }
            drawHoles(ctx, cols: shown.count, rows: 7, cell: cell)
            for (w, week) in shown.enumerated() {
                for d in 0..<7 {
                    guard let seconds = week[d], level(seconds) > 0 else { continue }
                    drawStitch(ctx, stitches[level(seconds) - 1], col: w, row: d, cell: cell)
                }
            }
        }
        .frame(width: CGFloat(shown.count) * cell, height: 7 * cell)
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
                HeatGrid(days: days)
            } else {
                Spacer(minLength: 0)
                HeatGrid(days: days, allWeeks: true)
                Spacer(minLength: 0)
            }
            if family == .systemLarge {
                HStack {
                    stat(Format.durationText(s.today), "today")
                    stat(Format.durationText(s.week), "this week")
                    stat(Format.durationText(s.month), "this month")
                }
                if let book = s.book {
                    Divider().overlay(Theme.surface)
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
                .containerBackground(for: .widget) { Theme.cloth }
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
