package com.mansfera.lynxreminders.core

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** In-memory server with the §4 semantics: versions, LWW by updated_at, RLS rejections, manifest. */
class FakeRemote(private val me: String) : RemoteStore {
    var seq = 0L
    val lists = linkedMapOf<String, ListRow>()
    val reminders = linkedMapOf<String, ReminderRow>()
    val members = mutableListOf<MemberRow>()
    val forbidden = mutableSetOf<String>() // ids RLS rejects on write
    val hidden = mutableSetOf<String>() // ids the caller can no longer see
    val upsertCalls = mutableListOf<List<String>>()

    fun serverList(id: String, name: String, updated: String, owner: String = me): ListRow {
        val r = ListRow(id, owner, name, createdAt = Instant.parse(updated), updatedAt = Instant.parse(updated), version = ++seq)
        lists[id] = r
        if (members.none { it.listId == id && it.userId == owner }) members += MemberRow(id, owner, "owner")
        return r
    }

    fun serverReminder(id: String, listId: String, title: String, updated: String, parent: String? = null): ReminderRow {
        val r = ReminderRow(id, listId, parent, me, title = title, createdAt = Instant.parse(updated), updatedAt = Instant.parse(updated), version = ++seq)
        reminders[id] = r
        return r
    }

    private fun visibleLists() = lists.values.filter { it.id !in hidden }
    private fun visibleRem() = reminders.values.filter { it.id !in hidden && it.listId !in hidden }

    override suspend fun pullLists(afterVersion: Long, limit: Int) = visibleLists().filter { it.version > afterVersion }.sortedBy { it.version }.take(limit)
    override suspend fun pullReminders(afterVersion: Long, limit: Int) = visibleRem().filter { it.version > afterVersion }.sortedBy { it.version }.take(limit)
    override suspend fun listsByIds(ids: List<String>) = visibleLists().filter { it.id in ids }
    override suspend fun remindersByIds(ids: List<String>) = visibleRem().filter { it.id in ids }
    override suspend fun members() = members.toList()
    override suspend fun shares() = emptyList<ShareRow>()
    override suspend fun invites() = emptyList<InviteRow>()
    override suspend fun manifest() = visibleLists().map { ManifestEntry("lists", it.id, it.version) } + visibleRem().map { ManifestEntry("reminders", it.id, it.version) }

    override suspend fun upsertLists(rows: List<ListRow>): List<ListRow> {
        upsertCalls += rows.map { "L:" + it.id }
        if (rows.any { it.id in forbidden }) throw RemoteException(403, "42501")
        return rows.mapNotNull { r ->
            val cur = lists[r.id]
            if (cur != null && r.updatedAt.isBefore(cur.updatedAt)) null
            else r.copy(version = ++seq).also {
                lists[r.id] = it
                if (cur == null) members += MemberRow(r.id, r.ownerId, "owner")
            }
        }
    }

    override suspend fun upsertReminders(rows: List<ReminderRow>): List<ReminderRow> {
        upsertCalls += rows.map { "R:" + it.id }
        if (rows.any { it.id in forbidden }) throw RemoteException(403, "42501")
        return rows.mapNotNull { r ->
            // Mimic the FK: a subtask cannot arrive before its parent
            if (r.parentId != null) require(reminders.containsKey(r.parentId)) { "parent ${r.parentId} missing" }
            val cur = reminders[r.id]
            // Last-writer-wins: an older write is skipped and missing from the response
            if (cur != null && r.updatedAt.isBefore(cur.updatedAt)) null
            else r.copy(version = ++seq).also { reminders[r.id] = it }
        }
    }
}

class MemDb(var d: LocalDb) : DbStore {
    override val current get() = d
    override suspend fun update(transform: (LocalDb) -> LocalDb) { d = transform(d) }
}

class SyncEngineTest {
    private val me = "11111111-1111-1111-1111-111111111111"
    private val t0 = "2026-11-14T08:00:00Z"
    private fun i(s: String) = Instant.parse(s)

    private fun localReminder(id: String, listId: String, title: String, updated: String, parent: String? = null, version: Long = 0) =
        ReminderRow(id, listId, parent, me, title = title, createdAt = i(updated), updatedAt = i(updated), version = version)

    @Test
    fun pullReplacesCleanRowsAndAdvancesCursor() = runTest {
        val remote = FakeRemote(me)
        remote.serverList("L1", "Home", t0)
        remote.serverReminder("R1", "L1", "server title", t0)
        val db = MemDb(LocalDb(userId = me))
        val engine = SyncEngine(remote, db, clock = { i("2026-11-14T09:00:00Z") })
        val rep = engine.sync()
        assertEquals("server title", db.d.reminders["R1"]!!.title)
        assertEquals(remote.seq, maxOf(db.d.sync.cursorLists, db.d.sync.cursorReminders))
        assertTrue(rep.changed)
        // Nothing new → nothing changes
        assertFalse(engine.sync().changed)
    }

    @Test
    fun dirtyNewerLocalRowWinsOverOlderServerRow() = runTest {
        val remote = FakeRemote(me)
        remote.serverList("L1", "Home", t0)
        remote.serverReminder("R1", "L1", "server old", "2026-11-14T08:00:00Z")
        val local = localReminder("R1", "L1", "local newer", "2026-11-14T08:30:00Z", version = 0)
        val db = MemDb(LocalDb(userId = me, reminders = mapOf("R1" to local), dirtyReminders = setOf("R1")))
        SyncEngine(remote, db, clock = { i("2026-11-14T09:00:00Z") }).sync()
        // Kept locally during pull, then pushed and accepted
        assertEquals("local newer", db.d.reminders["R1"]!!.title)
        assertEquals("local newer", remote.reminders["R1"]!!.title)
        assertTrue(db.d.dirtyReminders.isEmpty())
    }

    @Test
    fun newerServerRowBeatsDirtyLocalRow() = runTest {
        val remote = FakeRemote(me)
        remote.serverList("L1", "Home", t0)
        remote.serverReminder("R1", "L1", "server newer", "2026-11-14T09:00:00Z")
        val local = localReminder("R1", "L1", "local older", "2026-11-14T08:30:00Z")
        val db = MemDb(LocalDb(userId = me, reminders = mapOf("R1" to local), dirtyReminders = setOf("R1")))
        SyncEngine(remote, db).sync()
        assertEquals("server newer", db.d.reminders["R1"]!!.title)
        assertFalse("R1" in db.d.dirtyReminders)
    }

    @Test
    fun equalTimestampsTakeServer() {
        assertTrue(SyncEngine.shouldTakeServer(i(t0), true, i(t0)))
        assertTrue(SyncEngine.shouldTakeServer(i(t0), false, i("2026-01-01T00:00:00Z")))
        assertFalse(SyncEngine.shouldTakeServer(i(t0), true, i("2026-01-01T00:00:00Z")))
        assertTrue(SyncEngine.shouldTakeServer(null, false, i(t0)))
    }

    @Test
    fun manifestRemovesCleanRowsOnlyAndRefetchesStale() = runTest {
        val remote = FakeRemote(me)
        remote.serverList("L1", "Home", t0)
        val r1 = remote.serverReminder("R1", "L1", "kept", t0)
        val gone = localReminder("GONE", "L1", "access lost", t0, version = 3)
        val draft = localReminder("DRAFT", "L1", "not pushed yet", t0)
        val stale = r1.copy(title = "stale", version = r1.version - 1)
        val db = MemDb(
            LocalDb(
                userId = me,
                lists = mapOf("L1" to remote.lists["L1"]!!),
                reminders = mapOf("R1" to stale, "GONE" to gone, "DRAFT" to draft),
                dirtyReminders = setOf("DRAFT"),
                sync = SyncState(cursorLists = remote.seq, cursorReminders = remote.seq),
            ),
        )
        val rep = SyncEngine(remote, db).sync(forceManifest = true)
        assertTrue(rep.ranManifest)
        assertNull("clean row missing from manifest is removed", db.d.reminders["GONE"])
        assertEquals("kept", db.d.reminders["R1"]!!.title) // stale version refetched
        assertTrue("dirty row is kept and pushed", remote.reminders.containsKey("DRAFT"))
    }

    @Test
    fun pushesListsFirstThenParentsBeforeSubtasks() = runTest {
        val remote = FakeRemote(me)
        val list = ListRow("L9", me, "New", createdAt = i(t0), updatedAt = i(t0))
        val sub = localReminder("S1", "L9", "sub", t0, parent = "P1")
        val parent = localReminder("P1", "L9", "goal", t0)
        val db = MemDb(
            LocalDb(
                userId = me, lists = mapOf("L9" to list), reminders = linkedMapOf("S1" to sub, "P1" to parent),
                dirtyLists = setOf("L9"), dirtyReminders = linkedSetOf("S1", "P1"),
            ),
        )
        SyncEngine(remote, db).sync()
        val order = remote.upsertCalls.flatten()
        assertEquals(listOf("L:L9", "R:P1", "R:S1"), order)
        assertTrue(db.d.dirtyLists.isEmpty() && db.d.dirtyReminders.isEmpty())
        assertTrue(db.d.reminders["S1"]!!.version > 0)
    }

    @Test
    fun rlsRejectDropsLocalChangeAndRefetches() = runTest {
        val remote = FakeRemote(me)
        remote.serverList("L1", "Shared", t0, owner = "someone-else")
        remote.serverReminder("R1", "L1", "server", t0)
        remote.forbidden += "R1"
        val edited = remote.reminders["R1"]!!.copy(title = "my edit", updatedAt = i("2026-11-14T10:00:00Z"))
        val ok = localReminder("R2", "L1", "allowed", t0)
        val db = MemDb(
            LocalDb(
                userId = me, lists = mapOf("L1" to remote.lists["L1"]!!), reminders = mapOf("R1" to edited, "R2" to ok),
                dirtyReminders = setOf("R1", "R2"), sync = SyncState(cursorLists = remote.seq, cursorReminders = remote.seq),
            ),
        )
        val rep = SyncEngine(remote, db).sync()
        assertEquals(1, rep.rejected)
        assertEquals("server", db.d.reminders["R1"]!!.title)
        assertFalse("R1" in db.d.dirtyReminders)
        assertEquals("allowed", remote.reminders["R2"]!!.title)
    }

    @Test
    fun pushSkippedByLastWriterWinsIsMarkedCleanAndRefetched() = runTest {
        val remote = FakeRemote(me)
        remote.serverList("L1", "Home", t0)
        remote.serverReminder("R1", "L1", "server newer", "2026-11-14T09:00:00Z")
        val local = localReminder("R1", "L1", "local older", "2026-11-14T08:30:00Z", version = 1)
        val db = MemDb(
            LocalDb(
                userId = me, lists = mapOf("L1" to remote.lists["L1"]!!), reminders = mapOf("R1" to local), dirtyReminders = setOf("R1"),
                // Cursor already past the server row, so only the push sees the conflict
                sync = SyncState(cursorLists = remote.seq, cursorReminders = remote.seq, lastManifestAt = i("2026-11-14T08:59:00Z")),
            ),
        )
        SyncEngine(remote, db, clock = { i("2026-11-14T09:00:00Z") }).sync()
        assertEquals("server newer", db.d.reminders["R1"]!!.title)
        assertFalse("R1" in db.d.dirtyReminders)
    }

    @Test
    fun editDuringPushStaysDirty() = runTest {
        val remote = FakeRemote(me)
        val list = ListRow("L1", me, "A", createdAt = i(t0), updatedAt = i(t0))
        val db = object : DbStore {
            var d = LocalDb(userId = me, lists = mapOf("L1" to list), dirtyLists = setOf("L1"))
            override val current get() = d
            override suspend fun update(transform: (LocalDb) -> LocalDb) { d = transform(d) }
        }
        val slow = object : RemoteStore by remote {
            override suspend fun upsertLists(rows: List<ListRow>): List<ListRow> {
                val res = remote.upsertLists(rows)
                // The user renames the list while the request is in flight
                db.d = db.d.copy(lists = mapOf("L1" to list.copy(name = "B", updatedAt = i("2026-11-14T08:00:05Z"))))
                return res
            }
        }
        SyncEngine(slow, db).sync()
        assertEquals("B", db.d.lists["L1"]!!.name)
        assertTrue("L1" in db.d.dirtyLists)
    }

    @Test
    fun membershipChangeTriggersManifest() = runTest {
        val remote = FakeRemote(me)
        val db = MemDb(LocalDb(userId = me, sync = SyncState(lastManifestAt = i("2026-11-14T08:59:00Z"))))
        val engine = SyncEngine(remote, db, clock = { i("2026-11-14T09:00:00Z") })
        assertFalse(engine.sync().ranManifest)
        remote.serverList("L5", "Joined", t0, owner = "other")
        remote.members += MemberRow("L5", me, "editor")
        assertTrue(engine.sync().ranManifest)
    }

    @Test
    fun adoptOnSignInMarksLocalRowsDirtyWithUserId() {
        val l = ListRow("L1", LOCAL_USER_ID, "Mine", createdAt = i(t0), updatedAt = i(t0))
        val r = ReminderRow("R1", "L1", null, LOCAL_USER_ID, title = "x", createdAt = i(t0), updatedAt = i(t0))
        val d = LocalDb(lists = mapOf("L1" to l), reminders = mapOf("R1" to r)).adoptedBy(me, "a@b.c")
        assertEquals(me, d.lists["L1"]!!.ownerId)
        assertEquals(me, d.reminders["R1"]!!.createdBy)
        assertEquals(setOf("L1"), d.dirtyLists)
        assertEquals(setOf("R1"), d.dirtyReminders)
    }

    @Test
    fun adoptDropsTheUntouchedAutomaticList() {
        val auto = ListRow("L1", LOCAL_USER_ID, ListRow.DEFAULT_NAME, createdAt = i(t0), updatedAt = i(t0))
        val used = ListRow("L2", LOCAL_USER_ID, ListRow.DEFAULT_NAME, createdAt = i(t0), updatedAt = i(t0))
        val renamed = ListRow("L3", LOCAL_USER_ID, "Groceries", createdAt = i(t0), updatedAt = i(t0))
        val r = ReminderRow("R1", "L2", null, LOCAL_USER_ID, title = "x", createdAt = i(t0), updatedAt = i(t0))
        val d = LocalDb(lists = listOf(auto, used, renamed).associateBy { it.id }, reminders = mapOf("R1" to r)).adoptedBy(me, "a@b.c")
        assertNull(d.lists["L1"])
        assertEquals(setOf("L2", "L3"), d.dirtyLists)
    }

    @Test
    fun serverTimestampsParse() {
        assertEquals(i("2026-11-14T08:00:00Z"), Instants.parse("2026-11-14T08:00:00+00:00"))
        assertEquals(i("2026-11-14T08:00:00.123456Z"), Instants.parse("2026-11-14T08:00:00.123456+00:00"))
        assertEquals("2026-11-14T08:00:00Z", Instants.format(Instants.parse("2026-11-14T08:00:00Z")))
        val json = """{"id":"L","owner_id":"o","name":"n","created_at":"2026-11-14T08:00:00.5+00:00","updated_at":"2026-11-14T08:00:00Z","version":7,"extra":1}"""
        val row = LynxJson.decodeFromString(ListRow.serializer(), json)
        assertEquals(7L, row.version)
    }
}
