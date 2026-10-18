import SwiftUI
import SwiftData

/// Reorder, archive, restore and delete medications.
struct ManageView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Medication.sortOrder), SortDescriptor(\Medication.createdAt)])
    private var meds: [Medication]

    @State private var editing: Medication?
    @State private var pendingDelete: Medication?

    private var active: [Medication] { meds.filter { !$0.isArchived && !$0.isCompleted(at: .now) } }
    private var completed: [Medication] { meds.filter { !$0.isArchived && $0.isCompleted(at: .now) } }
    private var archived: [Medication] { meds.filter(\.isArchived) }

    var body: some View {
        NavigationStack {
            List {
                if meds.isEmpty {
                    ContentUnavailableView("No medications yet", systemImage: "pills",
                                           description: Text("Add one from the board with the + button."))
                }
                if !active.isEmpty {
                    Section("Active") {
                        ForEach(active) { row($0) }
                            .onMove(perform: move)
                    }
                }
                if !completed.isEmpty {
                    Section("Completed courses") { ForEach(completed) { row($0) } }
                }
                if !archived.isEmpty {
                    Section("Archived") { ForEach(archived) { row($0) } }
                }
            }
            .navigationTitle("Medications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
            .sheet(item: $editing) { MedicationEditor(medication: $0) }
            .confirmationDialog("Delete \(pendingDelete?.name ?? "")?",
                                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Medication & History", role: .destructive) {
                    if let m = pendingDelete { context.delete(m); DoseActions.commit(context, scheduleChanged: true) }
                    pendingDelete = nil
                }
            } message: {
                Text("Every recorded dose for this medication will be removed too.")
            }
        }
        .tint(Theme.sage)
    }

    private func row(_ m: Medication) -> some View {
        Button { editing = m } label: {
            HStack(spacing: 12) {
                thumbnail(m)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(.body.weight(.medium)).foregroundStyle(Theme.ink)
                    Text([m.doseLine, m.isPRN ? "PRN" : ScheduleEngine.describe(m)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                if m.alarmsEnabled { Image(systemName: "alarm").font(.caption).foregroundStyle(Theme.inkTertiary) }
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { pendingDelete = m } label: { Label("Delete", systemImage: "trash") }
            Button {
                m.isArchived.toggle()
                m.updatedAt = .now
                DoseActions.commit(context, scheduleChanged: true)
            } label: {
                Label(m.isArchived ? "Restore" : "Archive", systemImage: m.isArchived ? "tray.and.arrow.up" : "archivebox")
            }
            .tint(Theme.lavender)
        }
    }

    @ViewBuilder
    private func thumbnail(_ m: Medication) -> some View {
        if let data = m.photoData, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Image(systemName: m.isPRN ? "cross.vial" : "pills")
                .foregroundStyle(m.isPRN ? Theme.lavender : Theme.sage)
                .frame(width: 38, height: 38)
                .background(m.isPRN ? Theme.lavenderSoft : Theme.sageSoft,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = active
        ordered.move(fromOffsets: source, toOffset: destination)
        for (i, m) in ordered.enumerated() { m.sortOrder = i }
        let offset = ordered.count
        for (i, m) in (completed + archived).enumerated() { m.sortOrder = offset + i }
        DoseActions.commit(context, scheduleChanged: true)
    }
}
