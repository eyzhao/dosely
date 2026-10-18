import SwiftUI
import SwiftData
import MessageUI

struct ExportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(SettingsStore.self) private var store
    @Query(sort: \Medication.sortOrder) private var meds: [Medication]

    private enum Period: String, CaseIterable, Identifiable {
        case today = "Today", week = "7 days", month = "30 days", all = "All", custom = "Custom"
        var id: String { rawValue }
    }

    @State private var period: Period = .week
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -13, to: Calendar.current.startOfDay(for: .now))!
    @State private var customEnd = Date()
    @State private var includeList = true
    @State private var includeLog = true
    @State private var includeSummary = true
    @State private var selected: Set<UUID> = []
    @State private var search = ""
    @State private var showMail = false
    @State private var showMessage = false
    @State private var copied = false

    private var interval: (Date, Date) {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let endOfToday = cal.date(byAdding: .day, value: 1, to: today)!
        switch period {
        case .today: return (today, endOfToday)
        case .week: return (cal.date(byAdding: .day, value: -6, to: today)!, endOfToday)
        case .month: return (cal.date(byAdding: .day, value: -29, to: today)!, endOfToday)
        case .all:
            let earliest = meds.flatMap { [$0.startDate] + ($0.doses ?? []).map(\.chartTime) }.min() ?? today
            return (cal.startOfDay(for: earliest), endOfToday)
        case .custom:
            let s = cal.startOfDay(for: min(customStart, customEnd))
            let e = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(customStart, customEnd)))!
            return (s, e)
        }
    }

    private var text: String {
        let (s, e) = interval
        return ExportBuilder.build(
            meds: meds, settings: store.settings,
            options: .init(start: s, end: e.addingTimeInterval(-1),
                           includeList: includeList, includeLog: includeLog, includeSummary: includeSummary,
                           medicationIDs: selected, filter: search),
            now: .now)
    }

    private var subject: String {
        "Medication record · \(Date().formatted(date: .abbreviated, time: .omitted))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls
                    preview
                }
                .padding(16)
                .padding(.bottom, 90)
            }
            .background(Theme.canvas)
            .navigationTitle("Export & Share")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter log by name, status or note")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
            .safeAreaInset(edge: .bottom) { shareBar }
            .sheet(isPresented: $showMail) {
                MailComposer(subject: subject, body: text).ignoresSafeArea()
            }
            .sheet(isPresented: $showMessage) {
                MessageComposer(body: text).ignoresSafeArea()
            }
        }
        .tint(Theme.sage)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Period", selection: $period.animation()) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if period == .custom {
                HStack {
                    DatePicker("From", selection: $customStart, displayedComponents: .date).labelsHidden()
                    Image(systemName: "arrow.right").foregroundStyle(Theme.inkTertiary)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date).labelsHidden()
                }
            }

            HStack(spacing: 8) {
                toggleChip("Medications", isOn: $includeList)
                toggleChip("Log", isOn: $includeLog)
                toggleChip("Summary", isOn: $includeSummary)
                Spacer(minLength: 0)
                Menu {
                    Button {
                        selected = []
                    } label: {
                        if selected.isEmpty { Label("All medications", systemImage: "checkmark") }
                        else { Text("All medications") }
                    }
                    Divider()
                    ForEach(meds) { m in
                        Button {
                            if selected.contains(m.id) { selected.remove(m.id) } else { selected.insert(m.id) }
                        } label: {
                            if selected.contains(m.id) { Label(m.name, systemImage: "checkmark") }
                            else { Text(m.name) }
                        }
                    }
                } label: {
                    Label(selected.isEmpty ? "All" : "\(selected.count)", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.footnote.weight(.semibold))
                }
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func toggleChip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            Haptics.tap()
        } label: {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(isOn.wrappedValue ? Theme.sage : Theme.inkTertiary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(isOn.wrappedValue ? Theme.sageSoft : Theme.surfaceSunk, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var preview: some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(Theme.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var shareBar: some View {
        HStack(spacing: 10) {
            shareButton("Mail", icon: "envelope") {
                if MFMailComposeViewController.canSendMail() {
                    showMail = true
                } else if let url = composeURL(scheme: "mailto:?subject=\(encode(subject))&body=\(encode(text))") {
                    openURL(url)
                }
            }
            shareButton("Message", icon: "message") {
                if MFMessageComposeViewController.canSendText() {
                    showMessage = true
                } else if let url = composeURL(scheme: "sms:&body=\(encode(text))") {
                    openURL(url)
                }
            }
            shareButton(copied ? "Copied" : "Copy", icon: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = text
                Haptics.success()
                withAnimation { copied = true }
                Task { try? await Task.sleep(for: .seconds(1.6)); withAnimation { copied = false } }
            }
            ShareLink(item: text, subject: Text(subject)) {
                VStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .medium))
                    Text("More").font(.caption2.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func shareButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                Text(title).font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.glass)
    }

    private func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?+"))) ?? ""
    }

    private func composeURL(scheme: String) -> URL? { URL(string: scheme) }
}

// MARK: - Mail & Messages

struct MailComposer: UIViewControllerRepresentable {
    let subject: String
    let body: String
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator { dismiss() } }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) { done() }
    }
}

struct MessageComposer: UIViewControllerRepresentable {
    let body: String
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator { dismiss() } }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.messageComposeDelegate = context.coordinator
        vc.body = body
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) { done() }
    }
}
