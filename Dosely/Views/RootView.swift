import SwiftUI
import SwiftData

struct DoseTarget: Identifiable {
    let id = UUID()
    let med: Medication
    let slot: Date?
    let record: DoseRecord?
}

enum RootSheet: Identifiable {
    case newMedication, edit(Medication), settings, export, manage, dose(DoseTarget)

    var id: String {
        switch self {
        case .newMedication: "new"
        case .edit(let m): "edit-\(m.id)"
        case .settings: "settings"
        case .export: "export"
        case .manage: "manage"
        case .dose(let t): "dose-\(t.id)"
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var undo: (() -> Void)?
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

private struct ScrollMetrics: Equatable {
    var x: CGFloat
    var width: CGFloat
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(SettingsStore.self) private var store
    @Environment(Clock.self) private var clock

    @Query(sort: [SortDescriptor(\Medication.sortOrder), SortDescriptor(\Medication.createdAt)])
    private var meds: [Medication]

    @State private var timeline = TimelineModel()
    @State private var position = ScrollPosition(edge: .leading)
    @State private var expanded: Set<UUID> = []
    @State private var cardHeights: [UUID: CGFloat] = [:]
    @State private var sheet: RootSheet?
    @State private var photoMed: Medication?
    @State private var fullWidth: CGFloat = 390
    @State private var didInitialScroll = false
    @State private var toast: Toast?

    private var visibleMeds: [Medication] {
        let cutoff = clock.now.addingTimeInterval(-86_400)
        return meds.filter { m in
            !m.isArchived && (store.settings.showCompleted || !(m.endDate.map { $0 < cutoff } ?? false))
        }
    }

    /// Cheap fingerprint of everything that shapes the grid.
    private var signature: Int {
        var h = Hasher()
        h.combine(store.settings)
        for m in visibleMeds {
            h.combine(m.id); h.combine(m.updatedAt); h.combine(m.startDate); h.combine(m.endDate)
            h.combine(m.customTimes); h.combine(m.frequencyRaw); h.combine(m.repeatInterval); h.combine(m.weekdays); h.combine(m.isPRN); h.combine(m.alarmsEnabled)
            for d in m.doses ?? [] {
                h.combine(d.id); h.combine(d.takenAt); h.combine(d.statusRaw); h.combine(d.scheduledTime)
            }
        }
        return h.finalize()
    }

    var body: some View {
        let list = visibleMeds
        ZStack(alignment: .bottom) {
            Theme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                SummaryHeader(stats: TodayStats(meds: list, settings: store.settings, now: clock.now),
                              now: clock.now,
                              onAdd: { sheet = .newMedication },
                              onSettings: { sheet = .settings },
                              onExport: { sheet = .export },
                              onManage: { sheet = .manage })
                if list.isEmpty {
                    EmptyStateView(
                        onAdd: { sheet = .newMedication },
                        onSample: { SampleData.insert(into: context, settings: store.settings) }
                    )
                } else {
                    board(list)
                }
            }

            if !list.isEmpty {
                VStack(spacing: 10) {
                    if let toast {
                        ToastView(toast: toast) { self.toast = nil }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    NowButton(timeline: timeline, now: clock.now) { recenter(animated: true) }
                }
                .padding(.bottom, 12)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullWidth = $0 }
        .onChange(of: signature, initial: true) { rebuild() }
        .onChange(of: Calendar.current.startOfDay(for: clock.now)) { rebuild() }
        .task(id: toast?.id) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { toast = nil }
        }
        .sheet(item: $sheet) { sheetContent($0) }
        .fullScreenCover(item: $photoMed) { med in
            PhotoViewer(med: med)
        }
    }

    // MARK: Board

    private func rowHeight(_ med: Medication) -> CGFloat {
        MAR.rowHeight + (expanded.contains(med.id) ? (cardHeights[med.id] ?? 0) : 0)
    }

    @ViewBuilder
    private func board(_ list: [Medication]) -> some View {
        let heights = list.map(rowHeight)
        let total = heights.reduce(0, +)
        VStack(spacing: 0) {
            ColumnHeaderBar(timeline: timeline, count: list.count, now: clock.now)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    nameColumn(list)
                        .zIndex(1)
                    ScrollView(.horizontal) {
                        GridCanvas(timeline: timeline, meds: list, heights: heights,
                                   totalHeight: total, now: clock.now, handler: handler)
                    }
                    .scrollIndicators(.hidden)
                    .scrollPosition($position)
                    .frame(height: total)
                    .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                        ScrollMetrics(x: geo.contentOffset.x, width: geo.containerSize.width)
                    } action: { _, m in
                        timeline.updateScroll(x: m.x, viewport: m.width)
                    }
                    .onAppear {
                        guard !didInitialScroll else { return }
                        timeline.viewportWidth = max(200, fullWidth - MAR.nameWidth)
                        DispatchQueue.main.async {
                            recenter(animated: false)
                            didInitialScroll = true
                        }
                    }
                }
                .animation(.snappy(duration: 0.3), value: heights)
                .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func nameColumn(_ list: [Medication]) -> some View {
        VStack(spacing: 0) {
            ForEach(list) { med in
                let isOpen = expanded.contains(med.id)
                VStack(alignment: .leading, spacing: 0) {
                    NameCell(med: med,
                             isExpanded: isOpen,
                             isCompleted: med.isCompleted(at: clock.now),
                             onTap: { toggle(med) },
                             onQuickLog: { quickLog(med) })
                    if isOpen {
                        MedicationDetailCard(
                            med: med,
                            settings: store.settings,
                            now: clock.now,
                            onEdit: { sheet = .edit(med) },
                            onLog: { sheet = .dose(DoseTarget(med: med, slot: nil, record: nil)) },
                            onClose: { toggle(med) },
                            onPhoto: { photoMed = med }
                        )
                        .frame(width: max(280, fullWidth - 24))
                        .padding(.leading, 12)
                        .padding(.bottom, 12)
                        .fixedSize(horizontal: true, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                            withAnimation(.snappy(duration: 0.3)) { cardHeights[med.id] = h }
                        }
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                                                removal: .opacity))
                    }
                }
                .frame(width: MAR.nameWidth, height: rowHeight(med), alignment: .topLeading)
                .overlay(alignment: .bottom) {
                    if !isOpen { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                }
            }
        }
        .frame(width: MAR.nameWidth, alignment: .topLeading)
        .background(alignment: .trailing) {
            Rectangle().fill(Theme.hairline).frame(width: 1)
        }
    }

    // MARK: Actions

    private var handler: CellHandler {
        CellHandler(
            tap: { med, key, scheduled, record in handleTap(med: med, key: key, scheduled: scheduled, record: record) },
            set: { med, slot, status, atSlot in
                let existing = DoseActions.record(for: med, slot: slot)
                DoseActions.set(status, med: med, slot: slot, existing: existing,
                                takenAt: atSlot ? slot : clock.now, context: context)
                if status == .taken { Haptics.success() } else { Haptics.light() }
            },
            edit: { med, slot, record in sheet = .dose(DoseTarget(med: med, slot: slot, record: record)) }
        )
    }

    private func handleTap(med: Medication, key: Int, scheduled: Bool, record: DoseRecord?) {
        let slot = Date(minuteKey: key)
        guard scheduled else {
            if let record { sheet = .dose(DoseTarget(med: med, slot: nil, record: record)) }
            return
        }
        if let record {
            let previous = (record.status, record.takenAt, record.note)
            DoseActions.set(nil, med: med, slot: slot, existing: record, takenAt: slot, context: context)
            Haptics.light()
            show(Toast(message: "Cleared \(med.name) · \(Fmt.time(slot))") {
                DoseActions.set(previous.0, med: med, slot: slot, existing: nil,
                                takenAt: previous.1, note: previous.2, context: context)
            })
        } else if slot > clock.now.addingTimeInterval(2 * 3600) {
            sheet = .dose(DoseTarget(med: med, slot: slot, record: nil))
        } else {
            DoseActions.set(.taken, med: med, slot: slot, existing: nil,
                            takenAt: DoseActions.defaultTakenTime(slot: slot, now: clock.now), context: context)
            Haptics.success()
        }
    }

    private func quickLog(_ med: Medication) {
        guard let record = DoseActions.logNow(med, context: context) else { return }
        Haptics.success()
        var message = "\(med.name) logged at \(Fmt.time(record.takenAt))"
        if let hours = med.frequency.intervalHours {
            message += " · next after \(Fmt.time(record.takenAt.addingTimeInterval(hours * 3600)))"
        }
        show(Toast(message: message) {
            DoseActions.set(nil, med: med, slot: nil, existing: record, takenAt: .now, context: context)
        })
    }

    private func show(_ t: Toast) {
        withAnimation(.snappy) { toast = t }
    }

    private func toggle(_ med: Medication) {
        Haptics.tap()
        withAnimation(.snappy(duration: 0.3)) {
            if expanded.contains(med.id) { expanded.remove(med.id) } else { expanded.insert(med.id) }
        }
    }

    private func rebuild() {
        let corrected = timeline.rebuild(meds: visibleMeds, settings: store.settings, now: clock.now)
        if didInitialScroll, let corrected {
            position.scrollTo(x: corrected)
        }
    }

    private func recenter(animated: Bool) {
        let target = timeline.centeredOffset(for: clock.now)
        if animated {
            Haptics.tap()
            withAnimation(.smooth(duration: 0.55)) { position.scrollTo(x: target) }
        } else {
            position.scrollTo(x: target)
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ s: RootSheet) -> some View {
        switch s {
        case .newMedication:
            MedicationEditor(medication: nil)
        case .edit(let med):
            MedicationEditor(medication: med)
        case .settings:
            SettingsView()
        case .export:
            ExportView()
        case .manage:
            ManageView()
        case .dose(let target):
            DoseSheet(target: target)
                .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Header

struct SummaryHeader: View {
    let stats: TodayStats
    let now: Date
    let onAdd: () -> Void
    let onSettings: () -> Void
    let onExport: () -> Void
    let onManage: () -> Void

    private var progress: Double {
        stats.total == 0 ? 0 : Double(stats.resolved) / Double(stats.total)
    }

    private var headline: String {
        if stats.total == 0 { return "Nothing scheduled today" }
        if stats.resolved == stats.total { return stats.missed > 0 ? "\(stats.taken) of \(stats.total) taken" : "All done for today" }
        return "\(stats.taken) of \(stats.total) taken"
    }

    private var subline: (String, Color)? {
        if !stats.dueNow.isEmpty {
            let names = stats.dueNow.prefix(2).map(\.name).joined(separator: ", ")
            let more = stats.dueNow.count > 2 ? " +\(stats.dueNow.count - 2)" : ""
            return ("Due now · \(names)\(more)", Theme.honey)
        }
        if stats.overdue > 0 {
            return ("\(stats.overdue) overdue · not checked off", Theme.clay)
        }
        if let next = stats.next {
            let day = Calendar.current.isDateInToday(next.time) ? "" : "\(Fmt.dayLabel(next.time).lowercased()) "
            return ("Next · \(next.med.name) \(day)at \(Fmt.time(next.time))", Theme.inkSecondary)
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().stroke(Theme.sageSoft, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.sage, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth, value: progress)
                if stats.total > 0 && progress >= 1 {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.sage)
                } else {
                    Image(systemName: "pills.fill").font(.system(size: 13)).foregroundStyle(Theme.sage.opacity(0.8))
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.inkTertiary)
                Text(headline)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                if let subline {
                    Text(subline.0)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(subline.1)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button(action: onAdd) {
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).frame(width: 24, height: 24)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(Theme.sage)
                .accessibilityLabel("Add medication")

                Menu {
                    Button("Export & Share", systemImage: "square.and.arrow.up", action: onExport)
                    Button("Manage Medications", systemImage: "list.bullet", action: onManage)
                    Divider()
                    Button("Settings", systemImage: "gearshape", action: onSettings)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(Theme.ink)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }
}

// MARK: - Floating controls

struct NowButton: View {
    let timeline: TimelineModel
    let now: Date
    let action: () -> Void

    private var icon: String {
        guard let x = timeline.nowX(now) else { return "scope" }
        if x < timeline.scrollX + 24 { return "arrow.left" }
        if x > timeline.scrollX + timeline.viewportWidth - 24 { return "arrow.right" }
        return "scope"
    }

    var body: some View {
        Button(action: action) {
            Label("Now", systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.sage)
        .accessibilityLabel("Scroll to current time")
    }
}

struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            if let undo = toast.undo {
                Button("Undo") {
                    undo()
                    Haptics.tap()
                    dismiss()
                }
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.sage)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 24)
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let onAdd: () -> Void
    let onSample: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().fill(Theme.sageSoft).frame(width: 120, height: 120)
                Image(systemName: "pills")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(Theme.sage)
            }
            VStack(spacing: 6) {
                Text("Your medications, gently kept")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text("Add a medication to build your administration record. Doses line up on a timeline you can tick off, with alarms when they're due.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
            Button(action: onAdd) {
                Label("Add medication", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.sage)
            Button("Explore with sample data", action: onSample)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.inkSecondary)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
