import LynxCore
import SwiftUI

/// Settings (SPEC §10).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal
    #if os(macOS)
    @State private var launchAtLogin = LaunchAtLogin.enabled
    @State private var loginError: String?
    #endif

    var body: some View {
        let s = model.settings
        ScrollView {
            VStack(alignment: .leading, spacing: Brand.Space.l) {
                Caption("Reminders")
                Panel(padding: 0) {
                    VStack(spacing: 0) {
                        FormRow("Default list") {
                            Picker("", selection: Binding(get: { s.defaultListId ?? model.defaultList?.id ?? UUID() },
                                                          set: { s.defaultListId = $0 })) {
                                ForEach(model.db.visibleLists) { Text($0.name).tag($0.id) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        Hairline()
                        FormRow("All-day alerts at") {
                            DatePicker("", selection: Binding(get: {
                                Calendar.current.date(bySettingHour: s.allDayAlertMinutes / 60, minute: s.allDayAlertMinutes % 60, second: 0, of: Date()) ?? Date()
                            }, set: { d in
                                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                                s.allDayAlertMinutes = (c.hour ?? 9) * 60 + (c.minute ?? 0)
                                model.rebuildAlerts()
                            }), displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                        }
                        Hairline()
                        FormRow("Default early alert") {
                            Picker("", selection: Binding(get: { s.defaultEarlyAlert }, set: { s.defaultEarlyAlert = $0 })) {
                                Text("None").tag(0)
                                ForEach([5, 15, 30, 60], id: \.self) { Text("\(Formats.duration(minutes: $0)) before").tag($0) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        Hairline()
                        FormRow("Default snooze") {
                            Picker("", selection: Binding(get: { s.defaultSnooze }, set: { s.defaultSnooze = $0 })) {
                                ForEach([5, 10, 15, 30, 60], id: \.self) { Text(Formats.duration(minutes: $0)).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        Hairline()
                        FormRow("Show completed in lists") {
                            Toggle("", isOn: Binding(get: { s.showCompleted }, set: { s.showCompleted = $0 }))
                                .labelsHidden().toggleStyle(.switch).tint(pal.toggleTint)
                        }
                    }
                }
                Text("Weeks start on the day your system uses.").font(Brand.caption).foregroundStyle(pal.muted)
                #if os(macOS)
                Caption("Mac")
                Panel(padding: 0) {
                    VStack(spacing: 0) {
                        FormRow("Open at login") {
                            Toggle("", isOn: Binding(get: { launchAtLogin }, set: { on in
                                do {
                                    try LaunchAtLogin.set(on)
                                    loginError = nil
                                } catch {
                                    loginError = "macOS refused: \(error.localizedDescription)"
                                }
                                launchAtLogin = LaunchAtLogin.enabled
                            })).labelsHidden().toggleStyle(.switch).tint(pal.toggleTint)
                        }
                        Hairline()
                        FormRow("Menu bar item") {
                            Toggle("", isOn: Binding(get: { s.showMenuBarExtra }, set: { s.showMenuBarExtra = $0 }))
                                .labelsHidden().toggleStyle(.switch).tint(pal.toggleTint)
                        }
                    }
                }
                Text(loginError ?? "Location, Bluetooth and app triggers work while Lynx runs. It keeps running in the menu bar when you close the window.")
                    .font(Brand.caption).foregroundStyle(loginError == nil ? pal.muted : pal.signal)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            }
            .padding(Brand.Space.xl)
        }
        .background(pal.bg)
        .themed()
        #if os(macOS)
        .frame(width: 460, height: 500)
        #endif
    }
}
