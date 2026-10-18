import SwiftUI
import SwiftData
import PhotosUI

struct MedDraft {
    var name = ""
    var dose = ""
    var route: Route = .oral
    var indication = ""
    var notes = ""
    var isPRN = false
    var frequency: Frequency = .daily
    var repeatInterval = 1
    var weekdays: Set<Int> = []
    var useDefaultTimes = true
    var customTimes: [Int] = []
    var startDate = Calendar.current.startOfDay(for: .now)
    var hasEnd = false
    var endDate = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: .now))!
    var alarmsEnabled = true
    var alertStyle: AlertStyle = .automatic
    var photoData: Data?

    init() {}

    init(_ m: Medication) {
        name = m.name; dose = m.dose; route = m.route; indication = m.indication; notes = m.notes
        isPRN = m.isPRN; frequency = m.frequency
        repeatInterval = max(1, m.repeatInterval)
        weekdays = Set(m.weekdays)
        useDefaultTimes = m.customTimes.isEmpty
        customTimes = m.customTimes.sorted()
        startDate = m.startDate
        hasEnd = m.endDate != nil
        if let e = m.endDate { endDate = e }
        alarmsEnabled = m.alarmsEnabled
        alertStyle = m.alertStyle
        photoData = m.photoData
        normalizeRecurrence()
    }

    var needsTimes: Bool { !isPRN || alarmsEnabled }
    var mustUseCustomTimes: Bool { frequency == .asNeeded }

    func effectiveTimes(_ settings: ScheduleSettings) -> [Int] {
        (useDefaultTimes && !mustUseCustomTimes) ? settings.defaultTimes(for: frequency) : Array(Set(customTimes)).sorted()
    }

    func pattern(_ settings: ScheduleSettings) -> ScheduleEngine.Pattern {
        ScheduleEngine.Pattern(times: effectiveTimes(settings),
                               recurrence: isPRN ? .everyDays(1) : recurrence,
                               start: startDate, end: hasEnd ? endDate : nil, producesSlots: needsTimes)
    }

    var recurrence: Recurrence {
        ScheduleEngine.recurrence(frequency: frequency, interval: repeatInterval,
                                  weekdays: Array(weekdays), start: startDate)
    }

    var scheduleDescription: String {
        ScheduleEngine.describe(frequency: frequency, interval: repeatInterval,
                                weekdays: Array(weekdays), start: startDate)
    }

    /// Keeps the repeat settings sensible when the frequency changes.
    mutating func normalizeRecurrence() {
        switch frequency {
        case .everyNDays: repeatInterval = min(max(2, repeatInterval), 90)
        case .weekly:
            repeatInterval = min(max(1, repeatInterval), 12)
            if weekdays.isEmpty { weekdays = [Calendar.current.component(.weekday, from: startDate)] }
        case .monthly: repeatInterval = min(max(1, repeatInterval), 24)
        default: break
        }
    }

    func apply(to m: Medication) {
        m.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        m.dose = dose.trimmingCharacters(in: .whitespacesAndNewlines)
        m.route = route
        m.indication = indication.trimmingCharacters(in: .whitespacesAndNewlines)
        m.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        m.isPRN = isPRN
        m.frequency = frequency
        m.repeatInterval = (!isPRN && frequency.hasRepeatInterval) ? repeatInterval : 1
        m.weekdays = (!isPRN && frequency == .weekly) ? weekdays.sorted() : []
        m.customTimes = (useDefaultTimes && !mustUseCustomTimes) ? [] : Array(Set(customTimes)).sorted()
        m.startDate = startDate
        m.endDate = hasEnd ? max(endDate, startDate) : nil
        m.alarmsEnabled = alarmsEnabled
        m.alertStyle = alertStyle
        m.photoData = photoData
        m.updatedAt = .now
    }
}

struct MedicationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(SettingsStore.self) private var store
    @Query(sort: \Medication.sortOrder) private var allMeds: [Medication]

    let medication: Medication?
    @State private var draft: MedDraft
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var confirmDelete = false

    init(medication: Medication?) {
        self.medication = medication
        _draft = State(initialValue: medication.map { MedDraft($0) } ?? MedDraft())
    }

    private var settings: ScheduleSettings { store.settings }
    private var canSave: Bool { !draft.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                photoSection
                detailsSection
                scheduleSection
                courseSection
                alarmSection
                Section("Notes") {
                    TextField("Instructions, prescriber, pharmacy…", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...6)
                }
                if medication != nil { manageSection }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(medication == nil ? "New Medication" : "Edit Medication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).fontWeight(.semibold).disabled(!canSave)
                }
            }
            .photosPicker(isPresented: $showLibrary, selection: $pickerItem, matching: .images)
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        draft.photoData = ImageUtil.compressed(image)
                    }
                    pickerItem = nil
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in draft.photoData = ImageUtil.compressed(image) }
                    .ignoresSafeArea()
            }
            .confirmationDialog("Delete \(draft.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Medication & History", role: .destructive, action: delete)
            } message: {
                Text("This removes the medication and every dose recorded for it. Archive instead to keep the history.")
            }
        }
        .tint(Theme.sage)
    }

    // MARK: Sections

    private var photoSection: some View {
        Section {
            HStack {
                Spacer()
                Menu {
                    Button("Choose from Library", systemImage: "photo.on.rectangle") { showLibrary = true }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Take Photo", systemImage: "camera") { showCamera = true }
                    }
                    if draft.photoData != nil {
                        Button("Remove Photo", systemImage: "trash", role: .destructive) { draft.photoData = nil }
                    }
                } label: {
                    photoBadge
                }
                Spacer()
            }
        }
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var photoBadge: some View {
        if let data = draft.photoData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.sage)
                        .offset(x: 6, y: 6)
                }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "camera")
                    .font(.system(size: 24, weight: .light))
                Text("Add photo")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(Theme.sage)
            .frame(width: 96, height: 96)
            .background(Theme.sageSoft, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var detailsSection: some View {
        Section("Medication") {
            TextField("Name", text: $draft.name)
                .font(.headline)
                .textInputAutocapitalization(.words)
            TextField("Dose (e.g. 500 mg, 2 puffs)", text: $draft.dose)
            Picker("Route", selection: $draft.route) {
                ForEach(Route.allCases) { r in
                    Text("\(r.label)  \(r.abbreviation)").tag(r)
                }
            }
            TextField("Indication (what it's for)", text: $draft.indication)
        }
    }

    private var scheduleSection: some View {
        Section {
            Toggle(isOn: $draft.isPRN.animation()) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("As needed (PRN)")
                    Text("Doses are logged when taken rather than scheduled")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: draft.isPRN) { _, prn in
                if prn {
                    draft.alarmsEnabled = false
                } else {
                    draft.alarmsEnabled = true
                    if draft.frequency == .asNeeded { draft.frequency = .daily }
                }
            }

            Picker(draft.isPRN ? "Maximum frequency" : "Frequency", selection: $draft.frequency.animation()) {
                ForEach(frequencyOptions) { f in
                    Text(f.hasRepeatInterval ? f.label : "\(f.label) · \(f.abbreviation)").tag(f)
                }
            }
            .onChange(of: draft.frequency) { _, _ in draft.normalizeRecurrence() }

            if !draft.isPRN && draft.frequency.hasRepeatInterval {
                recurrenceControls
            }

            if draft.needsTimes {
                if draft.mustUseCustomTimes {
                    TimesEditor(times: $draft.customTimes, defaultNew: settings.anchorMinutes)
                } else {
                    Toggle(isOn: $draft.useDefaultTimes.animation()) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use default times")
                            Text(Fmt.times(settings.defaultTimes(for: draft.frequency)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: draft.useDefaultTimes) { _, useDefault in
                        if !useDefault && draft.customTimes.isEmpty {
                            draft.customTimes = settings.defaultTimes(for: draft.frequency)
                        }
                    }
                    if !draft.useDefaultTimes {
                        TimesEditor(times: $draft.customTimes, defaultNew: settings.anchorMinutes)
                    }
                }
            }
        } header: {
            Text("Schedule")
        } footer: {
            if draft.isPRN {
                Text(draft.alarmsEnabled
                     ? "Reminder times appear as optional dashed boxes and never count as missed."
                     : "Use the + beside the name to log a dose. The maximum frequency tells you when the next dose is allowed.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(draft.scheduleDescription) at \(Fmt.times(draft.effectiveTimes(settings), separator: ", ")).")
                    if draft.frequency == .monthly && Calendar.current.component(.day, from: draft.startDate) > 28 {
                        Text("In shorter months the dose falls on the last day of the month.")
                    }
                    if draft.useDefaultTimes && !draft.mustUseCustomTimes {
                        Text("Default times converge on \(Fmt.minutes(settings.anchorMinutes)) and follow any change in Settings.")
                    }
                }
            }
        }
    }

    private var frequencyOptions: [Frequency] {
        guard draft.isPRN else { return Frequency.scheduled }
        var options = Frequency.prnOptions
        if !options.contains(draft.frequency) { options.append(draft.frequency) }
        return options
    }

    @ViewBuilder
    private var recurrenceControls: some View {
        switch draft.frequency {
        case .everyNDays:
            Stepper(value: $draft.repeatInterval, in: 2...90) {
                LabeledContent("Repeat", value: "Every \(draft.repeatInterval) days")
            }
        case .weekly:
            WeekdayPicker(selection: $draft.weekdays)
            Stepper(value: $draft.repeatInterval, in: 1...12) {
                LabeledContent("Repeat", value: draft.repeatInterval == 1 ? "Every week" : "Every \(draft.repeatInterval) weeks")
            }
        case .monthly:
            Stepper(value: $draft.repeatInterval, in: 1...24) {
                LabeledContent("Repeat", value: draft.repeatInterval == 1 ? "Every month" : "Every \(draft.repeatInterval) months")
            }
            LabeledContent("Day of month",
                           value: "The \(ScheduleEngine.ordinal(Calendar.current.component(.day, from: draft.startDate))) · from first dose")
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var courseSection: some View {
        Section {
            DatePicker("First dose", selection: $draft.startDate)
            Toggle("Has an end date", isOn: $draft.hasEnd.animation())
            if draft.hasEnd {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(courseOptions) { option in
                            Button(option.label) { setCourse(days: option.days) }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .font(.footnote.weight(.medium))
                        }
                    }
                }
                .scrollIndicators(.hidden)
                DatePicker("Last dose", selection: $draft.endDate, in: draft.startDate...)
            }
        } header: {
            Text("Course")
        } footer: {
            if draft.hasEnd && draft.needsTimes {
                let count = ScheduleEngine.slots(draft.pattern(settings), from: draft.startDate.floorMinute,
                                                 to: draft.endDate.addingTimeInterval(60)).count
                Text("\(count) scheduled \(count == 1 ? "dose" : "doses") in this course. Handy for antibiotics — the last box appears at the final administration.")
            }
        }
    }

    private struct CourseOption: Identifiable {
        let label: String
        let days: Int
        var id: Int { days }
    }

    private var courseOptions: [CourseOption] {
        if draft.frequency.isLongInterval && !draft.isPRN {
            return [CourseOption(label: "4 weeks", days: 28), CourseOption(label: "8 weeks", days: 56),
                    CourseOption(label: "12 weeks", days: 84), CourseOption(label: "6 months", days: 182),
                    CourseOption(label: "1 year", days: 365)]
        }
        return [3, 5, 7, 10, 14, 28].map { CourseOption(label: "\($0) days", days: $0) }
    }

    private var alarmSection: some View {
        Section {
            Toggle(draft.isPRN ? "Reminder alarms" : "Alarms", isOn: $draft.alarmsEnabled.animation())
            if draft.alarmsEnabled {
                Picker("Alert", selection: $draft.alertStyle) {
                    Text("App default (\(settings.alertStyle == .vibrate ? "vibrate" : "sound"))").tag(AlertStyle.automatic)
                    Text("System sound").tag(AlertStyle.sound)
                    Text("Vibrate only").tag(AlertStyle.vibrate)
                }
            }
        } header: {
            Text("Alarms")
        } footer: {
            if !settings.alarmsEnabled {
                Text("Alarms are switched off for all medications in Settings.")
            } else if draft.isPRN && draft.alarmsEnabled {
                Text("PRN medications don't ring by default — this opts in at the times above.")
            }
        }
    }

    private var manageSection: some View {
        Section {
            if let medication {
                Button(medication.isArchived ? "Restore Medication" : "Archive Medication",
                       systemImage: medication.isArchived ? "tray.and.arrow.up" : "archivebox") {
                    medication.isArchived.toggle()
                    medication.updatedAt = .now
                    DoseActions.commit(context, scheduleChanged: true)
                    dismiss()
                }
            }
            Button("Delete Medication", systemImage: "trash", role: .destructive) { confirmDelete = true }
        } footer: {
            Text("Archived medications leave the board but keep their history for export.")
        }
    }

    // MARK: Actions

    private func setCourse(days: Int) {
        let cal = Calendar.current
        let firstDay = cal.startOfDay(for: draft.startDate)
        guard let boundary = cal.date(byAdding: .day, value: days, to: firstDay) else { return }
        var p = draft.pattern(settings)
        p.end = nil
        if let last = ScheduleEngine.slots(p, from: draft.startDate.floorMinute, to: boundary).last {
            draft.endDate = last
        } else {
            draft.endDate = boundary.addingTimeInterval(-60)
        }
        draft.hasEnd = true
        Haptics.tap()
    }

    private func save() {
        let med: Medication
        if let medication {
            med = medication
        } else {
            med = Medication()
            med.sortOrder = (allMeds.map(\.sortOrder).max() ?? -1) + 1
            context.insert(med)
        }
        draft.apply(to: med)
        DoseActions.commit(context, scheduleChanged: true)
        Haptics.success()
        dismiss()
    }

    private func delete() {
        if let medication { context.delete(medication) }
        DoseActions.commit(context, scheduleChanged: true)
        dismiss()
    }
}

// MARK: - Times editor

struct TimesEditor: View {
    @Binding var times: [Int]
    var defaultNew: Int = 9 * 60

    var body: some View {
        ForEach(Array(times.enumerated()), id: \.offset) { i, _ in
            HStack {
                DatePicker("Dose \(i + 1)", selection: binding(at: i).asTimeOfDay(), displayedComponents: .hourAndMinute)
                Button {
                    withAnimation { if i < times.count { times.remove(at: i) } }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(Theme.clay)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove time")
            }
        }
        Button {
            withAnimation {
                let next = times.max().map { ($0 + 60) % 1440 } ?? defaultNew
                times.append(next)
            }
        } label: {
            Label("Add time", systemImage: "plus.circle.fill")
        }
    }

    private func binding(at i: Int) -> Binding<Int> {
        Binding(
            get: { i < times.count ? times[i] : 0 },
            set: { if i < times.count { times[i] = $0 } }
        )
    }
}

// MARK: - Photo helpers

enum ImageUtil {
    static func compressed(_ image: UIImage, maxDimension: CGFloat = 1400) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / max(longest, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.8)
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Weekday picker

struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        let cal = Calendar.current
        let symbols = cal.veryShortWeekdaySymbols
        let names = cal.weekdaySymbols
        HStack(spacing: 6) {
            ForEach(ScheduleEngine.orderedWeekdays(cal), id: \.self) { day in
                let on = selection.contains(day)
                Button {
                    if on {
                        if selection.count > 1 { selection.remove(day) }   // always keep one day
                    } else {
                        selection.insert(day)
                    }
                    Haptics.tap()
                } label: {
                    Text(symbols[day - 1])
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(on ? Color.white : Theme.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(on ? Theme.sage : Theme.surfaceSunk, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(names[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
