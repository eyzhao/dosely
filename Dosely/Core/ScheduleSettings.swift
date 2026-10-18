import Foundation
import Observation

/// Global scheduling preferences. Every regular frequency converges on `anchorMinutes`.
struct ScheduleSettings: Codable, Hashable {
    /// The convergence point, minutes after midnight (default 09:00).
    var anchorMinutes: Int = 9 * 60
    /// End of the waking day, used for QHS and for spreading TID/QID (default 21:00).
    var bedtimeMinutes: Int = 21 * 60
    /// Spread TID/QID between the convergence time and bedtime instead of around the clock.
    var spreadOverWakingDay: Bool = true
    /// Manual per-frequency overrides, keyed by Frequency.rawValue.
    var overrides: [String: [Int]] = [:]
    var alarmsEnabled: Bool = true
    /// Global alarm style: `.sound` or `.vibrate`.
    var alertStyle: AlertStyle = .sound
    var showCompleted: Bool = true
    /// Doses due within this many minutes of each other share one alarm (0 = exact same time only).
    var alarmMergeMinutes: Int = 0
    /// Keep re-alarming a dose that hasn't been checked off.
    var repeatUntilCharted: Bool = true
    /// Minutes between repeats (and after tapping Dismiss).
    var repeatIntervalMinutes: Int = 20

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScheduleSettings()
        anchorMinutes = try c.decodeIfPresent(Int.self, forKey: .anchorMinutes) ?? d.anchorMinutes
        bedtimeMinutes = try c.decodeIfPresent(Int.self, forKey: .bedtimeMinutes) ?? d.bedtimeMinutes
        spreadOverWakingDay = try c.decodeIfPresent(Bool.self, forKey: .spreadOverWakingDay) ?? d.spreadOverWakingDay
        overrides = try c.decodeIfPresent([String: [Int]].self, forKey: .overrides) ?? d.overrides
        alarmsEnabled = try c.decodeIfPresent(Bool.self, forKey: .alarmsEnabled) ?? d.alarmsEnabled
        alertStyle = try c.decodeIfPresent(AlertStyle.self, forKey: .alertStyle) ?? d.alertStyle
        showCompleted = try c.decodeIfPresent(Bool.self, forKey: .showCompleted) ?? d.showCompleted
        alarmMergeMinutes = try c.decodeIfPresent(Int.self, forKey: .alarmMergeMinutes) ?? d.alarmMergeMinutes
        repeatUntilCharted = try c.decodeIfPresent(Bool.self, forKey: .repeatUntilCharted) ?? d.repeatUntilCharted
        repeatIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .repeatIntervalMinutes) ?? d.repeatIntervalMinutes
    }

    /// Times derived purely from the convergence point and bedtime.
    func computedTimes(for frequency: Frequency) -> [Int] {
        let a = anchorMinutes
        func norm(_ m: Int) -> Int { ((m % 1440) + 1440) % 1440 }
        func every(_ hours: Int) -> [Int] {
            stride(from: 0, to: 1440, by: hours * 60).map { norm(a + $0) }
        }
        var span = norm(bedtimeMinutes - a)
        if span == 0 { span = 1440 }
        func spread(_ n: Int) -> [Int] {
            (0..<n).map { i in
                let raw = Double(span) * Double(i) / Double(n - 1)
                return norm(a + Int((raw / 30).rounded()) * 30)
            }
        }

        let result: [Int]
        switch frequency {
        case .daily, .q48h, .everyNDays, .weekly, .monthly: result = [a]
        case .bid, .q12h: result = every(12)
        case .q8h: result = every(8)
        case .q6h: result = every(6)
        case .q4h: result = every(4)
        case .tid: result = (spreadOverWakingDay && span >= 360 && span < 1440) ? spread(3) : every(8)
        case .qid: result = (spreadOverWakingDay && span >= 480 && span < 1440) ? spread(4) : every(6)
        case .qhs: result = [norm(bedtimeMinutes)]
        case .asNeeded: result = []
        }
        return Array(Set(result)).sorted()
    }

    /// Effective default times for a frequency (manual override if set).
    func defaultTimes(for frequency: Frequency) -> [Int] {
        if let o = overrides[frequency.rawValue], !o.isEmpty { return Array(Set(o)).sorted() }
        return computedTimes(for: frequency)
    }

    func isOverridden(_ frequency: Frequency) -> Bool {
        !(overrides[frequency.rawValue] ?? []).isEmpty
    }
}

@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()
    private static let key = "dosely.settings.v1"

    var settings: ScheduleSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
            // Any settings change can move dose times: rebuild every alarm.
            AlarmScheduler.shared.requestSync(full: true)
        }
    }

    private init() {
        settings = Self.load()
    }

    static func load() -> ScheduleSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(ScheduleSettings.self, from: data) else {
            return ScheduleSettings()
        }
        return s
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
