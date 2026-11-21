package com.mansfera.lynxreminders.notify

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.mansfera.lynxreminders.LynxApp
import com.mansfera.lynxreminders.MainActivity
import com.mansfera.lynxreminders.R
import com.mansfera.lynxreminders.core.ContextEvent
import com.mansfera.lynxreminders.core.NotificationPlanner
import com.mansfera.lynxreminders.core.PlannedAlert
import com.mansfera.lynxreminders.core.PlannerInputs
import com.mansfera.lynxreminders.core.ReminderRow
import com.mansfera.lynxreminders.core.TriggerMatching
import com.mansfera.lynxreminders.core.effectiveDue
import com.mansfera.lynxreminders.data.DeviceStore
import com.mansfera.lynxreminders.data.LocalStore
import com.mansfera.lynxreminders.sync.SyncController
import com.mansfera.lynxreminders.ui.Fmt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalTime

object Channels {
    const val REMINDERS = "reminders"
    const val WATCH = "trigger-watch"

    fun create(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(REMINDERS, context.getString(R.string.channel_reminders), NotificationManager.IMPORTANCE_HIGH).apply {
                description = context.getString(R.string.channel_reminders_desc)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(WATCH, context.getString(R.string.channel_watch), NotificationManager.IMPORTANCE_MIN).apply {
                description = context.getString(R.string.channel_watch_desc)
                setShowBadge(false)
            },
        )
    }
}

/**
 * Turns the local store into AlarmManager alarms (SPEC §5.5): plans the soonest 60, cancels what is no
 * longer planned. Exact alarms when allowed; otherwise inexact `setAndAllowWhileIdle` (and the UI
 * offers the settings screen).
 */
class AlarmScheduler(private val context: Context, private val store: LocalStore, private val device: DeviceStore) {
    private val am = context.getSystemService(AlarmManager::class.java)

    fun canExact(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || am.canScheduleExactAlarms()

    private fun pending(alertId: String, reminderId: String?, kind: String?, flags: Int): PendingIntent? {
        val i = Intent(context, AlarmReceiver::class.java).apply {
            data = Uri.parse("lynx://alarm/" + Uri.encode(alertId))
            reminderId?.let { putExtra(EXTRA_REMINDER, it) }
            kind?.let { putExtra(EXTRA_KIND, it) }
        }
        return PendingIntent.getBroadcast(context, alertId.hashCode(), i, flags or PendingIntent.FLAG_IMMUTABLE)
    }

    @Synchronized
    fun reschedule() {
        val st = device.value
        val now = Instant.now()
        val plan: List<PlannedAlert> = NotificationPlanner.plan(
            store.value.liveReminders(),
            PlannerInputs(
                now = now,
                allDayAlertTime = runCatching { LocalTime.parse(st.settings.allDayAlertTime) }.getOrDefault(LocalTime.of(9, 0)),
                snoozes = st.snoozes,
                contextFired = st.contextFired,
            ),
        )
        val wanted = plan.map { it.id }.toSet()
        for (old in st.scheduledAlarms - wanted) {
            pending(old, null, null, PendingIntent.FLAG_NO_CREATE)?.let { am.cancel(it); it.cancel() }
        }
        val exact = canExact()
        for (a in plan) {
            val pi = pending(a.id, a.reminderId, a.kind, PendingIntent.FLAG_UPDATE_CURRENT) ?: continue
            try {
                if (exact) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, a.at.toEpochMilli(), pi)
                else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, a.at.toEpochMilli(), pi)
            } catch (e: SecurityException) {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, a.at.toEpochMilli(), pi)
            }
        }
        device.edit { it.copy(scheduledAlarms = wanted, snoozes = it.snoozes.filterValues { t -> t.isAfter(now.minusSeconds(60)) }) }
    }

    companion object {
        const val EXTRA_REMINDER = "reminder_id"
        const val EXTRA_KIND = "kind"
    }
}

object Notifier {
    private const val ACTION_DONE = "com.mansfera.lynxreminders.DONE"
    private const val ACTION_SNOOZE = "com.mansfera.lynxreminders.SNOOZE"
    const val EXTRA_MINUTES = "minutes"

    fun canPost(context: Context) = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun action(context: Context, r: ReminderRow, action: String, minutes: Int = 0): PendingIntent {
        val i = Intent(context, ActionReceiver::class.java).apply {
            this.action = action
            data = Uri.parse("lynx://action/${r.id}/$action/$minutes")
            putExtra(AlarmScheduler.EXTRA_REMINDER, r.id)
            putExtra(EXTRA_MINUTES, minutes)
        }
        return PendingIntent.getBroadcast(context, (r.id + action + minutes).hashCode(), i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    /** One notification per reminder (tag = id) so nags replace the previous alert instead of piling up. */
    fun post(context: Context, r: ReminderRow, text: String) {
        if (!canPost(context)) return
        val open = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            data = Uri.parse("lynxreminders://reminder/${r.id}")
        }
        val content = PendingIntent.getActivity(context, r.id.hashCode(), open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = NotificationCompat.Builder(context, Channels.REMINDERS)
            .setSmallIcon(R.drawable.ic_stat_lynx)
            .setContentTitle(r.title.ifBlank { "Reminder" })
            .setContentText(text)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(content)
            .setAutoCancel(true)
            .addAction(0, "Done", action(context, r, ACTION_DONE))
            .addAction(0, "Snooze 10 min", action(context, r, ACTION_SNOOZE, 10))
            .addAction(0, "Snooze 1 h", action(context, r, ACTION_SNOOZE, 60))
            .build()
        try {
            NotificationManagerCompat.from(context).notify(r.id, NOTIFICATION_ID, n)
        } catch (e: SecurityException) {
            Log.w("Lynx", "notification permission revoked", e)
        }
    }

    fun cancel(context: Context, reminderId: String) = NotificationManagerCompat.from(context).cancel(reminderId, NOTIFICATION_ID)

    const val NOTIFICATION_ID = 1
    fun isDone(a: String?) = a == ACTION_DONE
    fun isSnooze(a: String?) = a == ACTION_SNOOZE
}

/** Fires a time alert planned by [AlarmScheduler]. */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val g = (context.applicationContext as LynxApp).graph
        val id = intent.getStringExtra(AlarmScheduler.EXTRA_REMINDER) ?: return
        val kind = intent.getStringExtra(AlarmScheduler.EXTRA_KIND) ?: "due"
        val r = g.store.value.reminders[id]
        if (r != null && r.isOpen) {
            val now = Instant.now()
            val text = when (kind) {
                "early" -> r.dueAt?.let { "Due " + Fmt.dueLabel(r, it, now) } ?: "Coming up"
                "nag" -> "Still open" + (r.effectiveDue(now)?.let { " · due " + Fmt.dueLabel(r, it, now) } ?: "")
                "snooze" -> "Snoozed reminder"
                else -> Fmt.notificationLine(r, now)
            }
            Notifier.post(context, r, text)
        }
        if (kind == "snooze") g.device.edit { it.copy(snoozes = it.snoozes - id) }
        val pr = goAsync()
        CoroutineScope(Dispatchers.Default).launch {
            try { g.alarms.reschedule(); g.device.flush() } finally { pr.finish() }
        }
    }
}

/** Done / Snooze from the notification, without opening the UI (SPEC §5.5). */
class ActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val g = (context.applicationContext as LynxApp).graph
        val id = intent.getStringExtra(AlarmScheduler.EXTRA_REMINDER) ?: return
        val pr = goAsync()
        CoroutineScope(Dispatchers.Default).launch {
            try {
                when {
                    Notifier.isDone(intent.action) -> g.repo.complete(id)
                    Notifier.isSnooze(intent.action) -> g.repo.snooze(id, intent.getIntExtra(Notifier.EXTRA_MINUTES, 10))
                }
                Notifier.cancel(context, id)
                g.alarms.reschedule()
                g.store.flush(); g.device.flush()
                if (Notifier.isDone(intent.action)) SyncController.enqueueOnce(context)
            } finally {
                pr.finish()
            }
        }
    }
}

/** Boot, clock and time-zone changes, app update, exact-alarm permission change → rebuild alarms and triggers. */
class SystemEventsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val g = (context.applicationContext as LynxApp).graph
        val pr = goAsync()
        CoroutineScope(Dispatchers.Default).launch {
            try {
                g.alarms.reschedule()
                g.triggers.refresh(fromBackground = true)
            } finally {
                pr.finish()
            }
        }
    }
}

/** Posts a context-trigger alert (`<id>|ctx|0`), records the cooldown and starts the nag (SPEC §6). */
class ContextFirer(private val context: Context, private val store: LocalStore, private val device: DeviceStore, private val alarms: AlarmScheduler) {
    fun handle(event: ContextEvent, describe: (ReminderRow) -> String) {
        val now = Instant.now()
        val hits = TriggerMatching.evaluate(store.value.liveReminders(), event, now, device.value.cooldowns)
        if (hits.isEmpty()) return
        for (r in hits) Notifier.post(context, r, describe(r))
        device.edit { st ->
            st.copy(
                cooldowns = st.cooldowns + hits.associate { TriggerMatching.cooldownKey(it.id, event) to now },
                contextFired = st.contextFired + hits.filter { it.nag != null }.associate { it.id to now },
            )
        }
        alarms.reschedule()
        device.flush()
    }
}
