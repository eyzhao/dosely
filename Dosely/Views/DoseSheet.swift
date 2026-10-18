import SwiftUI
import SwiftData

/// Chart a single administration precisely: status, actual time, and a note.
struct DoseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let target: DoseTarget

    private enum Choice: String, CaseIterable, Identifiable {
        case taken = "Taken", skipped = "Skipped", missed = "Missed", notGiven = "Clear"
        var id: String { rawValue }
    }

    @State private var choice: Choice
    @State private var time: Date
    @State private var note: String

    init(target: DoseTarget) {
        self.target = target
        let now = Date()
        if let r = target.record {
            let current: Choice = switch r.status {
            case .taken: .taken
            case .skipped: .skipped
            case .missed: .missed
            }
            _choice = State(initialValue: current)
            _time = State(initialValue: r.takenAt)
            _note = State(initialValue: r.note)
        } else {
            _choice = State(initialValue: .taken)
            _time = State(initialValue: target.slot.map { DoseActions.defaultTakenTime(slot: $0, now: now) } ?? now)
            _note = State(initialValue: "")
        }
    }

    private var isNewUnscheduled: Bool { target.slot == nil && target.record == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(target.med.title)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                        if let slot = target.slot {
                            Label("Scheduled \(Fmt.shortDay(slot)), \(Fmt.time(slot))", systemImage: "clock")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Label(target.med.isPRN ? "As-needed dose" : "Unscheduled dose", systemImage: "plus.circle")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if target.med.isPRN, let next = ScheduleEngine.nextAllowed(for: target.med),
                           next > .now, target.record == nil {
                            Label("Minimum interval not yet reached — next from \(Fmt.dayTime(next))",
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(Theme.honey)
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    Picker("Status", selection: $choice.animation()) {
                        ForEach(target.slot == nil ? [Choice.taken, .skipped] : Choice.allCases) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                    if choice == .taken {
                        DatePicker("Time given", selection: $time)
                        HStack(spacing: 8) {
                            quick("Now") { time = .now }
                            if let slot = target.slot { quick("On time") { time = slot } }
                            quick("−15 min") { time = time.addingTimeInterval(-900) }
                            quick("+15 min") { time = time.addingTimeInterval(900) }
                        }
                    }
                    if choice != .notGiven {
                        TextField("Note (optional)", text: $note, axis: .vertical)
                    }
                }

                if target.record != nil && target.slot == nil {
                    Section {
                        Button("Delete This Dose", systemImage: "trash", role: .destructive) {
                            DoseActions.set(nil, med: target.med, slot: nil, existing: target.record,
                                            takenAt: .now, context: context)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNewUnscheduled ? "Log Dose" : "Dose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.sage)
    }

    private func quick(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title) { action(); Haptics.tap() }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .font(.caption.weight(.medium))
    }

    private func save() {
        let status: DoseStatus? = switch choice {
        case .taken: .taken
        case .skipped: .skipped
        case .missed: .missed
        case .notGiven: nil
        }
        let existing = target.record ?? target.slot.flatMap { DoseActions.record(for: target.med, slot: $0) }
        DoseActions.set(status, med: target.med, slot: target.slot, existing: existing,
                        takenAt: status == .taken ? time : (target.slot ?? time),
                        note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                        context: context)
        if status == .taken { Haptics.success() }
        dismiss()
    }
}
