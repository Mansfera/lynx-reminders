package com.mansfera.lynxreminders.core

import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit
import java.time.temporal.TemporalAdjusters

data class QuickAddResult(
    val title: String,
    val dueAt: Instant? = null,
    val allDay: Boolean = false,
    val repeat: RepeatRule? = null,
    val priority: Int = 0,
    val listId: String? = null,
    /** Detail that doesn't fit a short title (only Claude fills this; the local parser never does). */
    val notes: String? = null,
)

/**
 * Light natural-language parsing for quick add (SPEC §7): "tomorrow", "today", "tonight",
 * "mon"…"sun", "at 9", "9:30", "in 2 hours", "every day/week/month", "every 45 min",
 * "!"/"!!"/"!!!" priority, "#list". Parsing is sugar; the editor is the source of truth.
 */
object QuickAddParser {
    private val weekdays = mapOf(
        "mon" to DayOfWeek.MONDAY, "monday" to DayOfWeek.MONDAY,
        "tue" to DayOfWeek.TUESDAY, "tues" to DayOfWeek.TUESDAY, "tuesday" to DayOfWeek.TUESDAY,
        "wed" to DayOfWeek.WEDNESDAY, "wednesday" to DayOfWeek.WEDNESDAY,
        "thu" to DayOfWeek.THURSDAY, "thur" to DayOfWeek.THURSDAY, "thurs" to DayOfWeek.THURSDAY, "thursday" to DayOfWeek.THURSDAY,
        "fri" to DayOfWeek.FRIDAY, "friday" to DayOfWeek.FRIDAY,
        "sat" to DayOfWeek.SATURDAY, "saturday" to DayOfWeek.SATURDAY,
        "sun" to DayOfWeek.SUNDAY, "sunday" to DayOfWeek.SUNDAY,
    )
    private val wdAlt = weekdays.keys.sortedByDescending { it.length }.joinToString("|")

    private val unitAlt = "minutes|minute|mins|min|m|hours|hour|hrs|hr|h|days|day|d|weeks|week|w|months|month|years|year"
    private fun unitOf(s: String): String = when {
        s.startsWith("mi") || s == "m" -> "minute"
        s.startsWith("h") -> "hour"
        s.startsWith("d") -> "day"
        s.startsWith("w") -> "week"
        s.startsWith("mo") -> "month"
        else -> "year"
    }

    private val reEvery = Regex("""(?i)(?:^|\s)every\s+(?:(\d+)\s*($unitAlt)\b|(day|week|month|year|hour|minute|weekday)\b|($wdAlt)\b)""")
    private val reIn = Regex("""(?i)(?:^|\s)in\s+(\d+)\s*($unitAlt)\b""")
    private val reAt = Regex("""(?i)(?:^|\s)(?:at\s+)(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b""")
    private val reClock = Regex("""(?i)(?:^|\s)(\d{1,2}):(\d{2})\s*(am|pm)?\b|(?:^|\s)(\d{1,2})\s*(am|pm)\b""")
    private val reDay = Regex("""(?i)(?:^|\s)(today|tonight|tomorrow|tmrw|($wdAlt))(?=[\s,.]|$)""")
    private val rePriority = Regex("""(?:^|\s)(!{1,3})(?=\s|$)""")
    private val reList = Regex("""(?:^|\s)#(\S+)""")

    fun parse(text: String, now: Instant, zone: ZoneId, lists: List<ListRow> = emptyList()): QuickAddResult {
        var s = " $text "
        fun cut(m: MatchResult) { s = s.substring(0, m.range.first) + " " + s.substring(m.range.last + 1) }

        var priority = 0
        rePriority.find(s)?.let { priority = it.groupValues[1].length; cut(it) }

        var listId: String? = null
        reList.find(s)?.let { m ->
            val key = m.groupValues[1].lowercase()
            val l = lists.firstOrNull { it.name.replace(" ", "").lowercase() == key }
                ?: lists.firstOrNull { it.name.replace(" ", "").lowercase().startsWith(key) }
            if (l != null) { listId = l.id; cut(m) }
        }

        val nowLocal = LocalDateTime.ofInstant(now, zone)
        val today = nowLocal.toLocalDate()

        var repeatUnit: String? = null
        var repeatInterval = 1
        var repeatWeekdays: List<Int>? = null
        var repeatDay: LocalDate? = null
        reEvery.find(s)?.let { m ->
            when {
                m.groupValues[1].isNotEmpty() -> { repeatInterval = m.groupValues[1].toInt().coerceAtLeast(1); repeatUnit = unitOf(m.groupValues[2].lowercase()) }
                m.groupValues[3].isNotEmpty() -> {
                    val w = m.groupValues[3].lowercase()
                    if (w == "weekday") { repeatUnit = "week"; repeatWeekdays = listOf(1, 2, 3, 4, 5) } else repeatUnit = w
                }
                else -> {
                    val dow = weekdays.getValue(m.groupValues[4].lowercase())
                    repeatUnit = "week"; repeatWeekdays = listOf(dow.value)
                    repeatDay = today.with(TemporalAdjusters.nextOrSame(dow))
                }
            }
            cut(m)
        }

        var relative: Instant? = null
        reIn.find(s)?.let { m ->
            val n = m.groupValues[1].toLong()
            relative = when (unitOf(m.groupValues[2].lowercase())) {
                "minute" -> now.plus(n, ChronoUnit.MINUTES)
                "hour" -> now.plus(n, ChronoUnit.HOURS)
                "day" -> ZonedDateTime.ofInstant(now, zone).plusDays(n).toInstant()
                "week" -> ZonedDateTime.ofInstant(now, zone).plusWeeks(n).toInstant()
                "month" -> ZonedDateTime.ofInstant(now, zone).plusMonths(n).toInstant()
                else -> ZonedDateTime.ofInstant(now, zone).plusYears(n).toInstant()
            }
            cut(m)
        }

        var day: LocalDate? = repeatDay
        var tonight = false
        reDay.find(s)?.let { m ->
            val w = m.groupValues[1].lowercase()
            day = when (w) {
                "today" -> today
                "tonight" -> { tonight = true; today }
                "tomorrow", "tmrw" -> today.plusDays(1)
                else -> today.with(TemporalAdjusters.next(weekdays.getValue(w)))
            }
            cut(m)
        }

        var time: LocalTime? = null
        (reAt.find(s))?.let { m ->
            time = toTime(m.groupValues[1].toInt(), m.groupValues[2].ifEmpty { "0" }.toInt(), m.groupValues[3])
            cut(m)
        } ?: reClock.find(s)?.let { m ->
            time = if (m.groupValues[1].isNotEmpty()) toTime(m.groupValues[1].toInt(), m.groupValues[2].toInt(), m.groupValues[3])
            else toTime(m.groupValues[4].toInt(), 0, m.groupValues[5])
            cut(m)
        }
        if (tonight && time == null) time = LocalTime.of(20, 0)

        val (dueInstant, allDay) = resolveDue(day, time, relative, repeatUnit, repeatInterval, now, zone)
        val repeat = repeatUnit?.let { unit -> anchored(RepeatRule(unit = unit, interval = repeatInterval, anchor = "", weekdays = repeatWeekdays), dueInstant!!, zone) }

        val title = s.replace(Regex("\\s+"), " ").trim().ifEmpty { text.trim() }
        return QuickAddResult(title = title, dueAt = dueInstant, allDay = allDay, repeat = repeat, priority = priority, listId = listId)
    }

    /**
     * A day, a time of day or an absolute instant → due instant and all-day flag; a time with no day is the next
     * such time, a repeat with no day starts from now. Shared by the local parser and Claude's parse ([QuickAddAI]).
     */
    internal fun resolveDue(day: LocalDate?, time: LocalTime?, relative: Instant?, repeatUnit: String?, repeatInterval: Int, now: Instant, zone: ZoneId): Pair<Instant?, Boolean> {
        if (relative != null) return relative to false
        val nowLocal = LocalDateTime.ofInstant(now, zone)
        val today = nowLocal.toLocalDate()
        if (day != null || time != null) {
            val d = day ?: if (time != null && !LocalDateTime.of(today, time).isAfter(nowLocal)) today.plusDays(1) else today
            return if (time != null) ZonedDateTime.of(LocalDateTime.of(d, time), zone).toInstant() to false
            else ZonedDateTime.of(d.atStartOfDay(), zone).toInstant() to true
        }
        if (repeatUnit == null) return null to false
        if (repeatUnit == "minute" || repeatUnit == "hour") {
            val step = repeatInterval.toLong() * (if (repeatUnit == "minute") 1 else 60)
            return now.truncatedTo(ChronoUnit.MINUTES).plus(step, ChronoUnit.MINUTES) to false
        }
        return ZonedDateTime.of(today.atStartOfDay(), zone).toInstant() to true
    }

    internal fun anchored(rule: RepeatRule, due: Instant, zone: ZoneId): RepeatRule =
        rule.copy(anchor = Recurrence.formatLocal(LocalDateTime.ofInstant(due, zone)))

    private fun toTime(h0: Int, m: Int, ampm: String): LocalTime {
        var h = h0
        when (ampm.lowercase()) {
            "pm" -> if (h < 12) h += 12
            "am" -> if (h == 12) h = 0
        }
        return LocalTime.of(h.coerceIn(0, 23), m.coerceIn(0, 59))
    }
}
