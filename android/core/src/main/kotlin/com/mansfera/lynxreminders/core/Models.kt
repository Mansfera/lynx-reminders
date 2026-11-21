package com.mansfera.lynxreminders.core

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

/**
 * Rows mirror the server columns (SPEC §2) with the same snake_case names.
 * Local-only state (dirty flags, cooldowns, notification ids) never lives in these classes.
 */

/** ISO-8601 instants. Parses `Z`, `+00:00` and fractional seconds; writes `2026-11-14T08:00:00Z`. */
object InstantSerializer : KSerializer<Instant> {
    override val descriptor = PrimitiveSerialDescriptor("Instant", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeString(Instants.format(value))
    override fun deserialize(decoder: Decoder): Instant = Instants.parse(decoder.decodeString())
}

object Instants {
    fun parse(s: String): Instant = try {
        OffsetDateTime.parse(s, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant()
    } catch (_: Exception) {
        // Postgres may emit "+00" without minutes or a space instead of T
        val fixed = s.trim().replace(' ', 'T').let { if (Regex("[+-]\\d\\d$").containsMatchIn(it)) "$it:00" else it }
        OffsetDateTime.parse(fixed, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant()
    }

    /** Whole seconds when possible, like the reference implementation; millis otherwise. */
    fun format(i: Instant): String =
        if (i.nano == 0) DateTimeFormatter.ISO_INSTANT.format(i)
        else DateTimeFormatter.ISO_INSTANT.format(i.truncatedTo(ChronoUnit.MILLIS))
}

typealias InstantS = @Serializable(with = InstantSerializer::class) Instant

/** Shared JSON configuration: tolerant reads, explicit nulls on write (so clearing a field reaches the server). */
@OptIn(ExperimentalSerializationApi::class)
val LynxJson: Json = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    explicitNulls = true
    coerceInputValues = true
}

/** Placeholder owner id for data created before signing in; replaced by the account id on sign-in. */
const val LOCAL_USER_ID = "00000000-0000-0000-0000-000000000000"

object ListColors {
    val all = listOf("ink", "slate", "blue", "green", "yellow", "orange", "red", "pink", "brown")
}

object ListIcons {
    val all = listOf("list", "cart", "house", "briefcase", "book", "heart", "star", "flag", "gift", "plane", "leaf", "bolt")
}

@Serializable
data class Profile(
    val id: String,
    val email: String? = null,
    @SerialName("display_name") val displayName: String? = null,
)

@Serializable
data class ListRow(
    val id: String,
    @SerialName("owner_id") val ownerId: String,
    val name: String,
    val color: String = "ink",
    val icon: String = "list",
    @SerialName("sort_order") val sortOrder: Double = 0.0,
    @SerialName("created_at") val createdAt: InstantS,
    @SerialName("updated_at") val updatedAt: InstantS,
    @SerialName("deleted_at") val deletedAt: InstantS? = null,
    val version: Long = 0,
) {
    val isDeleted get() = deletedAt != null
}

@Serializable
data class Window(val start: String, val end: String)

@Serializable
data class RepeatEnd(
    val type: String = "never", // never | on | after
    val date: String? = null,
    val count: Int? = null,
) {
    companion object {
        val Never = RepeatEnd("never")
    }
}

@Serializable
data class RepeatRule(
    val unit: String, // minute | hour | day | week | month | year
    val interval: Int = 1,
    val anchor: String, // local wall time "2026-11-14T09:00"
    val weekdays: List<Int>? = null,
    val window: Window? = null,
    val end: RepeatEnd? = null,
    @SerialName("from") val from: String? = null, // due | completion
    val advance: String? = null, // complete | auto
    @SerialName("completed_count") val completedCount: Int? = null,
) {
    val fromCompletion get() = from == "completion"
    val autoAdvance get() = advance == "auto"
    val endOrNever get() = end ?: RepeatEnd.Never
}

@Serializable
data class Nag(
    @SerialName("every_minutes") val everyMinutes: Int,
    val max: Int? = null,
)

@Serializable
data class LocationTrigger(
    val name: String,
    val address: String? = null,
    val lat: Double,
    val lon: Double,
    val radius: Double = 150.0,
    val on: String = "arrive", // arrive | leave
)

@Serializable
data class PlatformIds(val mac: String? = null, val android: String? = null)

@Serializable
data class BluetoothTrigger(
    val name: String,
    val on: String = "connect", // connect | disconnect
    val ids: PlatformIds? = null,
)

@Serializable
data class AppTrigger(
    val name: String,
    val on: String = "open",
    val apple: String? = null,
    val android: String? = null,
)

@Serializable
data class ReminderRow(
    val id: String,
    @SerialName("list_id") val listId: String,
    @SerialName("parent_id") val parentId: String? = null,
    @SerialName("created_by") val createdBy: String,
    @SerialName("assignee_id") val assigneeId: String? = null,
    val title: String,
    val notes: String? = null,
    val url: String? = null,
    val priority: Int = 0,
    val flagged: Boolean = false,
    @SerialName("completed_at") val completedAt: InstantS? = null,
    @SerialName("completed_by") val completedBy: String? = null,
    @SerialName("due_at") val dueAt: InstantS? = null,
    @SerialName("all_day") val allDay: Boolean = false,
    @SerialName("time_zone") val timeZone: String = "UTC",
    @SerialName("early_alert_minutes") val earlyAlertMinutes: Int? = null,
    val repeat: RepeatRule? = null,
    val nag: Nag? = null,
    val location: LocationTrigger? = null,
    val bluetooth: BluetoothTrigger? = null,
    @SerialName("app_trigger") val appTrigger: AppTrigger? = null,
    @SerialName("sort_order") val sortOrder: Double = 0.0,
    @SerialName("created_at") val createdAt: InstantS,
    @SerialName("updated_at") val updatedAt: InstantS,
    @SerialName("deleted_at") val deletedAt: InstantS? = null,
    val version: Long = 0,
) {
    val isCompleted get() = completedAt != null
    val isDeleted get() = deletedAt != null
    val isOpen get() = completedAt == null && deletedAt == null
    val hasContextTrigger get() = location != null || bluetooth != null || appTrigger != null
}

@Serializable
data class MemberRow(
    @SerialName("list_id") val listId: String,
    @SerialName("user_id") val userId: String,
    val role: String = "editor",
    @SerialName("added_by") val addedBy: String? = null,
    @SerialName("created_at") val createdAt: InstantS? = null,
    val version: Long = 0,
    val profile: Profile? = null,
)

@Serializable
data class ShareRow(
    @SerialName("reminder_id") val reminderId: String,
    @SerialName("user_id") val userId: String,
    @SerialName("added_by") val addedBy: String? = null,
    @SerialName("created_at") val createdAt: InstantS? = null,
    val version: Long = 0,
    val profile: Profile? = null,
)

@Serializable
data class InviteRow(
    val id: String,
    val email: String,
    @SerialName("list_id") val listId: String? = null,
    @SerialName("reminder_id") val reminderId: String? = null,
    @SerialName("invited_by") val invitedBy: String? = null,
    @SerialName("created_at") val createdAt: InstantS? = null,
)

@Serializable
data class ManifestEntry(val t: String, val id: String, val v: Long)

@Serializable
data class ShareResult(val status: String, @SerialName("user_id") val userId: String? = null)

@Serializable
data class SyncState(
    @SerialName("cursor_lists") val cursorLists: Long = 0,
    @SerialName("cursor_reminders") val cursorReminders: Long = 0,
    @SerialName("last_manifest_at") val lastManifestAt: InstantS? = null,
    @SerialName("last_sync_at") val lastSyncAt: InstantS? = null,
)

/**
 * Everything the device stores for the current account (or for local-only use).
 * Rows are keyed by id; `dirty*` hold ids with local edits not yet pushed (SPEC §4).
 */
@Serializable
data class LocalDb(
    @SerialName("user_id") val userId: String? = null,
    val email: String? = null,
    val lists: Map<String, ListRow> = emptyMap(),
    val reminders: Map<String, ReminderRow> = emptyMap(),
    @SerialName("dirty_lists") val dirtyLists: Set<String> = emptySet(),
    @SerialName("dirty_reminders") val dirtyReminders: Set<String> = emptySet(),
    val members: List<MemberRow> = emptyList(),
    val shares: List<ShareRow> = emptyList(),
    val invites: List<InviteRow> = emptyList(),
    val sync: SyncState = SyncState(),
) {
    val me: String get() = userId ?: LOCAL_USER_ID

    fun visibleLists(): List<ListRow> = lists.values.filter { !it.isDeleted }.sortedWith(compareBy({ it.sortOrder }, { it.createdAt }))

    fun liveReminders(): List<ReminderRow> = reminders.values.filter { r ->
        !r.isDeleted && lists[r.listId]?.isDeleted != true &&
            (r.parentId == null || reminders[r.parentId]?.isDeleted == false)
    }

    fun subtasksOf(id: String): List<ReminderRow> =
        reminders.values.filter { it.parentId == id && !it.isDeleted }.sortedWith(compareBy({ it.sortOrder }, { it.createdAt }))

    fun membersOf(listId: String) = members.filter { it.listId == listId }
    fun isShared(listId: String) = members.count { it.listId == listId } > 1 || invites.any { it.listId == listId }
}
