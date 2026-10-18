import SwiftUI
import SwiftData

@main
struct DoselyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var clock = Clock()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(SettingsStore.shared)
                .environment(AlarmScheduler.shared)
                .environment(clock)
                .tint(Theme.sage)
                .fontDesign(.rounded)
                .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { clock.now = $0 }
                // A clock or time-zone change moves every dose: rebuild all alarms.
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                    clock.now = .now
                    AlarmScheduler.shared.requestSync(full: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    clock.now = .now
                    AlarmScheduler.shared.requestSync(full: true)
                }
                .task { AlarmScheduler.shared.requestSync(delay: .seconds(1)) }
        }
        .modelContainer(DataStore.shared.container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                clock.now = .now
                AlarmScheduler.shared.refreshAuthorization()
                AlarmScheduler.shared.requestSync(delay: .milliseconds(300))
            }
        }
        .backgroundTask(.appRefresh(AlarmScheduler.refreshTaskID)) {
            await AlarmScheduler.shared.sync()
        }
    }
}
