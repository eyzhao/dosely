import Foundation
import SwiftUI

enum Fmt {
    static func time(_ d: Date) -> String {
        d.formatted(date: .omitted, time: .shortened)
    }

    static func dateFor(minutes m: Int, on day: Date = .now) -> Date {
        Calendar.current.date(bySettingHour: (m / 60) % 24, minute: m % 60, second: 0, of: day) ?? day
    }

    static func minutes(_ m: Int) -> String { time(dateFor(minutes: m)) }

    static func times(_ ms: [Int], separator: String = " · ") -> String {
        ms.sorted().map(minutes).joined(separator: separator)
    }

    static func columnTime(_ key: Int) -> String { time(Date(minuteKey: key)) }

    /// "Today", "Yesterday", "Tomorrow" or "Fri 9 Oct".
    static func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    static func shortDay(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "today 09:04", "yesterday 21:00", "Fri 9 Oct 09:00"
    static func dayTime(_ d: Date) -> String {
        "\(dayLabel(d).lowercasedIfRelative) \(time(d))"
    }

    /// "+45m", "−1h 10m"
    static func offset(_ seconds: TimeInterval) -> String {
        let sign = seconds < 0 ? "−" : "+"
        let total = Int(abs(seconds) / 60)
        let h = total / 60, m = total % 60
        if h == 0 { return "\(sign)\(m)m" }
        return m == 0 ? "\(sign)\(h)h" : "\(sign)\(h)h \(m)m"
    }
}

private extension String {
    var lowercasedIfRelative: String {
        ["Today", "Yesterday", "Tomorrow"].contains(self) ? lowercased() : self
    }
}

extension Binding where Value == Int {
    /// Bridges "minutes after midnight" to a Date for hour/minute DatePickers.
    func asTimeOfDay() -> Binding<Date> {
        let base = self
        return Binding<Date>(
            get: { Fmt.dateFor(minutes: base.wrappedValue) },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                base.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }
}
