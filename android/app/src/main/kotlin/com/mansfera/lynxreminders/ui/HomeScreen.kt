package com.mansfera.lynxreminders.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.DonutLarge
import androidx.compose.material.icons.rounded.Group
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PersonOutline
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.mansfera.lynxreminders.core.LocalDb
import com.mansfera.lynxreminders.core.ReminderRow
import com.mansfera.lynxreminders.core.SmartList
import com.mansfera.lynxreminders.core.SmartLists
import com.mansfera.lynxreminders.core.effectiveDue
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Home: Today stage (hero), 2×2 stats grid, smart lists, my lists, shared lists, quick add. */
@Composable
fun HomeScreen(
    db: LocalDb,
    now: Instant,
    signedIn: Boolean,
    selected: Route?,
    banner: (@Composable () -> Unit)?,
    onOpen: (Route) -> Unit,
    onQuickAdd: (String) -> Unit,
    onNewReminder: () -> Unit,
    onMoveList: (id: String, up: Boolean) -> Unit,
    showQuickAdd: Boolean = true,
) {
    val c = lynx
    val zone = ZoneId.systemDefault()
    val counts = remember(db, now) { SmartLists.counts(db, now, zone) }
    var reorder by rememberSaveable { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().background(c.bg)) {
        LazyColumn(
            Modifier.weight(1f).fillMaxWidth(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(start = Sp.s14, end = Sp.s14, bottom = Sp.s24),
            verticalArrangement = Arrangement.spacedBy(Sp.s10),
        ) {
            item(key = "top") {
                Row(itemMotion().fillMaxWidth().statusBarsPadding().padding(top = Sp.s6), verticalAlignment = Alignment.CenterVertically) {
                    SearchPill(Modifier.weight(1f)) { onOpen(Route.Search) }
                    RoundIconButton(if (signedIn) Icons.Rounded.Person else Icons.Rounded.PersonOutline, "Account and settings") { onOpen(Route.Account) }
                }
            }
            // The notice fades in or out and everything below glides to make room.
            if (banner != null) item(key = "banner") { Box(itemMotion()) { banner() } }
            item(key = "today") { TodayStage(db, now, zone, itemMotion()) { onOpen(Route.Smart(SmartList.TODAY)) } }
            item(key = "stats") { StatsGrid(counts, selected, itemMotion()) { onOpen(Route.Smart(it)) } }
            item(key = "smart") {
                Panel(itemMotion(), padding = 0.dp) {
                    val rows = buildList {
                        add(Triple(SmartList.GOALS, Icons.Rounded.DonutLarge, counts[SmartList.GOALS] ?: 0))
                        if (signedIn) {
                            add(Triple(SmartList.SHARED_WITH_ME, Icons.Rounded.Group, counts[SmartList.SHARED_WITH_ME] ?: 0))
                            add(Triple(SmartList.ASSIGNED_TO_ME, Icons.Rounded.Person, counts[SmartList.ASSIGNED_TO_ME] ?: 0))
                        }
                        add(Triple(SmartList.COMPLETED, Icons.Rounded.CheckCircle, -1))
                    }
                    rows.forEachIndexed { i, (k, icon, n) ->
                        if (i > 0) Hairline(Modifier.padding(start = 54.dp))
                        NavRow(icon, k.title, if (n >= 0) "$n" else null, selected = selected == Route.Smart(k)) { onOpen(Route.Smart(k)) }
                    }
                }
            }
            val mine = SmartLists.myLists(db)
            item(key = "mine-title") {
                Row(itemMotion().fillMaxWidth().padding(top = Sp.s6), verticalAlignment = Alignment.CenterVertically) {
                    Text("My lists", style = LynxType.title, color = c.fg, modifier = Modifier.weight(1f).padding(start = Sp.s4))
                    if (mine.size > 1) TextAction(if (reorder) "Done" else "Reorder", color = c.muted) { reorder = !reorder }
                    TextAction("New list") { onOpen(Route.ListEdit(null)) }
                }
            }
            item(key = "mine") {
                if (mine.isEmpty()) {
                    val note = if (SmartLists.sharedLists(db).isNotEmpty()) "Lists only you use appear here." else "No lists yet. Reminders you add go to a list called Reminders."
                    Panel(itemMotion()) { Text(note, style = LynxType.body, color = c.muted) }
                } else {
                    Panel(itemMotion(), padding = 0.dp) {
                        mine.forEachIndexed { i, l ->
                            // Keyed and gliding, so Reorder moves the row instead of swapping names in place.
                            key(l.id) {
                                Column(Modifier.animatePlacement()) {
                                    if (i > 0) Hairline(Modifier.padding(start = 58.dp))
                                    ListNavRow(
                                        name = l.name, color = c.listColor(l.color), icon = l.icon, count = SmartLists.openCount(db, l.id),
                                        selected = selected == Route.ListR(l.id), avatars = emptyList(),
                                        reorder = if (reorder) ({ up: Boolean -> onMoveList(l.id, up) }) else null,
                                    ) { onOpen(Route.ListR(l.id)) }
                                }
                            }
                        }
                    }
                }
            }
            val shared = SmartLists.sharedLists(db)
            if (shared.isNotEmpty()) {
                item(key = "shared-title") { Text("Shared lists", style = LynxType.title, color = c.fg, modifier = itemMotion().padding(start = Sp.s4, top = Sp.s12)) }
                item(key = "shared") {
                    Panel(itemMotion(), padding = 0.dp) {
                        shared.forEachIndexed { i, l ->
                            if (i > 0) Hairline(Modifier.padding(start = 58.dp))
                            val people = db.membersOf(l.id).filter { it.userId != db.me }.map { it.profile?.displayName ?: it.profile?.email }
                            ListNavRow(l.name, c.listColor(l.color), l.icon, SmartLists.openCount(db, l.id), selected == Route.ListR(l.id), people, null) { onOpen(Route.ListR(l.id)) }
                        }
                    }
                }
            }
        }
        if (showQuickAdd) QuickAddBar("New reminder", onAdd = onQuickAdd, onExpand = onNewReminder)
    }
}


@Composable
fun SearchPill(modifier: Modifier = Modifier, onClick: () -> Unit) {
    val c = lynx
    Row(
        modifier
            .padding(end = Sp.s6)
            .heightIn(min = 44.dp)
            .clip(CircleShape)
            .background(c.sunk)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = Sp.s14),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Sp.s10),
    ) {
        Icon(Icons.Rounded.Search, null, tint = c.muted, modifier = Modifier.size(20.dp))
        Text("Search", style = LynxType.body, color = c.muted)
    }
}

/** Today stage: big open-today count, the 24 h day ruler and "3 overdue · next at 14:30". */
@Composable
fun TodayStage(db: LocalDb, now: Instant, zone: ZoneId, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val c = lynx
    val today = remember(db, now) { SmartLists.sections(db, SmartList.TODAY, now, zone).flatMap { it.items } }
    val overdue = today.count { SmartLists.isOverdue(it, now, zone) }
    val upcoming = today.filter { !it.allDay }.mapNotNull { it.effectiveDue(now) }.filter { it.isAfter(now) }.minOrNull()
    val caption = buildList {
        if (overdue > 0) add("$overdue overdue")
        if (upcoming != null) add("next at ${Fmt.time(upcoming)}")
        if (isEmpty()) add(if (today.isEmpty()) "Nothing due today" else "All set for the rest of the day")
    }.joinToString(" · ")
    val dateLabel = now.atZone(zone).format(DateTimeFormatter.ofPattern("EEE d MMM", Locale.ENGLISH)).uppercase()

    // The hero's blocks rise in once per app launch, not on every return to Home.
    val intro = rememberEntrance(3, play = firstTimeSinceLaunch("today-stage"))
    Stage(modifier.clickable(role = Role.Button, onClick = onClick).semantics { contentDescription = "Today: ${today.size} open. $caption" }) {
        // Number, unit and date share the hero's baseline, like "80 %" on the Lynx Battery stage
        Row(modifier = Modifier.fillMaxWidth().rise(intro[0])) {
            CountText(today.size, LynxType.hero, c.fg, Modifier.alignByBaseline())
            Text(" today", style = LynxType.heroUnit, color = c.fg.copy(alpha = 0.6f), modifier = Modifier.alignByBaseline())
            Spacer(Modifier.weight(1f))
            Text(dateLabel, style = LynxType.mono, color = c.fg.copy(alpha = 0.7f), modifier = Modifier.alignByBaseline())
        }
        Spacer(Modifier.height(Sp.s14))
        Box(Modifier.rise(intro[1])) { DayRuler(today, now, zone) }
        Spacer(Modifier.height(Sp.s14))
        Text(caption, style = LynxType.rowMedium, color = if (overdue > 0) c.signal else c.fg.copy(alpha = 0.75f), modifier = Modifier.rise(intro[2]))
    }
}

/**
 * The Lynx tick ruler re-used as the 24 h of today: major tick every 6 h, the past drawn as a line,
 * each reminder a dot at its time (overdue in signal red), and a "now" marker.
 */
@Composable
fun DayRuler(items: List<ReminderRow>, now: Instant, zone: ZoneId) {
    val c = lynx
    val startOfDay = now.atZone(zone).toLocalDate().atStartOfDay(zone).toInstant()
    fun frac(i: Instant) = ((i.epochSecond - startOfDay.epochSecond) / 86400f).coerceIn(0f, 1f)
    val nowF = frac(now)
    val dots = items.filter { !it.allDay }.mapNotNull { r -> r.effectiveDue(now)?.let { frac(it) to it.isBefore(now) } }
    Column(Modifier.fillMaxWidth()) {
        Canvas(Modifier.fillMaxWidth().height(22.dp).padding(horizontal = 4.dp)) {
            val w = size.width
            val h = size.height
            val n = 49 // a tick every 30 min
            for (i in 0 until n) {
                val x = w * i / (n - 1)
                val major = i % 12 == 0
                val th = if (major) 8.dp.toPx() else 4.dp.toPx()
                drawRect(c.fg.copy(alpha = if (major) 0.45f else 0.2f), Offset(x - 0.5f, h - th), Size(1f.dp.toPx().coerceAtLeast(1f), th))
            }
            // covered part
            drawRect(c.fg, Offset(0f, h - 1.5.dp.toPx()), Size(w * nowF, 1.5.dp.toPx()))
            // now marker
            drawRect(c.fg.copy(alpha = 0.8f), Offset(w * nowF - 0.75.dp.toPx(), h - 14.dp.toPx()), Size(1.5.dp.toPx(), 14.dp.toPx()))
            // reminders
            val r = 4.dp.toPx()
            dots.forEach { (f, overdue) ->
                drawCircle(if (overdue) c.signal else c.fg, r, Offset(w * f, r))
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 4.dp)) {
            listOf("00", "06", "12", "18", "24").forEachIndexed { i, s ->
                Text(s, style = LynxType.monoSmall, color = c.fg.copy(alpha = 0.6f))
                if (i < 4) Spacer(Modifier.weight(1f))
            }
        }
    }
}

/** 2×2 panel with hairline dividers; each cell = 28 sp count + caption. Selected cell gets the sunk fill. */
@Composable
fun StatsGrid(counts: Map<SmartList, Int>, selected: Route?, modifier: Modifier = Modifier, onClick: (SmartList) -> Unit) {
    val c = lynx
    Panel(modifier, padding = 0.dp) {
        listOf(SmartList.TODAY to SmartList.SCHEDULED, SmartList.ALL to SmartList.FLAGGED).forEachIndexed { row, (a, b) ->
            if (row > 0) Hairline()
            Row(Modifier.fillMaxWidth().height(androidx.compose.foundation.layout.IntrinsicSize.Min)) {
                StatCell(a, counts[a] ?: 0, selected == Route.Smart(a), Modifier.weight(1f)) { onClick(a) }
                VHairline()
                StatCell(b, counts[b] ?: 0, selected == Route.Smart(b), Modifier.weight(1f)) { onClick(b) }
            }
        }
    }
}

@Composable
private fun StatCell(kind: SmartList, n: Int, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val c = lynx
    Column(
        modifier
            .background(if (selected) c.sunk else Color.Transparent)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(Sp.s14)
            .semantics { contentDescription = "${kind.title}: $n" },
        verticalArrangement = Arrangement.spacedBy(Sp.s4),
    ) {
        CountText(n, LynxType.stat, c.fg)
        Text(kind.title, style = LynxType.caption, color = c.muted)
    }
}

@Composable
fun NavRow(icon: ImageVector, title: String, trailing: String?, selected: Boolean = false, onClick: () -> Unit) {
    val c = lynx
    Row(
        Modifier
            .fillMaxWidth()
            .background(if (selected) c.sunk else Color.Transparent)
            .clickable(onClick = onClick)
            .heightIn(min = 52.dp)
            .padding(horizontal = Sp.s14),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Sp.s14),
    ) {
        Icon(icon, null, tint = c.fg, modifier = Modifier.size(24.dp))
        Text(title, style = LynxType.row, color = c.fg, modifier = Modifier.weight(1f))
        if (trailing != null) Text(trailing, style = LynxType.mono, color = c.muted)
        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = c.muted, modifier = Modifier.size(18.dp))
    }
}

@Composable
fun ListNavRow(
    name: String, color: Color, icon: String, count: Int, selected: Boolean, avatars: List<String?>,
    reorder: ((Boolean) -> Unit)?, onClick: () -> Unit,
) {
    val c = lynx
    Row(
        Modifier
            .fillMaxWidth()
            .background(if (selected) c.sunk else Color.Transparent)
            .clickable(onClick = onClick)
            .heightIn(min = 56.dp)
            .padding(horizontal = Sp.s14),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Sp.s14),
    ) {
        ListBadge(color, icon)
        Text(name, style = LynxType.row, color = c.fg, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (avatars.isNotEmpty()) {
            Box {
                avatars.take(3).forEachIndexed { i, a -> Avatar(a, Modifier.offset(x = (i * 14).dp)) }
            }
            Spacer(Modifier.width(14.dp * (minOf(3, avatars.size) - 1).coerceAtLeast(0)))
        }
        if (reorder != null) {
            RoundIconButton(Icons.Rounded.ArrowUpward, "Move $name up", filled = false, size = 30.dp) { reorder(true) }
            RoundIconButton(Icons.Rounded.ArrowDownward, "Move $name down", filled = false, size = 30.dp) { reorder(false) }
        } else {
            Text("$count", style = LynxType.mono, color = c.muted)
        }
    }
}

/** Bottom dock: quick-add field (light natural-language parsing) and the round Ink "+" button. */
@Composable
fun QuickAddBar(hint: String, onAdd: (String) -> Unit, onExpand: () -> Unit) {
    val c = lynx
    var text by rememberSaveable { mutableStateOf("") }
    Column(Modifier.fillMaxWidth().background(c.bg)) {
        Hairline()
        Row(
            Modifier.fillMaxWidth().navigationBarsPadding().imePadding().padding(start = Sp.s14, end = Sp.s6, top = Sp.s6, bottom = Sp.s6),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            LynxField(
                value = text, onValueChange = { text = it }, placeholder = hint,
                modifier = Modifier.weight(1f),
                onDone = { if (text.isNotBlank()) { onAdd(text); text = "" } },
            )
            RoundIconButton(Icons.Rounded.Add, if (text.isBlank()) "New reminder with details" else "Add reminder") {
                if (text.isBlank()) onExpand() else { onAdd(text); text = "" }
            }
        }
    }
}

