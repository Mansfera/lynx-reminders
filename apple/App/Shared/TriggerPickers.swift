import CoreLocation
import LynxCore
import MapKit
import SwiftUI

/// Sheet chrome shared by the pickers: title, a Done pill, content.
struct SheetScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    var doneTitle = "Done"
    var doneDisabled = false
    let onCancel: () -> Void
    let onDone: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.palette) private var pal

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Brand.title)
                    if let subtitle { Text(subtitle).font(Brand.caption).foregroundStyle(pal.muted) }
                }
                Spacer()
                LinkButton(title: "Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                InkPill(title: doneTitle, symbol: "checkmark", action: onDone)
                    .disabled(doneDisabled)
                    .keyboardShortcut(.defaultAction)
            }
            content
        }
        .padding(Brand.Space.xl)
        .background(pal.bg)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420)
        #endif
    }
}

// MARK: - Location (SPEC §6.2)

struct LocationPickerSheet: View {
    let reminderId: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var pal

    @State private var query = ""
    @FocusState private var queryFocused: Bool
    @State private var results: [MKMapItem] = []
    @State private var pin: CLLocationCoordinate2D?
    @State private var name = ""
    @State private var address: String?
    @State private var radius: Double = 150
    @State private var on: LocationEvent = .arrive
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var searching = false
    @State private var locating = false

    var body: some View {
        SheetScaffold(title: "Location", subtitle: "Alerts when you arrive or leave — on this device, while the app runs.",
                      doneDisabled: pin == nil, onCancel: { dismiss() }, onDone: save) {
            HStack(spacing: Brand.Space.s) {
                HStack(spacing: Brand.Space.xs) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(pal.muted)
                    TextField("Search for a place or address", text: $query).textFieldStyle(.plain).font(Brand.text(13))
                        .focused($queryFocused)
                        .onSubmit(search)
                    if searching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, Brand.Space.m).padding(.vertical, Brand.Space.s)
                .background(pal.sunk, in: Capsule())
                .focusOnTap($queryFocused, Capsule())
                RoundIconButton(symbol: "location.fill", label: "Current location", filled: false) { useCurrent() }
                    .opacity(locating ? 0.5 : 1)
            }
            if !results.isEmpty {
                Panel(padding: 0) {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(results.prefix(8).enumerated()), id: \.offset) { i, item in
                                if i > 0 { Hairline() }
                                Button { choose(item) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name ?? "Place").font(Brand.text(13))
                                        Text(Self.address(item.placemark)).font(Brand.caption).foregroundStyle(pal.muted).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Brand.Space.l).padding(.vertical, Brand.Space.s)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }
            MapReader { proxy in
                Map(position: $camera) {
                    UserAnnotation()
                    if let pin {
                        MapCircle(center: pin, radius: radius)
                            .foregroundStyle(pal.fg.opacity(0.12))
                            .stroke(pal.fg.opacity(0.6), lineWidth: 1.5)
                        Annotation(name.isEmpty ? "Pin" : name, coordinate: pin) {
                            Circle().fill(pal.fg).frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(pal.bg, lineWidth: 3))
                                .gesture(DragGesture(coordinateSpace: .named("map")).onChanged { v in
                                    if let c = proxy.convert(v.location, from: .named("map")) { self.pin = c }
                                }.onEnded { _ in reverseGeocode() })
                        }
                    }
                }
                .coordinateSpace(.named("map"))
                .onTapGesture(coordinateSpace: .named("map")) { p in
                    if let c = proxy.convert(p, from: .named("map")) {
                        pin = c
                        if name.isEmpty { name = "Pinned place" }
                        reverseGeocode()
                    }
                }
                .mapControls {
                    #if os(macOS)
                    MapZoomStepper()
                    #endif
                    MapCompass()
                    #if os(iOS)
                    MapUserLocationButton()
                    #endif
                }
            }
            .frame(minHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(pal.line))
            Text(Platform.isMac ? "Click the map to drop the pin, drag it to adjust." : "Tap the map to drop the pin, drag it to adjust.").font(Brand.caption).foregroundStyle(pal.muted)
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    FormRow("Name") {
                        TextField("Home", text: $name).textFieldStyle(.plain).font(Brand.text(13)).multilineTextAlignment(.trailing)
                    }
                    Hairline()
                    FormRow("When I") {
                        CapsuleTabs(items: [(LocationEvent.arrive, "Arrive"), (.leave, "Leave")], selection: $on)
                    }
                    Hairline()
                    FormRow("Radius") {
                        Slider(value: $radius, in: 100...2000, step: 50).frame(maxWidth: 200).tint(pal.fg)
                        Text("\(Int(radius)) m").font(Brand.mono(11)).frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        // Ask up front so the map can show where you are (the dot and its button need permission).
        if model.triggers.authorization == .notDetermined { model.triggers.requestAlways() }
        guard let l = model.db.reminders[reminderId]?.location else { return }
        let c = CLLocationCoordinate2D(latitude: l.lat, longitude: l.lon)
        pin = c
        name = l.name
        address = l.address
        radius = l.radius
        on = l.on
        camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: max(800, l.radius * 5), longitudinalMeters: max(800, l.radius * 5)))
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        if let pin { req.region = MKCoordinateRegion(center: pin, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        Task {
            let resp = try? await MKLocalSearch(request: req).start()
            results = resp?.mapItems ?? []
            searching = false
            if results.count == 1 { choose(results[0]) }
        }
    }

    private func choose(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        pin = c
        name = item.name ?? name
        address = Self.address(item.placemark)
        results = []
        camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: max(800, radius * 5), longitudinalMeters: max(800, radius * 5)))
    }

    private func useCurrent() {
        locating = true
        Task {
            let loc = await model.triggers.currentLocation()
            locating = false
            guard let loc else {
                model.toast = model.triggers.locationAllowed
                    ? "Couldn't find where you are. Try again in a moment."
                    : "Location is off for Lynx. Allow it in Settings → Permissions."
                return
            }
            pin = loc.coordinate
            if name.isEmpty { name = "Here" }
            camera = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 800, longitudinalMeters: 800))
            reverseGeocode()
        }
    }

    private func reverseGeocode() {
        guard let pin else { return }
        Task {
            let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: pin.latitude, longitude: pin.longitude))
            if let m = marks?.first { address = Self.address(m) }
        }
    }

    static func address(_ p: CLPlacemark) -> String {
        [p.thoroughfare.map { t in p.subThoroughfare.map { "\(t) \($0)" } ?? t }, p.locality, p.country]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private func save() {
        guard let pin else { return }
        let trig = LocationTrigger(name: name.isEmpty ? (address ?? "Place") : name, address: address,
                                   lat: pin.latitude, lon: pin.longitude, radius: radius, on: on)
        model.updateReminder(reminderId) { $0.location = trig }
        model.triggers.requestAlways()
        dismiss()
    }
}

// MARK: - Bluetooth (SPEC §6.3)

struct BluetoothPickerSheet: View {
    let reminderId: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var pal
    @State private var name = ""
    @State private var macId: String?
    @State private var on: BluetoothEvent = .connect
    #if os(macOS)
    @State private var devices: [MacTriggers.PairedDevice] = []
    #endif

    var body: some View {
        SheetScaffold(title: "Bluetooth", subtitle: subtitle, doneDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty,
                      onCancel: { dismiss() }, onDone: save) {
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    FormRow("When") {
                        CapsuleTabs(items: [(BluetoothEvent.connect, "Connects"), (.disconnect, "Disconnects")], selection: $on)
                    }
                    Hairline()
                    FormRow("Device name") {
                        TextField("AirPods Pro", text: $name).textFieldStyle(.plain).font(Brand.text(13)).multilineTextAlignment(.trailing)
                            .onChange(of: name) { _, n in if let d = pairedName(macId), d != n { macId = nil } }
                    }
                }
            }
            #if os(macOS)
            Caption("Paired devices")
            Panel(padding: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        if devices.isEmpty {
                            Text("No paired devices found. Type the name above.").font(Brand.caption).foregroundStyle(pal.muted)
                                .padding(Brand.Space.l)
                        }
                        ForEach(Array(devices.enumerated()), id: \.element.id) { i, d in
                            if i > 0 { Hairline() }
                            Button { name = d.name; macId = d.address } label: {
                                HStack {
                                    Image(systemName: "headphones").foregroundStyle(pal.muted)
                                    Text(d.name).font(Brand.text(13))
                                    if d.connected { Text("connected").font(Brand.mono(10, .regular)).foregroundStyle(pal.muted) }
                                    Spacer()
                                    if macId == d.address { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)) }
                                }
                                .padding(.horizontal, Brand.Space.l).padding(.vertical, Brand.Space.s)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            #else
            ShortcutsGuideInline(kind: "Bluetooth")
            #endif
            Spacer(minLength: 0)
        }
        .onAppear {
            if let b = model.db.reminders[reminderId]?.bluetooth {
                name = b.name
                on = b.on
                macId = b.ids?["mac"]
            }
            #if os(macOS)
            devices = MacTriggers.pairedDevices()
            #endif
        }
    }

    private var subtitle: String {
        Platform.isMac ? "Alerts when the device connects or disconnects while the app runs."
            : "iOS can't watch Bluetooth for apps; a Shortcuts automation tells Lynx instead."
    }

    private func pairedName(_ id: String?) -> String? {
        #if os(macOS)
        return devices.first { $0.address == id }?.name
        #else
        return nil
        #endif
    }

    private func save() {
        let existing = model.db.reminders[reminderId]?.bluetooth
        var ids = existing?.ids ?? [:]
        // Keep the other platform's id only if it is still the same device (same name).
        if existing?.name.caseInsensitiveCompare(name) != .orderedSame { ids = [:] }
        #if os(macOS)
        ids["mac"] = macId
        #endif
        let trig = BluetoothTrigger(name: name.trimmingCharacters(in: .whitespaces), on: on, ids: ids.isEmpty ? nil : ids)
        model.updateReminder(reminderId) { $0.bluetooth = trig }
        dismiss()
    }
}

// MARK: - App opened (SPEC §6.4)

struct AppPickerSheet: View {
    let reminderId: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var pal
    @State private var name = ""
    @State private var bundleId: String?
    @State private var filter = ""
    @FocusState private var filterFocused: Bool
    #if os(macOS)
    @State private var apps: [MacTriggers.InstalledApp] = []
    #endif

    var body: some View {
        SheetScaffold(title: "App opened", subtitle: Platform.isMac ? "Alerts when you switch to this app." : "Runs through a Shortcuts automation on iOS.",
                      doneDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty, onCancel: { dismiss() }, onDone: save) {
            #if os(macOS)
            HStack(spacing: Brand.Space.xs) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(pal.muted)
                TextField("Filter apps", text: $filter).textFieldStyle(.plain).font(Brand.text(13))
                    .focused($filterFocused)
            }
            .padding(.horizontal, Brand.Space.m).padding(.vertical, Brand.Space.s)
            .background(pal.sunk, in: Capsule())
            .focusOnTap($filterFocused, Capsule())
            Panel(padding: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let shown = apps.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, app in
                            if i > 0 { Hairline() }
                            Button { name = app.name; bundleId = app.bundleId } label: {
                                HStack(spacing: Brand.Space.s) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 22, height: 22)
                                    Text(app.name).font(Brand.text(13))
                                    Spacer()
                                    if bundleId == app.bundleId { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)) }
                                }
                                .padding(.horizontal, Brand.Space.l).padding(.vertical, Brand.Space.xs)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 260)
            }
            #else
            Panel(padding: 0) {
                FormRow("App name") {
                    TextField("Slack", text: $name).textFieldStyle(.plain).font(Brand.text(13)).multilineTextAlignment(.trailing)
                }
            }
            ShortcutsGuideInline(kind: "App")
            Spacer(minLength: 0)
            #endif
        }
        .onAppear {
            if let a = model.db.reminders[reminderId]?.appTrigger {
                name = a.name
                bundleId = a.apple
            }
            #if os(macOS)
            apps = MacTriggers.installedApps()
            #endif
        }
    }

    private func save() {
        let existing = model.db.reminders[reminderId]?.appTrigger
        let sameApp = existing?.name.caseInsensitiveCompare(name) == .orderedSame
        let trig = AppTrigger(name: name.trimmingCharacters(in: .whitespaces), apple: bundleId ?? (sameApp ? existing?.apple : nil),
                              android: sameApp ? existing?.android : nil)
        model.updateReminder(reminderId) { $0.appTrigger = trig }
        dismiss()
    }
}

// MARK: - iOS Shortcuts guide (SPEC §6.1)

/// Explains the Shortcuts personal automation that runs "Fire Lynx trigger".
struct ShortcutsGuideInline: View {
    let kind: String
    @Environment(\.palette) private var pal
    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s) {
            Caption("Set up once in Shortcuts")
            Panel {
                VStack(alignment: .leading, spacing: Brand.Space.s) {
                    ForEach(Array(ShortcutsGuideSheet.steps(kind).enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .top, spacing: Brand.Space.s) {
                            Text("\(i + 1)").font(Brand.mono(11)).frame(width: 20, height: 20).background(pal.sunk, in: Circle())
                            Text(step).font(Brand.text(13)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

struct ShortcutsGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var pal

    static func steps(_ kind: String) -> [String] {
        let trigger = kind == "App" ? "App, choose the app, and tick “Is Opened”" : "Bluetooth, choose the device, and pick “Is Connected” (or “Is Disconnected”)"
        return [
            "Open Shortcuts → Automation → New Automation.",
            "Pick \(trigger). Set “Run Immediately”.",
            "Add the action “Fire Lynx trigger” from Lynx Reminders.",
            kind == "App" ? "Kind: App · Name: the app's name, exactly as in the reminder · Event: Open."
                : "Kind: Bluetooth · Name: the device name, exactly as in the reminder · Event: Connect or Disconnect.",
            "Done. Lynx alerts every open reminder that matches, at most once per 15 minutes.",
        ]
    }

    var body: some View {
        SheetScaffold(title: "Shortcuts automation", subtitle: "iOS lets apps hear about Bluetooth and other apps only through Shortcuts.",
                      onCancel: { dismiss() }, onDone: { dismiss() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Brand.Space.l) {
                    ShortcutsGuideInline(kind: "Bluetooth")
                    ShortcutsGuideInline(kind: "App")
                }
            }
        }
    }
}
