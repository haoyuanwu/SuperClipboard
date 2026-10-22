import Foundation
import SwiftUI

enum ClipboardTimestampFormatter {
    private static var cachedFormatters: [String: DateFormatter] = [:]

    static func string(for date: Date, relativeTo now: Date, timeZone: TimeZone = .current) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return "刚才" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60))分钟前" }
        if elapsed < 86_400 {
            let minutes = Int(elapsed / 60)
            return "\(minutes / 60)小时\(minutes % 60)分前"
        }

        let format = elapsed < 172_800 ? "'昨天' HH:mm" : "yyyy-MM-dd HH:mm"
        let key = timeZone.identifier + format
        let formatter: DateFormatter
        if let cached = cachedFormatters[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            cachedFormatters[key] = formatter
        }
        return formatter.string(from: date)
    }
}

struct ClipboardTimestamp: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: date, by: 60)) { context in
            Text(ClipboardTimestampFormatter.string(for: date, relativeTo: context.date))
        }
    }
}
