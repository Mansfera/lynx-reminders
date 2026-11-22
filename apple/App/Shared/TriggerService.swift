import CoreLocation
import Foundation
import LynxCore

/// Context triggers on this device (SPEC §6). Location uses CLMonitor on both platforms; Bluetooth and
/// app-opened use IOBluetooth / NSWorkspace on macOS (MacTriggers) and the FireTriggerIntent on iOS.
@MainActor
final class TriggerService: NSObject {
    private unowned let model: AppModel
    private let manager = CLLocationManager()
    private var monitor: CLMonitor?
    /// CLMonitor asserts when two monitors with one name exist: create it once, and run one region pass at a time.
    private var monitorCreation: Task<CLMonitor, Never>?
    private var applyingRegions = false
    private var regionsAgain = false
    private var monitorTask: Task<Void, Never>?
    private var monitored: [String: RegionPlanner.Region] = [:]
    private var refreshTask: Task<Void, Never>?
    private var locationWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    #if os(macOS)
    let mac = MacTriggers()
    #endif

    /// iOS monitors at most 20 regions per app → the nearest 20 (SPEC §6.1). macOS uses the same cap.
    static let regionLimit = 20

    init(model: AppModel) {
        self.model = model
        super.init()
        manager.delegate = self
        authorization = manager.authorizationStatus
        #if os(macOS)
        mac.onEvent = { [weak model] event in model?.handleTrigger(event, platform: .mac) }
        #endif
    }

    /// Re-reads the store: which regions to monitor, whether Bluetooth/app observers are needed. Debounced.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.apply()
        }
    }

    private func apply() async {
        let db = model.db
        let open = db.reminders.values.filter(\.isOpen)
        #if os(macOS)
        mac.setBluetoothNeeded(open.contains { $0.bluetooth != nil })
        mac.setAppsNeeded(open.contains { $0.appTrigger != nil })
        #endif
        await applyRegions(db)
    }

    // MARK: Location

    private func applyRegions(_ db: LocalDatabase) async {
        if applyingRegions { regionsAgain = true; return }
        applyingRegions = true
        defer {
            applyingRegions = false
            if regionsAgain { regionsAgain = false; refresh() }
        }
        let hasLocation = db.reminders.values.contains { $0.isOpen && $0.location != nil }
        guard hasLocation || !monitored.isEmpty else { return }
        if hasLocation, authorization == .notDetermined { requestAlways() }
        guard authorization == .authorizedAlways || authorization == .authorized else { return }
        let origin = manager.location.map { (lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        let wanted = RegionPlanner.regions(in: db, near: origin, limit: Self.regionLimit)
        let wantedById = Dictionary(wanted.map { (Self.identifier($0), $0) }, uniquingKeysWith: { a, _ in a })
        if monitor == nil {
            if monitorCreation == nil {
                monitorCreation = Task { await CLMonitor("LynxRegions") }
            }
            let m = await monitorCreation!.value
            if monitor == nil {
                monitor = m
                startListening(m)
            }
        }
        guard let monitor else { return }
        for id in monitored.keys where wantedById[id] == nil {
            await monitor.remove(id)
            monitored[id] = nil
        }
        for (id, region) in wantedById where monitored[id] == nil {
            let condition = CLMonitor.CircularGeographicCondition(
                center: CLLocationCoordinate2D(latitude: region.lat, longitude: region.lon), radius: region.radius)
            await monitor.add(condition, identifier: id, assuming: .unknown)
            monitored[id] = region
        }
    }

    /// `<reminder id>|<lat>|<lon>|<radius>`: a moved region gets a new identifier and fresh state.
    static func identifier(_ r: RegionPlanner.Region) -> String {
        "\(r.reminderId.uuidString)|\(String(format: "%.5f|%.5f|%.0f", r.lat, r.lon, r.radius))"
    }

    private func startListening(_ m: CLMonitor) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            do {
                for try await event in await m.events {
                    let id = event.identifier
                    let state = event.state
                    await MainActor.run { self?.regionEvent(id: id, state: state) }
                }
            } catch {}
        }
    }

    private func regionEvent(id: String, state: CLMonitor.Event.State) {
        guard let reminderId = UUID(uuidString: String(id.split(separator: "|").first ?? "")) else { return }
        let now: String
        switch state {
        case .satisfied: now = "inside"
        case .unsatisfied: now = "outside"
        default: return
        }
        let before = model.device.regionStates[id]
        model.updateDevice { $0.regionStates[id] = now }
        // Only a change between two known states is an arrival or a departure; the first reading just records
        // where we are (no "arrive" when the app starts at home).
        guard let before, before != now else { return }
        model.handleTrigger(.location(regionId: reminderId, event: now == "inside" ? .arrive : .leave),
                            platform: Platform.triggerPlatform)
    }

    func requestAlways() {
        #if os(iOS)
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.requestAlwaysAuthorization()
        #else
        manager.requestAlwaysAuthorization()
        #endif
    }

    var locationAllowed: Bool {
        #if os(iOS)
        authorization == .authorizedAlways || authorization == .authorizedWhenInUse
        #else
        authorization == .authorizedAlways || authorization == .authorized
        #endif
    }

    /// Settings → Permissions: the first tap asks the system, and on iOS a second tap asks to upgrade
    /// "While using" to "Always" (iOS shows that prompt once). Returns false when only the Settings app can change it.
    func askForLocation() -> Bool {
        switch authorization {
        case .notDetermined:
            requestAlways()
            return true
        #if os(iOS)
        case .authorizedWhenInUse where !UserDefaults.standard.bool(forKey: "askedAlwaysLocation"):
            UserDefaults.standard.set(true, forKey: "askedAlwaysLocation")
            manager.requestAlwaysAuthorization()
            return true
        #endif
        default:
            return false
        }
    }

    /// One-shot current location for the picker. Asks for permission first and waits for the answer:
    /// `requestLocation()` before that fails straight away.
    func currentLocation() async -> CLLocation? {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
            await withCheckedContinuation { authorizationWaiters.append($0) }
        }
        guard locationAllowed else { return nil }
        if let last = manager.location, -last.timestamp.timeIntervalSinceNow < 60 { return last }
        return await withCheckedContinuation { cont in
            locationWaiters.append(cont)
            manager.requestLocation()
        }
    }

    fileprivate func deliver(_ loc: CLLocation?) {
        let waiters = locationWaiters
        locationWaiters = []
        for w in waiters { w.resume(returning: loc) }
    }

    fileprivate func authorizationChanged(_ status: CLAuthorizationStatus) {
        authorization = status
        model.locationAuthorization = status
        if status != .notDetermined {
            let waiters = authorizationWaiters
            authorizationWaiters = []
            for w in waiters { w.resume() }
        }
        refresh()
    }
}

extension TriggerService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationChanged(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        Task { @MainActor in self.deliver(loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let last = manager.location
        Task { @MainActor in self.deliver(last) }
    }
}
