package com.mansfera.lynxreminders.core

import java.time.Instant

/** Pure edit rules shared by the UI, notification actions and tests. */
object Edits {
    /**
     * Completing a reminder (SPEC §5.3): a repeating reminder that advances keeps
     * `completed_at = null` and moves `due_at`; otherwise it is completed for good.
     */
    fun complete(r: ReminderRow, now: Instant, me: String): ReminderRow {
        val rule = r.repeat
        val due = r.dueAt
        if (rule != null && due != null) {
            val res = try {
                Recurrence.complete(rule, Recurrence.zone(r.timeZone), due, now)
            } catch (_: Exception) {
                null
            }
            if (res != null) {
                return if (res.completed) {
                    r.copy(completedAt = now, completedBy = me, repeat = res.repeat, dueAt = res.dueAt, updatedAt = now)
                } else {
                    r.copy(dueAt = res.dueAt, repeat = res.repeat, updatedAt = now)
                }
            }
        }
        return r.copy(completedAt = now, completedBy = me, updatedAt = now)
    }

    fun uncomplete(r: ReminderRow, now: Instant): ReminderRow = r.copy(completedAt = null, completedBy = null, updatedAt = now)

    /** Fractional ordering: a value between two neighbours (or past the end). */
    fun sortBetween(before: Double?, after: Double?): Double = when {
        before == null && after == null -> 1000.0
        before == null -> after!! - 1000.0
        after == null -> before + 1000.0
        else -> (before + after) / 2
    }
}
