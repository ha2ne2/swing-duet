import Foundation

// 画面に出す日時・時間の表記と、日付ごとの節への分け方

/// 使い回す DateFormatter（作るのが重いので、一覧の行ごとに作らない）
private enum Formatters {
    static let compact = make("M/d HH:mm")
    static let time = make("HH:mm")
    static let day = make("M月d日（E）")
    static let dayWithYear = make("y年M月d日（E）")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter
    }
}

extension Date {
    /// 「9/10 14:32」。クリップの表示名（名前が無いとき）と、動画の一覧のラベルに使う
    var compactLabel: String { Formatters.compact.string(from: self) }

    /// 「14:32」。日付の節の中の行に使う
    var timeLabel: String { Formatters.time.string(from: self) }

    /// 日付の節の見出し：「今日」「昨日」、それ以外は「9月8日（月）」（年が違えば「2025年12月3日（水）」）
    var dayLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "今日" }
        if calendar.isDateInYesterday(self) { return "昨日" }
        let sameYear = calendar.isDate(self, equalTo: Date(), toGranularity: .year)
        return (sameYear ? Formatters.day : Formatters.dayWithYear).string(from: self)
    }
}

extension TimeInterval {
    /// 「0:04」のような長さ・再生位置の表記（秒未満は切り捨て）
    var clockLabel: String {
        let whole = Int(rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

extension Sequence {
    /// 日付ごとの節に分ける（新しい日から）。一覧やグリッドの見出しに使う
    func groupedByDay(_ date: (Element) -> Date) -> [(day: Date, items: [Element])] {
        let grouped = Dictionary(grouping: self) { Calendar.current.startOfDay(for: date($0)) }
        return grouped.keys.sorted(by: >).map { (day: $0, items: grouped[$0] ?? []) }
    }
}
