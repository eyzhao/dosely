import Foundation

extension Date {
    /// Whole minutes since 1970 — the identity of a time slot.
    var minuteKey: Int { Int((timeIntervalSince1970 / 60).rounded(.down)) }
    var floorMinute: Date { Date(timeIntervalSince1970: TimeInterval(minuteKey) * 60) }
    init(minuteKey: Int) { self.init(timeIntervalSince1970: TimeInterval(minuteKey) * 60) }
}

/// Which days a schedule falls on.
enum Recurrence: Hashable {
    /// Every N days counted from the first-dose day (1 = daily).
    case everyDays(Int)
    /// On the given weekdays (1 = Sun … 7 = Sat), every N weeks counted from the first-dose week.
    case weekly(weekdays: Set<Int>, every: Int)
    /// On a day of the month (clamped to short months), every N months from the first-dose month.
    case monthly(day: Int, every: Int)
}

/// Pure schedule maths: turns a medication + global settings into concrete dose times.
enum ScheduleEngine {

    struct Pattern {
        var times: [Int]          // minutes after midnight
        var recurrence: Recurrence
        var start: Date
        var end: Date?
        var producesSlots: Bool
    }

    // MARK: Building patterns

    static func recurrence(frequency: Frequency, interval: Int, weekdays: [Int], start: Date,
                           calendar cal: Calendar = .current) -> Recurrence {
        let n = max(1, interval)
        switch frequency {
        case .q48h:
            return .everyDays(2)
        case .everyNDays:
            return .everyDays(max(2, n))
        case .weekly:
            let set = Set(weekdays.filter { (1...7).contains($0) })
            return .weekly(weekdays: set.isEmpty ? [cal.component(.weekday, from: start)] : set, every: n)
        case .monthly:
            return .monthly(day: cal.component(.day, from: start), every: n)
        default:
            return .everyDays(1)
        }
    }

    static func recurrence(for med: Medication) -> Recurrence {
        recurrence(frequency: med.frequency, interval: med.repeatInterval, weekdays: med.weekdays, start: med.startDate)
    }

    /// The administration times used for a medication.
    static func times(for med: Medication, settings: ScheduleSettings) -> [Int] {
        if !med.customTimes.isEmpty { return Array(Set(med.customTimes)).sorted() }
        return settings.defaultTimes(for: med.frequency)
    }

    /// Scheduled meds always have slots; PRN meds only when reminders are switched on.
    static func producesSlots(_ med: Medication) -> Bool {
        !med.isPRN || med.alarmsEnabled
    }

    static func pattern(for med: Medication, settings: ScheduleSettings) -> Pattern {
        Pattern(times: times(for: med, settings: settings),
                recurrence: med.isPRN ? .everyDays(1) : recurrence(for: med),
                start: med.startDate,
                end: med.endDate,
                producesSlots: producesSlots(med))
    }

    // MARK: Day matching

    static func matches(_ r: Recurrence, day dayStart: Date, start: Date, calendar cal: Calendar = .current) -> Bool {
        let startDay = cal.startOfDay(for: start)
        func days(_ a: Date, _ b: Date) -> Int { cal.dateComponents([.day], from: a, to: b).day ?? 0 }

        switch r {
        case .everyDays(let n):
            guard n > 1 else { return true }
            let diff = days(startDay, dayStart)
            return diff >= 0 && diff % n == 0

        case .weekly(let weekdays, let every):
            guard weekdays.contains(cal.component(.weekday, from: dayStart)) else { return false }
            guard every > 1 else { return true }
            let w0 = cal.dateInterval(of: .weekOfYear, for: startDay)?.start ?? startDay
            let w1 = cal.dateInterval(of: .weekOfYear, for: dayStart)?.start ?? dayStart
            let weeks = Int((Double(days(w0, w1)) / 7).rounded())
            return weeks >= 0 && weeks % every == 0

        case .monthly(let day, let every):
            let c = cal.dateComponents([.year, .month, .day], from: dayStart)
            let s = cal.dateComponents([.year, .month], from: startDay)
            guard let y = c.year, let m = c.month, let d = c.day, let sy = s.year, let sm = s.month else { return false }
            let months = (y - sy) * 12 + (m - sm)
            guard months >= 0, months % max(1, every) == 0 else { return false }
            let daysInMonth = cal.range(of: .day, in: .month, for: dayStart)?.count ?? 31
            return d == min(day, daysInMonth)
        }
    }

    // MARK: Slots

    static func slots(_ p: Pattern, on day: Date, calendar cal: Calendar = .current) -> [Date] {
        guard p.producesSlots, !p.times.isEmpty else { return [] }
        let dayStart = cal.startOfDay(for: day)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let start = p.start.floorMinute
        if dayEnd <= start { return [] }
        if let end = p.end, end < dayStart { return [] }
        guard matches(p.recurrence, day: dayStart, start: p.start, calendar: cal) else { return [] }
        return p.times.compactMap { m in
            cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: dayStart)
        }
        .filter { slot in slot >= start && slot < dayEnd && (p.end.map { end in slot <= end } ?? true) }
    }

    /// All slots in [from, to).
    static func slots(_ p: Pattern, from: Date, to: Date, calendar cal: Calendar = .current) -> [Date] {
        guard p.producesSlots, from < to else { return [] }
        var out: [Date] = []
        var day = cal.startOfDay(for: max(from, p.start))
        var guardCount = 0
        while day < to && guardCount < 4000 {
            if let end = p.end, day > end { break }
            out += slots(p, on: day, calendar: cal).filter { $0 >= from && $0 < to }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            guardCount += 1
        }
        return out
    }

    static func slots(for med: Medication, from: Date, to: Date, settings: ScheduleSettings) -> [Date] {
        slots(pattern(for: med, settings: settings), from: from, to: to)
    }

    static func slots(for med: Medication, on day: Date, settings: ScheduleSettings) -> [Date] {
        slots(pattern(for: med, settings: settings), on: day)
    }

    /// When a PRN (or any) medication may next be given, based on its minimum interval.
    static func nextAllowed(for med: Medication) -> Date? {
        guard let hours = med.frequency.intervalHours,
              let last = med.takenRecords.last?.takenAt else { return nil }
        return last.addingTimeInterval(hours * 3600)
    }

    // MARK: Descriptions

    /// Weekdays ordered by the user's calendar (Mon-first or Sun-first).
    static func orderedWeekdays(_ cal: Calendar = .current) -> [Int] {
        (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 + 1 }
    }

    static func ordinal(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// "Weekly on Mon, Thu", "Every 2 weeks on Sun", "Every 3 days", "Monthly on the 15th", "Twice daily".
    static func describe(frequency: Frequency, interval: Int, weekdays: [Int], start: Date,
                         calendar cal: Calendar = .current) -> String {
        switch recurrence(frequency: frequency, interval: interval, weekdays: weekdays, start: start, calendar: cal) {
        case .everyDays(let n) where frequency.hasRepeatInterval || frequency == .q48h:
            return n == 2 ? "Every other day" : "Every \(n) days"
        case .weekly(let set, let every):
            let symbols = cal.shortWeekdaySymbols
            let names = orderedWeekdays(cal).filter(set.contains).map { symbols[$0 - 1] }
            let list = set.count == 7 ? "every day" : names.joined(separator: ", ")
            return every == 1 ? "Weekly on \(list)" : "Every \(every) weeks on \(list)"
        case .monthly(let day, let every):
            return every == 1 ? "Monthly on the \(ordinal(day))" : "Every \(every) months on the \(ordinal(day))"
        default:
            return frequency.label
        }
    }

    static func describe(_ med: Medication) -> String {
        describe(frequency: med.frequency, interval: med.repeatInterval, weekdays: med.weekdays, start: med.startDate)
    }

    /// Compact code for lists: "BID", "Q3D", "Weekly", "Q2W", "Monthly", "Q3M".
    static func shortCode(_ med: Medication) -> String {
        if med.isPRN { return "PRN" }
        let n = max(1, med.repeatInterval)
        switch med.frequency {
        case .everyNDays: return "Q\(max(2, n))D"
        case .weekly: return n == 1 ? "Weekly" : "Q\(n)W"
        case .monthly: return n == 1 ? "Monthly" : "Q\(n)M"
        default: return med.frequency.abbreviation
        }
    }
}
