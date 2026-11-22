import CoreLocation
import LynxCore
import SwiftUI
import UserNotifications

/// Settings (SPEC §10).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var pal
    @State private var claudeKey = ""
    @State private var connecting = false
    @State private var claudeError: String?
    @AppStorage("permissionsHidden") private var permissionsHidden = false
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
                claudeSection(s)
                permissionsSection
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
        .frame(width: 460, height: 720)
        #endif
    }

    /// AI reads quick add (SPEC §7a): Apple Intelligence on the device (free, private), or Claude with the user's
    /// own Anthropic key (Claude subscriptions can't sign in to other apps).
    @ViewBuilder private func claudeSection(_ s: AppSettings) -> some View {
        let device = model.onDeviceStatus
        // With no AI on this device and no Claude key, there is nothing to switch: only the Claude section shows.
        if model.quickAddReader != nil || device.shown {
        Caption("AI")
        Panel(padding: 0) {
            VStack(spacing: 0) {
                FormRow("AI reads new reminders") {
                    Toggle("", isOn: Binding(get: { s.aiReadsQuickAdd }, set: { s.aiReadsQuickAdd = $0 }))
                        .labelsHidden().toggleStyle(.switch).tint(pal.toggleTint)
                        .disabled(model.quickAddReader == nil)
                }
                if model.claudeConnected, device == .available {
                    Hairline()
                    FormRow("Read with") {
                        Picker("", selection: Binding(get: { s.quickAddReader }, set: { s.quickAddReader = $0 })) {
                            Text(OnDeviceAI.name).tag(QuickAddAI.Reader.device)
                            Text("Claude").tag(QuickAddAI.Reader.claude)
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                if device.shown {
                    Hairline()
                    FormRow(OnDeviceAI.name) {
                        Text(device.label).font(Brand.mono(11)).foregroundStyle(pal.muted)
                    }
                }
            }
        }
        Text("AI reads each line you type into “New reminder” and fills in the date, repeat, priority and list. "
             + "Tap its name in the field to turn it off."
             + (device.shown ? " \(OnDeviceAI.name) runs on this device: free, and nothing leaves it." : ""))
            .font(Brand.caption).foregroundStyle(pal.muted).fixedSize(horizontal: false, vertical: true)
        }

        Caption("Claude")
            .task { model.refreshOnDevice() }
        Panel(padding: 0) {
            VStack(spacing: 0) {
                if model.claudeConnected {
                    FormRow("Anthropic key") {
                        Text("Connected").font(Brand.mono(11)).foregroundStyle(pal.muted)
                        SoftButton(title: "Remove", role: .destructive) { model.disconnectClaude() }
                    }
                    Hairline()
                    FormRow("Model") {
                        Picker("", selection: Binding(get: { s.claudeModel }, set: { s.claudeModel = $0 })) {
                            if !model.claudeModels.contains(where: { $0.id == s.claudeModel }) {
                                Text(s.claudeModel).tag(s.claudeModel)  // before the list loads
                            }
                            ForEach(model.claudeModels) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().fixedSize()
                    }
                } else {
                    FormRow("Anthropic key") {
                        SecureField("sk-ant-…", text: $claudeKey)
                            .textFieldStyle(.plain).font(Brand.mono(12)).frame(maxWidth: 170)
                            .onSubmit(connectClaude)
                        if connecting {
                            ProgressView().controlSize(.small)
                        } else {
                            SoftButton(title: "Connect", action: connectClaude)
                        }
                    }
                }
            }
        }
        .task(id: model.claudeConnected) { await model.loadClaudeModels() }
        if let claudeError {
            Text(claudeError).font(Brand.caption).foregroundStyle(pal.signal).fixedSize(horizontal: false, vertical: true)
        }
        Text("With Claude, the line, your list names and the current time go to Anthropic with your own API key, billed to it. "
             + "Haiku is the quickest and cheapest; larger models read tricky lines better but take longer. "
             + "The key stays on this device. Claude Pro and Max subscriptions can't sign in to other apps.")
            .font(Brand.caption).foregroundStyle(pal.muted).fixedSize(horizontal: false, vertical: true)
        if !model.claudeConnected {
            LinkButton(title: "Get a key at console.anthropic.com") {
                Platform.open(URL(string: "https://console.anthropic.com/settings/keys")!)
            }
        }
    }

    // MARK: Permissions

    private var notificationsGranted: Bool {
        switch model.notificationsAuthorization {
        case .authorized, .provisional: true
        #if os(iOS)
        case .ephemeral: true
        #endif
        default: false
        }
    }

    private var locationGranted: Bool {
        model.locationAuthorization == .authorizedAlways
    }

    private var locationDetail: String {
        #if os(iOS)
        if model.locationAuthorization == .authorizedWhenInUse {
            return "Set to While Using: choose Always so arrive / leave alerts work while the app is closed"
        }
        return "For arrive / leave reminders while the app is closed"
        #else
        return "For arrive / leave reminders"
        #endif
    }

    /// Same rows as Android's Settings → Permissions. Once everything is granted it can be hidden; it comes back by
    /// itself if a permission is turned off later.
    @ViewBuilder private var permissionsSection: some View {
        let allGranted = notificationsGranted && locationGranted
        if !(allGranted && permissionsHidden) {
            HStack {
                Caption("Permissions")
                Spacer()
                if allGranted {
                    Button("Hide") { withAnimation(Motion.content) { permissionsHidden = true } }
                        .buttonStyle(.plain).font(Brand.text(11, .medium)).foregroundStyle(pal.muted)
                }
            }
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    PermissionRow(title: "Notifications", detail: "Needed for every alert", granted: notificationsGranted) {
                        if model.notificationsAuthorization == .notDetermined {
                            model.notifications.requestAuthorization()
                        } else {
                            Platform.openSettings(.notifications)
                        }
                    }
                    Hairline()
                    PermissionRow(title: Platform.isMac ? "Location" : "Location, all the time", detail: locationDetail, granted: locationGranted) {
                        if !model.triggers.askForLocation() { Platform.openSettings(.location) }
                    }
                }
            }
            .task { await model.notifications.refreshStatus() }
        }
    }

    private func connectClaude() {
        let key = claudeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !connecting else { return }
        connecting = true
        claudeError = nil
        Task {
            do {
                try await model.connectClaude(key)
                claudeKey = ""
            } catch {
                claudeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            connecting = false
        }
    }
}

/// A permission with what it's for; "Allow" until granted, then a check.
private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let allow: () -> Void
    @Environment(\.palette) private var pal

    var body: some View {
        HStack(spacing: Brand.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Brand.text(13))
                Text(detail).font(Brand.caption).foregroundStyle(pal.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Brand.Space.s)
            if granted {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(pal.fg)
                    .accessibilityLabel("Granted")
            } else {
                SoftButton(title: "Allow", action: allow)
            }
        }
        .padding(.horizontal, Brand.Space.l)
        .padding(.vertical, Brand.Space.s)
        .frame(minHeight: Platform.isMac ? 40 : 44)
    }
}
