import Foundation
import LynxCore
import LynxSync
import Observation
import SwiftUI

/// What the sidebar selects.
enum SidebarItem: Hashable {
    case smart(SmartList)
    case list(UUID)
    case search
}

/// The app: local store, account, sync, notifications and triggers. Everything the UI does goes through here.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let store: LynxStore
    private(set) var db: LocalDatabase
    private(set) var device: DeviceState
    @ObservationIgnored private let deviceFile: JSONFile<DeviceState>
    let settings = AppSettings.shared

    // Account and sync
    let backend: LynxBackend?
    private(set) var user: SignedInUser?
    private(set) var profile: Profile?
    private(set) var syncing = false
    private(set) var syncError: String?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var realtime: RealtimeHandle?

    // UI state
    var selection: SidebarItem? = .smart(.today)
    var selectedReminder: UUID?
    /// The column an iPhone (collapsed split view) shows. Selection alone doesn't navigate there, so
    /// taps go through `show(_:)` / `showReminder(_:)`, which also set this.
    var compactColumn: NavigationSplitViewColumn = .sidebar
    var searchText = "" {
        didSet {
            if !searchText.isEmpty { selection = .search } else if selection == .search { selection = .smart(.today) }
        }
    }
    var focusSearch = 0
    var focusQuickAdd = 0
    var now = Date()
    var pendingGoalCompletion: UUID?
    var showAccount = false
    var showSettings = false
    var listEditor: ListEditorState?
    var shareListTarget: UUID?
    var shareReminderTarget: UUID?
    var toast: String?

    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var observer: UUID?
    @ObservationIgnored private var started = false
    @ObservationIgnored var notifications: NotificationService!
    @ObservationIgnored var triggers: TriggerService!

    var me: UUID? { user?.id }
    var signedIn: Bool { user != nil }
    var queries: SmartQueries { SmartQueries(db: db, me: me, now: now) }

    static var dataFolder: URL {
        if let dir = ProcessInfo.processInfo.environment["LYNX_DATA_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        return LynxPaths.dataFolder
    }

    private init() {
        let folder = Self.dataFolder
        store = LynxStore(folder: folder)
        db = store.snapshot
        deviceFile = JSONFile(url: folder.appendingPathComponent("device.json"))
        device = deviceFile.load() ?? DeviceState()
        // A scratch data folder (LYNX_DATA_DIR) keeps its session next to it, never in the Keychain.
        let scratch = ProcessInfo.processInfo.environment["LYNX_DATA_DIR"] != nil
        backend = BackendConfig.load().map { scratch ? LynxBackend(config: $0, sessionFolder: folder) : LynxBackend(config: $0) }
        notifications = NotificationService(model: self)
        triggers = TriggerService(model: self)
    }

    /// Called once from the app's first scene.
    func start() {
        guard !started else { return }
        started = true
        observer = store.observe { [weak self] newDb in
            Task { @MainActor in self?.storeChanged(newDb) }
        }
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        notifications.configure()
        notifications.purgeUnknown()
        if settings.onboarded { notifications.requestAuthorization() }
        if ProcessInfo.processInfo.environment["LYNX_DEMO"] == "1" { DemoData.seed(into: self) }
        ensureDefaultList()
        rebuildAlerts()
        triggers.refresh()
        Task { await restoreSession() }
    }

    private func tick() {
        now = Date()
    }

    private func storeChanged(_ newDb: LocalDatabase) {
        guard newDb != db else { return }
        db = newDb
    }

    // MARK: - Lifecycle

    func becameActive() {
        now = Date()
        rebuildAlerts()
        Task { await engine?.schedule(after: 0.2) }
    }

    func willTerminate() {
        store.flush()
        deviceFile.flush()
    }

    // MARK: - Account

    private func restoreSession() async {
        guard let backend else { return }
        guard let u = await backend.restoreSession() else {
            // Signed out elsewhere (or the session expired for good) while rows still belong to an account.
            return
        }
        signedIn(u)
    }

    /// After a successful sign-in: local-only rows are claimed and uploaded, sync starts.
    func signedIn(_ u: SignedInUser) {
        user = u
        settings.onboarded = true
        notifications.requestAuthorization()
        store.write { db in
            if db.accountId != u.id {
                if db.accountId != nil { db = LocalDatabase() }  // another account's leftovers
                db.claim(for: u.id, email: u.email)
            }
        }
        db = store.snapshot
        startSync()
        Task {
            if let p = try? await backend?.fetchProfile(u.id) { profile = p }
        }
    }

    private func startSync() {
        guard let backend, let u = user else { return }
        let engine = SyncEngine(store: store, remote: backend.remote, me: u.id)
        self.engine = engine
        Task {
            await engine.setReportHandler { report in
                Task { @MainActor in AppModel.shared.syncFinished(report) }
            }
            await self.runSync(manifest: true)
        }
        realtime?.stop()
        realtime = backend.startRealtime(
            onChange: { Task { await engine.schedule(after: 0.5) } },
            onReconnect: { Task { await engine.schedule(after: 0.5, manifest: true) } }
        )
    }

    func runSync(manifest: Bool = false) async {
        guard let engine else { return }
        syncing = true
        _ = await engine.syncNow(manifest: manifest)
        syncing = false
    }

    private func syncFinished(_ report: SyncReport) {
        syncError = report.error
        db = store.snapshot
        // Sign-in leaves the automatic list behind; only an account with no lists at all gets one back.
        if report.error == nil { ensureDefaultList() }
        if report.changed > 0 {
            rebuildAlerts()
            triggers.refresh()
        }
        if let sel = selectedReminder, db.reminders[sel] == nil || db.reminders[sel]?.isDeleted == true { selectedReminder = nil }
        if case .list(let id) = selection, db.list(id) == nil { selection = .smart(.today) }
    }

    enum SignOutData { case keep, remove }

    func signOut(_ data: SignOutData) async {
        realtime?.stop()
        realtime = nil
        await engine?.cancel()
        // Push what's left while we still can (best effort).
        if db.hasDirtyRows { await runSync() }
        engine = nil
        await backend?.signOut()
        user = nil
        profile = nil
        store.write { db in
            switch data {
            case .keep: db.detachAsLocalCopy()
            case .remove: db = LocalDatabase()
            }
        }
        db = store.snapshot
        selection = .smart(.today)
        selectedReminder = nil
        ensureDefaultList()
        rebuildAlerts()
        triggers.refresh()
    }

    func deleteAccount() async throws {
        guard let backend else { return }
        try await backend.deleteAccount()
        realtime?.stop()
        realtime = nil
        engine = nil
        user = nil
        profile = nil
        store.write { $0 = LocalDatabase() }
        db = store.snapshot
        settings.onboarded = false
        selectedReminder = nil
        ensureDefaultList()
        rebuildAlerts()
    }

    func updateDisplayName(_ name: String) async {
        guard let backend, let u = user else { return }
        try? await backend.updateDisplayName(name, user: u.id)
        profile = try? await backend.fetchProfile(u.id)
        await runSync()
    }

    // MARK: - Edits

    /// Every user edit: save locally, rebuild alerts, refresh triggers, sync in 1 s.
    @discardableResult
    private func mutate<T>(_ body: (inout LocalDatabase) -> T) -> T {
        let result = store.write(body)
        db = store.snapshot
        afterLocalChange()
        return result
    }

    private func afterLocalChange() {
        rebuildAlerts()
        triggers.refresh()
        Task { await engine?.schedule(after: 1) }
    }

    /// Opens a sidebar item: selects it, and on iPhone pushes its list.
    func show(_ item: SidebarItem) {
        selection = item
        compactColumn = .content
    }

    /// Opens a reminder: selects it, and on iPhone pushes its details.
    func showReminder(_ id: UUID) {
        selectedReminder = id
        compactColumn = .detail
    }

    func ensureDefaultList() {
        if db.visibleLists.isEmpty {
            let l = LynxList(ownerId: me, name: LynxList.defaultName, color: .ink, icon: .list, sortOrder: 1)
            store.write { $0.upsertList(l) }
            db = store.snapshot
        }
        if settings.defaultListId.flatMap({ db.list($0) }) == nil {
            settings.defaultListId = (queries.myLists.first ?? db.visibleLists.first)?.id
        }
    }

    var defaultList: LynxList? {
        settings.defaultListId.flatMap { db.list($0) } ?? db.visibleLists.first
    }

    /// The list a new reminder goes into from the current selection.
    var currentListForNew: UUID? {
        if case .list(let id) = selection, db.list(id) != nil { return id }
        return defaultList?.id
    }

    @discardableResult
    func createList(name: String, color: ListColor, icon: ListIcon) -> LynxList {
        let l = LynxList(ownerId: me, name: name.isEmpty ? "Untitled" : name, color: color, icon: icon, sortOrder: db.nextListSortOrder())
        mutate { $0.upsertList(l) }
        return l
    }

    func updateList(_ id: UUID, _ body: @escaping (inout LynxList) -> Void) {
        mutate { $0.editList(id, body) }
    }

    func deleteList(_ id: UUID) {
        mutate { $0.deleteList(id) }
        if selection == .list(id) { selection = .smart(.today) }
        ensureDefaultList()
    }

    /// Reorders lists within the given order (fractional sort_order: only moved rows change).
    func moveLists(_ ordered: [UUID], from source: IndexSet, to destination: Int) {
        var ids = ordered
        ids.move(fromOffsets: source, toOffset: destination)
        mutate { db in
            for (i, id) in ids.enumerated() where db.lists[id]?.sortOrder != Double(i + 1) {
                db.editList(id) { $0.sortOrder = Double(i + 1) }
            }
        }
    }

    /// Quick add (SPEC §7): parses dates, repeats, priority and #list.
    @discardableResult
    func quickAdd(_ text: String, list: UUID? = nil, parent: UUID? = nil, flagged: Bool = false) -> Reminder? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parsed = QuickAddParser.parse(trimmed, lists: db.visibleLists, now: Date())
        let parentRow = parent.flatMap { db.reminders[$0] }
        guard let listId = parentRow?.listId ?? parsed.listId ?? list ?? currentListForNew else { return nil }
        var r = Reminder(listId: listId, parentId: parent, createdBy: me, title: parsed.title.isEmpty ? trimmed : parsed.title,
                         sortOrder: db.nextReminderSortOrder(list: listId, parent: parent))
        r.dueAt = parsed.dueAt
        r.allDay = parsed.allDay
        r.repeat = parsed.repeat
        r.priority = parsed.priority
        r.flagged = flagged
        if r.dueAt != nil, !r.allDay, settings.defaultEarlyAlert > 0 { r.earlyAlertMinutes = settings.defaultEarlyAlert }
        mutate { $0.upsertReminder(r) }
        return db.reminders[r.id]
    }

    func updateReminder(_ id: UUID, _ body: @escaping (inout Reminder) -> Void) {
        mutate { $0.editReminder(id, body) }
    }

    func moveReminder(_ id: UUID, toList list: UUID) {
        mutate { $0.move(id, toList: list) }
    }

    /// Toggle from a checkbox. Completing a goal with open subtasks asks first (SPEC §2).
    func toggle(_ id: UUID) {
        guard let r = db.reminders[id] else { return }
        if r.isOpen, db.subtasks(of: id).contains(where: \.isOpen) {
            pendingGoalCompletion = id
            return
        }
        mutate { $0.toggleComplete(id, by: me) }
        clearDeviceState(for: id)
    }

    func completeGoal(_ id: UUID, includeSubtasks: Bool) {
        pendingGoalCompletion = nil
        mutate { $0.complete(id, by: me, includeSubtasks: includeSubtasks) }
        clearDeviceState(for: id)
    }

    /// "Done" from a notification: no UI, mark completed (or advance the repeat), then sync in the background.
    func completeFromNotification(_ id: UUID) {
        guard db.reminders[id]?.isOpen == true else { return }
        mutate { $0.complete(id, by: me, includeSubtasks: false) }
        clearDeviceState(for: id)
        Task { await engine?.schedule(after: 0.1) }
    }

    func deleteReminder(_ id: UUID) {
        mutate { $0.deleteReminder(id) }
        if selectedReminder == id { selectedReminder = nil }
        clearDeviceState(for: id)
    }

    func snooze(_ id: UUID, minutes: Int) {
        device.snoozes[id] = Date().addingTimeInterval(TimeInterval(minutes * 60))
        device.contextFired[id] = nil
        saveDevice()
        rebuildAlerts()
    }

    private func clearDeviceState(for id: UUID) {
        guard db.reminders[id]?.isOpen != true else { return }
        device.snoozes[id] = nil
        device.contextFired[id] = nil
        saveDevice()
        rebuildAlerts()
    }

    func updateDevice(_ body: (inout DeviceState) -> Void) {
        body(&device)
        saveDevice()
    }

    private func saveDevice() { deviceFile.save(device) }

    // MARK: - Alerts and triggers

    func rebuildAlerts() {
        let open = Set(db.reminders.values.filter(\.isOpen).map(\.id))
        device.prune(open: open, now: Date())
        notifications.schedule(NotificationPlanner.plan(db: db, device: device, now: Date(), settings: settings.plannerSettings))
    }

    /// A context trigger happened (location, Bluetooth, app): notify matching reminders (cooldown 15 min) and start nags.
    func handleTrigger(_ event: TriggerEvent, platform: TriggerPlatform) {
        let now = Date()
        let hits = TriggerMatcher.reminders(for: event, in: db, device: device, now: now, platform: platform)
        guard !hits.isEmpty else { return }
        TriggerMatcher.recordFired(hits, event: event, device: &device, now: now)
        saveDevice()
        for r in hits { notifications.postContext(r, event: event, list: db.lists[r.listId]?.name) }
        rebuildAlerts()
    }

    // MARK: - Sharing

    func shareList(_ id: UUID, email: String) async throws -> ShareResult {
        guard let backend else { throw RemoteError.network("No server configured") }
        if db.dirtyLists.contains(id) { await runSync() }  // the list must exist on the server first
        let r = try await backend.shareList(id, email: email)
        await runSync(manifest: true)
        return r
    }

    func unshareList(_ id: UUID, user: UUID) async throws {
        try await backend?.unshareList(id, user: user)
        await runSync(manifest: true)
    }

    func leaveList(_ id: UUID) async throws {
        try await backend?.leaveList(id)
        await runSync(manifest: true)
        if selection == .list(id) { selection = .smart(.today) }
    }

    /// The share sheets' check while typing: what sharing would do, without sharing.
    func sharePreview(email: String, list: UUID? = nil, reminder: UUID? = nil) async throws -> ShareResult {
        guard let backend else { throw RemoteError.network("No server configured") }
        return try await backend.sharePreview(email: email, list: list, reminder: reminder)
    }

    func shareReminder(_ id: UUID, email: String) async throws -> ShareResult {
        guard let backend else { throw RemoteError.network("No server configured") }
        if db.dirtyReminders.contains(id) { await runSync() }
        let r = try await backend.shareReminder(id, email: email)
        await runSync(manifest: true)
        return r
    }

    func unshareReminder(_ id: UUID, user: UUID) async throws {
        try await backend?.unshareReminder(id, user: user)
        await runSync(manifest: true)
    }

    func cancelInvite(_ id: UUID) async throws {
        try await backend?.cancelInvite(id)
        await runSync()
    }

    // MARK: - Helpers for views

    func list(for r: Reminder) -> LynxList? { db.lists[r.listId] }

    func color(for r: Reminder) -> ListColor { db.lists[r.listId]?.listColor ?? .ink }

    func title(for item: SidebarItem) -> String {
        switch item {
        case .smart(let s): return s.title
        case .list(let id): return db.lists[id]?.name ?? ""
        case .search: return "Search"
        }
    }

    func isOwner(of listId: UUID) -> Bool {
        guard let l = db.lists[listId] else { return false }
        return l.ownerId == nil || l.ownerId == me
    }
}

/// The list editor sheet: nil id = a new list.
struct ListEditorState: Identifiable {
    var id: UUID?
    var name: String
    var color: ListColor
    var icon: ListIcon
    var identity: String { id?.uuidString ?? "new" }
}

extension ListEditorState {
    var sheetId: String { identity }
}
