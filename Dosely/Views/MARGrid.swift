import SwiftUI

// MARK: - Cell model & actions

struct CellHandler {
    var tap: (_ med: Medication, _ key: Int, _ scheduled: Bool, _ record: DoseRecord?) -> Void
    var set: (_ med: Medication, _ slot: Date, _ status: DoseStatus?, _ atSlot: Bool) -> Void
    var edit: (_ med: Medication, _ slot: Date?, _ record: DoseRecord?) -> Void
}

private enum CellVisual {
    case taken(offset: TimeInterval?), extra, skipped, chartedMissed, due, overdue, upcoming, optional
}

// MARK: - Grid canvas (virtualised days)

struct GridCanvas: View {
    let timeline: TimelineModel
    let meds: [Medication]
    let heights: [CGFloat]
    let totalHeight: CGFloat
    let now: Date
    let handler: CellHandler

    var body: some View {
        let range = timeline.visibleRange
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: timeline.totalWidth, height: totalHeight)
            ForEach(timeline.days[range]) { day in
                DayColumnView(day: day, meds: meds, heights: heights, now: now, handler: handler)
                    .frame(width: day.width, height: totalHeight, alignment: .top)
                    .offset(x: day.x)
            }
            if let x = timeline.nowX(now) {
                Rectangle()
                    .fill(Theme.sage.opacity(0.55))
                    .frame(width: 1.5, height: totalHeight)
                    .offset(x: x - 0.75)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: timeline.totalWidth, height: totalHeight, alignment: .topLeading)
    }
}

struct DayColumnView: View {
    let day: DayLayout
    let meds: [Medication]
    let heights: [CGFloat]
    let now: Date
    let handler: CellHandler

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(meds.enumerated()), id: \.element.id) { i, med in
                HStack(spacing: 0) {
                    ForEach(day.columns, id: \.self) { key in
                        cell(med: med, key: key)
                            .frame(width: MAR.columnWidth, height: MAR.rowHeight)
                    }
                }
                .padding(.horizontal, MAR.dayPadding)
                .frame(width: day.width, height: i < heights.count ? heights[i] : MAR.rowHeight, alignment: .topLeading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                }
            }
            Spacer(minLength: 0)
        }
        .background(day.isToday ? Theme.sage.opacity(0.05) : Color.clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.hairline).frame(width: 1)
        }
    }

    @ViewBuilder
    private func cell(med: Medication, key: Int) -> some View {
        let scheduled = day.scheduled[med.id]?.contains(key) ?? false
        let record = day.records[med.id]?[key]
        if scheduled || record != nil {
            DoseCellView(med: med, key: key, scheduled: scheduled, record: record, now: now, handler: handler)
        } else {
            Color.clear
        }
    }
}

// MARK: - A single check box

struct DoseCellView: View {
    let med: Medication
    let key: Int
    let scheduled: Bool
    let record: DoseRecord?
    let now: Date
    let handler: CellHandler

    private var slot: Date { Date(minuteKey: key) }

    private var visual: CellVisual {
        if let record {
            switch record.status {
            case .skipped: return .skipped
            case .missed: return .chartedMissed
            case .taken:
                if !scheduled { return .extra }
                let off = record.takenAt.timeIntervalSince(slot)
                return .taken(offset: abs(off) >= 30 * 60 ? off : nil)
            }
        }
        if med.isPRN { return .optional }
        let diff = slot.timeIntervalSince(now)
        if diff > 30 * 60 { return .upcoming }
        if diff >= -60 * 60 { return .due }
        return .overdue
    }

    var body: some View {
        Button {
            handler.tap(med, key, scheduled, record)
        } label: {
            ZStack {
                box
                if case .taken(let offset?) = visual {
                    Text(Fmt.offset(offset))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.inkTertiary)
                        .offset(y: MAR.cell / 2 + 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(CellPressStyle())
        .contextMenu { menu }
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var box: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        switch visual {
        case .taken:
            shape.fill(Theme.sage)
                .frame(width: MAR.cell, height: MAR.cell)
                .overlay(Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
        case .extra:
            shape.fill(Theme.lavender)
                .frame(width: MAR.cell, height: MAR.cell)
                .overlay(Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
        case .skipped:
            shape.fill(Theme.surfaceSunk)
                .frame(width: MAR.cell, height: MAR.cell)
                .overlay(Image(systemName: "minus").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.inkTertiary))
        case .due:
            shape.fill(Theme.honeySoft)
                .overlay(shape.strokeBorder(Theme.honey, lineWidth: 2))
                .frame(width: MAR.cell, height: MAR.cell)
                .phaseAnimator([1.0, 1.07]) { view, scale in
                    view.scaleEffect(scale)
                } animation: { _ in .easeInOut(duration: 1.1) }
        case .chartedMissed:
            shape.fill(Theme.clay)
                .frame(width: MAR.cell, height: MAR.cell)
                .overlay(Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
        case .overdue:
            shape.fill(Theme.claySoft)
                .overlay(shape.strokeBorder(Theme.clay, lineWidth: 1.5))
                .frame(width: MAR.cell, height: MAR.cell)
        case .upcoming:
            shape.fill(Theme.surface)
                .overlay(shape.strokeBorder(Theme.outline, lineWidth: 1.5))
                .frame(width: MAR.cell, height: MAR.cell)
        case .optional:
            shape.fill(Color.clear)
                .overlay(shape.strokeBorder(Theme.lavender.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
                .frame(width: MAR.cell, height: MAR.cell)
        }
    }

    @ViewBuilder
    private var menu: some View {
        if scheduled {
            Text("\(med.title) · \(Fmt.dayLabel(slot)) \(Fmt.time(slot))")
            Button("Taken now", systemImage: "checkmark.circle") { handler.set(med, slot, .taken, false) }
            Button("Taken at \(Fmt.time(slot))", systemImage: "clock") { handler.set(med, slot, .taken, true) }
            Button("Skipped", systemImage: "minus.circle") { handler.set(med, slot, .skipped, true) }
            Button("Missed", systemImage: "xmark.circle") { handler.set(med, slot, .missed, true) }
            Button("Details…", systemImage: "square.and.pencil") { handler.edit(med, slot, record) }
            if record != nil {
                Button("Clear", systemImage: "arrow.uturn.backward", role: .destructive) { handler.set(med, slot, nil, true) }
            }
        } else if let record {
            Text("\(med.title) · \(Fmt.dayTime(record.takenAt))")
            Button("Details…", systemImage: "square.and.pencil") { handler.edit(med, nil, record) }
        }
    }

    private var accessibilityText: String {
        let when = "\(Fmt.dayLabel(slot)) \(Fmt.time(slot))"
        switch visual {
        case .taken, .extra: return "\(med.name), \(when), taken"
        case .skipped: return "\(med.name), \(when), skipped"
        case .due: return "\(med.name), \(when), due now"
        case .chartedMissed: return "\(med.name), \(when), missed"
        case .overdue: return "\(med.name), \(when), overdue, not charted"
        case .upcoming: return "\(med.name), \(when), upcoming"
        case .optional: return "\(med.name), \(when), optional reminder"
        }
    }
}

private struct CellPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Pinned header

struct ColumnHeaderBar: View {
    let timeline: TimelineModel
    let count: Int
    let now: Date

    var body: some View {
        HStack(spacing: 0) {
            Text(count == 1 ? "1 MEDICATION" : "\(count) MEDICATIONS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.leading, 16)
                .padding(.bottom, 9)
                .frame(width: MAR.nameWidth, height: MAR.headerHeight, alignment: .bottomLeading)
            DayHeaderStrip(timeline: timeline, now: now)
        }
        .frame(height: MAR.headerHeight)
        .background(Theme.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

struct DayHeaderStrip: View {
    let timeline: TimelineModel
    let now: Date

    var body: some View {
        let x = timeline.scrollX
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(timeline.days[timeline.visibleRange]) { day in
                DayHeaderView(day: day,
                              labelShift: min(max(0, x - day.x), max(0, day.width - 96)),
                              nowKey: now.minuteKey)
                    .frame(width: day.width, height: MAR.headerHeight, alignment: .topLeading)
                    .offset(x: day.x - x)
            }
            if let nx = timeline.nowX(now) {
                Capsule()
                    .fill(Theme.sage)
                    .frame(width: 8, height: 8)
                    .offset(x: nx - x - 4, y: MAR.headerHeight - 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

private struct DayHeaderView: View {
    let day: DayLayout
    let labelShift: CGFloat
    let nowKey: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(Fmt.dayLabel(day.date))
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(day.isToday ? Theme.sage : Theme.ink)
                if Calendar.current.isDateInToday(day.date) || Calendar.current.isDateInYesterday(day.date)
                    || Calendar.current.isDateInTomorrow(day.date) {
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated).day()))
                        .font(.caption2)
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            .fixedSize()
            .padding(.leading, MAR.dayPadding + 4)
            .offset(x: labelShift)

            HStack(spacing: 0) {
                ForEach(day.columns, id: \.self) { key in
                    Text(Fmt.columnTime(key))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .foregroundStyle(key < nowKey ? Theme.inkTertiary : Theme.inkSecondary)
                        .frame(width: MAR.columnWidth)
                }
            }
            .padding(.horizontal, MAR.dayPadding)
        }
        .padding(.top, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 1) }
    }
}

// MARK: - Name column cell

struct NameCell: View {
    let med: Medication
    let isExpanded: Bool
    let isCompleted: Bool
    let onTap: () -> Void
    let onQuickLog: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(med.name.isEmpty ? "Untitled" : med.name)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(isExpanded ? Theme.sage : (isCompleted ? Theme.inkTertiary : Theme.ink))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if med.isPRN {
                    Text("PRN")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.lavender)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Theme.lavenderSoft, in: Capsule())
                }
            }
            Spacer(minLength: 0)
            if med.isPRN {
                Button(action: onQuickLog) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.lavender)
                        .frame(width: 26, height: 26)
                        .background(Theme.lavenderSoft, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Log a dose of \(med.name)")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(width: MAR.nameWidth, height: MAR.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isExpanded ? "Hides details" : "Shows details")
    }
}
