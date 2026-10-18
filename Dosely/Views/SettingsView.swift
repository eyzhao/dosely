import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var store
    @Environment(AlarmScheduler.self) private var alarms
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    DatePicker(selection: $store.settings.anchorMinutes.asTimeOfDay(), displayedComponents: .hourAndMinute) {
                        Label("Convergence time", systemImage: "scope")
                    }
                    DatePicker(selection: $store.settings.bedtimeMinutes.asTimeOfDay(), displayedComponents: .hourAndMinute) {
                        Label("Bedtime", systemImage: "moon")
                    }
                    Toggle(isOn: $store.settings.spreadOverWakingDay) {
                        Label("Spread TID & QID over the waking day", systemImage: "sun.horizon")
                    }
                } header: {
                    Text("Daily rhythm")
                } footer: {
                    Text("Every schedule converges on \(Fmt.minutes(store.settings.anchorMinutes)). Once-daily doses fall there, twice-daily doses at \(Fmt.times(store.settings.defaultTimes(for: .bid), separator: " and ")), and interval schedules count forward from it. Bedtime anchors QHS doses.")
                }

                Section {
                    ForEach(Frequency.scheduled) { f in
                        NavigationLink {
                            FrequencyDefaultsEditor(frequency: f)
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.label)
                                    Text(f.abbreviation).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Fmt.times(store.settings.defaultTimes(for: f), separator: ", "))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(store.settings.isOverridden(f) ? Theme.sage : .secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                } header: {
                    Text("Default times")
                } footer: {
                    Text("Medications set to “Use default times” follow these automatically. Times shown in green have been adjusted by hand.")
                }

                Section {
                    Toggle(isOn: $store.settings.alarmsEnabled) {
                        Label("Medication alarms", systemImage: "alarm")
                    }
                    Picker(selection: $store.settings.alertStyle) {
                        Text("System sound").tag(AlertStyle.sound)
                        Text("Vibrate only").tag(AlertStyle.vibrate)
                    } label: {
                        Label("Alert style", systemImage: "speaker.wave.2")
                    }
                    .disabled(!store.settings.alarmsEnabled)
                    Picker(selection: $store.settings.alarmMergeMinutes) {
                        Text("Same time only").tag(0)
                        Text("Within 15 min").tag(15)
                        Text("Within 30 min").tag(30)
                        Text("Within 1 hour").tag(60)
                    } label: {
                        Label("Combine alarms", systemImage: "square.stack")
                    }
                    .disabled(!store.settings.alarmsEnabled)
                    Toggle(isOn: $store.settings.repeatUntilCharted) {
                        Label("Repeat until checked off", systemImage: "repeat")
                    }
                    .disabled(!store.settings.alarmsEnabled)
                    if store.settings.repeatUntilCharted {
                        Picker(selection: $store.settings.repeatIntervalMinutes) {
                            ForEach([5, 10, 15, 20, 30, 45, 60, 90, 120], id: \.self) { m in
                                Text(Self.intervalLabel(m)).tag(m)
                            }
                        } label: {
                            Label("Ring again after", systemImage: "clock.arrow.circlepath")
                        }
                        .disabled(!store.settings.alarmsEnabled)
                    }
                    authorizationRow
                    if alarms.authorization == .authorized && store.settings.alarmsEnabled {
                        NavigationLink {
                            UpcomingAlarmsView()
                        } label: {
                            LabeledContent("Upcoming alarms") {
                                if let next = alarms.nextAlarm {
                                    Text("\(alarms.scheduledCount) · next \(Fmt.dayTime(next))")
                                } else {
                                    Text("None")
                                }
                            }
                        }
                    }
                    Button("Rebuild All Alarms", systemImage: "arrow.triangle.2.circlepath") {
                        Haptics.tap()
                        Task { await alarms.sync(full: true) }
                    }
                    if let error = alarms.lastError {
                        Text(error).font(.caption).foregroundStyle(Theme.clay)
                    }
                } header: {
                    Text("Alarms")
                } footer: {
                    Text("Alarms use AlarmKit, so they break through Silent mode and Focus. Doses due together ring as one alarm listing every medication, and its Taken button charts them all. If you tap Dismiss without checking a dose off, it rings again after the chosen interval, over and over, until it's charted (taken, skipped or missed) or the medication's next dose comes due. PRN medications never ring unless you opt in on that medication. Alarms cover the next 62 days (up to 60 alarms, with every medication's next two always included) and are rebuilt in full whenever a schedule changes.")
                }

                Section("Display") {
                    Toggle(isOn: $store.settings.showCompleted) {
                        Label("Show completed courses", systemImage: "checkmark.circle")
                    }
                }

                Section {
                    LabeledContent("Dosely", value: "1.0")
                } footer: {
                    Text("Dosely is a personal record and reminder tool. It doesn't give medical advice — follow your prescriber's and pharmacist's instructions.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
            .onAppear { alarms.refreshAuthorization() }
        }
        .tint(Theme.sage)
    }

    static func intervalLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        if minutes == 60 { return "1 hour" }
        return minutes % 60 == 0 ? "\(minutes / 60) hours" : "\(minutes / 60)½ hours"
    }

    @ViewBuilder
    private var authorizationRow: some View {
        switch alarms.authorization {
        case .authorized:
            LabeledContent("Permission") {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.sage)
            }
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                LabeledContent("Permission") {
                    Text("Not allowed — open Settings").foregroundStyle(Theme.clay)
                }
            }
        default:
            Button("Allow Alarms", systemImage: "alarm.waves.left.and.right") {
                Task { await alarms.requestAuthorization() }
            }
        }
    }
}

struct FrequencyDefaultsEditor: View {
    let frequency: Frequency
    @Environment(SettingsStore.self) private var store
    @State private var times: [Int] = []
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TimesEditor(times: $times, defaultNew: store.settings.anchorMinutes)
            } footer: {
                Text("From the convergence point this would be \(Fmt.times(store.settings.computedTimes(for: frequency), separator: ", ")).")
            }
            if store.settings.isOverridden(frequency) {
                Section {
                    Button("Reset to Convergence Times", systemImage: "arrow.counterclockwise") {
                        store.settings.overrides[frequency.rawValue] = nil
                        times = store.settings.computedTimes(for: frequency)
                    }
                }
            }
        }
        .navigationTitle("\(frequency.label) · \(frequency.abbreviation)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            times = store.settings.defaultTimes(for: frequency)
            loaded = true
        }
        .onChange(of: times) { _, newValue in
            guard loaded else { return }
            let clean = Array(Set(newValue)).sorted()
            if clean == store.settings.computedTimes(for: frequency) || clean.isEmpty {
                store.settings.overrides[frequency.rawValue] = nil
            } else {
                store.settings.overrides[frequency.rawValue] = clean
            }
        }
    }
}

/// Read-only list of what AlarmKit currently has scheduled — handy for checking consolidation.
struct UpcomingAlarmsView: View {
    @Environment(AlarmScheduler.self) private var alarms

    var body: some View {
        List {
            if alarms.upcoming.isEmpty {
                ContentUnavailableView("No alarms scheduled", systemImage: "alarm",
                                       description: Text("Alarms appear here for doses that haven't been charted yet."))
            }
            ForEach(groupedByDay) { section in
                Section(Fmt.dayLabel(section.day)) {
                    ForEach(section.items) { alarm in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(Fmt.time(alarm.time))
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .frame(width: 64, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alarm.title).font(.subheadline)
                                if alarm.count > 1 || alarm.isRepeat {
                                    Text([alarm.count > 1 ? "\(alarm.count) medications in one alarm" : nil,
                                          alarm.isRepeat ? "repeat — not yet checked off" : nil]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: alarm.playsSound ? "speaker.wave.2" : "iphone.radiowaves.left.and.right")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let last = alarms.lastFullRebuild {
                Section {
                    EmptyView()
                } footer: {
                    Text("Last full rebuild \(Fmt.dayTime(last)).")
                }
            }
        }
        .navigationTitle("Upcoming Alarms")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await alarms.sync(full: true) }
    }

    private struct DaySection: Identifiable {
        let day: Date
        let items: [AlarmPreview]
        var id: Date { day }
    }

    private var groupedByDay: [DaySection] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: alarms.upcoming) { cal.startOfDay(for: $0.time) }
        return groups.keys.sorted().map { day in
            DaySection(day: day, items: (groups[day] ?? []).sorted { $0.time < $1.time })
        }
    }
}
