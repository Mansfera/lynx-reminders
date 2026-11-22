package com.mansfera.lynxreminders.data

import com.mansfera.lynxreminders.core.Edits
import com.mansfera.lynxreminders.core.ListRow
import com.mansfera.lynxreminders.core.LocalDb
import com.mansfera.lynxreminders.core.QuickAddResult
import com.mansfera.lynxreminders.core.ReminderRow
import java.time.Instant
import java.time.ZoneId
import java.util.UUID

/**
 * Every user edit: set `updated_at = now`, mark dirty, save locally, then [onChange]
 * (reschedule alerts, refresh triggers, schedule a sync with 1 s debounce — SPEC §4).
 */
class Repository(
    private val store: LocalStore,
    private val device: DeviceStore,
    private val onChange: () -> Unit,
) {
    val db get() = store.value
    private fun now() = Instant.now()
    private fun newId() = UUID.randomUUID().toString()

    private fun editDb(transform: (LocalDb) -> LocalDb) {
        store.edit(transform)
        onChange()
    }

    // ---------- lists ----------

    fun createList(name: String, color: String, icon: String): ListRow {
        val t = now()
        val last = db.visibleLists().maxOfOrNull { it.sortOrder }
        val row = ListRow(newId(), db.me, name.trim().ifEmpty { "Untitled" }, color, icon, Edits.sortBetween(last, null), t, t)
        editDb { it.copy(lists = it.lists + (row.id to row), dirtyLists = it.dirtyLists + row.id) }
        return row
    }

    fun updateList(id: String, transform: (ListRow) -> ListRow) = editDb { d ->
        val cur = d.lists[id] ?: return@editDb d
        val next = transform(cur).copy(updatedAt = now())
        d.copy(lists = d.lists + (id to next), dirtyLists = d.dirtyLists + id)
    }

    fun deleteList(id: String) = updateList(id) { it.copy(deletedAt = now()) }

    /** Moves [id] to position [toIndex] among visible lists (fractional sort_order). */
    fun moveList(id: String, toIndex: Int) {
        val others = db.visibleLists().filter { it.id != id }
        val i = toIndex.coerceIn(0, others.size)
        val before = others.getOrNull(i - 1)?.sortOrder
        val after = others.getOrNull(i)?.sortOrder
        updateList(id) { it.copy(sortOrder = Edits.sortBetween(before, after)) }
    }

    /** A list to put new reminders in; creates "Reminders" when there is none. */
    fun defaultListId(): String {
        val pref = device.value.settings.defaultListId
        val lists = db.visibleLists()
        return lists.firstOrNull { it.id == pref }?.id ?: lists.firstOrNull()?.id ?: createList(ListRow.DEFAULT_NAME, "ink", "list").id
    }

    // ---------- reminders ----------

    /** The default list without side effects ("" when there is no list yet; [saveReminder] creates one). */
    private fun defaultListIdOrBlank(): String {
        val pref = device.value.settings.defaultListId
        val lists = db.visibleLists()
        return lists.firstOrNull { it.id == pref }?.id ?: lists.firstOrNull()?.id ?: ""
    }

    fun newReminderDraft(listId: String?, parentId: String? = null): ReminderRow {
        val t = now()
        val list = listId ?: defaultListIdOrBlank()
        val parentList = parentId?.let { db.reminders[it]?.listId }
        return ReminderRow(
            id = newId(), listId = parentList ?: list, parentId = parentId, createdBy = db.me, title = "",
            timeZone = ZoneId.systemDefault().id, earlyAlertMinutes = device.value.settings.defaultEarlyAlert,
            createdAt = t, updatedAt = t,
        )
    }

    fun saveReminder(r0: ReminderRow) {
        // A draft made before any list existed gets the default list now, not when the editor opened
        val r = if (r0.listId.isBlank() || db.lists[r0.listId] == null) r0.copy(listId = defaultListId()) else r0
        saveResolved(r)
    }

    private fun saveResolved(r: ReminderRow) = editDb { d ->
        val t = now()
        var rows = d.reminders
        var dirty = d.dirtyReminders
        val existing = rows[r.id]
        val sort = if (existing == null) {
            val last = rows.values.filter { it.listId == r.listId && it.parentId == r.parentId }.maxOfOrNull { it.sortOrder }
            Edits.sortBetween(last, null)
        } else r.sortOrder
        val next = r.copy(updatedAt = t, sortOrder = sort, title = r.title.trim())
        rows = rows + (r.id to next)
        dirty = dirty + r.id
        // Subtasks follow their goal into another list
        if (existing != null && existing.listId != r.listId) {
            d.subtasksOf(r.id).forEach { s ->
                rows = rows + (s.id to s.copy(listId = r.listId, updatedAt = t)); dirty = dirty + s.id
            }
        }
        d.copy(reminders = rows, dirtyReminders = dirty)
    }

    fun addQuick(q: QuickAddResult, listId: String?, parentId: String? = null): ReminderRow {
        val draft = newReminderDraft(q.listId ?: listId, parentId).copy(
            title = q.title, dueAt = q.dueAt, allDay = q.allDay, repeat = q.repeat, priority = q.priority,
        )
        saveReminder(draft)
        return draft
    }

    fun updateReminder(id: String, transform: (ReminderRow) -> ReminderRow) {
        val cur = db.reminders[id] ?: return
        saveReminder(transform(cur))
    }

    /** Completes (or advances a repeating reminder). [withSubtasks] also completes open subtasks of a goal. */
    fun complete(id: String, withSubtasks: Boolean = false) {
        val t = now()
        editDb { d ->
            val r = d.reminders[id] ?: return@editDb d
            var rows = d.reminders + (id to Edits.complete(r, t, d.me))
            var dirty = d.dirtyReminders + id
            if (withSubtasks) d.subtasksOf(id).filter { it.isOpen }.forEach { s ->
                rows = rows + (s.id to Edits.complete(s, t, d.me)); dirty = dirty + s.id
            }
            d.copy(reminders = rows, dirtyReminders = dirty)
        }
        device.edit { it.copy(snoozes = it.snoozes - id, contextFired = it.contextFired - id) }
    }

    fun uncomplete(id: String) = updateReminder(id) { Edits.uncomplete(it, now()) }

    fun toggle(id: String) {
        val r = db.reminders[id] ?: return
        if (r.isCompleted) uncomplete(id) else complete(id)
    }

    fun delete(id: String) = editDb { d ->
        val t = now()
        val r = d.reminders[id] ?: return@editDb d
        var rows = d.reminders + (id to r.copy(deletedAt = t, updatedAt = t))
        var dirty = d.dirtyReminders + id
        d.subtasksOf(id).forEach { s -> rows = rows + (s.id to s.copy(deletedAt = t, updatedAt = t)); dirty = dirty + s.id }
        d.copy(reminders = rows, dirtyReminders = dirty)
    }

    fun setFlag(id: String, flagged: Boolean) = updateReminder(id) { it.copy(flagged = flagged) }

    // ---------- device-only ----------

    fun snooze(id: String, minutes: Int) {
        device.edit { it.copy(snoozes = it.snoozes + (id to now().plusSeconds(minutes * 60L)), contextFired = it.contextFired - id) }
        onChange()
    }

    fun updateSettings(transform: (Settings) -> Settings) {
        device.edit { it.copy(settings = transform(it.settings)) }
        onChange()
    }
}
