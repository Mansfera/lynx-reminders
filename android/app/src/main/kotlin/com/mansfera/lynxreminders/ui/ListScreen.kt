package com.mansfera.lynxreminders.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Flag
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.PersonAdd
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.mansfera.lynxreminders.core.LocalDb
import com.mansfera.lynxreminders.core.ReminderRow
import com.mansfera.lynxreminders.core.Section
import com.mansfera.lynxreminders.core.SmartList
import com.mansfera.lynxreminders.core.SmartLists
import com.mansfera.lynxreminders.core.effectiveDue
import java.time.Instant
import java.time.ZoneId

/** Screen header: back (when stacked), large title, actions. */
@Composable
fun ScreenHeader(title: String, titleColor: androidx.compose.ui.graphics.Color = lynx.fg, subtitle: String? = null, onBack: (() -> Unit)?, actions: @Composable () -> Unit = {}) {
    val c = lynx
    Column(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = Sp.s14).padding(top = Sp.s6)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            if (onBack != null) RoundIconButton(Icons.AutoMirrored.Rounded.ArrowBack, "Back", filled = false, onClick = onBack)
            Spacer(Modifier.weight(1f))
            actions()
        }
        Text(title, style = LynxType.screenTitle, color = titleColor, modifier = Modifier.padding(start = Sp.s4, top = Sp.s6), maxLines = 2, overflow = TextOverflow.Ellipsis)
        if (subtitle != null) Text(subtitle, style = LynxType.mono, color = c.muted, modifier = Modifier.padding(start = Sp.s4, top = Sp.s4))
        Spacer(Modifier.heightIn(min = Sp.s10))
    }
}

data class RowHandlers(
    val onToggle: (ReminderRow) -> Unit,
    val onOpen: (ReminderRow) -> Unit,
)

/** A smart list or a user list. */
@Composable
fun ListScreen(
    route: Route,
    db: LocalDb,
    now: Instant,
    showCompletedDefault: Boolean,
    signedIn: Boolean,
    handlers: RowHandlers,
    onBack: (() -> Unit)?,
    onEditList: (String) -> Unit,
    onShareList: (String) -> Unit,
    onQuickAdd: (String) -> Unit,
    onNewReminder: () -> Unit,
) {
    val c = lynx
    val zone = ZoneId.systemDefault()
    var showCompleted by rememberSaveable(route) { mutableStateOf(showCompletedDefault) }
    val list = (route as? Route.ListR)?.let { db.lists[it.id] }
    val title = when (route) {
        is Route.Smart -> route.kind.title
        is Route.ListR -> list?.name ?: "List"
        else -> ""
    }
    val sections: List<Section> = remember(db, now, route, showCompleted) {
        when (route) {
            is Route.Smart -> SmartLists.sections(db, route.kind, now, zone)
            is Route.ListR -> listOf(Section(listId = route.id, items = SmartLists.listItems(db, route.id, showCompleted)))
            else -> emptyList()
        }
    }
    val total = sections.sumOf { s -> s.items.count { it.isOpen } }
    val titleColor = if (list != null) c.listColor(list.color) else c.fg

    Column(Modifier.fillMaxSize().background(c.bg)) {
        ScreenHeader(
            title, titleColor = titleColor,
            subtitle = if (route == Route.Smart(SmartList.COMPLETED)) null else "$total open",
            onBack = onBack,
        ) {
            if (list != null) {
                if (signedIn) RoundIconButton(Icons.Rounded.PersonAdd, "Share list", filled = false) { onShareList(list.id) }
                RoundIconButton(Icons.Rounded.MoreHoriz, "Edit list", filled = false) { onEditList(list.id) }
            }
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(start = Sp.s14, end = Sp.s14, bottom = Sp.s24)) {
            val empty = sections.all { it.items.isEmpty() }
            if (empty) item { EmptyNote(emptyText(route)) }
            sections.filter { it.items.isNotEmpty() }.forEach { sec ->
                val header = when {
                    sec.date != null -> Fmt.dayHeader(sec.date!!, now.atZone(zone).toLocalDate())
                    sec.listId != null && route !is Route.ListR -> db.lists[sec.listId]?.name
                    else -> null
                }
                if (header != null) item(key = "h-" + (sec.date?.toString() ?: sec.listId)) { SectionLabel(header) }
                item(key = "p-" + (sec.date?.toString() ?: sec.listId ?: "all")) {
                    Panel(padding = 0.dp) {
                        sec.items.forEachIndexed { i, r ->
                            if (i > 0) Hairline(Modifier.padding(start = 52.dp))
                            ReminderItem(r, db, now, zone, handlers, showListName = route is Route.Smart)
                        }
                    }
                    Spacer(Modifier.heightIn(min = Sp.s10))
                }
            }
            if (route is Route.ListR) {
                item {
                    TextAction(if (showCompleted) "Hide completed" else "Show completed", color = c.muted) { showCompleted = !showCompleted }
                }
            }
        }
        if (route != Route.Smart(SmartList.COMPLETED)) QuickAddBar(if (list != null) "New in ${list.name}" else "New reminder", onQuickAdd, onNewReminder)
    }
}

private fun emptyText(route: Route) = when (route) {
    Route.Smart(SmartList.TODAY) -> "Nothing due today."
    Route.Smart(SmartList.SCHEDULED) -> "Reminders with a date show up here, grouped by day."
    Route.Smart(SmartList.FLAGGED) -> "Flag a reminder to keep it here."
    Route.Smart(SmartList.GOALS) -> "A reminder with subtasks becomes a goal with a progress ring."
    Route.Smart(SmartList.SHARED_WITH_ME) -> "Reminders people share with you appear here."
    Route.Smart(SmartList.ASSIGNED_TO_ME) -> "Nothing assigned to you."
    Route.Smart(SmartList.COMPLETED) -> "Completed reminders appear here."
    else -> "No reminders yet. Type one below."
}

/** Reminder row: checkbox in list color, title, notes, trigger chips; goal ring and flag on the right. */
@Composable
fun ReminderItem(r: ReminderRow, db: LocalDb, now: Instant, zone: ZoneId, handlers: RowHandlers, showListName: Boolean = false) {
    val c = lynx
    val list = db.lists[r.listId]
    val color = c.listColor(list?.color)
    val goal = remember(db, r.id) { SmartLists.goalProgress(db, r.id) }
    val due = r.effectiveDue(now)
    val overdue = SmartLists.isOverdue(r, now, zone)
    val assignee = r.assigneeId?.let { id -> db.members.firstOrNull { it.userId == id }?.profile ?: db.shares.firstOrNull { it.userId == id }?.profile }
    Row(
        Modifier.fillMaxWidth().clickable { handlers.onOpen(r) }.heightIn(min = 56.dp).padding(end = Sp.s14, top = Sp.s4, bottom = Sp.s4),
        verticalAlignment = Alignment.Top,
    ) {
        CheckCircle(r.isCompleted, color, { handlers.onToggle(r) }, pulse = goal?.full == true && r.isOpen, label = r.title)
        Column(Modifier.weight(1f).padding(top = 13.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (r.priority > 0) Text("!".repeat(r.priority) + " ", style = LynxType.rowMedium, color = color)
                Text(
                    r.title.ifBlank { "Untitled" }, style = LynxType.row, color = if (r.isCompleted) c.muted else c.fg,
                    maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false),
                )
            }
            val parent = r.parentId?.let { db.reminders[it] }
            val context = listOfNotNull(parent?.title?.let { "in $it" }, if (showListName) list?.name else null).joinToString(" · ")
            if (context.isNotEmpty()) Text(context, style = LynxType.caption, color = c.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            r.notes?.takeIf { it.isNotBlank() }?.let { Text(it, style = LynxType.caption, color = c.muted, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            TriggerChips(chipsFor(r, due, now, overdue && r.isOpen))
            Spacer(Modifier.heightIn(min = 6.dp))
        }
        Row(Modifier.padding(top = 14.dp, start = Sp.s10), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Sp.s6)) {
            if (goal != null) {
                GoalRing(goal.fraction, color)
                Text("${goal.done}/${goal.total}", style = LynxType.mono, color = c.muted)
            }
            if (r.flagged) Icon(Icons.Rounded.Flag, "Flagged", tint = c.fg, modifier = Modifier.size(16.dp))
            if (assignee != null) Avatar(assignee.displayName ?: assignee.email)
        }
    }
}

@Composable
fun SearchScreen(db: LocalDb, now: Instant, handlers: RowHandlers, onBack: () -> Unit) {
    val c = lynx
    var q by rememberSaveable { mutableStateOf("") }
    val zone = ZoneId.systemDefault()
    val results = remember(db, q) { SmartLists.search(db, q) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    Column(Modifier.fillMaxSize().background(c.bg)) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = Sp.s14, vertical = Sp.s6), verticalAlignment = Alignment.CenterVertically) {
            RoundIconButton(Icons.AutoMirrored.Rounded.ArrowBack, "Back", filled = false, onClick = onBack)
            Spacer(Modifier.width(Sp.s6))
            LynxField(q, { q = it }, "Search titles and notes", Modifier.weight(1f).focusRequester(focus))
        }
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(Sp.s14)) {
            if (q.isNotBlank() && results.isEmpty()) item { EmptyNote("No reminders match “$q”.") }
            if (results.isNotEmpty()) item {
                Panel(padding = 0.dp) {
                    results.forEachIndexed { i, r ->
                        if (i > 0) Hairline(Modifier.padding(start = 52.dp))
                        ReminderItem(r, db, now, zone, handlers, showListName = true)
                    }
                }
            }
        }
    }
}
