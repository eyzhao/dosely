import Foundation
import SwiftUI
import SwiftData
import AlarmKit
import ActivityKit
import AppIntents
import CryptoKit
import BackgroundTasks
import Observation

/// Metadata attached to every Dosely alarm.
struct DoseAlarmMetadata: AlarmMetadata {
    var scheduledTime: Date
    var medicationIDs: [UUID]
}

/// One medication dose that an alarm stands for.
struct DoseRef: Hashable {
    var medicationID: UUID
    var slot: Date

    /// "UUID@minuteKey" — compact, stable encoding for the alarm's intent.
    var token: String { "\(medicationID.uuidString)@\(slot.minuteKey)" }

    init(medicationID: UUID, slot: Date) {
        self.medicationID = medicationID
        self.slot = slot.floorMinute
    }

    init?(token: Substring) {
        let parts = token.split(separator: "@")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), let key = Int(parts[1]) else { return nil }
        self.init(medicationID: id, slot: Date(minuteKey: key))
    }

    static func encode(_ refs: [DoseRef]) -> String { refs.map(\.token).joined(separator: ";") }
    static func decode(_ s: String) -> [DoseRef] { s.split(separator: ";").compactMap(DoseRef.init(token:)) }
}

/// A consolidated alarm: every dose due at (or, with a merge window, near) the same time.
struct AlarmGroup {
    var time: Date
    var doses: [DoseRef]
    var title: String
    var playsSound: Bool
    var isRepeat: Bool = false
}

struct AlarmPreview: Identifiable, Hashable {
    var id: UUID
    var time: Date
    var title: String
    var count: Int
    var playsSound: Bool
    var isRepeat: Bool
}

/// Keeps AlarmKit in step with the medication schedule.
///
/// * **Consolidation** — all doses due at the same minute (or within the merge window set in Settings)
///   become a single alarm whose title lists every medication; its "Taken" button charts them all.
/// * **Full rebuild on schedule change** — a fingerprint of everything that determines dose times
///   (medications, times, recurrence, course dates, settings, time zone, app build) is stored with the
///   alarm cache. Whenever it changes, every Dosely alarm is cancelled and the whole window is rescheduled.
///   Charting a dose only changes which doses are outstanding, so it uses a quick diff instead.
/// * **Long schedules** — the window reaches 62 days ahead so weekly and monthly doses are covered, and
///   every medication is guaranteed its next two alarms before frequent doses fill the 60-alarm budget.
@MainActor
@Observable
final class AlarmScheduler {
    static let shared = AlarmScheduler()
    static let refreshTaskID = "com.dosely.app.alarm-refresh"
    static let horizon: TimeInterval = 62 * 24 * 3600
    static let maxAlarms = 60
    static let guaranteedPerMedication = 2
    /// Overdue doses this old (and not checked off) still re-alarm.
    static let repeatLookback: TimeInterval = 35 * 24 * 3600
    /// Every repeat within this window is scheduled up front.
    static let repeatLookahead: TimeInterval = 6 * 3600
    /// Repeats pre-scheduled after every dose, however far ahead, in case Dismiss can't be observed.
    static let backupRepeats = 3
    /// A bundled silent clip: the alarm still vibrates but plays no audible sound.
    static let silentSoundName = "dosely_silent.wav"

    private static let cacheKey = "dosely.alarmCache.v2"
    private static let fingerprintKey = "dosely.alarmFingerprint.v2"
    private static let lastFullKey = "dosely.alarmLastFull.v2"
    private static let snoozeKey = "dosely.alarmSnoozes.v1"

    private(set) var authorization: AlarmManager.AuthorizationState = .notDetermined
    private(set) var scheduledCount = 0
    private(set) var nextAlarm: Date?
    private(set) var upcoming: [AlarmPreview] = []
    private(set) var lastFullRebuild: Date?
    private(set) var lastError: String?

    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var needsResync = false
    @ObservationIgnored private var pendingFull = false

    private init() {
        authorization = AlarmManager.shared.authorizationState
        lastFullRebuild = UserDefaults.standard.object(forKey: Self.lastFullKey) as? Date
    }

    // MARK: Public

    func refreshAuthorization() {
        authorization = AlarmManager.shared.authorizationState
    }

    func requestAuthorization() async {
        do {
            authorization = try await AlarmManager.shared.requestAuthorization()
        } catch {
            lastError = error.localizedDescription
            refreshAuthorization()
        }
        requestSync(full: true, delay: .zero)
    }

    /// Debounced sync — call freely after any change. `full` forces every alarm to be rebuilt.
    func requestSync(full: Bool = false, delay: Duration = .milliseconds(500)) {
        if full { pendingFull = true }
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func sync(full: Bool = false) async {
        if full { pendingFull = true }
        if isSyncing { needsResync = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            needsResync = false
            let doFull = pendingFull
            pendingFull = false
            await performSync(forceFull: doFull)
        } while needsResync
    }

    // MARK: Planning

    private struct PlanItem {
        var time: Date          // when this alarm rings
        var med: Medication
        var slot: Date          // the dose it belongs to
        var isRepeat: Bool
    }

    /// - Parameter snoozes: next ring time for doses whose alarm was dismissed, keyed by `DoseRef.token`.
    static func plan(meds: [Medication], settings: ScheduleSettings, now: Date,
                     snoozes: [String: Date] = [:]) -> [UUID: AlarmGroup] {
        guard settings.alarmsEnabled else { return [:] }
        // Look slightly into the past so an alarm that is ringing right now isn't cancelled
        // unless its dose has actually been charted.
        let from = now.addingTimeInterval(-15 * 60)
        let to = now.addingTimeInterval(horizon)
        let interval = TimeInterval(max(1, settings.repeatIntervalMinutes) * 60)
        let lookahead = now.addingTimeInterval(repeatLookahead)

        // 1. Every outstanding dose: its on-time alarm plus, until it is checked off, repeats.
        var items: [PlanItem] = []
        for med in meds where !med.isArchived && med.alarmsEnabled {
            let all = ScheduleEngine.slots(for: med, from: now.addingTimeInterval(-repeatLookback), to: to, settings: settings)
            for (i, slot) in all.enumerated() where DoseActions.record(for: med, slot: slot) == nil {
                if slot >= from {
                    items.append(PlanItem(time: slot, med: med, slot: slot, isRepeat: false))
                }

                // Repeats: scheduled meds only, and never for history back-filled before the med was added.
                guard settings.repeatUntilCharted, !med.isPRN,
                      slot >= med.createdAt.addingTimeInterval(-15 * 60) else { continue }
                // A dose stops nagging once the same medication's next dose is due (that one takes over).
                let chainEnd = i + 1 < all.count ? all[i + 1] : to
                // After Dismiss: ring again `interval` after dismissal. Otherwise: every `interval` after the dose.
                var t = snoozes[DoseRef(medicationID: med.id, slot: slot).token] ?? slot.addingTimeInterval(interval)
                var k = 0
                if t < from {
                    let steps = (from.timeIntervalSince(t) / interval).rounded(.up)
                    t = t.addingTimeInterval(steps * interval)
                    k = Int(steps)
                }
                // Always pre-schedule a few backups (in case the alarm times out without a Dismiss),
                // and every repeat in the next few hours. Dismiss and each app sync extend the chain.
                while t < chainEnd && t < to && (k < backupRepeats || t <= lookahead) {
                    items.append(PlanItem(time: t, med: med, slot: slot, isRepeat: true))
                    t = t.addingTimeInterval(interval)
                    k += 1
                }
            }
        }
        items.sort { ($0.time, $0.med.sortOrder, $0.med.createdAt) < ($1.time, $1.med.sortOrder, $1.med.createdAt) }

        // 2. Consolidate: same minute always; within the merge window when one is set. Repeats for
        //    different doses also merge when within half an interval, so overdue meds nag together.
        let window = TimeInterval(max(0, settings.alarmMergeMinutes) * 60)
        let repeatWindow = max(window, interval / 2)
        var groups: [[PlanItem]] = []
        for item in items {
            if let first = groups.last?.first,
               item.time.timeIntervalSince(first.time) <= (item.isRepeat ? repeatWindow : window),
               !(groups[groups.count - 1].contains { $0.med.id == item.med.id }) {
                groups[groups.count - 1].append(item)
            } else {
                groups.append([item])
            }
        }

        // 3. Budget: anything in the next few hours (incl. repeats), then each medication's next on-time
        //    doses (so weekly/monthly meds are never crowded out), then everything else in time order.
        var chosen = Set<Int>()
        var perMed: [UUID: Int] = [:]
        for (i, g) in groups.enumerated() {
            if g[0].time <= lookahead { chosen.insert(i) }
            for item in g where !item.isRepeat {
                let n = perMed[item.med.id, default: 0]
                if n < guaranteedPerMedication { chosen.insert(i) }
                perMed[item.med.id] = n + 1
            }
        }
        for i in groups.indices where chosen.count < maxAlarms { chosen.insert(i) }
        let selected = chosen.sorted().prefix(maxAlarms)

        // 4. Build alarms with content-derived IDs.
        var result: [UUID: AlarmGroup] = [:]
        for i in selected {
            let g = groups[i]
            let meds = g.map { $0.med }
            let sound = meds.contains { med in
                let style = med.alertStyle == .automatic ? settings.alertStyle : med.alertStyle
                return style != .vibrate
            }
            let refs = g.map { DoseRef(medicationID: $0.med.id, slot: $0.slot) }
            let isRepeat = g.allSatisfy { $0.isRepeat }
            let title = (isRepeat ? "Still due · " : "") + Self.title(for: meds)
            let time = g[0].time
            let signature = "\(time.minuteKey)|\(sound)|\(title)|" + DoseRef.encode(refs)
            result[stableUUID(signature)] = AlarmGroup(time: time, doses: refs, title: title,
                                                       playsSound: sound, isRepeat: isRepeat)
        }
        return result
    }

    /// "Metformin 500 mg" · "Metformin, Atorvastatin & Vitamin D3" · "5 meds: Metformin, Atorvastatin +3"
    static func title(for meds: [Medication]) -> String {
        switch meds.count {
        case 0: return "Medication due"
        case 1: return meds[0].title
        case 2: return "\(meds[0].name) & \(meds[1].name)"
        case 3: return "\(meds[0].name), \(meds[1].name) & \(meds[2].name)"
        default: return "\(meds.count) meds: \(meds[0].name), \(meds[1].name) +\(meds.count - 2)"
        }
    }

    /// Everything that determines *when* alarms ring. Doses taken are deliberately excluded.
    static func fingerprint(meds: [Medication], settings: ScheduleSettings) -> String {
        var parts: [String] = []
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        parts.append(String(decoding: (try? enc.encode(settings)) ?? Data(), as: UTF8.self))
        parts.append(TimeZone.current.identifier)
        parts.append(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        for m in meds.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            parts.append([
                m.id.uuidString, m.title, m.frequencyRaw, "\(m.repeatInterval)",
                m.weekdays.sorted().map(String.init).joined(separator: ","),
                m.customTimes.sorted().map(String.init).joined(separator: ","),
                "\(m.startDate.timeIntervalSince1970)", "\(m.endDate?.timeIntervalSince1970 ?? -1)",
                "\(m.isPRN)", "\(m.alarmsEnabled)", m.alertStyleRaw, "\(m.isArchived)", "\(m.sortOrder)"
            ].joined(separator: "|"))
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Sync

    private func performSync(forceFull: Bool) async {
        let settings = SettingsStore.shared.settings
        let context = DataStore.shared.container.mainContext
        let meds = (try? context.fetch(FetchDescriptor<Medication>())) ?? []
        let now = Date()
        let defaults = UserDefaults.standard

        let fingerprint = Self.fingerprint(meds: meds, settings: settings)
        let full = forceFull || fingerprint != defaults.string(forKey: Self.fingerprintKey)
        let snoozes = pruneSnoozes(meds: meds, now: now)
        let plan = Self.plan(meds: meds, settings: settings, now: now, snoozes: snoozes)

        let manager = AlarmManager.shared
        var cache = loadCache()
        let live = Set(((try? manager.alarms) ?? []).map(\.id))
        let known = live.union(cache.keys)

        var kept = Set<UUID>()
        if full {
            // Clear the whole cache: every alarm we know of, live or remembered.
            for id in known { try? manager.cancel(id: id) }
            cache.removeAll()
        } else {
            for id in known where plan[id] == nil {
                try? manager.cancel(id: id)
                cache[id] = nil
            }
            kept = live.intersection(plan.keys)
        }

        authorization = manager.authorizationState
        if !plan.isEmpty && authorization == .notDetermined {
            authorization = (try? await manager.requestAuthorization()) ?? manager.authorizationState
        }
        guard authorization == .authorized else {
            saveCache(cache)
            scheduledCount = 0
            nextAlarm = nil
            upcoming = []
            return
        }

        var failures = 0
        for (id, group) in plan.sorted(by: { $0.value.time < $1.value.time })
        where !kept.contains(id) && group.time > now.addingTimeInterval(5) {
            do {
                try await schedule(id: id, group: group)
                kept.insert(id)
                cache[id] = group.time
            } catch {
                failures += 1
                lastError = error.localizedDescription
            }
        }

        saveCache(cache)
        if failures == 0 {
            lastError = nil
            // Only remember the fingerprint once everything was scheduled, so a failure retries in full.
            defaults.set(fingerprint, forKey: Self.fingerprintKey)
        }
        if full {
            lastFullRebuild = now
            defaults.set(now, forKey: Self.lastFullKey)
        }

        let active = plan.filter { kept.contains($0.key) && $0.value.time > now }
        scheduledCount = active.count
        nextAlarm = active.values.map { $0.time }.min()
        upcoming = active
            .map { AlarmPreview(id: $0.key, time: $0.value.time, title: $0.value.title,
                                count: $0.value.doses.count, playsSound: $0.value.playsSound,
                                isRepeat: $0.value.isRepeat) }
            .sorted { $0.time < $1.time }
        scheduleBackgroundRefresh()
    }

    private func schedule(id: UUID, group: AlarmGroup) async throws {
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: group.title),
            stopButton: AlarmButton(text: "Dismiss", textColor: .white, systemImageName: "xmark"),
            secondaryButton: AlarmButton(text: group.doses.count > 1 ? "All taken" : "Taken",
                                         textColor: .white, systemImageName: "checkmark"),
            secondaryButtonBehavior: .custom
        )
        let attributes = AlarmAttributes<DoseAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: DoseAlarmMetadata(scheduledTime: group.time, medicationIDs: group.doses.map(\.medicationID)),
            tintColor: Theme.sage
        )
        let configuration = AlarmManager.AlarmConfiguration<DoseAlarmMetadata>(
            countdownDuration: nil,
            schedule: .fixed(group.time),
            attributes: attributes,
            stopIntent: DismissDoseAlarmIntent(alarmID: id, doses: group.doses),
            secondaryIntent: MarkTakenIntent(alarmID: id, doses: group.doses),
            sound: group.playsSound ? .default : .named(Self.silentSoundName)
        )
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
    }

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(2 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Repeats after Dismiss

    /// Called when an alarm's Dismiss button is tapped: its doses ring again after the repeat interval.
    func noteDismissed(_ doses: [DoseRef]) {
        let settings = SettingsStore.shared.settings
        guard settings.repeatUntilCharted else { return }
        let next = Date().addingTimeInterval(TimeInterval(max(1, settings.repeatIntervalMinutes) * 60))
        var snoozes = loadSnoozes()
        for dose in doses { snoozes[dose.token] = next }
        saveSnoozes(snoozes)
    }

    /// Drops snoozes for doses that are charted, gone, or too old to matter.
    private func pruneSnoozes(meds: [Medication], now: Date) -> [String: Date] {
        let byID = Dictionary(meds.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let cutoff = now.addingTimeInterval(-Self.repeatLookback)
        var snoozes = loadSnoozes()
        for (token, _) in snoozes {
            guard let ref = DoseRef(token: Substring(token)), ref.slot > cutoff,
                  let med = byID[ref.medicationID], DoseActions.record(for: med, slot: ref.slot) == nil else {
                snoozes[token] = nil
                continue
            }
        }
        saveSnoozes(snoozes)
        return snoozes
    }

    private func loadSnoozes() -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: Self.snoozeKey) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func saveSnoozes(_ snoozes: [String: Date]) {
        UserDefaults.standard.set(snoozes.mapValues { $0.timeIntervalSince1970 }, forKey: Self.snoozeKey)
    }

    // MARK: Cache

    private func loadCache() -> [UUID: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: Double] ?? [:]
        var out: [UUID: Date] = [:]
        for (k, v) in raw { if let id = UUID(uuidString: k) { out[id] = Date(timeIntervalSince1970: v) } }
        return out
    }

    private func saveCache(_ cache: [UUID: Date]) {
        let raw = Dictionary(uniqueKeysWithValues: cache.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) })
        UserDefaults.standard.set(raw, forKey: Self.cacheKey)
    }

    /// Deterministic (name-based) UUID so identical alarms keep identical IDs across syncs.
    static func stableUUID(_ string: String) -> UUID {
        var b = Array(SHA256.hash(data: Data(string.utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// The alarm's "Taken" button: charts every dose in the consolidated alarm and silences it.
struct MarkTakenIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mark Medications Taken"
    static var description = IntentDescription("Records the medications from a Dosely alarm as taken.")
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Alarm ID") var alarmID: String
    /// "UUID@minuteKey;UUID@minuteKey…" — each medication with its own scheduled slot.
    @Parameter(title: "Doses") var doses: String

    init() {}

    init(alarmID: UUID, doses: [DoseRef]) {
        self.alarmID = alarmID.uuidString
        self.doses = DoseRef.encode(doses)
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) {
            try? AlarmManager.shared.stop(id: id)
        }
        DoseActions.markTakenFromAlarm(DoseRef.decode(doses), context: DataStore.shared.container.mainContext)
        await AlarmScheduler.shared.sync()     // cancel this dose's pending repeats before we're suspended
        return .result()
    }
}

/// The alarm's "Dismiss" button: silences it and, unless the doses get checked off,
/// rings again after the repeat interval (Settings ▸ Repeat every…), for as long as it takes.
struct DismissDoseAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Dismiss Medication Alarm"
    static var description = IntentDescription("Silences a Dosely alarm; it rings again later if the dose isn't checked off.")
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Alarm ID") var alarmID: String
    @Parameter(title: "Doses") var doses: String

    init() {}

    init(alarmID: UUID, doses: [DoseRef]) {
        self.alarmID = alarmID.uuidString
        self.doses = DoseRef.encode(doses)
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) {
            try? AlarmManager.shared.stop(id: id)
        }
        AlarmScheduler.shared.noteDismissed(DoseRef.decode(doses))
        await AlarmScheduler.shared.sync()
        return .result()
    }
}
