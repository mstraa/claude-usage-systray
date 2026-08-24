import Foundation

enum Format {

    /// The API reports the same logical reset as both "09:00:00.216" and "08:59:59.628" on
    /// different calls, so truncating renders an 11h reset as "10h59". Rounding to the
    /// nearest minute keeps that jitter invisible; sub-second precision is meaningless here.
    static func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate:
                (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    }

    /// 24-hour clock in the French style: "17h" on the hour, "17h23" otherwise.
    /// Always 24-hour regardless of the system's 12/24 preference, since the components are
    /// read directly rather than run through a locale-driven formatter.
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: roundedToMinute(date))
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        return minute == 0 ? "\(hour)h" : String(format: "%dh%02d", hour, minute)
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d")
        return formatter
    }()

    /// "at 17h", "tomorrow at 9h", "Wed 26 at 9h" — the day is only named when it is not today.
    static func resetPhrase(_ rawDate: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        // Rounded before the day comparison, so a 23:59:59.6 reset cannot be labelled today
        // while its clock reads 0h.
        let date = roundedToMinute(rawDate)
        let time = clock(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) {
            return "at \(time)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time)"
        }
        return "\(weekdayFormatter.string(from: date)) at \(time)"
    }

    /// "in 2h13m", "in 45m", "in 3d 4h", "now".
    static func relative(to date: Date, from now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded())
        if seconds <= 0 { return "now" }
        if seconds < 60 { return "in <1m" }

        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24

        if days >= 1 {
            let remainingHours = hours % 24
            return remainingHours == 0 ? "in \(days)d" : "in \(days)d \(remainingHours)h"
        }
        if hours >= 1 {
            let remainingMinutes = minutes % 60
            return remainingMinutes == 0 ? "in \(hours)h" : "in \(hours)h\(String(format: "%02d", remainingMinutes))m"
        }
        return "in \(minutes)m"
    }

    /// Percentages arrive as whole numbers today, but a fractional value should not render
    /// as "8.0%" if that ever changes.
    static func percent(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.05 {
            return "\(Int(rounded.rounded()))%"
        }
        return String(format: "%.1f%%", rounded)
    }
}
