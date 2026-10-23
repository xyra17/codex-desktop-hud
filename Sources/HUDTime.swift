import Foundation

enum HUDTime {
    // Only display a reset supplied by the account API/log, never infer now + 5 hours.
    static func resetLabel(timestamp: TimeInterval?, now: Date = Date(),
                           timeZone: TimeZone = .autoupdatingCurrent) -> String? {
        guard let timestamp = timestamp, timestamp.isFinite,
              timestamp > now.timeIntervalSince1970, timestamp < 253402300800 else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "\(time) 重置" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "明日 \(time) 重置" }
        formatter.dateFormat = "MM/dd HH:mm"
        return "\(formatter.string(from: date)) 重置"
    }
}
