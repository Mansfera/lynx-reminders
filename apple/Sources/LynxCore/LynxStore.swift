import Foundation

/// The app data folder: `~/Library/Application Support/com.mansfera.lynxreminders/` (SPEC header).
public enum LynxPaths {
    public static let appId = "com.mansfera.lynxreminders"

    public static var dataFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appId, isDirectory: true)
    }
}

/// A Codable value persisted as JSON: atomic writes (temp file + rename), debounced.
public final class JSONFile<Value: Codable & Sendable>: @unchecked Sendable {
    public let url: URL
    private let queue: DispatchQueue
    private let delay: TimeInterval
    private var pending: Value?
    private var scheduled = false
    private let lock = NSLock()

    public init(url: URL, delay: TimeInterval = 0.4) {
        self.url = url
        self.delay = delay
        queue = DispatchQueue(label: "\(LynxPaths.appId).file.\(url.lastPathComponent)")
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? LynxJSON.decoder().decode(Value.self, from: data)
    }

    /// Schedules a write; several saves within `delay` collapse into one.
    public func save(_ value: Value) {
        lock.lock()
        pending = value
        let needSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard needSchedule else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flush() }
    }

    /// Writes the pending value now (call before the process exits).
    public func flush() {
        lock.lock()
        let value = pending
        pending = nil
        scheduled = false
        lock.unlock()
        guard let value else { return }
        write(value)
    }

    public func writeNow(_ value: Value) {
        lock.lock()
        pending = nil
        lock.unlock()
        write(value)
    }

    private func write(_ value: Value) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try LynxJSON.encoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Lynx: could not save \(url.lastPathComponent): \(error)")
        }
    }

    public func delete() {
        lock.lock()
        pending = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }
}

/// The single source of truth on a device: the local database behind a lock, persisted as `store.json`.
/// The UI reads snapshots and writes through `write`; the sync engine does the same from its actor.
public final class LynxStore: @unchecked Sendable {
    private let lock = NSLock()
    private var db: LocalDatabase
    private let file: JSONFile<LocalDatabase>?
    private var observers: [UUID: @Sendable (LocalDatabase) -> Void] = [:]

    /// In-memory store (tests, previews).
    public init(_ db: LocalDatabase = LocalDatabase()) {
        self.db = db
        file = nil
    }

    /// Store persisted to `folder/store.json`.
    public init(folder: URL) {
        let f = JSONFile<LocalDatabase>(url: folder.appendingPathComponent("store.json"))
        file = f
        db = f.load() ?? LocalDatabase()
    }

    public var snapshot: LocalDatabase {
        lock.lock()
        defer { lock.unlock() }
        return db
    }

    public func read<T>(_ body: (LocalDatabase) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(db)
    }

    /// Mutates the database atomically, persists (debounced) and notifies observers if anything changed.
    @discardableResult
    public func write<T>(_ body: (inout LocalDatabase) throws -> T) rethrows -> T {
        lock.lock()
        var copy = db
        let result: T
        do {
            result = try body(&copy)
        } catch {
            lock.unlock()
            throw error
        }
        let changed = copy != db
        if changed { db = copy }
        let obs = Array(observers.values)
        lock.unlock()
        if changed {
            file?.save(copy)
            for o in obs { o(copy) }
        }
        return result
    }

    @discardableResult
    public func observe(_ body: @escaping @Sendable (LocalDatabase) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = body
        lock.unlock()
        return id
    }

    public func removeObserver(_ id: UUID) {
        lock.lock()
        observers[id] = nil
        lock.unlock()
    }

    public func flush() { file?.flush() }
}
