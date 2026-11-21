package com.mansfera.lynxreminders.core

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * shared/vectors/server-rows.json: real rows written by both clients (SPEC §11).
 * macOS omits absent optionals, Android writes explicit nulls; both must decode either way.
 */
class ServerRowsTest {
    private val root: JsonObject by lazy {
        val dir = System.getProperty("lynx.vectors") ?: "../../shared/vectors"
        val f = File(dir, "server-rows.json")
        assertTrue("fixture not found at ${f.absolutePath}", f.exists())
        LynxJson.parseToJsonElement(f.readText()).jsonObject
    }

    private fun present(o: JsonObject, k: String) = o[k] != null && o[k] !is JsonNull

    @Test
    fun listsFromBothClientsDecode() {
        val raw = root["lists"]!!.jsonArray
        val lists = LynxJson.decodeFromJsonElement(ListSerializer(ListRow.serializer()), raw)
        assertEquals(raw.size, lists.size)
        val writers = raw.map { it.jsonObject["_written_by"]!!.jsonPrimitive.content }.toSet()
        assertEquals(setOf("apple", "android"), writers)
    }

    @Test
    fun remindersFromBothClientsDecodeWithEveryTrigger() {
        val raw = root["reminders"]!!.jsonArray
        val reminders = LynxJson.decodeFromJsonElement(ListSerializer(ReminderRow.serializer()), raw)
        assertEquals(raw.size, reminders.size)
        reminders.zip(raw.map { it.jsonObject }).forEach { (r, j) ->
            val who = j["_written_by"]!!.jsonPrimitive.content
            assertEquals(j["id"]!!.jsonPrimitive.content, r.id)
            assertEquals("repeat from $who", present(j, "repeat"), r.repeat != null)
            assertEquals("nag from $who", present(j, "nag"), r.nag != null)
            assertEquals("location from $who", present(j, "location"), r.location != null)
            assertEquals("bluetooth from $who", present(j, "bluetooth"), r.bluetooth != null)
            assertEquals("app_trigger from $who", present(j, "app_trigger"), r.appTrigger != null)
            assertEquals("parent_id from $who", present(j, "parent_id"), r.parentId != null)
            assertEquals("completed_at from $who", present(j, "completed_at"), r.completedAt != null)
            assertEquals("deleted_at from $who", present(j, "deleted_at"), r.deletedAt != null)
            assertEquals(who, j["all_day"]!!.jsonPrimitive.boolean, r.allDay)
        }
    }

    /** Server timestamps carry microseconds and the client writes milliseconds, so the first encode may
     *  truncate; after that, encoding must be stable. */
    @Test
    fun roundTripIsStable() {
        val ser = ListSerializer(ReminderRow.serializer())
        val reminders = LynxJson.decodeFromJsonElement(ser, root["reminders"]!!.jsonArray)
        val once = LynxJson.encodeToString(ser, reminders)
        assertEquals(once, LynxJson.encodeToString(ser, LynxJson.decodeFromString(ser, once)))
    }
}
