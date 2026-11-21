package com.mansfera.lynxreminders.ui

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.location.Address
import android.location.Geocoder
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.MyLocation
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import com.mansfera.lynxreminders.core.AppTrigger
import com.mansfera.lynxreminders.core.BluetoothTrigger
import com.mansfera.lynxreminders.core.LocalDb
import com.mansfera.lynxreminders.core.LocationTrigger
import com.mansfera.lynxreminders.core.PlatformIds
import com.mansfera.lynxreminders.core.Recurrence
import com.mansfera.lynxreminders.core.ReminderRow
import com.mansfera.lynxreminders.core.RepeatEnd
import com.mansfera.lynxreminders.core.RepeatRule
import com.mansfera.lynxreminders.core.Window
import com.mansfera.lynxreminders.triggers.BluetoothDevices
import com.mansfera.lynxreminders.triggers.LaunchableApps
import com.mansfera.lynxreminders.triggers.Perms
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import kotlin.coroutines.resume

@Composable
fun LynxSheet(onDismiss: () -> Unit, title: String, action: (@Composable () -> Unit)? = null, scroll: Boolean = true, content: @Composable ColumnScope.() -> Unit) {
    val c = lynx
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = c.bg,
        contentColor = c.fg,
        scrimColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.35f),
    ) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = Sp.s14).padding(bottom = Sp.s18)) {
            Row(Modifier.fillMaxWidth().padding(bottom = Sp.s10), verticalAlignment = Alignment.CenterVertically) {
                Text(title, style = LynxType.title, color = c.fg, modifier = Modifier.weight(1f).padding(start = Sp.s4))
                action?.invoke()
            }
            Column(
                (if (scroll) Modifier.verticalScroll(rememberScrollState()) else Modifier).fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(Sp.s10), content = content,
            )
        }
    }
}

@Composable
private fun Stepper(value: Int, range: IntRange, label: String, onChange: (Int) -> Unit) {
    val c = lynx
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Sp.s6)) {
        RoundIconButton(Icons.Rounded.Remove, "Fewer", filled = false, size = 32.dp) { onChange((value - 1).coerceIn(range)) }
        Text("$value", style = LynxType.stat, color = c.fg, modifier = Modifier.padding(horizontal = Sp.s6))
        RoundIconButton(Icons.Rounded.Add, "More", filled = false, size = 32.dp) { onChange((value + 1).coerceIn(range)) }
        Text(label, style = LynxType.row, color = c.muted)
    }
}

// ---------- repeat ----------

@Composable
fun RepeatSheet(r: ReminderRow, onDismiss: () -> Unit, onSave: (ReminderRow) -> Unit) {
    val c = lynx
    val due = r.dueLocal() ?: LocalDateTime.now()
    val anchor = Recurrence.formatLocal(due)
    var rule by remember { mutableStateOf(r.repeat) }
    val presets = listOf(
        "never" to "Never", "day" to "Daily", "weekdays" to "Weekdays", "week" to "Weekly", "month" to "Monthly", "year" to "Yearly", "custom" to "Custom",
    )
    fun presetOf(x: RepeatRule?): String = when {
        x == null -> "never"
        x.interval == 1 && x.window == null && x.end == null && x.from == null && x.advance == null && x.weekdays.isNullOrEmpty() && x.unit in setOf("day", "week", "month", "year") -> x.unit
        x.interval == 1 && x.unit == "week" && x.weekdays == listOf(1, 2, 3, 4, 5) && x.window == null && x.end == null -> "weekdays"
        else -> "custom"
    }
    var mode by remember { mutableStateOf(presetOf(r.repeat)) }
    fun base(unit: String) = RepeatRule(unit = unit, interval = 1, anchor = anchor, completedCount = r.repeat?.completedCount)

    LynxSheet(onDismiss, "Repeat", action = {
        InkPill("Set", Icons.Rounded.Check) { onSave(r.copy(repeat = rule?.copy(anchor = anchor))) }
    }) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            presets.forEach { (k, label) ->
                CapsuleTabs(listOf(k to label), mode, small = true) {
                    mode = it
                    rule = when (it) {
                        "never" -> null
                        "weekdays" -> base("week").copy(weekdays = listOf(1, 2, 3, 4, 5))
                        "custom" -> rule ?: base("day")
                        else -> base(it)
                    }
                }
            }
        }
        val cur = rule
        if (mode == "custom" && cur != null) {
            Panel {
                Text("Every", style = LynxType.caption, color = c.muted)
                Stepper(cur.interval, 1..999, "") { rule = cur.copy(interval = it) }
                Spacer(Modifier.height(Sp.s6))
                CapsuleTabs(listOf("minute" to "Min", "hour" to "Hour", "day" to "Day", "week" to "Week", "month" to "Month", "year" to "Year"), cur.unit, small = true) { u ->
                    rule = cur.copy(unit = u, window = if (u == "minute" || u == "hour") cur.window else null,
                        weekdays = if (u == "week" || ((u == "minute" || u == "hour") && cur.window != null)) cur.weekdays else null,
                        interval = if (u == "minute" && cur.interval < 5) 45 else cur.interval)
                }
            }
            val sub = cur.unit == "minute" || cur.unit == "hour"
            if (sub) {
                Panel(padding = 0.dp) {
                    SettingRow("Only between", cur.window?.let { "${it.start}–${it.end}, restarting each day" } ?: "Around the clock") {
                        LynxSwitch(cur.window != null, { on -> rule = cur.copy(window = if (on) Window("09:00", "18:00") else null, weekdays = if (on) cur.weekdays else null) })
                    }
                    cur.window?.let { w ->
                        Hairline()
                        Row(Modifier.padding(Sp.s14), horizontalArrangement = Arrangement.spacedBy(Sp.s10), verticalAlignment = Alignment.CenterVertically) {
                            Text("From", style = LynxType.caption, color = c.muted)
                            HourChips(w.start) { rule = cur.copy(window = w.copy(start = it)) }
                        }
                        Row(Modifier.padding(start = Sp.s14, end = Sp.s14, bottom = Sp.s14), horizontalArrangement = Arrangement.spacedBy(Sp.s10), verticalAlignment = Alignment.CenterVertically) {
                            Text("Until", style = LynxType.caption, color = c.muted)
                            HourChips(w.end) { rule = cur.copy(window = w.copy(end = it)) }
                        }
                    }
                }
            }
            if (cur.unit == "week" || (sub && cur.window != null)) {
                Panel {
                    Text(if (cur.unit == "week") "On" else "On these days", style = LynxType.caption, color = c.muted)
                    WeekdayPicker(cur.weekdays.orEmpty()) { rule = cur.copy(weekdays = it.ifEmpty { null }) }
                }
            }
            Panel {
                Text("Ends", style = LynxType.caption, color = c.muted)
                val end = cur.endOrNever
                CapsuleTabs(listOf("never" to "Never", "on" to "On a date", "after" to "After"), end.type, small = true) { t ->
                    rule = cur.copy(end = when (t) {
                        "on" -> RepeatEnd("on", date = due.toLocalDate().plusMonths(1).toString())
                        "after" -> RepeatEnd("after", count = 10)
                        else -> null
                    })
                }
                if (end.type == "after") Stepper(end.count ?: 10, 1..999, "times") { rule = cur.copy(end = end.copy(count = it)) }
                if (end.type == "on") {
                    val d = end.date?.let { runCatching { LocalDate.parse(it) }.getOrNull() } ?: due.toLocalDate()
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        RoundIconButton(Icons.Rounded.Remove, "Earlier", filled = false, size = 32.dp) { rule = cur.copy(end = end.copy(date = d.minusDays(1).toString())) }
                        Text(d.toString(), style = LynxType.mono, color = c.fg, modifier = Modifier.padding(horizontal = Sp.s10))
                        RoundIconButton(Icons.Rounded.Add, "Later", filled = false, size = 32.dp) { rule = cur.copy(end = end.copy(date = d.plusDays(1).toString())) }
                        TextAction("+1 month", color = c.muted) { rule = cur.copy(end = end.copy(date = d.plusMonths(1).toString())) }
                    }
                }
            }
            Panel {
                Text("Next one is counted from", style = LynxType.caption, color = c.muted)
                CapsuleTabs(listOf("due" to "Due date", "completion" to "Completion"), cur.from ?: "due", small = true) { rule = cur.copy(from = if (it == "due") null else it) }
                Spacer(Modifier.height(Sp.s6))
                Text("Moves on", style = LynxType.caption, color = c.muted)
                CapsuleTabs(listOf("complete" to "When completed", "auto" to "Automatically"), cur.advance ?: "complete", small = true) { rule = cur.copy(advance = if (it == "complete") null else it) }
                Text(
                    if (cur.autoAdvance) "Good for “drink water every 45 min”: a missed slot is skipped, nothing stays overdue." else "Stays overdue until you complete it.",
                    style = LynxType.caption, color = c.muted,
                )
            }
        }
        Text("Starts ${Fmt.dayWord(due.toLocalDate(), LocalDate.now())} at ${Fmt.time(due.toLocalTime())}, from the due date.", style = LynxType.caption, color = c.muted)
    }
}

@Composable
private fun HourChips(value: String, onPick: (String) -> Unit) {
    val c = lynx
    val t = runCatching { LocalTime.parse(value) }.getOrDefault(LocalTime.of(9, 0))
    Row(verticalAlignment = Alignment.CenterVertically) {
        RoundIconButton(Icons.Rounded.Remove, "Earlier", filled = false, size = 30.dp) { onPick(t.minusMinutes(30).toString()) }
        Text(t.toString(), style = LynxType.mono, color = c.fg, modifier = Modifier.padding(horizontal = Sp.s6))
        RoundIconButton(Icons.Rounded.Add, "Later", filled = false, size = 30.dp) { onPick(t.plusMinutes(30).toString()) }
    }
}

@Composable
fun WeekdayPicker(selected: List<Int>, onChange: (List<Int>) -> Unit) {
    val c = lynx
    val names = listOf("M", "T", "W", "T", "F", "S", "S")
    val full = listOf("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
    Row(horizontalArrangement = Arrangement.spacedBy(Sp.s4)) {
        (1..7).forEach { d ->
            val on = d in selected
            Box(
                Modifier.size(40.dp).clip(CircleShape).background(if (on) c.fg else c.sunk)
                    .clickable(role = Role.Checkbox) { onChange(if (on) selected - d else (selected + d).sorted()) }
                    .semantics { contentDescription = full[d - 1] + if (on) ", selected" else "" },
                contentAlignment = Alignment.Center,
            ) { Text(names[d - 1], style = LynxType.label, color = if (on) c.bg else c.fg) }
        }
    }
}

// ---------- location ----------

private suspend fun geocode(context: Context, q: String): List<Address> {
    if (!Geocoder.isPresent()) return emptyList()
    val g = Geocoder(context)
    return if (Build.VERSION.SDK_INT >= 33) suspendCancellableCoroutine { cont ->
        g.getFromLocationName(q, 6, object : Geocoder.GeocodeListener {
            override fun onGeocode(addresses: MutableList<Address>) = cont.resume(addresses)
            override fun onError(errorMessage: String?) = cont.resume(emptyList())
        })
    } else withContext(Dispatchers.IO) {
        @Suppress("DEPRECATION") runCatching { g.getFromLocationName(q, 6) }.getOrNull().orEmpty()
    }
}

private suspend fun reverse(context: Context, lat: Double, lon: Double): Address? {
    if (!Geocoder.isPresent()) return null
    val g = Geocoder(context)
    return if (Build.VERSION.SDK_INT >= 33) suspendCancellableCoroutine { cont ->
        g.getFromLocation(lat, lon, 1, object : Geocoder.GeocodeListener {
            override fun onGeocode(addresses: MutableList<Address>) = cont.resume(addresses.firstOrNull())
            override fun onError(errorMessage: String?) = cont.resume(null)
        })
    } else withContext(Dispatchers.IO) {
        @Suppress("DEPRECATION") runCatching { g.getFromLocation(lat, lon, 1) }.getOrNull()?.firstOrNull()
    }
}

@SuppressLint("MissingPermission")
private suspend fun currentLocation(context: Context): android.location.Location? = suspendCancellableCoroutine { cont ->
    val cts = CancellationTokenSource()
    LocationServices.getFusedLocationProviderClient(context)
        .getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, cts.token)
        .addOnSuccessListener { cont.resume(it) }
        .addOnFailureListener { cont.resume(null) }
    cont.invokeOnCancellation { cts.cancel() }
}

/** "Obchodná 2" rather than the bare house number Geocoder puts in featureName. */
private fun Address.placeName(fallback: String): String =
    thoroughfare?.let { t -> listOfNotNull(t, subThoroughfare).joinToString(" ") }
        ?: featureName?.takeIf { it.any(Char::isLetter) } ?: locality ?: fallback

private fun Address.line(): String = (0..maxAddressLineIndex).mapNotNull { getAddressLine(it) }.joinToString(", ").ifEmpty { listOfNotNull(featureName, locality).joinToString(", ") }

@Composable
fun LocationSheet(current: LocationTrigger?, onDismiss: () -> Unit, onSave: (LocationTrigger) -> Unit) {
    val c = lynx
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var loc by remember { mutableStateOf(current) }
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<Address>>(emptyList()) }
    var status by remember { mutableStateOf<String?>(null) }
    var fine by remember { mutableStateOf(Perms.fineLocation(ctx)) }
    var background by remember { mutableStateOf(Perms.backgroundLocation(ctx)) }

    fun useHere() = scope.launch {
        status = "Finding you…"
        val l = currentLocation(ctx)
        if (l == null) { status = "Location unavailable. Try searching instead."; return@launch }
        val a = reverse(ctx, l.latitude, l.longitude)
        loc = LocationTrigger(name = loc?.name?.takeIf { it.isNotBlank() } ?: (a?.placeName("Here") ?: "Here"), address = a?.line(), lat = l.latitude, lon = l.longitude, radius = loc?.radius ?: 150.0, on = loc?.on ?: "arrive")
        status = null
    }
    // Only "Current location" continues into a position fix after the permission prompt
    var wantHere by remember { mutableStateOf(false) }
    val fgLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { res ->
        fine = res[Manifest.permission.ACCESS_FINE_LOCATION] == true
        if (fine && wantHere) useHere()
        wantHere = false
    }
    val bgLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { background = it }

    LynxSheet(onDismiss, "Location", action = {
        InkPill("Set", Icons.Rounded.Check, enabled = loc != null) { loc?.let(onSave) }
    }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            LynxField(query, { query = it }, "Search an address or place", Modifier.weight(1f), imeAction = ImeAction.Search, onDone = {
                scope.launch { status = "Searching…"; results = geocode(ctx, query); status = if (results.isEmpty()) "No places found." else null }
            }, leading = { Icon(Icons.Rounded.Search, null, tint = c.muted, modifier = Modifier.size(20.dp)) })
        }
        Panel(padding = 0.dp) {
            SettingRow("Current location", "Use where you are now", onClick = {
                if (Perms.fineLocation(ctx)) useHere() else { wantHere = true; fgLauncher.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)) }
            }) { Icon(Icons.Rounded.MyLocation, null, tint = c.fg) }
            results.forEach { a ->
                Hairline()
                SettingRow(a.placeName(a.line()), a.line(), onClick = {
                    loc = LocationTrigger(name = loc?.name?.takeIf { it.isNotBlank() } ?: a.placeName(query), address = a.line(), lat = a.latitude, lon = a.longitude, radius = loc?.radius ?: 150.0, on = loc?.on ?: "arrive")
                    results = emptyList()
                })
            }
        }
        status?.let { Text(it, style = LynxType.caption, color = c.muted) }
        loc?.let { l ->
            Panel {
                LynxField(l.name, { loc = l.copy(name = it) }, "Name, e.g. Home")
                Spacer(Modifier.height(Sp.s6))
                Text(l.address ?: "%.5f, %.5f".format(l.lat, l.lon), style = LynxType.caption, color = c.muted)
                Text("%.5f, %.5f".format(l.lat, l.lon), style = LynxType.mono, color = c.muted)
                Spacer(Modifier.height(Sp.s10))
                CapsuleTabs(listOf("arrive" to "When I arrive", "leave" to "When I leave"), l.on, small = true) { loc = l.copy(on = it) }
                Spacer(Modifier.height(Sp.s10))
                Text("Radius ${l.radius.toInt()} m", style = LynxType.caption, color = c.muted)
                Slider(
                    value = l.radius.toFloat(), onValueChange = { loc = l.copy(radius = (it / 50).toInt() * 50.0) }, valueRange = 100f..2000f,
                    colors = SliderDefaults.colors(thumbColor = c.fg, activeTrackColor = c.fg, inactiveTrackColor = c.fg.copy(alpha = 0.14f), activeTickColor = c.bg, inactiveTickColor = c.fg),
                )
            }
        }
        // Background location is a separate, second step on Android 10+ ("Allow all the time").
        if (!fine || !background) {
            Panel {
                Text("Location reminders work in the background", style = LynxType.rowMedium, color = c.fg)
                Text(
                    "Android checks the place for Lynx even when the app is closed. That needs location set to “Allow all the time”. Lynx only registers the places you pick; it does not track where you go.",
                    style = LynxType.caption, color = c.muted,
                )
                Spacer(Modifier.height(Sp.s10))
                if (!fine) TextAction("Allow location") { fgLauncher.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)) }
                else TextAction("Allow all the time") { bgLauncher.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION) }
            }
        }
    }
}

// ---------- Bluetooth ----------

@Composable
fun BluetoothSheet(current: BluetoothTrigger?, onDismiss: () -> Unit, onSave: (BluetoothTrigger) -> Unit) {
    val c = lynx
    val ctx = LocalContext.current
    var granted by remember { mutableStateOf(Perms.bluetooth(ctx)) }
    var bt by remember { mutableStateOf(current ?: BluetoothTrigger(name = "", on = "connect")) }
    val devices = remember(granted) { BluetoothDevices.bonded(ctx) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }

    LynxSheet(onDismiss, "Bluetooth", action = {
        InkPill("Set", Icons.Rounded.Check, enabled = bt.name.isNotBlank()) { onSave(bt.copy(name = bt.name.trim())) }
    }) {
        CapsuleTabs(listOf("connect" to "Connects", "disconnect" to "Disconnects"), bt.on, small = true) { bt = bt.copy(on = it) }
        if (!granted && Build.VERSION.SDK_INT >= 31) {
            Panel {
                Text("See your paired devices", style = LynxType.rowMedium, color = c.fg)
                Text("Lynx needs the Nearby devices permission to list paired devices and notice when one connects.", style = LynxType.caption, color = c.muted)
                TextAction("Allow") { launcher.launch(Manifest.permission.BLUETOOTH_CONNECT) }
            }
        }
        if (devices.isNotEmpty()) {
            Panel(padding = 0.dp) {
                devices.forEachIndexed { i, d ->
                    if (i > 0) Hairline()
                    val on = bt.ids?.android == d.address
                    SettingRow(d.name, d.address, onClick = { bt = bt.copy(name = d.name, ids = PlatformIds(mac = bt.ids?.mac, android = d.address)) }) {
                        if (on) Icon(Icons.Rounded.Check, "Selected", tint = c.fg)
                    }
                }
            }
        } else if (granted) {
            Text("No paired devices. Pair one in Bluetooth settings, or type its name.", style = LynxType.caption, color = c.muted)
        }
        Text("Or by name (matches on any of your devices)", style = LynxType.caption, color = c.muted)
        LynxField(bt.name, { bt = bt.copy(name = it, ids = if (it == bt.name) bt.ids else bt.ids?.copy(android = null)) }, "Device name, e.g. AirPods Pro")
    }
}

// ---------- app opened ----------

@Composable
fun AppSheet(current: AppTrigger?, onDismiss: () -> Unit, onSave: (AppTrigger) -> Unit) {
    val c = lynx
    val ctx = LocalContext.current
    var usage by remember { mutableStateOf(Perms.usageAccess(ctx)) }
    var filter by remember { mutableStateOf("") }
    var apps by remember { mutableStateOf<List<LaunchableApps.App>>(emptyList()) }
    LaunchedEffect(Unit) { apps = withContext(Dispatchers.IO) { LaunchableApps.list(ctx) } }
    // Re-check after returning from the Usage access screen
    val settingsLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { usage = Perms.usageAccess(ctx) }

    LynxSheet(onDismiss, "App opened", scroll = false) {
        if (!usage) {
            Panel {
                Text("Allow Usage access", style = LynxType.rowMedium, color = c.fg)
                Text(
                    "To notice when you open an app, Lynx reads which app is in front every few seconds, only while you have app reminders. Android shows a small notification while this runs.",
                    style = LynxType.caption, color = c.muted,
                )
                TextAction("Open Usage access settings") {
                    val i = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).apply { data = Uri.parse("package:" + ctx.packageName) }
                    runCatching { settingsLauncher.launch(i) }.onFailure { settingsLauncher.launch(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)) }
                }
            }
        }
        LynxField(filter, { filter = it }, "Filter apps", leading = { Icon(Icons.Rounded.Search, null, tint = c.muted, modifier = Modifier.size(20.dp)) })
        val shown = apps.filter { filter.isBlank() || it.label.contains(filter, true) }
        LazyColumn(Modifier.fillMaxWidth().heightIn(max = 420.dp)) {
            items(shown, key = { it.packageName }) { a ->
                val on = current?.android == a.packageName
                Row(
                    Modifier.fillMaxWidth().clickable { onSave(AppTrigger(name = a.label, on = "open", apple = current?.apple, android = a.packageName)) }
                        .heightIn(min = 52.dp).padding(horizontal = Sp.s4),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(a.label, style = LynxType.row, color = c.fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(a.packageName, style = LynxType.mono, color = c.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    if (on) Icon(Icons.Rounded.Check, "Selected", tint = c.fg)
                }
                Hairline()
            }
        }
    }
}

// ---------- list / assignee ----------

@Composable
fun ListPickerSheet(db: LocalDb, selected: String, onDismiss: () -> Unit, onPick: (String) -> Unit) {
    val c = lynx
    LynxSheet(onDismiss, "List") {
        Panel(padding = 0.dp) {
            db.visibleLists().forEachIndexed { i, l ->
                if (i > 0) Hairline(Modifier.padding(start = 58.dp))
                Row(Modifier.fillMaxWidth().clickable { onPick(l.id) }.heightIn(min = 56.dp).padding(horizontal = Sp.s14), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Sp.s14)) {
                    ListBadge(c.listColor(l.color), l.icon)
                    Text(l.name, style = LynxType.row, color = c.fg, modifier = Modifier.weight(1f))
                    if (l.id == selected) Icon(Icons.Rounded.Check, "Selected", tint = c.fg)
                }
            }
        }
    }
}

@Composable
fun AssigneeSheet(people: List<Pair<String, String>>, selected: String?, onDismiss: () -> Unit, onPick: (String?) -> Unit) {
    val c = lynx
    LynxSheet(onDismiss, "Assignee") {
        Panel(padding = 0.dp) {
            SettingRow("Nobody", onClick = { onPick(null) }) { if (selected == null) Icon(Icons.Rounded.Check, "Selected", tint = c.fg) }
            people.forEach { (id, name) ->
                Hairline()
                Row(Modifier.fillMaxWidth().clickable { onPick(id) }.heightIn(min = 52.dp).padding(horizontal = Sp.s14), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Sp.s14)) {
                    Avatar(name, size = 28.dp)
                    Text(name, style = LynxType.row, color = c.fg, modifier = Modifier.weight(1f))
                    if (id == selected) Icon(Icons.Rounded.Check, "Selected", tint = c.fg)
                }
            }
        }
    }
}
