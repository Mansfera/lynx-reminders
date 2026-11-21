package com.mansfera.lynxreminders.core

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

enum class SmartList(val title: String) {
    TODAY("Today"), SCHEDULED("Scheduled"), ALL("All"), FLAGGED("Flagged"),
    GOALS("Goals"), SHARED_WITH_ME("Shared with me"), ASSIGNED_TO_ME("Assigned to me"), COMPLETED("Completed");
}

/** A group of rows: by day ([date]) or by list ([listId]); both null = a single ungrouped section. */
data class Section(val date: LocalDate? = null, val listId: String? = null, val items: List<ReminderRow>)

data class GoalProgress(val done: Int, val total: Int) {
    val fraction: Float get() = if (total == 0) 0f else done.toFloat() / total
    val full get() = total > 0 && done == total
}

/** SPEC §7 smart lists, computed from the local store. */
object SmartLists {
    /** Local date of a reminder's effective due: all-day dates are read in the reminder's own zone. */
    fun dueDate(r: ReminderRow, now: Instant, deviceZone: ZoneId): LocalDate? {
        val eff = r.effectiveDue(now) ?: return null
        val zone = if (r.allDay) Recurrence.zone(r.timeZone) else deviceZone
        return eff.atZone(zone).toLocalDate()
    }

    fun isOverdue(r: ReminderRow, now: Instant, deviceZone: ZoneId): Boolean {
        if (!r.isOpen) return false
        val eff = r.effectiveDue(now) ?: return false
        return if (r.allDay) dueDate(r, now, deviceZone)!!.isBefore(today(now, deviceZone)) else eff.isBefore(now)
    }

    private fun today(now: Instant, zone: ZoneId) = now.atZone(zone).toLocalDate()

    private fun order(now: Instant): Comparator<ReminderRow> =
        compareBy<ReminderRow>({ it.effectiveDue(now) ?: Instant.MAX }, { it.sortOrder }, { it.createdAt })

    private fun inMyLists(db: LocalDb, r: ReminderRow): Boolean {
        if (db.userId == null) return true
        val memberLists = db.members.filter { it.userId == db.me }.map { it.listId }.toSet()
        return r.listId in memberLists || db.lists[r.listId]?.ownerId == db.me || db.members.none { it.listId == r.listId }
    }

    fun sharedWithMeIds(db: LocalDb): Set<String> {
        val ids = db.shares.filter { it.userId == db.me && it.addedBy != db.me }.map { it.reminderId }.toSet()
        return ids.filter { id -> db.reminders[id]?.let { !inMyLists(db, it) } ?: false }.toSet()
    }

    fun goalProgress(db: LocalDb, id: String): GoalProgress? {
        val subs = db.subtasksOf(id)
        if (subs.isEmpty()) return null
        return GoalProgress(subs.count { it.isCompleted }, subs.size)
    }

    fun sections(db: LocalDb, kind: SmartList, now: Instant, zone: ZoneId): List<Section> {
        val live = db.liveReminders()
        val open = live.filter { it.isOpen }
        val today = today(now, zone)
        val ord = order(now)
        return when (kind) {
            SmartList.TODAY -> listOf(Section(items = open.filter { r -> dueDate(r, now, zone)?.let { !it.isAfter(today) } == true }.sortedWith(ord)))
            SmartList.SCHEDULED -> open.filter { it.dueAt != null }
                .groupBy { dueDate(it, now, zone)!! }.toSortedMap()
                .map { (d, rs) -> Section(date = d, items = rs.sortedWith(ord)) }
            SmartList.ALL -> {
                val lists = db.visibleLists()
                lists.mapNotNull { l ->
                    val items = open.filter { it.listId == l.id && it.parentId == null }.sortedWith(compareBy({ it.sortOrder }, { it.createdAt }))
                    if (items.isEmpty()) null else Section(listId = l.id, items = items)
                }
            }
            SmartList.FLAGGED -> listOf(Section(items = open.filter { it.flagged }.sortedWith(ord)))
            SmartList.GOALS -> listOf(Section(items = open.filter { it.parentId == null && db.subtasksOf(it.id).isNotEmpty() }.sortedWith(ord)))
            SmartList.SHARED_WITH_ME -> {
                val ids = sharedWithMeIds(db)
                listOf(Section(items = live.filter { it.id in ids && it.isOpen }.sortedWith(ord)))
            }
            SmartList.ASSIGNED_TO_ME -> listOf(Section(items = open.filter { it.assigneeId != null && it.assigneeId == db.me }.sortedWith(ord)))
            SmartList.COMPLETED -> live.filter { it.isCompleted }
                .sortedByDescending { it.completedAt }
                .groupBy { it.completedAt!!.atZone(zone).toLocalDate() }
                .toSortedMap(compareByDescending { it })
                .map { (d, rs) -> Section(date = d, items = rs) }
        }.filter { it.items.isNotEmpty() || kind in setOf(SmartList.TODAY, SmartList.FLAGGED, SmartList.GOALS, SmartList.SHARED_WITH_ME, SmartList.ASSIGNED_TO_ME) }
    }

    fun count(db: LocalDb, kind: SmartList, now: Instant, zone: ZoneId): Int = sections(db, kind, now, zone).sumOf { it.items.size }

    fun counts(db: LocalDb, now: Instant, zone: ZoneId): Map<SmartList, Int> = SmartList.entries.associateWith { count(db, it, now, zone) }

    /** Rows of one user list: top-level reminders, open first; subtasks live under their goal. */
    fun listItems(db: LocalDb, listId: String, showCompleted: Boolean): List<ReminderRow> {
        val rows = db.liveReminders().filter { it.listId == listId && it.parentId == null }
        val open = rows.filter { it.isOpen }.sortedWith(compareBy({ it.sortOrder }, { it.createdAt }))
        val done = if (showCompleted) rows.filter { it.isCompleted }.sortedByDescending { it.completedAt } else emptyList()
        return open + done
    }

    fun openCount(db: LocalDb, listId: String): Int = db.liveReminders().count { it.listId == listId && it.isOpen && it.parentId == null }

    /** Search titles and notes across everything (SPEC §7). */
    fun search(db: LocalDb, query: String): List<ReminderRow> {
        val q = query.trim()
        if (q.isEmpty()) return emptyList()
        return db.liveReminders()
            .filter { it.title.contains(q, ignoreCase = true) || (it.notes?.contains(q, ignoreCase = true) == true) }
            .sortedWith(compareBy({ it.isCompleted }, { it.title.lowercase() }))
    }

    /** My lists: owned and not shared. Shared lists: everything with another member or invite. */
    fun myLists(db: LocalDb) = db.visibleLists().filter { !db.isShared(it.id) }
    fun sharedLists(db: LocalDb) = db.visibleLists().filter { db.isShared(it.id) }
}
