import Foundation

@main struct TimeTests {
    static func main() {
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let iso = ISO8601DateFormatter()
        let now = iso.date(from: "2026-10-23T15:30:00+08:00")!
        func label(_ date: String, _ timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!) -> String? {
            HUDTime.resetLabel(timestamp: iso.date(from: date)!.timeIntervalSince1970, now: now, timeZone: timeZone)
        }
        precondition(label("2026-10-23T17:30:00+08:00") == "17:30 重置")
        precondition(label("2026-10-24T01:30:00+08:00") == "明日 01:30 重置")
        precondition(label("2026-10-25T01:30:00+08:00") == "10/25 01:30 重置")
        precondition(label("2026-10-23T17:30:00+08:00", TimeZone(secondsFromGMT: 0)!) == "09:30 重置")
        precondition(label("2026-10-23T14:30:00+08:00") == nil)
        for value in [nil, now.timeIntervalSince1970, .infinity, .nan, 253402300800] as [TimeInterval?] {
            precondition(HUDTime.resetLabel(timestamp: value, now: now, timeZone: zone) == nil)
        }
        print("Reset time: same-day, cross-midnight, later dates, timezone and invalid/expired values passed")
    }
}
