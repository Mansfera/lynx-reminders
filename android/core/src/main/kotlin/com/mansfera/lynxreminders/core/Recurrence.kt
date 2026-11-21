package com.mansfera.lynxreminders.core

import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import kotlin.math.max

/**
 * Kotlin port of shared/reference/recurrence.py (SPEC §5). Must match every vector in
 * shared/vectors/recurrence.json. Occurrences are produced ascending; [generate] may start at a
 * later point of the series than the anchor when given a `hint` (pure optimisation: every skipped
 * occurrence is strictly earlier than the hint, so `nextAfter` results are unchanged).
 */
object Recurrence {
    private val LOCAL_FMT: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm")

    /** Bounded scans protect against rules that never produce an occurrence (e.g. window start > end). */
    private const val MAX_EMPTY_DAYS = 3700

    fun parseLocal(s: String): LocalDateTime = LocalDateTime.parse(s.take(16), LOCAL_FMT)
    fun formatLocal(d: LocalDateTime): String = d.truncatedTo(ChronoUnit.MINUTES).format(LOCAL_FMT)
    fun parseHm(s: String): LocalTime = LocalTime.of(s.substringBefore(':').toInt(), s.substringAfter(':').take(2).toInt())

    /** Wall time → instant. Gaps resolve forward, overlaps take the earlier offset (java.time default). */
    fun toUtc(local: LocalDateTime, tz: ZoneId): Instant = ZonedDateTime.of(local, tz).toInstant()
    fun toLocal(instant: Instant, tz: ZoneId): LocalDateTime = LocalDateTime.ofInstant(instant, tz)

    private fun addMonths(d: LocalDateTime, months: Long, day: Int): LocalDateTime {
        val base = d.withDayOfMonth(1).plusMonths(months)
        return base.withDayOfMonth(minOf(day, base.toLocalDate().lengthOfMonth()))
    }

    private fun stepMinutes(rule: RepeatRule): Long = rule.interval.toLong() * (if (rule.unit == "minute") 1 else 60)

    /** Every occurrence as an instant, ascending. Ignores `end` (callers apply it). */
    fun generate(rule: RepeatRule, tz: ZoneId, hint: Instant? = null): Sequence<Instant> = sequence {
        val anchor = parseLocal(rule.anchor)
        val n = rule.interval.toLong()
        require(n >= 1) { "interval must be >= 1" }
        val weekdays = (rule.weekdays ?: emptyList()).filter { it in 1..7 }.toSortedSet().toList()
        val hintDate: LocalDate? = hint?.let { toLocal(it, tz).toLocalDate() }

        when (rule.unit) {
            "minute", "hour" -> {
                val step = stepMinutes(rule)
                val window = rule.window
                if (window != null) {
                    val ws = parseHm(window.start)
                    val we = parseHm(window.end)
                    var d = anchor.toLocalDate()
                    // 8 days back keeps the latest slot before the hint even with a weekday filter
                    if (hintDate != null) d = maxOf(d, hintDate.minusDays(8))
                    var empty = 0
                    while (empty < MAX_EMPTY_DAYS) {
                        var produced = false
                        if (weekdays.isEmpty() || d.dayOfWeek.value in weekdays) {
                            var t = LocalDateTime.of(d, ws)
                            while (t.toLocalDate() == d && !t.toLocalTime().isAfter(we)) {
                                if (!t.isBefore(anchor)) {
                                    yield(toUtc(t, tz)); produced = true
                                }
                                t = t.plusMinutes(step)
                            }
                        }
                        empty = if (produced) 0 else empty + 1
                        d = d.plusDays(1)
                    }
                } else {
                    // Absolute durations: every N minutes of real time, DST does not shift the rhythm.
                    val start = toUtc(anchor, tz)
                    val stepD = Duration.ofMinutes(step)
                    var k = 0L
                    if (hint != null && hint.isAfter(start)) {
                        k = max(0L, Duration.between(start, hint).toMinutes() / step - 1)
                    }
                    while (true) {
                        yield(start.plus(stepD.multipliedBy(k)))
                        k++
                    }
                }
            }

            "day" -> {
                var k = 0L
                if (hintDate != null) {
                    val days = ChronoUnit.DAYS.between(anchor.toLocalDate(), hintDate)
                    k = max(0L, (days - 2) / n)
                }
                while (true) {
                    yield(toUtc(anchor.plusDays(k * n), tz)); k++
                }
            }

            "week" -> {
                if (weekdays.isEmpty()) {
                    var k = 0L
                    if (hintDate != null) {
                        val weeks = ChronoUnit.DAYS.between(anchor.toLocalDate(), hintDate) / 7
                        k = max(0L, (weeks - 1) / n)
                    }
                    while (true) {
                        yield(toUtc(anchor.plusWeeks(k * n), tz)); k++
                    }
                } else {
                    val week0 = anchor.toLocalDate().minusDays((anchor.dayOfWeek.value - 1).toLong())
                    var w = 0L
                    if (hintDate != null) {
                        val weeks = ChronoUnit.DAYS.between(week0, hintDate) / 7
                        w = max(0L, (weeks - 1) / n)
                    }
                    while (true) {
                        for (wd in weekdays) {
                            val d = week0.plusDays(w * n * 7 + wd - 1)
                            val t = LocalDateTime.of(d, anchor.toLocalTime())
                            if (!t.isBefore(anchor)) yield(toUtc(t, tz))
                        }
                        w++
                    }
                }
            }

            "month", "year" -> {
                val per = if (rule.unit == "month") n else n * 12
                var k = 0L
                if (hintDate != null) {
                    val months = ChronoUnit.MONTHS.between(anchor.toLocalDate().withDayOfMonth(1), hintDate.withDayOfMonth(1))
                    k = max(0L, (months - 2) / per)
                }
                while (true) {
                    yield(toUtc(addMonths(anchor, k * per, anchor.dayOfMonth), tz)); k++
                }
            }

            else -> throw IllegalArgumentException("unknown unit ${rule.unit}")
        }
    }

    fun withinEnd(rule: RepeatRule, instant: Instant, tz: ZoneId): Boolean {
        val end = rule.endOrNever
        if (end.type == "on" && end.date != null) {
            return !toLocal(instant, tz).toLocalDate().isAfter(LocalDate.parse(end.date))
        }
        return true // "never"; "after" is counted in completions, see complete()
    }

    /** First occurrence strictly after [after], or null when the series has ended. */
    fun nextAfter(rule: RepeatRule, tz: ZoneId, after: Instant): Instant? {
        for (occ in generate(rule, tz, hint = after)) {
            if (!withinEnd(rule, occ, tz)) return null
            if (occ.isAfter(after)) return occ
        }
        return null
    }

    fun upcoming(rule: RepeatRule, tz: ZoneId, after: Instant, limit: Int): List<Instant> {
        val out = ArrayList<Instant>()
        var t = after
        while (out.size < limit) {
            val nxt = nextAfter(rule, tz, t) ?: break
            out.add(nxt); t = nxt
        }
        return out
    }

    /**
     * advance == "auto": the current slot is the latest occurrence <= now that is >= dueAt;
     * before dueAt it is dueAt itself. Otherwise dueAt.
     */
    fun effectiveDue(rule: RepeatRule, tz: ZoneId, dueAt: Instant, now: Instant): Instant {
        if (!rule.autoAdvance || now.isBefore(dueAt)) return dueAt
        var cur = dueAt
        // Jump close to `now` first, then walk; the result is identical to walking from dueAt.
        for (occ in generate(rule, tz, hint = maxOf(dueAt, now.minus(Duration.ofDays(3))))) {
            if (!withinEnd(rule, occ, tz)) return cur
            if (!occ.isAfter(cur)) continue
            if (occ.isAfter(now)) return cur
            cur = occ
        }
        return cur
    }

    data class Completion(val completed: Boolean, val dueAt: Instant, val repeat: RepeatRule)

    /** What a completion does to a repeating reminder (SPEC §5.3). */
    fun complete(rule0: RepeatRule, tz: ZoneId, dueAt: Instant, completedAt: Instant): Completion {
        val count = (rule0.completedCount ?: 0) + 1
        var rule = rule0.copy(completedCount = count)
        val end = rule.endOrNever
        val current = effectiveDue(rule, tz, dueAt, completedAt)

        if (end.type == "after" && end.count != null && count >= end.count) {
            return Completion(true, current, rule)
        }

        if (rule.fromCompletion) {
            val n = rule.interval.toLong()
            val anchorTime = parseLocal(rule.anchor).toLocalTime()
            val doneLocal = toLocal(completedAt, tz)
            val next: Instant
            val newAnchor: LocalDateTime
            if (rule.unit == "minute" || rule.unit == "hour") {
                next = completedAt.plus(Duration.ofMinutes(stepMinutes(rule)))
                newAnchor = toLocal(next, tz)
            } else {
                val base = LocalDateTime.of(doneLocal.toLocalDate(), anchorTime)
                newAnchor = when (rule.unit) {
                    "day" -> base.plusDays(n)
                    "week" -> base.plusWeeks(n)
                    "month" -> addMonths(base, n, base.dayOfMonth)
                    else -> addMonths(base, n * 12, base.dayOfMonth)
                }
                next = toUtc(newAnchor, tz)
            }
            rule = rule.copy(anchor = formatLocal(newAnchor.withSecond(0).withNano(0)))
            if (!withinEnd(rule, next, tz)) return Completion(true, current, rule)
            return Completion(false, next, rule)
        }

        val next = nextAfter(rule, tz, current) ?: return Completion(true, current, rule)
        return Completion(false, next, rule)
    }

    /** Alert again every N minutes after the first alert, up to `max` times (null = 24 h worth, capped at 48). */
    fun nagTimes(nag: Nag, firedAt: Instant): List<Instant> {
        val every = nag.everyMinutes.coerceAtLeast(1)
        val mx = nag.max ?: minOf(48, (24 * 60) / every)
        return (1..mx).map { firedAt.plus(Duration.ofMinutes(every.toLong() * it)) }
    }

    fun zone(id: String?): ZoneId = try {
        if (id.isNullOrBlank()) ZoneId.systemDefault() else ZoneId.of(id)
    } catch (_: Exception) {
        ZoneId.systemDefault()
    }
}

/** Effective due of a reminder (SPEC §5.2); null when it has no due date. */
fun ReminderRow.effectiveDue(now: Instant): Instant? {
    val due = dueAt ?: return null
    val r = repeat ?: return due
    return try {
        Recurrence.effectiveDue(r, Recurrence.zone(timeZone), due, now)
    } catch (_: Exception) {
        due
    }
}
