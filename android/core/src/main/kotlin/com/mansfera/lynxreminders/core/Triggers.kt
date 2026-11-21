package com.mansfera.lynxreminders.core

import java.time.Duration
import java.time.Instant
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/** Context trigger events observed on this device (SPEC §6). */
sealed interface ContextEvent {
    /** [address] is the Android MAC ("A4:C3:61:…"), [name] the device name if known. */
    data class Bluetooth(val name: String?, val address: String?, val connected: Boolean) : ContextEvent
    data class AppOpened(val packageName: String, val label: String?) : ContextEvent
    data class Location(val reminderId: String, val entered: Boolean) : ContextEvent
}

object TriggerMatching {
    val COOLDOWN: Duration = Duration.ofMinutes(15)

    private fun normMac(s: String) = s.trim().replace('-', ':').uppercase()

    /** SPEC §6.3: match by this platform's id when present, otherwise by name (case-insensitive, exact). */
    fun matchesBluetooth(t: BluetoothTrigger, e: ContextEvent.Bluetooth): Boolean {
        val wanted = if (t.on == "disconnect") false else true
        if (e.connected != wanted) return false
        val id = t.ids?.android?.takeIf { it.isNotBlank() }
        return if (id != null) {
            e.address != null && normMac(id) == normMac(e.address)
        } else {
            e.name != null && t.name.trim().equals(e.name.trim(), ignoreCase = true)
        }
    }

    /** SPEC §6.4: match by this platform's identifier; if absent, by display name (case-insensitive). */
    fun matchesApp(t: AppTrigger, e: ContextEvent.AppOpened): Boolean {
        val id = t.android?.takeIf { it.isNotBlank() }
        return if (id != null) id == e.packageName
        else e.label != null && t.name.trim().equals(e.label.trim(), ignoreCase = true)
    }

    fun matchesLocation(r: ReminderRow, e: ContextEvent.Location): Boolean {
        val loc = r.location ?: return false
        if (r.id != e.reminderId) return false
        return if (loc.on == "leave") !e.entered else e.entered
    }

    fun kindOf(e: ContextEvent) = when (e) {
        is ContextEvent.Bluetooth -> "bluetooth"
        is ContextEvent.AppOpened -> "app"
        is ContextEvent.Location -> "location"
    }

    fun cooldownKey(reminderId: String, e: ContextEvent) = "$reminderId|${kindOf(e)}"

    /** True when the same reminder hasn't fired the same trigger within the cooldown. */
    fun cooledDown(lastFired: Instant?, now: Instant): Boolean =
        lastFired == null || Duration.between(lastFired, now) >= COOLDOWN

    /**
     * Reminders that should fire for [event]: open, matching, and out of cooldown.
     * [lastFired] maps [cooldownKey] → last fire time (local-only state).
     */
    fun evaluate(reminders: Collection<ReminderRow>, event: ContextEvent, now: Instant, lastFired: Map<String, Instant>): List<ReminderRow> =
        reminders.filter { r ->
            r.isOpen && when (event) {
                is ContextEvent.Bluetooth -> r.bluetooth?.let { matchesBluetooth(it, event) } == true
                is ContextEvent.AppOpened -> r.appTrigger?.let { matchesApp(it, event) } == true
                is ContextEvent.Location -> matchesLocation(r, event)
            } && cooledDown(lastFired[cooldownKey(r.id, event)], now)
        }

    /** Great-circle distance in metres. */
    fun distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val r = 6_371_000.0
        val dLat = Math.toRadians(lat2 - lat1)
        val dLon = Math.toRadians(lon2 - lon1)
        val a = sin(dLat / 2) * sin(dLat / 2) + cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    /** Geofences to register: open reminders with a location, the nearest [max] when a position is known. */
    fun geofenceSelection(reminders: Collection<ReminderRow>, max: Int, lat: Double?, lon: Double?): List<ReminderRow> {
        val candidates = reminders.filter { it.isOpen && it.location != null }
        if (candidates.size <= max || lat == null || lon == null) return candidates.take(max)
        return candidates.sortedBy { distanceMeters(lat, lon, it.location!!.lat, it.location.lon) }.take(max)
    }
}
