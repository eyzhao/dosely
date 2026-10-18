import Foundation
import SwiftData

/// A gentle demo so the grid can be explored before entering real medications.
@MainActor
enum SampleData {
    static func insert(into context: ModelContext, settings: ScheduleSettings) {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: today)!

        let amox = Medication(name: "Amoxicillin", dose: "500 mg", route: .oral, frequency: .tid,
                              indication: "Sinus infection", startDate: twoDaysAgo)
        let lastDay = cal.date(byAdding: .day, value: 6, to: twoDaysAgo)!
        amox.endDate = cal.date(bySettingHour: settings.bedtimeMinutes / 60,
                                minute: settings.bedtimeMinutes % 60, second: 0, of: lastDay)

        let metformin = Medication(name: "Metformin", dose: "500 mg", route: .oral, frequency: .bid,
                                   indication: "Type 2 diabetes",
                                   startDate: cal.date(byAdding: .day, value: -30, to: today)!)
        metformin.notes = "Take with food."

        let atorva = Medication(name: "Atorvastatin", dose: "20 mg", route: .oral, frequency: .qhs,
                                indication: "Cholesterol",
                                startDate: cal.date(byAdding: .day, value: -60, to: today)!)

        let vitD = Medication(name: "Vitamin D3", dose: "1000 IU", route: .oral, frequency: .daily,
                              indication: "Supplement",
                              startDate: cal.date(byAdding: .day, value: -60, to: today)!)

        let alendronate = Medication(name: "Alendronate", dose: "70 mg", route: .oral, frequency: .weekly,
                                     indication: "Bone density",
                                     startDate: cal.date(byAdding: .day, value: -60, to: today)!)
        alendronate.weekdays = [cal.component(.weekday, from: cal.date(byAdding: .day, value: -2, to: today)!)]
        alendronate.customTimes = [7 * 60]
        alendronate.notes = "Take with a full glass of water, 30 min before food. Stay upright."

        let ibuprofen = Medication(name: "Ibuprofen", dose: "400 mg", route: .oral, frequency: .q6h,
                                   isPRN: true, indication: "Pain or fever")

        let meds = [amox, metformin, atorva, vitD, alendronate, ibuprofen]
        for (i, m) in meds.enumerated() {
            m.sortOrder = i
            m.alarmsEnabled = false   // demo data never rings
            context.insert(m)
        }

        // Chart the last two days: mostly taken, one missed, one skipped.
        let from = cal.date(byAdding: .day, value: -2, to: today)!
        for med in [amox, metformin, atorva, vitD, alendronate] {
            let slots = ScheduleEngine.slots(for: med, from: from, to: now.addingTimeInterval(-3600), settings: settings)
            for (i, slot) in slots.enumerated() {
                if med === amox && i == 2 { continue }                 // a missed dose
                let status: DoseStatus = (med === vitD && i == 1) ? .skipped : .taken
                let jitter = TimeInterval(Int.random(in: -8...25) * 60)
                let r = DoseRecord(scheduledTime: slot, takenAt: slot.addingTimeInterval(jitter), status: status)
                context.insert(r)
                r.medication = med
            }
        }
        let prn = DoseRecord(scheduledTime: nil,
                             takenAt: cal.date(byAdding: .hour, value: -20, to: now)!.floorMinute,
                             status: .taken, note: "Headache")
        context.insert(prn)
        prn.medication = ibuprofen

        try? context.save()
    }
}
