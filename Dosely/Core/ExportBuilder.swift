import Foundation

/// Builds a plain-text administration record that reads well in Mail, Messages or Notes.
@MainActor
enum ExportBuilder {

    struct Options {
        var start: Date
        var end: Date
        var includeList = true
        var includeLog = true
        var includeSummary = true
        var medicationIDs: Set<UUID> = []     // empty = all
        var filter = ""
    }

    private struct Entry {
        let time: Date
        let med: Medication
        let status: String
        let note: String
    }

    static func build(meds allMeds: [Medication], settings: ScheduleSettings, options o: Options, now: Date) -> String {
        let meds = allMeds
            .filter { o.medicationIDs.isEmpty || o.medicationIDs.contains($0.id) }
            .sorted { ($0.isArchived ? 1 : 0, $0.sortOrder) < ($1.isArchived ? 1 : 0, $1.sortOrder) }
        let logEnd = min(o.end, now)
        let filter = o.filter.trimmingCharacters(in: .whitespaces).lowercased()

        var lines: [String] = []
        lines.append("MEDICATION ADMINISTRATION RECORD")
        lines.append("Period: \(o.start.formatted(date: .abbreviated, time: .omitted)) – \(o.end.formatted(date: .abbreviated, time: .omitted))")
        lines.append("Generated \(now.formatted(date: .abbreviated, time: .shortened))")

        if o.includeList {
            lines.append("")
            lines.append("MEDICATIONS")
            for (i, m) in meds.enumerated() {
                var title = "\(i + 1). \(m.title)"
                if m.route != .other { title += " \(m.route.abbreviation)" }
                if m.isArchived { title += " (archived)" }
                lines.append(title)
                lines.append("   \(scheduleText(m, settings: settings))")
                if !m.indication.isEmpty { lines.append("   For: \(m.indication)") }
                var course = "   Started \(m.startDate.formatted(date: .abbreviated, time: .omitted))"
                if let end = m.endDate {
                    course += end < now ? " · finished " : " · last dose "
                    course += end.formatted(date: .abbreviated, time: .shortened)
                }
                lines.append(course)
                if !m.notes.isEmpty { lines.append("   Notes: \(m.notes)") }
            }
        }

        var entries: [Entry] = []
        var summary: [(Medication, taken: Int, scheduled: Int, missed: Int, uncharted: Int, prn: Int)] = []

        if (o.includeLog || o.includeSummary) && o.start < logEnd {
            for m in meds {
                let slots = m.isPRN ? [] : ScheduleEngine.slots(for: m, from: o.start, to: logEnd, settings: settings)
                let slotKeys = Set(slots.map(\.minuteKey))
                var taken = 0, missed = 0, uncharted = 0, prn = 0
                for s in slots {
                    if let r = DoseActions.record(for: m, slot: s) {
                        if r.status == .missed {
                            missed += 1
                            entries.append(Entry(time: s, med: m, status: "✗ missed", note: r.note))
                        } else if r.status == .taken {
                            taken += 1
                            let delta = r.takenAt.timeIntervalSince(s)
                            let when = abs(delta) >= 30 * 60 ? " at \(Fmt.time(r.takenAt)) (\(Fmt.offset(delta)))" : " at \(Fmt.time(r.takenAt))"
                            entries.append(Entry(time: s, med: m, status: "✓ given\(when)", note: r.note))
                        } else {
                            entries.append(Entry(time: s, med: m, status: "– skipped", note: r.note))
                        }
                    } else if s < now.addingTimeInterval(-3600) {
                        uncharted += 1
                        entries.append(Entry(time: s, med: m, status: "? not charted", note: ""))
                    } else {
                        entries.append(Entry(time: s, med: m, status: "○ due", note: ""))
                    }
                }
                for r in m.doses ?? [] where r.chartTime >= o.start && r.chartTime < logEnd {
                    if let s = r.scheduledTime, slotKeys.contains(s.minuteKey) { continue }
                    let label = m.isPRN ? "PRN" : "extra dose"
                    if r.status == .taken {
                        prn += 1
                        entries.append(Entry(time: r.takenAt, med: m, status: "✓ given (\(label))", note: r.note))
                    } else {
                        let word = r.status == .missed ? "✗ missed" : "– skipped"
                        entries.append(Entry(time: r.chartTime, med: m, status: "\(word) (\(label))", note: r.note))
                    }
                }
                summary.append((m, taken, slots.filter { $0 < now.addingTimeInterval(-3600) || DoseActions.record(for: m, slot: $0) != nil }.count, missed, uncharted, prn))
            }
        }

        if o.includeLog {
            lines.append("")
            lines.append("ADMINISTRATION LOG")
            let filtered = entries.filter { e in
                guard !filter.isEmpty else { return true }
                return [e.med.name, e.med.indication, e.status, e.note].joined(separator: " ").lowercased().contains(filter)
            }
            .sorted { $0.time < $1.time }
            if filtered.isEmpty {
                lines.append("No administrations in this period.")
            }
            let cal = Calendar.current
            var currentDay: Date?
            for e in filtered {
                let day = cal.startOfDay(for: e.time)
                if day != currentDay {
                    currentDay = day
                    lines.append("")
                    lines.append(e.time.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                }
                var line = "  \(Fmt.time(e.time))  \(e.med.title) — \(e.status)"
                if !e.note.isEmpty { line += " · “\(e.note)”" }
                lines.append(line)
            }
        }

        if o.includeSummary && !summary.isEmpty {
            lines.append("")
            lines.append("SUMMARY")
            for s in summary {
                if s.0.isPRN {
                    lines.append("  \(s.0.name): \(s.prn) as-needed \(s.prn == 1 ? "dose" : "doses")")
                } else if s.scheduled > 0 {
                    let pct = Int((Double(s.taken) / Double(s.scheduled) * 100).rounded())
                    var line = "  \(s.0.name): \(s.taken)/\(s.scheduled) given (\(pct)%)"
                    if s.missed > 0 { line += ", \(s.missed) missed" }
                    if s.uncharted > 0 { line += ", \(s.uncharted) not charted" }
                    if s.prn > 0 { line += ", \(s.prn) extra" }
                    lines.append(line)
                }
            }
        }

        lines.append("")
        lines.append("— Exported from Dosely")
        return lines.joined(separator: "\n")
    }

    static func scheduleText(_ m: Medication, settings: ScheduleSettings) -> String {
        let times = ScheduleEngine.times(for: m, settings: settings)
        if m.isPRN {
            var s = "As needed (PRN)"
            if m.frequency != .asNeeded { s += ", no more than \(m.frequency.label.lowercased())" }
            if m.alarmsEnabled && !times.isEmpty { s += "; reminders at \(Fmt.times(times, separator: ", "))" }
            return s
        }
        let what = m.frequency.hasRepeatInterval
            ? ScheduleEngine.describe(m)
            : "\(ScheduleEngine.describe(m)) (\(m.frequency.abbreviation))"
        return "\(what) at \(Fmt.times(times, separator: ", "))"
    }
}
