package com.mansfera.lynxreminders.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.Instant
import java.time.ZoneId

/** Every case in shared/vectors/recurrence.json (SPEC §5, §11). */
class RecurrenceVectorsTest {
    private val vectors: JsonObject by lazy {
        val dir = System.getProperty("lynx.vectors") ?: "../../shared/vectors"
        val f = File(dir, "recurrence.json")
        assertTrue("vectors not found at ${f.absolutePath}", f.exists())
        LynxJson.parseToJsonElement(f.readText()).jsonObject
    }

    private fun rule(o: JsonObject) = LynxJson.decodeFromJsonElement(RepeatRule.serializer(), o["repeat"]!!)
    private fun s(o: JsonObject, k: String) = o[k]!!.jsonPrimitive.content
    private fun i(o: JsonObject, k: String) = Instant.parse(s(o, k))

    @Test
    fun next() {
        val cases = vectors["next"]!!.jsonArray
        assertTrue(cases.isNotEmpty())
        for (c in cases.map { it.jsonObject }) {
            val got = Recurrence.upcoming(rule(c), ZoneId.of(s(c, "time_zone")), i(c, "after"), 6).map { Instants.format(it) }
            val exp = c["expect"]!!.jsonArray.map { it.jsonPrimitive.content }
            assertEquals("next: ${s(c, "name")}", exp, got)
        }
    }

    @Test
    fun effectiveDue() {
        val cases = vectors["effective_due"]!!.jsonArray
        assertTrue(cases.isNotEmpty())
        for (c in cases.map { it.jsonObject }) {
            val got = Recurrence.effectiveDue(rule(c), ZoneId.of(s(c, "time_zone")), i(c, "due_at"), i(c, "now"))
            assertEquals("effective_due: ${s(c, "name")}", s(c, "expect"), Instants.format(got))
        }
    }

    @Test
    fun complete() {
        val cases = vectors["complete"]!!.jsonArray
        assertTrue(cases.isNotEmpty())
        for (c in cases.map { it.jsonObject }) {
            val name = s(c, "name")
            val res = Recurrence.complete(rule(c), ZoneId.of(s(c, "time_zone")), i(c, "due_at"), i(c, "completed_at"))
            val exp = c["expect"]!!.jsonObject
            assertEquals("complete.completed: $name", exp["completed"]!!.jsonPrimitive.boolean, res.completed)
            assertEquals("complete.due_at: $name", exp["due_at"]!!.jsonPrimitive.content, Instants.format(res.dueAt))
            val expRule = LynxJson.decodeFromJsonElement(RepeatRule.serializer(), exp["repeat"]!!)
            assertEquals("complete.repeat: $name", expRule, res.repeat)
        }
    }

    @Test
    fun nag() {
        val cases = vectors["nag"]!!.jsonArray
        assertTrue(cases.isNotEmpty())
        for (c in cases.map { it.jsonObject }) {
            val nag = LynxJson.decodeFromJsonElement(Nag.serializer(), c["nag"]!!)
            val got = Recurrence.nagTimes(nag, i(c, "fired_at")).map { Instants.format(it) }
            val exp = (c["expect"] as JsonArray).map { it.jsonPrimitive.content }
            assertEquals("nag: ${s(c, "name")}", exp, got)
        }
    }

    @Test
    fun vectorCountsAreAllCovered() {
        // Guard against a silently empty or renamed section.
        assertEquals(setOf("next", "effective_due", "complete", "nag"), vectors.keys)
    }

    @Test
    fun skipAheadMatchesWalkFromAnchor() {
        // The generator's skip-ahead must not change results: compare with a brute-force walk.
        val tz = ZoneId.of("Europe/Bratislava")
        val rules = listOf(
            RepeatRule("minute", 45, "2026-01-05T09:00", window = Window("09:00", "18:00"), weekdays = listOf(1, 3, 5)),
            RepeatRule("minute", 90, "2026-03-01T00:00"),
            RepeatRule("day", 10, "2026-01-01T07:00"),
            RepeatRule("week", 3, "2026-01-07T08:00", weekdays = listOf(2, 6)),
            RepeatRule("week", 2, "2026-01-07T08:00"),
            RepeatRule("month", 5, "2026-01-31T10:00"),
            RepeatRule("year", 1, "2024-02-29T10:00"),
        )
        val after = Instant.parse("2026-10-27T13:37:00Z")
        for (r in rules) {
            val brute = Recurrence.generate(r, tz).first { it.isAfter(after) }
            assertEquals(r.toString(), brute, Recurrence.nextAfter(r, tz, after))
        }
    }
}
