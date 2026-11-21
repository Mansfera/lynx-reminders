package com.mansfera.lynxreminders.core

import java.time.Duration
import java.time.Instant
import java.time.LocalTime
import java.time.ZonedDateTime

/** One planned local notification. [id] is `<reminder_id>|<kind>|<n>` (SPEC §5.5). */
data class PlannedAlert(
    val reminderId: String,
    val kind: String, // due | early | nag | auto | snooze | ctx
    val n: Int,
    val at: Instant,
) {
    val id: String get() = "$reminderId|$kind|$n"
}

/** Device-local inputs to the planner; never synced. */
data class PlannerInputs(
    val now: Instant,
    /** All-day reminders alert at this local time on their date (SPEC §10, default 09:00). */
    val allDayAlertTime: LocalTime = LocalTime.of(9, 0),
    /** reminder id → snoozed-until instant. */
    val snoozes: Map<String, Instant> = emptyMap(),
    /** reminder id → when its last context trigger fired (to continue the nag series). */
    val contextFired: Map<String, Instant> = emptyMap(),
    val cap: Int = CAP,
    val autoLookahead: Int = 12,
) {
    companion object {
        /** iOS allows 64 pending; plan 60 and keep 4 for snoozes. Android uses the same cap for parity. */
        const val CAP = 60
    }
}

object NotificationPlanner {
    /** The instant an alert for a due value fires: all-day reminders use the all-day alert time. */
    fun alertInstant(r: ReminderRow, due: Instant, allDayAlertTime: LocalTime): Instant {
        if (!r.allDay) return due
        val zone = Recurrence.zone(r.timeZone)
        val date = ZonedDateTime.ofInstant(due, zone).toLocalDate()
        return ZonedDateTime.of(date, allDayAlertTime, zone).toInstant()
    }

    fun plan(reminders: Collection<ReminderRow>, inputs: PlannerInputs): List<PlannedAlert> {
        val now = inputs.now
        val out = ArrayList<PlannedAlert>()
        for (r in reminders) {
            if (!r.isOpen) continue
            val snoozedUntil = inputs.snoozes[r.id]?.takeIf { it.isAfter(now) }
            if (snoozedUntil != null) {
                out += PlannedAlert(r.id, "snooze", 0, snoozedUntil)
                // Snoozing restarts the nag from the snooze time (SPEC §5.4)
                r.nag?.let { nag ->
                    Recurrence.nagTimes(nag, snoozedUntil).forEachIndexed { i, t -> out += PlannedAlert(r.id, "nag", i + 1, t) }
                }
            }
            val ctxFired = inputs.contextFired[r.id]
            if (ctxFired != null && r.nag != null && snoozedUntil == null) {
                Recurrence.nagTimes(r.nag, ctxFired).forEachIndexed { i, t ->
                    if (t.isAfter(now)) out += PlannedAlert(r.id, "nag", 100 + i + 1, t)
                }
            }
            val due = r.dueAt ?: continue
            val effective = r.effectiveDue(now) ?: due
            val alertAt = alertInstant(r, effective, inputs.allDayAlertTime)
            if (alertAt.isAfter(now)) out += PlannedAlert(r.id, "due", 0, alertAt)
            r.earlyAlertMinutes?.takeIf { it > 0 }?.let { m ->
                val early = alertAt.minus(Duration.ofMinutes(m.toLong()))
                if (early.isAfter(now)) out += PlannedAlert(r.id, "early", 0, early)
            }
            if (r.nag != null && snoozedUntil == null) {
                Recurrence.nagTimes(r.nag, alertAt).forEachIndexed { i, t ->
                    if (t.isAfter(now)) out += PlannedAlert(r.id, "nag", i + 1, t)
                }
            }
            val rule = r.repeat
            if (rule != null && rule.autoAdvance) {
                try {
                    val zone = Recurrence.zone(r.timeZone)
                    Recurrence.upcoming(rule, zone, maxOf(effective, now), inputs.autoLookahead).forEachIndexed { i, t ->
                        val at = alertInstant(r, t, inputs.allDayAlertTime)
                        if (at.isAfter(now) && at != alertAt) out += PlannedAlert(r.id, "auto", i, at)
                    }
                } catch (_: Exception) { /* malformed rule: plan only the due alert */ }
            }
        }
        return out.distinctBy { it.id }.sortedWith(compareBy({ it.at }, { it.id })).take(inputs.cap)
    }
}
