import SwiftUI

struct MedicationDetailCard: View {
    let med: Medication
    let settings: ScheduleSettings
    let now: Date
    let onEdit: () -> Void
    let onLog: () -> Void
    let onClose: () -> Void
    let onPhoto: () -> Void

    private var times: [Int] { ScheduleEngine.times(for: med, settings: settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            chips
            if !med.indication.isEmpty {
                row(icon: "heart.text.square", text: "For \(med.indication)")
            }
            if med.endDate != nil { course }
            status
            if !med.isPRN, let adherence { adherenceRow(adherence) }
            if !med.notes.isEmpty {
                row(icon: "note.text", text: med.notes)
            }
            actions
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.07), radius: 16, y: 8)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if let data = med.photoData, let image = UIImage(data: data) {
                Button(action: onPhoto) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View photo")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(med.name)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.ink)
                if !med.doseLine.isEmpty {
                    Text(med.doseLine)
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 30, height: 30)
                    .background(Theme.surfaceSunk, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse")
        }
    }

    private var chips: some View {
        FlowLayout(spacing: 6) {
            if med.isPRN {
                Chip(text: med.frequency == .asNeeded ? "PRN" : "PRN · max \(med.frequency.abbreviation)",
                     tint: Theme.lavender, fill: Theme.lavenderSoft)
            } else {
                Chip(text: med.frequency.hasRepeatInterval ? ScheduleEngine.describe(med)
                                                           : "\(ScheduleEngine.describe(med)) · \(med.frequency.abbreviation)",
                     tint: Theme.sage, fill: Theme.sageSoft)
            }
            if ScheduleEngine.producesSlots(med) && !times.isEmpty {
                Chip(text: Fmt.times(times), systemImage: med.customTimes.isEmpty ? "clock" : "clock.badge.checkmark")
            }
            Chip(text: med.route.label, systemImage: "arrow.down.forward.circle")
            if med.alarmsEnabled && settings.alarmsEnabled {
                let style = med.alertStyle == .automatic ? settings.alertStyle : med.alertStyle
                Chip(text: style == .vibrate ? "Vibrate" : "Alarm",
                     systemImage: style == .vibrate ? "iphone.radiowaves.left.and.right" : "alarm")
            } else {
                Chip(text: "No alarm", systemImage: "bell.slash")
            }
        }
    }

    private var course: some View {
        let cal = Calendar.current
        let end = med.endDate ?? now
        let totalDays = max(1, (cal.dateComponents([.day], from: cal.startOfDay(for: med.startDate), to: cal.startOfDay(for: end)).day ?? 0) + 1)
        let dayNumber = min(totalDays, max(1, (cal.dateComponents([.day], from: cal.startOfDay(for: med.startDate), to: cal.startOfDay(for: now)).day ?? 0) + 1))
        let allSlots = ScheduleEngine.slots(for: med, from: med.startDate.floorMinute, to: end.addingTimeInterval(60), settings: settings)
        let taken = allSlots.filter { DoseActions.record(for: med, slot: $0)?.status == .taken }.count
        let finished = end < now

        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(finished ? "Course completed" : "Day \(dayNumber) of \(totalDays)", systemImage: "calendar")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if !allSlots.isEmpty {
                    Text("\(taken) of \(allSlots.count) doses")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            if !allSlots.isEmpty {
                ProgressView(value: Double(taken), total: Double(allSlots.count))
                    .tint(Theme.sage)
            }
            Text("\(finished ? "Last dose was" : "Last dose") \(Fmt.shortDay(end)), \(Fmt.time(end))")
                .font(.caption)
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(12)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var status: some View {
        let last = med.takenRecords.last
        VStack(alignment: .leading, spacing: 6) {
            if let last {
                row(icon: "checkmark.circle", text: "Last taken \(Fmt.dayTime(last.takenAt))")
            } else {
                row(icon: "circle.dashed", text: "No doses recorded yet")
            }
            if !med.isPRN, let next = nextScheduled {
                row(icon: "calendar.badge.clock", text: "Next due \(Fmt.dayTime(next))")
            }
            if med.isPRN {
                if let next = ScheduleEngine.nextAllowed(for: med), next > now {
                    row(icon: "hourglass", text: "Next dose from \(Fmt.dayTime(next))", tint: Theme.honey)
                } else {
                    row(icon: "checkmark.seal", text: "Can be taken now", tint: Theme.sage)
                }
            }
        }
    }

    private var nextScheduled: Date? {
        ScheduleEngine.slots(for: med, from: now, to: now.addingTimeInterval(400 * 86_400), settings: settings)
            .first { DoseActions.record(for: med, slot: $0) == nil }
    }

    /// Look back further for weekly and monthly schedules so the figure means something.
    private var adherenceDays: Int {
        switch med.frequency {
        case .weekly: 8 * 7 * max(1, med.repeatInterval)
        case .monthly: 180 * max(1, med.repeatInterval)
        case .everyNDays: 6 * max(2, med.repeatInterval)
        default: 7
        }
    }

    private var adherence: (taken: Int, total: Int)? {
        let slots = ScheduleEngine.slots(for: med, from: now.addingTimeInterval(-Double(min(adherenceDays, 730)) * 86_400),
                                         to: now.addingTimeInterval(-3600), settings: settings)
        guard !slots.isEmpty else { return nil }
        let taken = slots.filter { DoseActions.record(for: med, slot: $0)?.status == .taken }.count
        return (taken, slots.count)
    }

    private func adherenceRow(_ a: (taken: Int, total: Int)) -> some View {
        let pct = Int((Double(a.taken) / Double(a.total) * 100).rounded())
        return row(icon: "chart.bar", text: "\(min(adherenceDays, 730))-day adherence \(pct)% · \(a.taken) of \(a.total)")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: onLog) {
                Label("Log dose", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(med.isPRN ? Theme.lavender : Theme.sage)

            Button(action: onEdit) {
                Label("Edit", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .tint(Theme.ink)
        }
        .buttonBorderShape(.capsule)
    }

    private func row(icon: String, text: String, tint: Color = Theme.inkSecondary) -> some View {
        Label {
            Text(text).foregroundStyle(tint == Theme.inkSecondary ? Theme.ink : tint)
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
        .font(.footnote)
    }
}

/// Full-screen look at a medication photo.
struct PhotoViewer: View {
    let med: Medication
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let data = med.photoData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding()
        }
        .overlay(alignment: .bottom) {
            Text(med.title)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.bottom, 30)
        }
        .onTapGesture { dismiss() }
    }
}
