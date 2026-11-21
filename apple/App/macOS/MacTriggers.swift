import AppKit
import IOBluetooth
import LynxCore
import ServiceManagement

/// macOS-only observers (SPEC §6.1): IOBluetooth connect/disconnect notifications and
/// NSWorkspace didActivateApplication. They run while the app runs (it keeps running with no window open).
@MainActor
final class MacTriggers: NSObject {
    var onEvent: ((TriggerEvent) -> Void)?
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    private var appObserver: NSObjectProtocol?
    /// IOBluetooth reports already-connected devices right after registering; those are not new connections.
    private var bluetoothStartedAt = Date.distantPast

    func setBluetoothNeeded(_ needed: Bool) {
        if needed, connectNote == nil {
            bluetoothStartedAt = Date()
            connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        } else if !needed, let n = connectNote {
            n.unregister()
            connectNote = nil
            for d in disconnectNotes.values { d.unregister() }
            disconnectNotes = [:]
        }
    }

    @objc nonisolated private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? device.nameOrAddress ?? ""
        let address = device.addressString ?? ""
        let box = UncheckedSendable(device)
        // IOBluetooth calls back on its own queue (via CoreBluetooth), not the main thread.
        Task { @MainActor in
            if self.disconnectNotes[address] == nil {
                self.disconnectNotes[address] = box.value.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
            }
            guard Date().timeIntervalSince(self.bluetoothStartedAt) > 3 else { return }
            self.onEvent?(.bluetooth(name: name, id: address, event: .connect))
        }
    }

    @objc nonisolated private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? device.nameOrAddress ?? ""
        let address = device.addressString ?? ""
        let box = UncheckedSendable(note)
        Task { @MainActor in
            box.value.unregister()
            self.disconnectNotes[address] = nil
            self.onEvent?(.bluetooth(name: name, id: address, event: .disconnect))
        }
    }

    func setAppsNeeded(_ needed: Bool) {
        if needed, appObserver == nil {
            appObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                let name = app.localizedName ?? ""
                let bundle = app.bundleIdentifier
                Task { @MainActor in self?.onEvent?(.app(name: name, bundleId: bundle)) }
            }
        } else if !needed, let o = appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            appObserver = nil
        }
    }

    // MARK: Pickers

    struct PairedDevice: Identifiable, Hashable {
        var id: String { address }
        let name: String
        let address: String
        let connected: Bool
    }

    /// `IOBluetoothDevice.pairedDevices()` (SPEC §6.3 picker).
    static func pairedDevices() -> [PairedDevice] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.compactMap { d in
            guard let address = d.addressString else { return nil }
            return PairedDevice(name: d.name ?? address, address: address, connected: d.isConnected())
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    struct InstalledApp: Identifiable, Hashable {
        var id: String { bundleId }
        let name: String
        let bundleId: String
        let url: URL
    }

    /// /Applications (+ Utilities, ~/Applications, /System/Applications) and running apps (SPEC §6.4 picker).
    static func installedApps() -> [InstalledApp] {
        let fm = FileManager.default
        var dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]
            .map { URL(fileURLWithPath: $0) }
        dirs.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        var seen = Set<String>()
        var out: [InstalledApp] = []
        func add(_ url: URL) {
            guard let b = Bundle(url: url), let id = b.bundleIdentifier, !seen.contains(id), id != Bundle.main.bundleIdentifier else { return }
            seen.insert(id)
            let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            out.append(InstalledApp(name: name, bundleId: id, url: url))
        }
        for dir in dirs {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for u in items where u.pathExtension == "app" { add(u) }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let u = app.bundleURL { add(u) }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Launch at login (SPEC §10) through SMAppService.
enum LaunchAtLogin {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
