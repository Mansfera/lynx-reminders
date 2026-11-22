package com.mansfera.lynxreminders.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.List
import androidx.compose.material.icons.automirrored.rounded.MenuBook
import androidx.compose.material.icons.rounded.Apps
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.CardGiftcard
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Eco
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.Flag
import androidx.compose.material.icons.rounded.Flight
import androidx.compose.material.icons.rounded.Headphones
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material.icons.rounded.Place
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.Schedule
import androidx.compose.material.icons.rounded.ShoppingCart
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.Work
import androidx.compose.material3.Icon
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.mansfera.lynxreminders.core.GoalProgress
import com.mansfera.lynxreminders.core.ReminderRow

// ---------- surfaces ----------

/** Panel (r 20) with a hairline border and no shadow — the default container. */
@Composable
fun Panel(modifier: Modifier = Modifier, padding: Dp = Sp.s14, content: @Composable ColumnScope.() -> Unit) {
    val c = lynx
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .background(c.panel)
            .border(1.dp, c.line, RoundedCornerShape(20.dp))
            .padding(padding),
        content = content,
    )
}

/** Stage (r 28): the sky scene. One per screen, for the hero only. */
@Composable
fun Stage(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val c = lynx
    BoxWithConstraints(modifier.fillMaxWidth().clip(RoundedCornerShape(28.dp))) {
        val w = constraints.maxWidth.toFloat()
        Box(Modifier.matchParentSize().background(c.stage(w, w * 0.8f)))
        Column(Modifier.fillMaxWidth().padding(Sp.s18), content = content)
    }
}

@Composable
fun Hairline(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(1.dp).background(lynx.line))
}

@Composable
fun VHairline(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxHeight().width(1.dp).background(lynx.line))
}

// ---------- buttons ----------

/** Ink pill: Ink capsule, white text, white circle with a glyph on the right. Inverts on dark. */
@Composable
fun InkPill(text: String, icon: ImageVector, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    val c = lynx
    val fill = if (c.dark) Color.White else c.fg
    val ink = if (c.dark) Color(0xFF0E0E10) else Color.White
    Row(
        modifier
            .heightIn(min = 48.dp)
            .clip(CircleShape)
            .background(if (enabled) fill else fill.copy(alpha = 0.35f))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(start = Sp.s18, end = Sp.s6, top = Sp.s6, bottom = Sp.s6),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Sp.s10),
    ) {
        Text(text, style = LynxType.label, color = ink)
        Box(Modifier.size(32.dp).clip(CircleShape).background(ink), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = fill, modifier = Modifier.size(18.dp))
        }
    }
}

/** Round icon button: Ink circle with a white symbol (filled), or a sunk circle with an Ink symbol. */
@Composable
fun RoundIconButton(icon: ImageVector, description: String, modifier: Modifier = Modifier, filled: Boolean = true, size: Dp = 36.dp, onClick: () -> Unit) {
    val c = lynx
    Box(
        modifier
            .size(48.dp)
            .clip(CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.size(size).clip(CircleShape).background(if (filled) c.fg else c.sunk), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = if (filled) c.bg else c.fg, modifier = Modifier.size(size * 0.5f))
        }
    }
}

/** Plain text action: muted until pressed. Used for secondary links ("Continue without account"). */
@Composable
fun TextAction(text: String, modifier: Modifier = Modifier, color: Color = lynx.ink2, onClick: () -> Unit) {
    Box(modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(12.dp)).clickable(role = Role.Button, onClick = onClick).padding(horizontal = Sp.s10), contentAlignment = Alignment.Center) {
        Text(text, style = LynxType.label, color = color)
    }
}

/** Capsule tabs: selected = Ink capsule with white text, others muted text. */
@Composable
fun <T> CapsuleTabs(options: List<Pair<T, String>>, selected: T, modifier: Modifier = Modifier, small: Boolean = false, onSelect: (T) -> Unit) {
    val c = lynx
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically) {
        options.forEach { (v, label) ->
            val on = v == selected
            Box(
                Modifier
                    .heightIn(min = if (small) 36.dp else 44.dp)
                    .clip(CircleShape)
                    .clickable(role = Role.Tab) { onSelect(v) }
                    .semantics { stateDescription = if (on) "Selected" else "" },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label,
                    style = if (small) LynxType.captionMedium else LynxType.label,
                    color = if (on) c.bg else c.muted,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(if (on) c.fg else Color.Transparent)
                        .padding(horizontal = if (small) Sp.s10 else Sp.s14, vertical = if (small) Sp.s6 else 9.dp),
                )
            }
        }
    }
}

/** Pull down to sync. Off (plain content) when there's no account to sync with. */
@Composable
fun SyncPull(enabled: Boolean, refreshing: Boolean, onRefresh: () -> Unit, content: @Composable () -> Unit) {
    if (!enabled) { content(); return }
    val c = lynx
    val state = rememberPullToRefreshState()
    PullToRefreshBox(
        isRefreshing = refreshing,
        onRefresh = onRefresh,
        state = state,
        modifier = Modifier.fillMaxSize(),
        indicator = {
            PullToRefreshDefaults.Indicator(
                state = state, isRefreshing = refreshing,
                containerColor = c.panel, color = c.fg,
                modifier = Modifier.align(Alignment.TopCenter).statusBarsPadding(),
            )
        },
    ) { content() }
}

// ---------- inputs ----------

@Composable
fun LynxField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    style: TextStyle = LynxType.row,
    singleLine: Boolean = true,
    keyboardType: KeyboardType = KeyboardType.Text,
    imeAction: ImeAction = ImeAction.Done,
    password: Boolean = false,
    onDone: (() -> Unit)? = null,
    leading: (@Composable () -> Unit)? = null,
    sunk: Boolean = true,
) {
    val c = lynx
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = singleLine,
        textStyle = style.copy(color = c.fg),
        cursorBrush = SolidColor(c.fg),
        visualTransformation = if (password) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = imeAction),
        keyboardActions = KeyboardActions(onAny = { onDone?.invoke() }),
        modifier = modifier,
        decorationBox = { inner ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = 48.dp)
                    .then(if (sunk) Modifier.clip(RoundedCornerShape(14.dp)).background(c.sunk) else Modifier)
                    .padding(horizontal = if (sunk) Sp.s14 else 0.dp, vertical = Sp.s10),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Sp.s10),
            ) {
                leading?.invoke()
                Box(Modifier.weight(1f)) {
                    if (value.isEmpty()) Text(placeholder, style = style, color = c.muted)
                    inner()
                }
            }
        },
    )
}

@Composable
fun LynxSwitch(checked: Boolean, onChange: (Boolean) -> Unit, modifier: Modifier = Modifier) {
    val c = lynx
    Switch(
        checked = checked, onCheckedChange = onChange, modifier = modifier,
        colors = SwitchDefaults.colors(
            checkedThumbColor = if (c.dark) Color(0xFF0E0E10) else Color.White,
            checkedTrackColor = c.toggleOn, checkedBorderColor = c.toggleOn,
            uncheckedThumbColor = c.muted, uncheckedTrackColor = c.sunk, uncheckedBorderColor = c.line,
        ),
    )
}

/** Row inside a panel: title + optional detail, trailing control. */
@Composable
fun SettingRow(title: String, detail: String? = null, modifier: Modifier = Modifier, onClick: (() -> Unit)? = null, trailing: @Composable RowScope.() -> Unit = {}) {
    val c = lynx
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = Sp.s14, vertical = Sp.s10),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Sp.s12),
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = LynxType.rowMedium, color = c.fg)
            if (detail != null) Text(detail, style = LynxType.caption, color = c.muted)
        }
        trailing()
    }
}

@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(text, style = LynxType.captionMedium, color = lynx.muted, modifier = modifier.padding(start = Sp.s4, top = Sp.s12, bottom = Sp.s6))
}

// ---------- reminder pieces ----------

/** 20 pt circle (22 dp), 1.5 pt stroke in list color; completed = filled with a white check. Pulses when a goal is full. */
@Composable
fun CheckCircle(checked: Boolean, color: Color, onClick: () -> Unit, modifier: Modifier = Modifier, pulse: Boolean = false, label: String = "") {
    val c = lynx
    val scale = if (pulse) {
        val t = rememberInfiniteTransition(label = "pulse")
        t.animateFloat(1f, 1.12f, infiniteRepeatable(tween(700), RepeatMode.Reverse), label = "pulse").value
    } else 1f
    val fill by animateFloatAsState(if (checked) 1f else 0f, tween(160), label = "fill")
    Box(
        modifier
            .size(48.dp)
            .clip(CircleShape)
            .clickable(role = Role.Checkbox, onClick = onClick)
            .semantics { contentDescription = (if (checked) "Completed: " else "Complete: ") + label },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(22.dp * scale)) {
            val stroke = 1.5.dp.toPx()
            drawCircle(color, radius = size.minDimension / 2 - stroke / 2, style = Stroke(stroke))
            if (fill > 0f) drawCircle(color.copy(alpha = fill), radius = size.minDimension / 2)
        }
        if (checked) Icon(Icons.Rounded.Check, null, tint = if (c.dark && color == c.fg) Color(0xFF0E0E10) else Color.White, modifier = Modifier.size(15.dp))
    }
}

/** Goal ring: track = line, progress = list color. */
@Composable
fun GoalRing(progress: Float, color: Color, modifier: Modifier = Modifier, size: Dp = 22.dp, stroke: Dp = 2.5.dp) {
    val c = lynx
    val p by animateFloatAsState(progress.coerceIn(0f, 1f), tween(300), label = "ring")
    Canvas(modifier.size(size)) {
        val s = stroke.toPx()
        val d = this.size.minDimension - s
        val tl = Offset(s / 2, s / 2)
        drawArc(c.line, 0f, 360f, false, tl, Size(d, d), style = Stroke(s))
        if (p > 0f) drawArc(color, -90f, 360f * p, false, tl, Size(d, d), style = Stroke(s, cap = StrokeCap.Round))
    }
}

@Composable
fun GoalRingLarge(progress: GoalProgress, color: Color, modifier: Modifier = Modifier) {
    Box(modifier.size(64.dp), contentAlignment = Alignment.Center) {
        GoalRing(progress.fraction, color, size = 64.dp, stroke = 5.dp)
        Text("${progress.done}/${progress.total}", style = LynxType.mono, color = lynx.fg)
    }
}

data class Chip(val icon: ImageVector?, val text: String, val alert: Boolean = false)

/** Trigger chips under the title, Geist Mono muted (overdue time in signal red). */
@Composable
fun TriggerChips(chips: List<Chip>, modifier: Modifier = Modifier) {
    if (chips.isEmpty()) return
    val c = lynx
    FlowRow(modifier, horizontalArrangement = Arrangement.spacedBy(Sp.s10), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        chips.forEach { ch ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                val col = if (ch.alert) c.signal else c.muted
                if (ch.icon != null) Icon(ch.icon, null, tint = col, modifier = Modifier.size(13.dp))
                Text(ch.text, style = LynxType.mono, color = col, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

object ChipIcons {
    val clock = Icons.Rounded.Schedule
    val repeat = Icons.Rounded.Repeat
    val location = Icons.Rounded.Place
    val bluetooth = Icons.Rounded.Headphones
    val app = Icons.Rounded.Apps
    val nag = Icons.Rounded.NotificationsActive
    val flag = Icons.Rounded.Flag
}

fun chipsFor(r: ReminderRow, due: java.time.Instant?, now: java.time.Instant, overdue: Boolean): List<Chip> = buildList {
    if (due != null) add(Chip(ChipIcons.clock, Fmt.dueLabel(r, due, now), alert = overdue))
    r.repeat?.let { add(Chip(ChipIcons.repeat, Fmt.repeatLabel(it))) }
    r.location?.let { add(Chip(ChipIcons.location, (if (it.on == "leave") "Leave " else "") + it.name)) }
    r.bluetooth?.let { add(Chip(ChipIcons.bluetooth, (if (it.on == "disconnect") "Off " else "") + it.name)) }
    r.appTrigger?.let { add(Chip(ChipIcons.app, it.name)) }
    r.nag?.let { add(Chip(ChipIcons.nag, Fmt.nagLabel(it))) }
}

/** Initials avatar on the sunk fill — no gradients. */
@Composable
fun Avatar(name: String?, modifier: Modifier = Modifier, size: Dp = 24.dp) {
    val c = lynx
    Box(modifier.size(size).clip(CircleShape).background(c.sunk).border(1.dp, c.line, CircleShape), contentAlignment = Alignment.Center) {
        Text(Fmt.initials(name), style = LynxType.monoSmall, color = c.fg)
    }
}

fun listIcon(key: String?): ImageVector = when (key) {
    "cart" -> Icons.Rounded.ShoppingCart
    "house" -> Icons.Rounded.Home
    "briefcase" -> Icons.Rounded.Work
    "book" -> Icons.AutoMirrored.Rounded.MenuBook
    "heart" -> Icons.Rounded.Favorite
    "star" -> Icons.Rounded.Star
    "flag" -> Icons.Rounded.Flag
    "gift" -> Icons.Rounded.CardGiftcard
    "plane" -> Icons.Rounded.Flight
    "leaf" -> Icons.Rounded.Eco
    "bolt" -> Icons.Rounded.Bolt
    else -> Icons.AutoMirrored.Rounded.List
}

/** List glyph: a small circle in the list color with the icon in white. */
@Composable
fun ListBadge(color: Color, icon: String?, modifier: Modifier = Modifier, size: Dp = 30.dp) {
    val c = lynx
    Box(modifier.size(size).clip(CircleShape).background(color), contentAlignment = Alignment.Center) {
        Icon(listIcon(icon), null, tint = if (c.dark && color == c.fg) Color(0xFF0E0E10) else Color.White, modifier = Modifier.size(size * 0.55f))
    }
}

@Composable
fun EmptyNote(text: String, modifier: Modifier = Modifier) {
    Text(text, style = LynxType.body, color = lynx.muted, modifier = modifier.padding(vertical = Sp.s18, horizontal = Sp.s4))
}

val ScreenPadding = PaddingValues(horizontal = Sp.s14)
