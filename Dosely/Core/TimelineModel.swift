import SwiftUI
import Observation

/// One day of the grid: its columns are the union of every medication's slot times
/// (plus any off-schedule records) on that day.
struct DayLayout: Identifiable {
    let index: Int
    let date: Date
    let columns: [Int]                          // minute keys, ascending
    let scheduled: [UUID: Set<Int>]             // med → slot minute keys
    let records: [UUID: [Int: DoseRecord]]      // med → chart minute → record
    let x: CGFloat
    let width: CGFloat
    var id: Int { index }
    var isToday: Bool { Calendar.current.isDateInToday(date) }
}

/// Virtualised, deterministic layout of the infinite timeline.
/// Days have exact x positions so the pinned header and the grid always agree,
/// and only days near the viewport are ever rendered.
@MainActor
@Observable
final class TimelineModel {
    private(set) var days: [DayLayout] = []
    private(set) var totalWidth: CGFloat = 0
    private(set) var visibleRange: Range<Int> = 0..<0

    var scrollX: CGFloat = 0
    var viewportWidth: CGFloat = 260

    @ObservationIgnored private(set) var firstDay = Calendar.current.startOfDay(for: .now)

    // MARK: Build

    /// Rebuilds the layout. Returns a corrected scroll offset when content before the
    /// viewport changed width, so the view doesn't jump.
    @discardableResult
    func rebuild(meds: [Medication], settings: ScheduleSettings, now: Date) -> CGFloat? {
        let cal = Calendar.current

        var anchor: (date: Date, offset: CGFloat)?
        if !days.isEmpty, let i = index(atX: scrollX) {
            anchor = (days[i].date, scrollX - days[i].x)
        }

        let today = cal.startOfDay(for: now)
        var first = cal.date(byAdding: .day, value: -30, to: today)!
        var last = cal.date(byAdding: .day, value: 365, to: today)!
        for med in meds {
            if let d = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: med.startDate)), d < first { first = d }
            if let e = med.endDate, let d = cal.date(byAdding: .day, value: 30, to: cal.startOfDay(for: e)), d > last { last = d }
            for r in med.doses ?? [] {
                let d = cal.startOfDay(for: r.chartTime)
                if d < first { first = d }
            }
        }
        // Keep it practically infinite but bounded (~11 years back, ~3 years forward).
        first = max(first, cal.date(byAdding: .day, value: -4000, to: today)!)
        last = min(last, cal.date(byAdding: .day, value: 1100, to: today)!)
        let count = max(1, (cal.dateComponents([.day], from: first, to: last).day ?? 0) + 1)

        // Records grouped by med → day index → chart minute.
        var records: [UUID: [Int: [Int: DoseRecord]]] = [:]
        for med in meds {
            for r in med.doses ?? [] {
                let ref = r.chartTime
                let di = cal.dateComponents([.day], from: first, to: cal.startOfDay(for: ref)).day ?? -1
                guard di >= 0 && di < count else { continue }
                records[med.id, default: [:]][di, default: [:]][ref.minuteKey] = r
            }
        }

        let patterns = meds.map { ($0.id, ScheduleEngine.pattern(for: $0, settings: settings)) }

        var newDays: [DayLayout] = []
        newDays.reserveCapacity(count)
        var x: CGFloat = 0
        var day = first
        for i in 0..<count {
            var cols = Set<Int>()
            var scheduled: [UUID: Set<Int>] = [:]
            var dayRecords: [UUID: [Int: DoseRecord]] = [:]
            for (id, p) in patterns {
                let keys = ScheduleEngine.slots(p, on: day, calendar: cal).map(\.minuteKey)
                if !keys.isEmpty {
                    scheduled[id] = Set(keys)
                    cols.formUnion(keys)
                }
                if let r = records[id]?[i] {
                    dayRecords[id] = r
                    cols.formUnion(r.keys)
                }
            }
            let sorted = cols.sorted()
            let width = max(MAR.minDayWidth, CGFloat(sorted.count) * MAR.columnWidth + MAR.dayPadding * 2)
            newDays.append(DayLayout(index: i, date: day, columns: sorted, scheduled: scheduled,
                                     records: dayRecords, x: x, width: width))
            x += width
            day = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }

        days = newDays
        totalWidth = x
        firstDay = first
        updateVisible()

        if let anchor, let i = dayIndex(for: anchor.date) {
            let newX = days[i].x + min(anchor.offset, days[i].width)
            if abs(newX - scrollX) > 0.5 { return newX }
        }
        return nil
    }

    // MARK: Scrolling

    func updateScroll(x: CGFloat, viewport: CGFloat) {
        if scrollX != x { scrollX = x }
        if viewport > 0, viewportWidth != viewport { viewportWidth = viewport }
        updateVisible()
    }

    private func updateVisible() {
        guard !days.isEmpty else {
            if !visibleRange.isEmpty { visibleRange = 0..<0 }
            return
        }
        let lo = index(atX: scrollX - viewportWidth) ?? 0
        let hi = (index(atX: scrollX + viewportWidth * 2) ?? days.count - 1) + 1
        let range = max(0, lo)..<min(days.count, hi)
        if range != visibleRange { visibleRange = range }
    }

    // MARK: Lookups

    func index(atX x: CGFloat) -> Int? {
        guard !days.isEmpty else { return nil }
        if x <= 0 { return 0 }
        if x >= totalWidth { return days.count - 1 }
        var lo = 0, hi = days.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if days[mid].x <= x { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func dayIndex(for date: Date) -> Int? {
        let cal = Calendar.current
        let d = cal.dateComponents([.day], from: firstDay, to: cal.startOfDay(for: date)).day ?? -1
        return (d >= 0 && d < days.count) ? d : nil
    }

    /// x position of the "now" line: between the last past column and the next one.
    func nowX(_ now: Date) -> CGFloat? {
        guard let i = dayIndex(for: now) else { return nil }
        let d = days[i]
        if d.columns.isEmpty {
            let start = Calendar.current.startOfDay(for: now)
            return d.x + d.width * CGFloat(now.timeIntervalSince(start) / 86_400)
        }
        let key = now.minuteKey
        let k = d.columns.firstIndex { $0 > key } ?? d.columns.count
        return d.x + MAR.dayPadding + CGFloat(k) * MAR.columnWidth
    }

    /// Scroll offset that centres "now" in the viewport.
    func centeredOffset(for now: Date) -> CGFloat {
        guard let x = nowX(now) else { return scrollX }
        let maxX = max(0, totalWidth - viewportWidth)
        return min(max(0, x - viewportWidth / 2), maxX)
    }
}

/// Today's at-a-glance numbers for the header.
struct TodayStats {
    /// `missed` = charted as missed; `overdue` = more than an hour late and not charted yet.
    var total = 0, taken = 0, skipped = 0, missed = 0, overdue = 0
    var resolved: Int { taken + skipped + missed }
    var dueNow: [Medication] = []
    var next: (med: Medication, time: Date)?

    @MainActor
    init(meds: [Medication], settings: ScheduleSettings, now: Date) {
        var upcoming: [(Medication, Date)] = []
        for med in meds where !med.isPRN && !med.isArchived {
            let p = ScheduleEngine.pattern(for: med, settings: settings)
            for slot in ScheduleEngine.slots(p, on: now) {
                total += 1
                if let r = DoseActions.record(for: med, slot: slot) {
                    switch r.status {
                    case .taken: taken += 1
                    case .skipped: skipped += 1
                    case .missed: missed += 1
                    }
                } else {
                    let diff = slot.timeIntervalSince(now)
                    if diff < -3600 { overdue += 1 }
                    else if diff <= 1800 { if !dueNow.contains(where: { $0 === med }) { dueNow.append(med) } }
                }
            }
            let ahead = ScheduleEngine.slots(p, from: now.addingTimeInterval(1800), to: now.addingTimeInterval(62 * 86_400))
            if let s = ahead.first(where: { DoseActions.record(for: med, slot: $0) == nil }) {
                upcoming.append((med, s))
            }
        }
        if let n = upcoming.min(by: { $0.1 < $1.1 }) { next = (n.0, n.1) }
    }
}
