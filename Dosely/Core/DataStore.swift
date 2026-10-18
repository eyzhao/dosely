import Foundation
import SwiftData
import Observation

/// One container shared by the app UI and the alarm "Taken" intent.
@MainActor
final class DataStore {
    static let shared = DataStore()
    let container: ModelContainer

    private init() {
        do {
            container = try ModelContainer(for: Medication.self, DoseRecord.self)
        } catch {
            fatalError("Could not open the medication store: \(error)")
        }
    }
}

/// A coarse clock the UI listens to (updated every 30 s and on foreground).
@MainActor
@Observable
final class Clock {
    var now = Date()
}

/// All mutations of dose records go through here so alarms stay in sync.
@MainActor
enum DoseActions {

    static func record(for med: Medication, slot: Date) -> DoseRecord? {
        let key = slot.minuteKey
        return med.doses?.first { $0.scheduledTime?.minuteKey == key }
    }

    /// Real time if the dose is being charted around now; otherwise the scheduled time (back-charting).
    static func defaultTakenTime(slot: Date, now: Date) -> Date {
        (slot > now.addingTimeInterval(-6 * 3600) && slot < now.addingTimeInterval(2 * 3600)) ? now : slot
    }

    /// Sets (or clears, when `status` is nil) the record for a slot or an unscheduled dose.
    @discardableResult
    static func set(_ status: DoseStatus?,
                    med: Medication,
                    slot: Date?,
                    existing: DoseRecord?,
                    takenAt: Date,
                    note: String? = nil,
                    context: ModelContext) -> DoseRecord? {
        guard let status else {
            if let existing { context.delete(existing) }
            commit(context)
            return nil
        }
        let record: DoseRecord
        if let existing {
            record = existing
        } else {
            record = DoseRecord(scheduledTime: slot?.floorMinute, takenAt: takenAt, status: status)
            context.insert(record)
            record.medication = med
        }
        record.status = status
        record.takenAt = takenAt
        if let note { record.note = note }
        commit(context)
        return record
    }

    @discardableResult
    static func logNow(_ med: Medication, at date: Date = .now, context: ModelContext) -> DoseRecord? {
        set(.taken, med: med, slot: nil, existing: nil, takenAt: date, context: context)
    }

    static func markTakenFromAlarm(_ doses: [DoseRef], context: ModelContext) {
        let meds = (try? context.fetch(FetchDescriptor<Medication>())) ?? []
        let byID = Dictionary(meds.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for dose in doses {
            guard let med = byID[dose.medicationID], record(for: med, slot: dose.slot) == nil else { continue }
            let r = DoseRecord(scheduledTime: dose.slot, takenAt: .now, status: .taken)
            context.insert(r)
            r.medication = med
        }
        commit(context)
    }

    /// Saves and resyncs alarms. Pass `scheduleChanged: true` whenever dose *times* may have changed
    /// (adding, editing, archiving or deleting a medication) to rebuild every alarm from scratch.
    static func commit(_ context: ModelContext, scheduleChanged: Bool = false) {
        try? context.save()
        AlarmScheduler.shared.requestSync(full: scheduleChanged)
    }
}
