package com.mansfera.lynxreminders.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId

private val T0: Instant = Instant.parse("2026-11-14T08:00:00Z")
private val BA: ZoneId = ZoneId.of("Europe/Bratislava")

private fun rem(id: String, title: String = id, list: String = "L1", parent: String? = null, due: String? = null, block: ReminderRow.() -> ReminderRow = { this }) =
    ReminderRow(id, list, parent, "me", title = title, dueAt = due?.let(Instant::parse), timeZone = "Europe/Bratislava", createdAt = T0, updatedAt = T0).block()

class TriggerMatchingTest {
    @Test
    fun bluetoothMatchesByPlatformIdWhenPresent() {
        val t = BluetoothTrigger("AirPods Pro", "connect", PlatformIds(mac = "a4-c3-61-00-00-01", android = "A4:C3:61:00:00:01"))
        assertTrue(TriggerMatching.matchesBluetooth(t, ContextEvent.Bluetooth("Other name", "a4:c3:61:00:00:01", true)))
        // Same name, different device → no match because the Android id is present
        assertFalse(TriggerMatching.matchesBluetooth(t, ContextEvent.Bluetooth("AirPods Pro", "11:22:33:44:55:66", true)))
        // Wrong event
        assertFalse(TriggerMatching.matchesBluetooth(t, ContextEvent.Bluetooth("AirPods Pro", "A4:C3:61:00:00:01", false)))
    }

    @Test
    fun bluetoothFallsBackToNameCaseInsensitiveExact() {
        val t = BluetoothTrigger("AirPods Pro", "disconnect", PlatformIds(mac = "a4-c3"))
        assertTrue(TriggerMatching.matchesBluetooth(t, ContextEvent.Bluetooth("airpods pro", "00:00:00:00:00:00", false)))
        assertFalse(TriggerMatching.matchesBluetooth(t, ContextEvent.Bluetooth("AirPods Pro 2", null, false)))
        assertFalse(TriggerMatching.matchesBluetooth(t, ContextEvent.Bluetooth(null, "x", false)))
    }

    @Test
    fun appMatchesByIdThenName() {
        val withId = AppTrigger("Slack", apple = "com.tinyspeck.slackmacgap", android = "com.Slack")
        assertTrue(TriggerMatching.matchesApp(withId, ContextEvent.AppOpened("com.Slack", "Something")))
        assertFalse(TriggerMatching.matchesApp(withId, ContextEvent.AppOpened("com.slack.fake", "Slack")))
        val byName = AppTrigger("Slack", apple = "com.tinyspeck.slackmacgap")
        assertTrue(TriggerMatching.matchesApp(byName, ContextEvent.AppOpened("com.Slack", "SLACK")))
        assertFalse(TriggerMatching.matchesApp(byName, ContextEvent.AppOpened("com.Slack", "Slack Beta")))
    }

    @Test
    fun evaluateAppliesOpenAndCooldown() {
        val a = rem("A") { copy(appTrigger = AppTrigger("Slack", android = "com.Slack")) }
        val done = rem("B") { copy(appTrigger = AppTrigger("Slack", android = "com.Slack"), completedAt = T0) }
        val e = ContextEvent.AppOpened("com.Slack", "Slack")
        assertEquals(listOf("A"), TriggerMatching.evaluate(listOf(a, done), e, T0, emptyMap()).map { it.id })
        val fired = mapOf(TriggerMatching.cooldownKey("A", e) to T0.minusSeconds(14 * 60))
        assertTrue(TriggerMatching.evaluate(listOf(a), e, T0, fired).isEmpty())
        val old = mapOf(TriggerMatching.cooldownKey("A", e) to T0.minusSeconds(15 * 60))
        assertEquals(1, TriggerMatching.evaluate(listOf(a), e, T0, old).size)
    }

    @Test
    fun locationArriveLeave() {
        val r = rem("A") { copy(location = LocationTrigger("Home", lat = 48.1486, lon = 17.1077, on = "leave")) }
        assertTrue(TriggerMatching.matchesLocation(r, ContextEvent.Location("A", entered = false)))
        assertFalse(TriggerMatching.matchesLocation(r, ContextEvent.Location("A", entered = true)))
    }

    @Test
    fun geofencesNearestFirstWhenOverLimit() {
        val near = rem("near") { copy(location = LocationTrigger("n", lat = 48.15, lon = 17.11)) }
        val far = rem("far") { copy(location = LocationTrigger("f", lat = 50.45, lon = 30.52)) }
        assertEquals(listOf("near"), TriggerMatching.geofenceSelection(listOf(far, near), 1, 48.14, 17.10).map { it.id })
    }
}

class SmartListsTest {
    private val now = Instant.parse("2026-11-14T12:00:00Z") // 13:00 in Bratislava
    private fun db(vararg r: ReminderRow) = LocalDb(
        userId = "me",
        lists = mapOf("L1" to ListRow("L1", "me", "Home", createdAt = T0, updatedAt = T0), "L2" to ListRow("L2", "x", "Work", createdAt = T0, updatedAt = T0)),
        reminders = r.associateBy { it.id },
        members = listOf(MemberRow("L1", "me", "owner"), MemberRow("L2", "x", "owner")),
    )

    @Test
    fun todayIncludesOverdueAndToday() {
        val d = db(
            rem("overdue", due = "2026-11-13T08:00:00Z"),
            rem("today", due = "2026-11-14T18:00:00Z"),
            rem("tomorrow", due = "2026-11-15T08:00:00Z"),
            rem("none"),
            rem("done", due = "2026-11-14T09:00:00Z") { copy(completedAt = T0) },
        )
        val ids = SmartLists.sections(d, SmartList.TODAY, now, BA).flatMap { it.items }.map { it.id }
        assertEquals(listOf("overdue", "today"), ids)
        assertTrue(SmartLists.isOverdue(d.reminders["overdue"]!!, now, BA))
    }

    @Test
    fun scheduledGroupsByDayAndCountsMatch() {
        val d = db(rem("a", due = "2026-11-15T08:00:00Z"), rem("b", due = "2026-11-15T09:00:00Z"), rem("c", due = "2026-11-20T08:00:00Z"), rem("x") { copy(flagged = true) })
        val secs = SmartLists.sections(d, SmartList.SCHEDULED, now, BA)
        assertEquals(2, secs.size)
        assertEquals(listOf("a", "b"), secs[0].items.map { it.id })
        val counts = SmartLists.counts(d, now, BA)
        assertEquals(3, counts[SmartList.SCHEDULED])
        assertEquals(4, counts[SmartList.ALL])
        assertEquals(1, counts[SmartList.FLAGGED])
    }

    @Test
    fun goalsSharedAssignedCompleted() {
        val goal = rem("goal")
        val s1 = rem("s1", parent = "goal") { copy(completedAt = T0) }
        val s2 = rem("s2", parent = "goal")
        val shared = rem("shared", list = "L2")
        val assigned = rem("assigned") { copy(assigneeId = "me") }
        val d = db(goal, s1, s2, shared, assigned).copy(shares = listOf(ShareRow("shared", "me", addedBy = "x")))
        assertEquals(listOf("goal"), SmartLists.sections(d, SmartList.GOALS, now, BA).flatMap { it.items }.map { it.id })
        assertEquals(GoalProgress(1, 2), SmartLists.goalProgress(d, "goal"))
        assertEquals(listOf("shared"), SmartLists.sections(d, SmartList.SHARED_WITH_ME, now, BA).flatMap { it.items }.map { it.id })
        assertEquals(listOf("assigned"), SmartLists.sections(d, SmartList.ASSIGNED_TO_ME, now, BA).flatMap { it.items }.map { it.id })
        assertEquals(listOf("s1"), SmartLists.sections(d, SmartList.COMPLETED, now, BA).flatMap { it.items }.map { it.id })
        // ALL shows top-level only, grouped by list
        assertEquals(setOf("goal", "assigned"), SmartLists.sections(d, SmartList.ALL, now, BA).first { it.listId == "L1" }.items.map { it.id }.toSet())
    }

    @Test
    fun searchTitlesAndNotes() {
        val d = db(rem("a", "Buy milk"), rem("b", "Call") { copy(notes = "about MILK prices") }, rem("c", "Other"))
        assertEquals(setOf("a", "b"), SmartLists.search(d, "milk").map { it.id }.toSet())
    }

    @Test
    fun deletedListHidesReminders() {
        val d = db(rem("a", due = "2026-11-14T08:00:00Z")).let { it.copy(lists = it.lists + ("L1" to it.lists["L1"]!!.copy(deletedAt = T0))) }
        assertEquals(0, SmartLists.count(d, SmartList.TODAY, now, BA))
    }
}

class QuickAddTest {
    private val now = Instant.parse("2026-11-14T12:00:00Z") // Saturday 13:00 Bratislava
    private val lists = listOf(ListRow("L-g", "me", "Groceries", createdAt = T0, updatedAt = T0), ListRow("L-w", "me", "Work stuff", createdAt = T0, updatedAt = T0))
    private fun p(s: String) = QuickAddParser.parse(s, now, BA, lists)
    private fun local(i: Instant?) = i!!.atZone(BA).toLocalDateTime().toString()

    @Test fun tomorrowAt9() = p("Call mom tomorrow at 9").let {
        assertEquals("Call mom", it.title); assertEquals("2026-11-15T09:00", local(it.dueAt)); assertFalse(it.allDay)
    }
    @Test fun tomorrowAt9Evening() {
        // 20:27 local on a Sunday: "tomorrow at 9" is Monday 09:00, not all-day
        val r = QuickAddParser.parse("Water plants tomorrow at 9", Instant.parse("2026-11-15T19:27:00Z"), BA, lists)
        assertEquals("Water plants", r.title); assertFalse(r.allDay); assertEquals("2026-11-16T09:00", local(r.dueAt))
    }
    @Test fun priorityAndList() = p("Milk !! #groceries").let {
        assertEquals("Milk", it.title); assertEquals(2, it.priority); assertEquals("L-g", it.listId); assertNull(it.dueAt)
    }
    @Test fun listByPrefixWithoutSpaces() = assertEquals("L-w", p("Report #workstuff").listId)
    @Test fun inTwoHours() = p("Stretch in 2 hours").let { assertEquals("Stretch", it.title); assertEquals(now.plusSeconds(7200), it.dueAt) }
    @Test fun everyFortyFiveMinutes() = p("Drink water every 45 min").let {
        assertEquals("Drink water", it.title); assertEquals("minute", it.repeat!!.unit); assertEquals(45, it.repeat!!.interval); assertNotNull(it.dueAt)
    }
    @Test fun everyDayAt8() = p("Vitamins every day at 8:30").let {
        assertEquals("Vitamins", it.title); assertEquals("day", it.repeat!!.unit); assertEquals("2026-11-15T08:30", local(it.dueAt)); assertEquals("2026-11-15T08:30", it.repeat!!.anchor)
    }
    @Test fun weekdayIsNextOccurrence() = assertEquals("2026-11-16T00:00", local(p("Gym mon").dueAt))
    @Test fun dateOnlyIsAllDay() = p("Taxes today").let { assertTrue(it.allDay); assertEquals("2026-11-14T00:00", local(it.dueAt)) }
    @Test fun clockTimeLaterToday() = assertEquals("2026-11-14T21:30", local(p("Read 9:30pm").dueAt))
    @Test fun pastTimeRollsToTomorrow() = assertEquals("2026-11-15T09:30", local(p("Standup 9:30").dueAt))
    @Test fun tonight() = assertEquals("2026-11-14T20:00", local(p("Trash tonight").dueAt))
    @Test fun plainTextUntouched() = p("Buy 2 apples for Sunday's cake").let { assertEquals("Buy 2 apples for Sunday's cake", it.title); assertNull(it.dueAt) }
    @Test fun unknownListKeepsHashtag() = assertEquals("Fix #bug", p("Fix #bug").title)
}

class PlannerAndEditsTest {
    @Test
    fun plansDueEarlyNagSortedAndCapped() {
        val now = Instant.parse("2026-11-14T07:00:00Z")
        val r = rem("A", due = "2026-11-14T08:00:00Z") { copy(earlyAlertMinutes = 15, nag = Nag(10, 3)) }
        val plan = NotificationPlanner.plan(listOf(r), PlannerInputs(now))
        assertEquals(listOf("A|early|0", "A|due|0", "A|nag|1", "A|nag|2", "A|nag|3"), plan.map { it.id })
        val many = (1..100).map { rem("R$it", due = Instant.parse("2026-11-14T08:00:00Z").plusSeconds(it * 60L).toString()) }
        assertEquals(PlannerInputs.CAP, NotificationPlanner.plan(many, PlannerInputs(now)).size)
    }

    @Test
    fun overdueNagStillPlansFutureNags() {
        val now = Instant.parse("2026-11-14T08:15:00Z")
        val r = rem("A", due = "2026-11-14T08:00:00Z") { copy(nag = Nag(10, 3)) }
        assertEquals(listOf("A|nag|2", "A|nag|3"), NotificationPlanner.plan(listOf(r), PlannerInputs(now)).map { it.id })
    }

    @Test
    fun allDayAlertsAtSetting() {
        val r = rem("A", due = "2026-11-14T23:00:00Z") { copy(allDay = true) } // 2026-11-15 00:00 local
        val plan = NotificationPlanner.plan(listOf(r), PlannerInputs(T0, allDayAlertTime = LocalTime.of(9, 0)))
        assertEquals(Instant.parse("2026-11-15T08:00:00Z"), plan.single().at)
    }

    @Test
    fun snoozeRestartsNagAndAutoPlansNext() {
        val now = Instant.parse("2026-11-14T08:05:00Z")
        val r = rem("A", due = "2026-11-14T08:00:00Z") { copy(nag = Nag(10, 1)) }
        val plan = NotificationPlanner.plan(listOf(r), PlannerInputs(now, snoozes = mapOf("A" to Instant.parse("2026-11-14T08:15:00Z"))))
        assertEquals(listOf("A|snooze|0" to "2026-11-14T08:15:00Z", "A|nag|1" to "2026-11-14T08:25:00Z"), plan.map { it.id to it.at.toString() })

        val auto = rem("W", due = "2026-11-14T08:00:00Z") {
            copy(repeat = RepeatRule("minute", 45, "2026-11-14T09:00", window = Window("09:00", "18:00"), advance = "auto"))
        }
        val p2 = NotificationPlanner.plan(listOf(auto), PlannerInputs(Instant.parse("2026-11-14T08:10:00Z"), autoLookahead = 2))
        assertEquals(listOf("W|auto|0" to "2026-11-14T08:45:00Z", "W|auto|1" to "2026-11-14T09:30:00Z"), p2.map { it.id to it.at.toString() })
    }

    @Test
    fun completingRepeatingAdvancesOtherwiseCompletes() {
        val daily = rem("A", due = "2026-11-10T08:00:00Z") { copy(repeat = RepeatRule("day", 1, "2026-11-10T09:00")) }
        val c = Edits.complete(daily, Instant.parse("2026-11-10T08:05:00Z"), "me")
        assertNull(c.completedAt)
        assertEquals(Instant.parse("2026-11-11T08:00:00Z"), c.dueAt)
        assertEquals(1, c.repeat!!.completedCount)
        val plain = Edits.complete(rem("B"), T0, "me")
        assertEquals(T0, plain.completedAt)
        assertEquals("me", plain.completedBy)
    }
}

class QuickAddAITest {
    private val now = Instant.parse("2026-11-14T12:00:00Z") // Saturday 13:00 Bratislava
    private val lists = listOf(ListRow("L-g", "me", "Groceries", createdAt = T0, updatedAt = T0), ListRow("L-w", "me", "Work Stuff", createdAt = T0, updatedAt = T0))
    private fun r(f: QuickAddAI.Fields) = QuickAddAI.result(f, "typed", lists, now, BA)
    private fun local(i: Instant?) = i!!.atZone(BA).toLocalDateTime().toString()

    @Test fun userMessage() {
        val m = QuickAddAI.userMessage("milk", lists, now, BA)
        assertTrue(m, m.startsWith("Now: 2026-11-14 13:00, Saturday (Europe/Bratislava)"))
        assertTrue(m.contains("Lists: Groceries, Work Stuff"))
        assertTrue(m.endsWith("<line>milk</line>"))
    }

    @Test fun parsesJsonDateAndTime() {
        val x = QuickAddAI.parse(
            """{"title":" Call mom ","notes":null,"date":"2026-11-15","time":"09:00","repeat":null,"priority":7,"list":"work stuff"}""",
            "typed", lists, now, BA,
        )
        assertEquals("Call mom", x.title); assertEquals("2026-11-15T09:00", local(x.dueAt)); assertFalse(x.allDay)
        assertEquals(3, x.priority); assertEquals("L-w", x.listId)
    }

    @Test fun dateOnlyIsAllDay() = r(QuickAddAI.Fields("Pay rent", notes = "  ", date = "2026-12-01", list = "Home")).let {
        assertTrue(it.allDay); assertEquals("2026-12-01T00:00", local(it.dueAt)); assertEquals(null, it.listId); assertEquals(null, it.notes)
    }

    @Test fun timeOnlyPassedIsTomorrowAndBadValuesIgnored() {
        assertEquals("2026-11-15T09:00", local(r(QuickAddAI.Fields("x", time = "09:00")).dueAt))
        val bad = r(QuickAddAI.Fields("", date = "soon", time = "25:00"))
        assertEquals("typed", bad.title); assertEquals(null, bad.dueAt)
    }

    @Test fun repeatsAreAnchored() {
        val daily = r(QuickAddAI.Fields("Pills", time = "20:00", repeat = QuickAddAI.Repeat("day")))
        assertEquals("2026-11-14T20:00", daily.repeat!!.anchor)
        val weekly = r(QuickAddAI.Fields("Gym", time = "07:00", repeat = QuickAddAI.Repeat("week", weekdays = listOf(3, 1, 1, 9))))
        assertEquals(listOf(1, 3), weekly.repeat!!.weekdays); assertEquals("2026-11-16T07:00", local(weekly.dueAt))
        val water = r(QuickAddAI.Fields("Water", repeat = QuickAddAI.Repeat("minute", 45)))
        assertEquals("2026-11-14T13:45", local(water.dueAt))
        assertEquals(null, r(QuickAddAI.Fields("x", repeat = QuickAddAI.Repeat("fortnight"))).repeat)
    }
}

class QuickAddReaderTest {
    private val now = Instant.parse("2026-11-14T12:00:00Z")
    private val lists = listOf(ListRow("L-g", "me", "Groceries", createdAt = T0, updatedAt = T0))

    @Test fun activeReader() {
        val r = QuickAddAI.Reader.entries
        assertEquals(QuickAddAI.Reader.CLAUDE, QuickAddAI.activeReader(r[0], claudeConnected = true, deviceAvailable = true))
        assertEquals(QuickAddAI.Reader.DEVICE, QuickAddAI.activeReader(QuickAddAI.Reader.DEVICE, true, true))
        assertEquals("device not ready", QuickAddAI.Reader.CLAUDE, QuickAddAI.activeReader(QuickAddAI.Reader.DEVICE, true, false))
        assertEquals(QuickAddAI.Reader.DEVICE, QuickAddAI.activeReader(QuickAddAI.Reader.CLAUDE, false, true))
        assertEquals(null, QuickAddAI.activeReader(QuickAddAI.Reader.CLAUDE, false, false))
    }

    @Test fun comingDays() = assertTrue(QuickAddAI.userMessage("x", lists, now, BA).contains("Coming days: Sunday 2026-11-15, Monday 2026-11-16,"))

    @Test fun lenientReplyInFence() {
        val q = QuickAddAI.parseLenient(
            "Sure:\n```json\n{\"title\": \"Milk\", \"date\": \"2026-11-15\", \"time\": null, \"repeat\": null, \"priority\": null, \"list\": \"groceries\"}\n```",
            "milk", lists, now, BA,
        )
        assertEquals("Milk", q.title); assertTrue(q.allDay); assertEquals("L-g", q.listId); assertEquals(0, q.priority)
    }
}
