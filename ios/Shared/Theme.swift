import SwiftUI

/// Night blue cloth and cotton floss, the same palette as the web app and the landing page.
enum Theme {
    static let cloth = Color(hex: 0x1C2A50)
    static let page = Color(hex: 0x141D36)
    static let surface = Color(hex: 0x24325C)
    static let text = Color(hex: 0xF4EBDD)
    static let cream = Color(hex: 0xF8E4BF)
    static let muted = Color(hex: 0xA3AAC2)
    static let tan = Color(hex: 0xE0A15E)
    static let ink = Color(hex: 0x1C2A50)
    static let flame = Color(hex: 0xF0913A)
    static let stitch = Color(hex: 0xF4EBDD).opacity(0.26)
    /// A running stitch, for dashed edges.
    static let runningStitch = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4])
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
