package com.mansfera.lynxreminders.core

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Duration
import java.time.Instant

/** Thrown by a [RemoteStore] for HTTP/PostgREST failures. */
class RemoteException(val status: Int, val pgCode: String? = null, message: String? = null) : Exception(message ?: "HTTP $status $pgCode") {
    /** Row-level security rejected the write (SPEC §4: 403 / 42501). */
    val isRlsReject: Boolean get() = status == 403 || pgCode == "42501"
}

/** The server as the sync engine sees it (PostgREST semantics, SPEC §4). */
interface RemoteStore {
    suspend fun pullLists(afterVersion: Long, limit: Int): List<ListRow>
    suspend fun pullReminders(afterVersion: Long, limit: Int): List<ReminderRow>
    suspend fun listsByIds(ids: List<String>): List<ListRow>
    suspend fun remindersByIds(ids: List<String>): List<ReminderRow>
    suspend fun members(): List<MemberRow>
    suspend fun shares(): List<ShareRow>
    suspend fun invites(): List<InviteRow>
    suspend fun manifest(): List<ManifestEntry>
    /** Upsert (`on_conflict=id`, merge-duplicates) and return the stored representation. */
    suspend fun upsertLists(rows: List<ListRow>): List<ListRow>
    suspend fun upsertReminders(rows: List<ReminderRow>): List<ReminderRow>
}

/** Local database access for the engine. [update] must apply the transform atomically to the latest state. */
interface DbStore {
    val current: LocalDb
    suspend fun update(transform: (LocalDb) -> LocalDb)
}

data class SyncReport(
    val changedRows: Int,
    val pushed: Int,
    val rejected: Int,
    val ranManifest: Boolean,
) {
    val changed get() = changedRows > 0 || rejected > 0
}

/**
 * The sync run of SPEC §4: pull → memberships → manifest (when needed) → push.
 * Runs are serialized. Never applies realtime payloads; callers just schedule [sync].
 */
class SyncEngine(
    private val remote: RemoteStore,
    private val db: DbStore,
    private val clock: () -> Instant = Instant::now,
    private val pageSize: Int = 500,
    private val batchSize: Int = 100,
) {
    private val mutex = Mutex()

    companion object {
        val MANIFEST_EVERY: Duration = Duration.ofHours(6)

        /** Merge rule: take the server row unless the local one is dirty and newer. */
        fun shouldTakeServer(localUpdated: Instant?, localDirty: Boolean, serverUpdated: Instant): Boolean =
            localUpdated == null || !localDirty || !serverUpdated.isBefore(localUpdated)
    }

    suspend fun sync(forceManifest: Boolean = false): SyncReport = mutex.withLock { runOnce(forceManifest) }

    private suspend fun runOnce(forceManifest: Boolean): SyncReport {
        var changed = 0
        // 1. Pull
        changed += pullAll()

        // 2. Memberships
        val me = db.current.me
        val before = membershipKey(db.current, me)
        val members = remote.members()
        val shares = remote.shares()
        val invites = remote.invites()
        db.update { it.copy(members = members, shares = shares, invites = invites) }
        val membershipChanged = membershipKey(db.current, me) != before

        // 3. Manifest
        val last = db.current.sync.lastManifestAt
        val due = last == null || Duration.between(last, clock()) >= MANIFEST_EVERY
        val runManifest = forceManifest || membershipChanged || due
        if (runManifest) changed += manifestStep()

        // 4. Push
        val (pushed, rejected) = push()

        db.update { it.copy(sync = it.sync.copy(lastSyncAt = clock())) }
        return SyncReport(changed + pushed.changedLocally, pushed.count, rejected, runManifest)
    }

    private fun membershipKey(d: LocalDb, me: String): Set<String> =
        d.members.filter { it.userId == me }.map { "l:${it.listId}" }.toSet() +
            d.shares.filter { it.userId == me }.map { "r:${it.reminderId}" }.toSet()

    private suspend fun pullAll(): Int {
        var changed = 0
        while (true) {
            val page = remote.pullLists(db.current.sync.cursorLists, pageSize)
            changed += mergeLists(page, advanceCursor = true)
            if (page.size < pageSize) break
        }
        while (true) {
            val page = remote.pullReminders(db.current.sync.cursorReminders, pageSize)
            changed += mergeReminders(page, advanceCursor = true)
            if (page.size < pageSize) break
        }
        return changed
    }

    private suspend fun mergeLists(rows: List<ListRow>, advanceCursor: Boolean): Int {
        if (rows.isEmpty()) return 0
        var changed = 0
        db.update { d ->
            val lists = d.lists.toMutableMap()
            val dirty = d.dirtyLists.toMutableSet()
            for (s in rows) {
                val local = lists[s.id]
                if (shouldTakeServer(local?.updatedAt, s.id in dirty, s.updatedAt)) {
                    if (local != s) changed++
                    lists[s.id] = s
                    dirty.remove(s.id)
                }
            }
            val cursor = if (advanceCursor) maxOf(d.sync.cursorLists, rows.maxOf { it.version }) else d.sync.cursorLists
            d.copy(lists = lists, dirtyLists = dirty, sync = d.sync.copy(cursorLists = cursor))
        }
        return changed
    }

    private suspend fun mergeReminders(rows: List<ReminderRow>, advanceCursor: Boolean): Int {
        if (rows.isEmpty()) return 0
        var changed = 0
        db.update { d ->
            val rem = d.reminders.toMutableMap()
            val dirty = d.dirtyReminders.toMutableSet()
            for (s in rows) {
                val local = rem[s.id]
                if (shouldTakeServer(local?.updatedAt, s.id in dirty, s.updatedAt)) {
                    if (local != s) changed++
                    rem[s.id] = s
                    dirty.remove(s.id)
                }
            }
            val cursor = if (advanceCursor) maxOf(d.sync.cursorReminders, rows.maxOf { it.version }) else d.sync.cursorReminders
            d.copy(reminders = rem, dirtyReminders = dirty, sync = d.sync.copy(cursorReminders = cursor))
        }
        return changed
    }

    private suspend fun manifestStep(): Int {
        var changed = 0
        val manifest = remote.manifest()
        val cur = db.current
        val listV = manifest.filter { it.t == "lists" }.associate { it.id to it.v }
        val remV = manifest.filter { it.t == "reminders" }.associate { it.id to it.v }

        val staleLists = listV.filter { (id, v) -> cur.lists[id]?.version != v }.keys.toList()
        val staleRem = remV.filter { (id, v) -> cur.reminders[id]?.version != v }.keys.toList()
        for (chunk in staleLists.chunked(batchSize)) changed += mergeLists(remote.listsByIds(chunk), advanceCursor = false)
        for (chunk in staleRem.chunked(batchSize)) changed += mergeReminders(remote.remindersByIds(chunk), advanceCursor = false)

        // Clean rows that vanished from the manifest: access lost → remove locally. Dirty rows stay (they will push).
        db.update { d ->
            val lists = d.lists.filter { (id, _) -> id in listV || id in d.dirtyLists }
            val rem = d.reminders.filter { (id, _) -> id in remV || id in d.dirtyReminders }
            changed += (d.lists.size - lists.size) + (d.reminders.size - rem.size)
            d.copy(lists = lists, reminders = rem, sync = d.sync.copy(lastManifestAt = clock()))
        }
        return changed
    }

    private data class Pushed(val count: Int, val changedLocally: Int)

    private suspend fun push(): Pair<Pushed, Int> {
        var count = 0
        var rejected = 0
        var changedLocally = 0
        val snap = db.current

        // Lists first
        val lists = snap.dirtyLists.mapNotNull { snap.lists[it] }
        for (chunk in lists.chunked(batchSize)) {
            val r = pushChunk(chunk, { remote.upsertLists(it) }, { listOf(it) }) { ok, bad ->
                markListsClean(chunk, ok); bad.forEach { dropAndRefetchList(it.id, it.updatedAt) }
                // Missing from the response = skipped by last-writer-wins: mark clean and re-fetch
                val back = ok.map { it.id }.toSet(); val badIds = bad.map { it.id }.toSet()
                chunk.filter { it.id !in back && it.id !in badIds }.forEach { dropAndRefetchList(it.id, it.updatedAt) }
            }
            count += r.first; rejected += r.second
        }

        // Then reminders: parents before subtasks
        val dirtyRem = snap.dirtyReminders.mapNotNull { snap.reminders[it] }
        val ordered = dirtyRem.filter { it.parentId == null } + dirtyRem.filter { it.parentId != null }
        for (chunk in ordered.chunked(batchSize)) {
            val r = pushChunk(chunk, { remote.upsertReminders(it) }, { listOf(it) }) { ok, bad ->
                markRemindersClean(chunk, ok); bad.forEach { dropAndRefetchReminder(it.id, it.updatedAt) }
                val back = ok.map { it.id }.toSet(); val badIds = bad.map { it.id }.toSet()
                chunk.filter { it.id !in back && it.id !in badIds }.forEach { dropAndRefetchReminder(it.id, it.updatedAt) }
            }
            count += r.first; rejected += r.second
        }
        changedLocally += rejected
        return Pushed(count, changedLocally) to rejected
    }

    /**
     * Pushes a batch; when RLS rejects the batch (it is one transaction on the server) the rows are
     * retried one by one so a single forbidden row does not block the others.
     */
    private suspend fun <T> pushChunk(
        chunk: List<T>,
        upsert: suspend (List<T>) -> List<T>,
        single: (T) -> List<T>,
        apply: suspend (ok: List<T>, rejected: List<T>) -> Unit,
    ): Pair<Int, Int> {
        try {
            val stored = upsert(chunk)
            apply(stored, emptyList())
            return chunk.size to 0
        } catch (e: RemoteException) {
            if (!e.isRlsReject) throw e
        }
        val ok = ArrayList<T>()
        val bad = ArrayList<T>()
        for (row in chunk) {
            try {
                ok += upsert(single(row))
            } catch (e: RemoteException) {
                if (e.isRlsReject) bad += row else throw e
            }
        }
        apply(ok, bad)
        return ok.size to bad.size
    }

    private suspend fun markListsClean(sent: List<ListRow>, stored: List<ListRow>) {
        val byId = stored.associateBy { it.id }
        db.update { d ->
            val lists = d.lists.toMutableMap()
            val dirty = d.dirtyLists.toMutableSet()
            for (s in sent) {
                val back = byId[s.id] ?: continue
                val local = lists[s.id]
                // Edited again while the push was in flight → keep it dirty for the next run
                if (local != null && local.updatedAt.isAfter(s.updatedAt)) continue
                lists[s.id] = back
                dirty.remove(s.id)
            }
            d.copy(lists = lists, dirtyLists = dirty)
        }
    }

    private suspend fun markRemindersClean(sent: List<ReminderRow>, stored: List<ReminderRow>) {
        val byId = stored.associateBy { it.id }
        db.update { d ->
            val rem = d.reminders.toMutableMap()
            val dirty = d.dirtyReminders.toMutableSet()
            for (s in sent) {
                val back = byId[s.id] ?: continue
                val local = rem[s.id]
                if (local != null && local.updatedAt.isAfter(s.updatedAt)) continue
                rem[s.id] = back
                dirty.remove(s.id)
            }
            d.copy(reminders = rem, dirtyReminders = dirty)
        }
    }

    private suspend fun dropAndRefetchList(id: String, sentUpdated: Instant) {
        val fresh = remote.listsByIds(listOf(id)).firstOrNull()
        db.update { d ->
            // Edited again after the push started → keep that newer local edit for the next run
            if (d.lists[id]?.updatedAt?.isAfter(sentUpdated) == true) return@update d
            val lists = d.lists.toMutableMap()
            if (fresh != null) lists[id] = fresh else lists.remove(id)
            d.copy(lists = lists, dirtyLists = d.dirtyLists - id)
        }
    }

    private suspend fun dropAndRefetchReminder(id: String, sentUpdated: Instant) {
        val fresh = remote.remindersByIds(listOf(id)).firstOrNull()
        db.update { d ->
            if (d.reminders[id]?.updatedAt?.isAfter(sentUpdated) == true) return@update d
            val rem = d.reminders.toMutableMap()
            if (fresh != null) rem[id] = fresh else rem.remove(id)
            d.copy(reminders = rem, dirtyReminders = d.dirtyReminders - id)
        }
    }
}

/** Sign-in: local rows created before the account get the user's id and are marked dirty (SPEC §1). */
fun LocalDb.adoptedBy(userId: String, email: String?): LocalDb {
    // Rows deleted before they were ever synced never need to reach the server
    val lists = lists.filterValues { !(it.isDeleted && it.version == 0L) }.mapValues { (_, l) -> if (l.ownerId == LOCAL_USER_ID) l.copy(ownerId = userId) else l }
    val rem = reminders.filterValues { !(it.isDeleted && it.version == 0L) }.mapValues { (_, r) ->
        r.copy(
            createdBy = if (r.createdBy == LOCAL_USER_ID) userId else r.createdBy,
            completedBy = if (r.completedBy == LOCAL_USER_ID) userId else r.completedBy,
            assigneeId = if (r.assigneeId == LOCAL_USER_ID) userId else r.assigneeId,
        )
    }
    val localLists = lists.filterValues { it.version == 0L }.keys
    val localRem = rem.filterValues { it.version == 0L }.keys
    return copy(
        userId = userId, email = email, lists = lists, reminders = rem,
        dirtyLists = (dirtyLists + localLists).filter { it in lists }.toSet(),
        dirtyReminders = (dirtyReminders + localRem).filter { it in rem }.toSet(),
    )
}
