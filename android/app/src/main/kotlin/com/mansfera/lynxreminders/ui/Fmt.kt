package com.mansfera.lynxreminders.ui

import com.mansfera.lynxreminders.core.Nag
import com.mansfera.lynxreminders.core.RepeatRule
import com.mansfera.lynxreminders.core.ReminderRow
import com.mansfera.lynxreminders.core.effectiveDue
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

/** Text formatting shared by UI rows and notifications. Times in Geist Mono use 24 h or 12 h per the device. */
object Fmt {
    @Volatile var is24: Boolean = true
    val zone: ZoneId get() = ZoneId.systemDefault()

    private val t24 = DateTimeFormatter.ofPattern("HH:mm")
    private val t12 = DateTimeFormatter.ofPattern("h:mm a", Locale.ENGLISH)
    private val dayShort = DateTimeFormatter.ofPattern("EEE", Locale.ENGLISH)
    private val dayMonth = DateTimeFormatter.ofPattern("d MMM", Locale.ENGLISH)
    private val dayMonthYear = DateTimeFormatter.ofPattern("d MMM yyyy", Locale.ENGLISH)
    private val longDay = DateTimeFormatter.ofPattern("EEEE d MMMM", Locale.ENGLISH)

    fun time(i: Instant, z: ZoneId = zone): String = i.atZone(z).format(if (is24) t24 else t12)
    fun time(t: java.time.LocalTime): String = t.format(if (is24) t24 else t12)

    fun dayWord(d: LocalDate, today: LocalDate): String = when (ChronoUnit.DAYS.between(today, d)) {
        0L -> "Today"
        1L -> "Tomorrow"
        -1L -> "Yesterday"
        in 2..6 -> d.format(dayShort)
        else -> if (d.year == today.year) d.format(dayMonth) else d.format(dayMonthYear)
    }

    /** "14:30", "Tomorrow 09:00", "Mon", "16 Nov 09:00". All-day reminders show the date only. */
    fun dueLabel(r: ReminderRow, due: Instant, now: Instant): String {
        val z = if (r.allDay) com.mansfera.lynxreminders.core.Recurrence.zone(r.timeZone) else zone
        val d = due.atZone(z).toLocalDate()
        val today = now.atZone(zone).toLocalDate()
        if (r.allDay) return dayWord(d, today)
        val day = dayWord(d, today)
        return if (day == "Today") time(due) else "$day ${time(due)}"
    }

    fun notificationLine(r: ReminderRow, now: Instant): String {
        val due = r.effectiveDue(now) ?: return "Reminder"
        val label = dueLabel(r, due, now)
        return if (due.isBefore(now.minusSeconds(120)) && !r.allDay) "Overdue · was due $label" else "Due $label"
    }

    fun dayHeader(d: LocalDate, today: LocalDate): String = when (ChronoUnit.DAYS.between(today, d)) {
        0L -> "Today"
        1L -> "Tomorrow"
        -1L -> "Yesterday"
        else -> d.format(longDay)
    }

    private fun unitWord(u: String, n: Int) = when (u) {
        "minute" -> if (n == 1) "minute" else "min"
        "hour" -> if (n == 1) "hour" else "hours"
        "day" -> if (n == 1) "day" else "days"
        "week" -> if (n == 1) "week" else "weeks"
        "month" -> if (n == 1) "month" else "months"
        else -> if (n == 1) "year" else "years"
    }

    private val wdNames = listOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")

    fun repeatLabel(r: RepeatRule): String {
        val n = r.interval
        val wds = r.weekdays.orEmpty().sorted()
        val base = when {
            r.unit == "day" && n == 1 -> "Daily"
            r.unit == "week" && n == 1 && wds == listOf(1, 2, 3, 4, 5) -> "Weekdays"
            r.unit == "week" && n == 1 && wds.isEmpty() -> "Weekly"
            r.unit == "month" && n == 1 -> "Monthly"
            r.unit == "year" && n == 1 -> "Yearly"
            r.unit == "minute" || r.unit == "hour" -> "$n ${unitWord(r.unit, n)}"
            else -> "Every $n ${unitWord(r.unit, n)}"
        }
        val days = if (wds.isNotEmpty() && base != "Weekdays") " " + wds.joinToString(" ") { wdNames.getOrElse(it - 1) { "?" } } else ""
        val window = r.window?.let { " ${it.start}–${it.end}" } ?: ""
        return base + days + window
    }

    fun nagLabel(n: Nag) = "nag ${n.everyMinutes} min"

    fun earlyLabel(m: Int?): String = when (m) {
        null, 0 -> "None"
        in 1..59 -> "$m min before"
        60 -> "1 hour before"
        1440 -> "1 day before"
        else -> if (m % 1440 == 0) "${m / 1440} days before" else if (m % 60 == 0) "${m / 60} hours before" else "$m min before"
    }

    fun initials(name: String?): String {
        val n = name?.trim().orEmpty()
        if (n.isEmpty()) return "?"
        val parts = n.substringBefore('@').split(' ', '.', '_', '-').filter { it.isNotEmpty() && it.first().isLetter() }.ifEmpty { listOf(n) }
        return (parts.first().take(1) + (parts.getOrNull(1)?.take(1) ?: "")).uppercase()
    }
}
