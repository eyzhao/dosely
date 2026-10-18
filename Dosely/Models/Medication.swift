import Foundation
import SwiftData

// MARK: - Enumerations

enum Route: String, CaseIterable, Codable, Identifiable {
    case oral, sublingual, buccal, inhaled, nasal, topical, transdermal, ophthalmic, otic
    case subcutaneous, intramuscular, intravenous, rectal, vaginal, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oral: "Oral"
        case .sublingual: "Sublingual"
        case .buccal: "Buccal"
        case .inhaled: "Inhaled"
        case .nasal: "Nasal"
        case .topical: "Topical"
        case .transdermal: "Transdermal"
        case .ophthalmic: "Eye"
        case .otic: "Ear"
        case .subcutaneous: "Subcutaneous"
        case .intramuscular: "Intramuscular"
        case .intravenous: "Intravenous"
        case .rectal: "Rectal"
        case .vaginal: "Vaginal"
        case .other: "Other"
        }
    }

    var abbreviation: String {
        switch self {
        case .oral: "PO"
        case .sublingual: "SL"
        case .buccal: "BUC"
        case .inhaled: "INH"
        case .nasal: "IN"
        case .topical: "TOP"
        case .transdermal: "TD"
        case .ophthalmic: "OPH"
        case .otic: "OT"
        case .subcutaneous: "SC"
        case .intramuscular: "IM"
        case .intravenous: "IV"
        case .rectal: "PR"
        case .vaginal: "PV"
        case .other: "Other"
        }
    }
}

enum Frequency: String, CaseIterable, Codable, Identifiable {
    case daily, bid, tid, qid, q4h, q6h, q8h, q12h, qhs, q48h, everyNDays, weekly, monthly, asNeeded

    var id: String { rawValue }

    /// Every frequency that produces a regular schedule.
    static var scheduled: [Frequency] { allCases.filter { $0 != .asNeeded } }

    /// Sensible "maximum frequency" choices for PRN medications.
    static let prnOptions: [Frequency] = [.asNeeded, .q4h, .q6h, .q8h, .q12h, .qid, .tid, .bid, .daily]

    /// Schedules measured in days, weeks or months rather than hours.
    var isLongInterval: Bool { [.q48h, .everyNDays, .weekly, .monthly].contains(self) }

    /// Whether the schedule has a user-chosen repeat count (every N days / weeks / months).
    var hasRepeatInterval: Bool { [.everyNDays, .weekly, .monthly].contains(self) }

    var label: String {
        switch self {
        case .daily: "Once daily"
        case .bid: "Twice daily"
        case .tid: "Three times daily"
        case .qid: "Four times daily"
        case .q4h: "Every 4 hours"
        case .q6h: "Every 6 hours"
        case .q8h: "Every 8 hours"
        case .q12h: "Every 12 hours"
        case .qhs: "At bedtime"
        case .q48h: "Every other day"
        case .everyNDays: "Every few days"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .asNeeded: "As needed"
        }
    }

    var abbreviation: String {
        switch self {
        case .daily: "QD"
        case .bid: "BID"
        case .tid: "TID"
        case .qid: "QID"
        case .q4h: "Q4H"
        case .q6h: "Q6H"
        case .q8h: "Q8H"
        case .q12h: "Q12H"
        case .qhs: "QHS"
        case .q48h: "QOD"
        case .everyNDays: "QnD"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .asNeeded: "PRN"
        }
    }

    /// Minimum spacing between doses — used for PRN "next dose allowed" guidance.
    var intervalHours: Double? {
        switch self {
        case .daily, .qhs: 24
        case .bid, .q12h: 12
        case .tid, .q8h: 8
        case .qid, .q6h: 6
        case .q4h: 4
        case .q48h: 48
        case .weekly: 168
        case .everyNDays, .monthly, .asNeeded: nil
        }
    }

}

enum AlertStyle: String, CaseIterable, Codable, Identifiable {
    case automatic, sound, vibrate
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "App default"
        case .sound: "System sound"
        case .vibrate: "Vibrate only"
        }
    }
}

enum DoseStatus: String, Codable {
    /// Given. `skipped` = deliberately not given. `missed` = should have been given but wasn't.
    case taken, skipped, missed
}

// MARK: - Models

@Model
final class Medication {
    var id: UUID = UUID()
    var name: String = ""
    var dose: String = ""
    var routeRaw: String = Route.oral.rawValue
    var frequencyRaw: String = Frequency.daily.rawValue
    var isPRN: Bool = false
    var indication: String = ""
    var notes: String = ""
    /// Minutes after midnight. Empty means "follow the global defaults for this frequency".
    var customTimes: [Int] = []
    /// Every N days / weeks / months for `.everyNDays`, `.weekly` and `.monthly`.
    var repeatInterval: Int = 1
    /// Calendar weekdays (1 = Sunday … 7 = Saturday) for `.weekly`. Empty = weekday of the first dose.
    var weekdays: [Int] = []
    var startDate: Date = Date()
    /// Time of the last administration (inclusive). Nil = ongoing.
    var endDate: Date?
    var alarmsEnabled: Bool = true
    var alertStyleRaw: String = AlertStyle.automatic.rawValue
    @Attribute(.externalStorage) var photoData: Data?
    var isArchived: Bool = false
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \DoseRecord.medication)
    var doses: [DoseRecord]? = []

    init(name: String = "",
         dose: String = "",
         route: Route = .oral,
         frequency: Frequency = .daily,
         isPRN: Bool = false,
         indication: String = "",
         startDate: Date = Calendar.current.startOfDay(for: .now),
         endDate: Date? = nil) {
        self.id = UUID()
        self.name = name
        self.dose = dose
        self.routeRaw = route.rawValue
        self.frequencyRaw = frequency.rawValue
        self.isPRN = isPRN
        self.indication = indication
        self.startDate = startDate
        self.endDate = endDate
        self.alarmsEnabled = !isPRN
        self.createdAt = .now
        self.updatedAt = .now
    }

    var route: Route {
        get { Route(rawValue: routeRaw) ?? .other }
        set { routeRaw = newValue.rawValue }
    }

    var frequency: Frequency {
        get { Frequency(rawValue: frequencyRaw) ?? .daily }
        set { frequencyRaw = newValue.rawValue }
    }

    var alertStyle: AlertStyle {
        get { AlertStyle(rawValue: alertStyleRaw) ?? .automatic }
        set { alertStyleRaw = newValue.rawValue }
    }

    /// "500 mg · Oral"
    var doseLine: String {
        [dose.trimmingCharacters(in: .whitespaces), route.label]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// "Amoxicillin 500 mg"
    var title: String {
        let d = dose.trimmingCharacters(in: .whitespaces)
        return d.isEmpty ? name : "\(name) \(d)"
    }

    func isCompleted(at now: Date) -> Bool {
        guard let endDate else { return false }
        return endDate < now
    }

    var takenRecords: [DoseRecord] {
        (doses ?? []).filter { $0.status == .taken }.sorted { $0.takenAt < $1.takenAt }
    }
}

@Model
final class DoseRecord {
    var id: UUID = UUID()
    /// The slot this record answers. Nil for unscheduled doses (PRN or extra).
    var scheduledTime: Date?
    var takenAt: Date = Date()
    var statusRaw: String = DoseStatus.taken.rawValue
    var note: String = ""
    var medication: Medication?

    init(scheduledTime: Date?, takenAt: Date, status: DoseStatus, note: String = "") {
        self.id = UUID()
        self.scheduledTime = scheduledTime
        self.takenAt = takenAt
        self.statusRaw = status.rawValue
        self.note = note
    }

    var status: DoseStatus {
        get { DoseStatus(rawValue: statusRaw) ?? .taken }
        set { statusRaw = newValue.rawValue }
    }

    /// The moment this record is charted against in the grid.
    var chartTime: Date { scheduledTime ?? takenAt }
}
