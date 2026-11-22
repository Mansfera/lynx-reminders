package com.mansfera.lynxreminders.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.PersonAdd
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDefaults
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TimePickerDefaults
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.mansfera.lynxreminders.core.LocalDb
import com.mansfera.lynxreminders.core.Nag
import com.mansfera.lynxreminders.core.QuickAddParser
import com.mansfera.lynxreminders.core.Recurrence
import com.mansfera.lynxreminders.core.ReminderRow
import com.mansfera.lynxreminders.core.SmartLists
import com.mansfera.lynxreminders.data.Repository
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit

/** Sets the due date/time; a repeating reminder re-anchors its series at the new wall time. */
fun ReminderRow.withDue(date: LocalDate?, time: LocalTime?): ReminderRow {
    if (date == null) return copy(dueAt = null, allDay = false, repeat = null)
    val zone = Recurrence.zone(timeZone)
    val local = LocalDateTime.of(date, time ?: LocalTime.MIDNIGHT)
    val due = ZonedDateTime.of(local, zone).toInstant()
    return copy(dueAt = due, allDay = time == null, repeat = repeat?.copy(anchor = Recurrence.formatLocal(local)))
}

fun ReminderRow.dueLocal(): LocalDateTime? = dueAt?.let { LocalDateTime.ofInstant(it, Recurrence.zone(timeZone)) }

@Composable
fun EditorScreen(
    route: Route.Editor,
    db: LocalDb,
    now: Instant,
    repo: Repository,
    signedIn: Boolean,
    handlers: RowHandlers,
    onClose: () -> Unit,
    onShare: (String) -> Unit,
    inPane: Boolean = false,
) {
    val c = lynx
    val existing = route.id?.let { db.reminders[it] }
    var draft by remember(route) { mutableStateOf(existing ?: repo.newReminderDraft(route.listId, route.parentId)) }
    val isNew = db.reminders[draft.id] == null
    var sheet by remember { mutableStateOf<String?>(null) }
    var datePicker by remember { mutableStateOf(false) }
    var timePicker by remember { mutableStateOf(false) }

    fun save() {
        val stored = db.reminders[draft.id]
        if (stored == null && draft.title.isBlank()) return
        if (stored != null && stored.copy(updatedAt = draft.updatedAt) == draft) return
        repo.saveReminder(draft.copy(title = draft.title.ifBlank { "Untitled" }))
    }
    fun close() { save(); onClose() }
    BackHandler { close() }

    val list = db.lists[draft.listId]
    val color = c.listColor(list?.color)

    Column(Modifier.fillMaxSize().background(c.bg)) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = Sp.s14, vertical = Sp.s6), verticalAlignment = Alignment.CenterVertically) {
            RoundIconButton(if (inPane) Icons.Rounded.Close else Icons.AutoMirrored.Rounded.ArrowBack, "Save and close", filled = false) { close() }
            Text(
                if (isNew) (if (draft.parentId != null) "New subtask" else "New reminder") else "Reminder",
                style = LynxType.label, color = c.muted, modifier = Modifier.weight(1f).padding(start = Sp.s6),
            )
            InkPill("Done", Icons.Rounded.Check, enabled = draft.title.isNotBlank() || !isNew) { close() }
        }
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Sp.s14).imePadding().navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(Sp.s10),
        ) {
            // Title, notes, URL
            Panel {
                LynxField(draft.title, { draft = draft.copy(title = it) }, "Title", style = LynxType.title, sunk = false, singleLine = false)
                Hairline()
                LynxField(draft.notes.orEmpty(), { draft = draft.copy(notes = it.ifEmpty { null }) }, "Notes", style = LynxType.body, sunk = false, singleLine = false)
                Hairline()
                LynxField(draft.url.orEmpty(), { draft = draft.copy(url = it.trim().ifEmpty { null }) }, "URL", style = LynxType.body, sunk = false, keyboardType = KeyboardType.Uri)
            }

            // When
            SectionLabel("When")
            Panel(padding = 0.dp) {
                val local = draft.dueLocal()
                SettingRow("Date", local?.let { Fmt.dayWord(it.toLocalDate(), LocalDate.now()) + if (it.year != LocalDate.now().year) " " + it.year else "" }, onClick = if (local != null) ({ datePicker = true }) else null) {
                    LynxSwitch(local != null, { on ->
                        draft = if (on) {
                            val t = LocalTime.now().truncatedTo(ChronoUnit.HOURS).plusHours(1)
                            draft.withDue(if (t == LocalTime.MIDNIGHT) LocalDate.now().plusDays(1) else LocalDate.now(), t)
                        } else draft.withDue(null, null)
                    })
                }
                // Time, early alert and repeat open under the date when it's switched on.
                AnimatedVisibility(local != null, enter = expandIn(), exit = collapseOut()) {
                    val at = lastNonNull(local) ?: return@AnimatedVisibility
                    Column {
                        Hairline()
                        SettingRow("Time", if (draft.allDay) "All day · alert at the all-day time" else Fmt.time(at.toLocalTime()), onClick = if (!draft.allDay) ({ timePicker = true }) else null) {
                            LynxSwitch(!draft.allDay, { on -> draft = draft.withDue(at.toLocalDate(), if (on) LocalTime.of(9, 0) else null) })
                        }
                        Hairline()
                        MenuRow("Early alert", Fmt.earlyLabel(draft.earlyAlertMinutes), listOf(null, 5, 15, 30, 60, 120, 1440).map { Fmt.earlyLabel(it) to it }) {
                            draft = draft.copy(earlyAlertMinutes = it)
                        }
                        Hairline()
                        SettingRow("Repeat", draft.repeat?.let { Fmt.repeatLabel(it) + (if (it.autoAdvance) " · advances on its own" else "") } ?: "Never", onClick = { sheet = "repeat" }) {
                            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = c.muted)
                        }
                    }
                }
            }

            // Nag
            Panel(padding = 0.dp) {
                SettingRow("Alert again until done", draft.nag?.let { "Every ${it.everyMinutes} min · " + (it.max?.let { m -> "$m times" } ?: "up to 24 h") } ?: "After a time or place alert") {
                    LynxSwitch(draft.nag != null, { draft = draft.copy(nag = if (it) Nag(10, 6) else null) })
                }
                AnimatedVisibility(draft.nag != null, enter = expandIn(), exit = collapseOut()) {
                    val nag = lastNonNull(draft.nag) ?: return@AnimatedVisibility
                    Column {
                        Hairline()
                        Column(Modifier.padding(horizontal = Sp.s14, vertical = Sp.s10), verticalArrangement = Arrangement.spacedBy(Sp.s6)) {
                            Text("Every", style = LynxType.caption, color = c.muted)
                            CapsuleTabs(listOf(5, 10, 15, 30, 60).map { it to "$it min" }, nag.everyMinutes, small = true) { draft = draft.copy(nag = nag.copy(everyMinutes = it)) }
                            Text("How many times", style = LynxType.caption, color = c.muted)
                            CapsuleTabs(listOf<Int?>(3, 6, 12, null).map { it to (it?.toString() ?: "Until done") }, nag.max, small = true) { draft = draft.copy(nag = nag.copy(max = it)) }
                        }
                    }
                }
            }

            // Triggers
            SectionLabel("Triggers")
            Panel(padding = 0.dp) {
                TriggerRow(ChipIcons.location, "Location", draft.location?.let { (if (it.on == "leave") "Leaving " else "Arriving at ") + it.name } ?: "Arrive at or leave a place",
                    set = draft.location != null, onClear = { draft = draft.copy(location = null) }) { sheet = "location" }
                Hairline(Modifier.padding(start = 52.dp))
                TriggerRow(ChipIcons.bluetooth, "Bluetooth", draft.bluetooth?.let { (if (it.on == "disconnect") "Disconnects from " else "Connects to ") + it.name } ?: "A device connects or disconnects",
                    set = draft.bluetooth != null, onClear = { draft = draft.copy(bluetooth = null) }) { sheet = "bluetooth" }
                Hairline(Modifier.padding(start = 52.dp))
                TriggerRow(ChipIcons.app, "App opened", draft.appTrigger?.let { "When you open ${it.name}" } ?: "When you open an app",
                    set = draft.appTrigger != null, onClear = { draft = draft.copy(appTrigger = null) }) { sheet = "app" }
            }

            // Details
            SectionLabel("Details")
            Panel(padding = 0.dp) {
                Column(Modifier.padding(horizontal = Sp.s14, vertical = Sp.s10), verticalArrangement = Arrangement.spacedBy(Sp.s6)) {
                    Text("Priority", style = LynxType.rowMedium, color = c.fg)
                    CapsuleTabs(listOf(0 to "None", 1 to "Low", 2 to "Medium", 3 to "High"), draft.priority, small = true) { draft = draft.copy(priority = it) }
                }
                Hairline()
                SettingRow("Flag") { LynxSwitch(draft.flagged, { draft = draft.copy(flagged = it) }) }
                if (draft.parentId == null) {
                    Hairline()
                    SettingRow("List", list?.name ?: "—", onClick = { sheet = "list" }) {
                        list?.let { ListBadge(color, it.icon, size = 24.dp) }
                    }
                }
                val people = assigneeCandidates(db, draft)
                if (people.isNotEmpty()) {
                    Hairline()
                    val who = people.firstOrNull { it.first == draft.assigneeId }?.second
                    SettingRow("Assignee", who ?: "Nobody", onClick = { sheet = "assignee" }) { if (who != null) Avatar(who) }
                }
            }

            // Goal / subtasks
            if (draft.parentId == null) {
                SubtasksPanel(draft, db, now, repo, handlers, color, ensureSaved = { if (db.reminders[draft.id] == null && draft.title.isNotBlank()) save() })
            }

            if (signedIn && !isNew) {
                Panel(padding = 0.dp) {
                    SettingRow("Share this reminder", "With someone, without sharing the list", onClick = { save(); onShare(draft.id) }) {
                        Icon(Icons.Rounded.PersonAdd, null, tint = c.fg)
                    }
                }
            }
            if (!isNew) {
                TextAction("Delete reminder", color = c.ink2, modifier = Modifier.padding(bottom = Sp.s24)) {
                    repo.delete(draft.id); onClose()
                }
            } else Spacer(Modifier.height(Sp.s24))
        }
    }

    if (datePicker) {
        val local = draft.dueLocal() ?: LocalDateTime.now()
        val st = rememberDatePickerState(initialSelectedDateMillis = local.toLocalDate().atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli())
        val motion = rememberDialogMotion()
        DatePickerDialog(
            onDismissRequest = { motion.close { datePicker = false } },
            confirmButton = { TextAction("Set") {
                st.selectedDateMillis?.let { ms ->
                    val d = Instant.ofEpochMilli(ms).atZone(ZoneOffset.UTC).toLocalDate()
                    draft = draft.withDue(d, if (draft.allDay) null else local.toLocalTime())
                }
                motion.close { datePicker = false }
            } },
            modifier = Modifier.dialogCard(motion),
            dismissButton = { TextAction("Cancel", color = c.muted) { motion.close { datePicker = false } } },
            colors = DatePickerDefaults.colors(containerColor = c.panel),
        ) {
            DialogWindowMotion(motion)
            DatePicker(st, colors = lynxDatePickerColors())
        }
    }
    if (timePicker) {
        val local = draft.dueLocal() ?: LocalDateTime.now()
        val st = rememberTimePickerState(local.hour, local.minute, Fmt.is24)
        val motion = rememberDialogMotion()
        Dialog(onDismissRequest = { motion.close { timePicker = false } }) {
            DialogWindowMotion(motion)
            Panel(Modifier.dialogCard(motion), padding = Sp.s18) {
                Text("Time", style = LynxType.title, color = c.fg, modifier = Modifier.padding(bottom = Sp.s14))
                TimePicker(st, colors = lynxTimePickerColors())
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextAction("Cancel", color = c.muted) { motion.close { timePicker = false } }
                    TextAction("Set") {
                        draft = draft.withDue(local.toLocalDate(), LocalTime.of(st.hour, st.minute)); motion.close { timePicker = false }
                    }
                }
            }
        }
    }
    when (sheet) {
        "repeat" -> RepeatSheet(draft, onDismiss = { sheet = null }) { draft = it; sheet = null }
        "location" -> LocationSheet(draft.location, onDismiss = { sheet = null }) { draft = draft.copy(location = it); sheet = null }
        "bluetooth" -> BluetoothSheet(draft.bluetooth, onDismiss = { sheet = null }) { draft = draft.copy(bluetooth = it); sheet = null }
        "app" -> AppSheet(draft.appTrigger, onDismiss = { sheet = null }) { draft = draft.copy(appTrigger = it); sheet = null }
        "list" -> ListPickerSheet(db, draft.listId, onDismiss = { sheet = null }) { draft = draft.copy(listId = it, assigneeId = null); sheet = null }
        "assignee" -> AssigneeSheet(assigneeCandidates(db, draft), draft.assigneeId, onDismiss = { sheet = null }) { draft = draft.copy(assigneeId = it); sheet = null }
    }
}

/** People who can see the reminder: list members and people it is shared with. */
fun assigneeCandidates(db: LocalDb, r: ReminderRow): List<Pair<String, String>> {
    if (db.userId == null) return emptyList()
    val members = db.membersOf(r.listId).map { it.userId to (it.profile?.displayName?.ifBlank { null } ?: it.profile?.email ?: "Member") }
    val shared = db.shares.filter { it.reminderId == r.id || it.reminderId == r.parentId }.map { it.userId to (it.profile?.displayName?.ifBlank { null } ?: it.profile?.email ?: "Someone") }
    val all = (members + shared).distinctBy { it.first }
    return if (all.size > 1) all.map { (id, n) -> id to (if (id == db.me) "$n (me)" else n) } else emptyList()
}

@Composable
private fun TriggerRow(icon: ImageVector, title: String, detail: String, set: Boolean, onClear: () -> Unit, onClick: () -> Unit) {
    val c = lynx
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).heightIn(min = 56.dp).padding(start = Sp.s14, end = Sp.s4),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Sp.s14),
    ) {
        Icon(icon, null, tint = if (set) c.fg else c.muted, modifier = Modifier.size(24.dp))
        Column(Modifier.weight(1f).padding(vertical = Sp.s10)) {
            Text(title, style = LynxType.rowMedium, color = c.fg)
            Text(detail, style = LynxType.caption, color = c.muted, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        if (set) RoundIconButton(Icons.Rounded.Close, "Remove $title trigger", filled = false, size = 28.dp, onClick = onClear)
        else Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = c.muted, modifier = Modifier.padding(end = Sp.s10))
    }
}

@Composable
fun <T> MenuRow(title: String, value: String, options: List<Pair<String, T>>, onPick: (T) -> Unit) {
    val c = lynx
    var open by remember { mutableStateOf(false) }
    Box {
        SettingRow(title, value, onClick = { open = true }) { Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = c.muted) }
        DropdownMenu(open, { open = false }, containerColor = c.panel) {
            options.forEach { (label, v) ->
                DropdownMenuItem(text = { Text(label, style = LynxType.row, color = c.fg) }, onClick = { onPick(v); open = false })
            }
        }
    }
}

@Composable
private fun SubtasksPanel(
    draft: ReminderRow, db: LocalDb, now: Instant, repo: Repository, handlers: RowHandlers,
    color: androidx.compose.ui.graphics.Color, ensureSaved: () -> Unit,
) {
    val c = lynx
    val subs = db.subtasksOf(draft.id)
    val progress = SmartLists.goalProgress(db, draft.id)
    var text by remember { mutableStateOf("") }
    SectionLabel(if (subs.isEmpty()) "Subtasks" else "Goal")
    Panel(padding = 0.dp) {
        // The goal header opens with the first subtask; subtasks expand in and collapse out.
        AnimatedVisibility(progress != null, enter = expandIn(), exit = collapseOut()) {
            val p = lastNonNull(progress) ?: return@AnimatedVisibility
            Column {
                Row(Modifier.padding(Sp.s14), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Sp.s14)) {
                    GoalRingLarge(p, color)
                    Column {
                        Text(if (p.full) "All subtasks done" else "${p.total - p.done} to go", style = LynxType.rowMedium, color = c.fg)
                        Text(if (p.full) "Complete the goal when you're ready" else "Completing the goal can complete them all", style = LynxType.caption, color = c.muted)
                    }
                }
                Hairline()
            }
        }
        AnimatedRows(subs, key = { it.id }) { s, _ ->
            Column {
                Row(Modifier.fillMaxWidth().clickable { handlers.onOpen(s) }.heightIn(min = 48.dp).padding(end = Sp.s14), verticalAlignment = Alignment.CenterVertically) {
                    CheckCircle(s.isCompleted, color, { handlers.onToggle(s) }, label = s.title)
                    Text(s.title, style = LynxType.row, color = if (s.isCompleted) c.muted else c.fg, modifier = Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                Hairline(Modifier.padding(start = 48.dp))
            }
        }
        Row(Modifier.fillMaxWidth().padding(start = Sp.s14, end = Sp.s4), verticalAlignment = Alignment.CenterVertically) {
            fun add() {
                if (text.isBlank() || draft.title.isBlank()) return
                ensureSaved()
                val q = QuickAddParser.parse(text, Instant.now(), ZoneId.systemDefault())
                repo.addQuick(q.copy(listId = null), draft.listId, parentId = draft.id)
                text = ""
            }
            LynxField(text, { text = it }, if (draft.title.isBlank()) "Give the reminder a title first" else "Add a subtask", Modifier.weight(1f), sunk = false, onDone = { add() })
            Box(Modifier.size(48.dp).clip(CircleShape).clickable(role = Role.Button) { add() }, contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.Add, "Add subtask", tint = c.fg)
            }
        }
    }
}

@Composable
fun lynxDatePickerColors() = lynx.let { c ->
    DatePickerDefaults.colors(
        containerColor = c.panel, titleContentColor = c.muted, headlineContentColor = c.fg, weekdayContentColor = c.muted,
        subheadContentColor = c.muted, navigationContentColor = c.fg, yearContentColor = c.fg, currentYearContentColor = c.fg,
        selectedYearContentColor = c.bg, selectedYearContainerColor = c.fg, dayContentColor = c.fg,
        selectedDayContentColor = c.bg, selectedDayContainerColor = c.fg, todayContentColor = c.fg, todayDateBorderColor = c.fg,
        dividerColor = c.line,
    )
}

@Composable
fun lynxTimePickerColors() = lynx.let { c ->
    TimePickerDefaults.colors(
        clockDialColor = c.sunk, clockDialSelectedContentColor = c.bg, clockDialUnselectedContentColor = c.fg, selectorColor = c.fg,
        containerColor = c.panel, periodSelectorBorderColor = c.line, periodSelectorSelectedContainerColor = c.fg,
        periodSelectorUnselectedContainerColor = c.panel, periodSelectorSelectedContentColor = c.bg, periodSelectorUnselectedContentColor = c.muted,
        timeSelectorSelectedContainerColor = c.fg, timeSelectorUnselectedContainerColor = c.sunk,
        timeSelectorSelectedContentColor = c.bg, timeSelectorUnselectedContentColor = c.fg,
    )
}
