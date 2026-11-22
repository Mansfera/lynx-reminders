package com.mansfera.lynxreminders.ui

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.Mail
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.mansfera.lynxreminders.R
import com.mansfera.lynxreminders.core.ListColors
import com.mansfera.lynxreminders.core.ListIcons
import com.mansfera.lynxreminders.core.LocalDb
import com.mansfera.lynxreminders.data.Settings as LynxSettings
import com.mansfera.lynxreminders.remote.PasskeyInfo
import com.mansfera.lynxreminders.sync.AccountState
import com.mansfera.lynxreminders.sync.SyncStatus
import com.mansfera.lynxreminders.triggers.Perms
import java.time.LocalTime
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

// ---------- welcome ----------

@Composable
fun WelcomeScreen(onSignIn: () -> Unit, onContinue: () -> Unit) {
    val c = lynx
    Column(
        Modifier.fillMaxSize().background(c.bg).statusBarsPadding().navigationBarsPadding().padding(Sp.s14),
        verticalArrangement = Arrangement.spacedBy(Sp.s14),
    ) {
        Stage(Modifier.weight(1f)) {
            Spacer(Modifier.weight(1f))
            Image(
                painterResource(R.drawable.etherlynx_mark), "Etherlynx mark",
                colorFilter = ColorFilter.tint(c.fg),
                modifier = Modifier.fillMaxWidth(0.62f).aspectRatio(1f).align(Alignment.CenterHorizontally),
            )
            Spacer(Modifier.weight(1f))
            Text("Lynx Reminders", style = LynxType.screenTitle, color = c.fg)
            Spacer(Modifier.height(Sp.s6))
            Text(
                "Reminders by time, place, Bluetooth device or app. Works on this phone without an account; sign in to sync and share.",
                style = LynxType.body, color = c.fg.copy(alpha = 0.75f),
            )
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            TextAction("Continue without account", color = c.ink2, onClick = onContinue)
            Spacer(Modifier.weight(1f))
            InkPill("Sign in", Icons.AutoMirrored.Rounded.ArrowForward, onClick = onSignIn)
        }
    }
}

// ---------- sign in / create account ----------

@Composable
fun AuthScreen(vm: AppVM, onBack: () -> Unit, onDone: () -> Unit) {
    val c = lynx
    var mode by remember { mutableStateOf("signin") } // signin | signup | code
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var codeSent by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var info by remember { mutableStateOf<String?>(null) }
    val ctx = LocalContext.current

    fun go(block: suspend () -> Unit, success: () -> Unit = onDone) {
        busy = true; error = null
        vm.run(onError = { error = it.ifEmpty { null }; busy = false }, onDone = { busy = false; success() }, block = block)
    }

    // With email confirmation on, sign-up emails a code: continue on the code step to finish.
    fun signUp() {
        var signedIn = false
        go({ signedIn = vm.g.sync.signUp(email, password) }) {
            if (signedIn) onDone() else {
                mode = "code"; codeSent = true; code = ""
                info = "We sent a 6-digit code to $email. Type it to finish creating your account."
            }
        }
    }

    Column(Modifier.fillMaxSize().background(c.bg).imePadding()) {
        ScreenHeader(if (mode == "signup") "Create account" else "Sign in", onBack = onBack)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Sp.s14), verticalArrangement = Arrangement.spacedBy(Sp.s10)) {
            CapsuleTabs(listOf("signin" to "Sign in", "signup" to "Create account", "code" to "Email code"), mode) { mode = it; error = null; info = null }
            Text(
                when (mode) {
                    "signup" -> "Your reminders on this phone move into the new account and start syncing."
                    "code" -> "No password: we email you a 6-digit code."
                    else -> "Sign in to sync your reminders and share lists."
                },
                style = LynxType.body, color = c.muted, modifier = Modifier.padding(horizontal = Sp.s4),
            )
            LynxField(email, { email = it.trim() }, "Email", keyboardType = KeyboardType.Email, imeAction = ImeAction.Next)
            when (mode) {
                "code" -> {
                    if (codeSent) LynxField(code, { code = it.filter(Char::isDigit).take(8) }, "6-digit code", keyboardType = KeyboardType.NumberPassword,
                        onDone = { go({ vm.g.sync.verifyCode(email, code) }) })
                }
                else -> LynxField(password, { password = it }, "Password", password = true, keyboardType = KeyboardType.Password, onDone = {
                    if (mode == "signup") signUp() else go({ vm.g.sync.signIn(email, password) })
                })
            }
            error?.let { Text(it, style = LynxType.caption, color = c.signal, modifier = Modifier.padding(horizontal = Sp.s4)) }
            info?.let { Text(it, style = LynxType.caption, color = c.muted, modifier = Modifier.padding(horizontal = Sp.s4)) }
            Row(Modifier.fillMaxWidth().padding(top = Sp.s6), verticalAlignment = Alignment.CenterVertically) {
                if (mode == "code" && codeSent) TextAction("Send again", color = c.muted) { go({ vm.g.sync.sendCode(email) }) { info = "Sent again." } }
                Spacer(Modifier.weight(1f))
                val valid = email.contains('@') && when (mode) { "code" -> !codeSent || code.length >= 6; else -> password.length >= 6 }
                InkPill(
                    when { busy -> "Working…"; mode == "signup" -> "Create account"; mode == "code" && !codeSent -> "Email me a code"; mode == "code" -> "Verify"; else -> "Sign in" },
                    if (mode == "code" && !codeSent) Icons.Rounded.Mail else Icons.AutoMirrored.Rounded.ArrowForward,
                    enabled = valid && !busy,
                ) {
                    when (mode) {
                        "signup" -> signUp()
                        "code" -> if (!codeSent) go({ vm.g.sync.sendCode(email) }) { codeSent = true; info = "Check $email for the code." } else go({ vm.g.sync.verifyCode(email, code) })
                        else -> go({ vm.g.sync.signIn(email, password) })
                    }
                }
            }
            if (mode == "signin") {
                // No email needed: the passkey says which account it is (SPEC §9).
                Hairline(Modifier.padding(vertical = Sp.s10))
                SettingRow("Use a passkey", "Face, fingerprint or screen lock instead of a password", onClick = {
                    if (!busy) go({ vm.g.sync.passkeys.signIn(AppVM.activityOf(ctx)) })
                }) {
                    Icon(Icons.Rounded.Key, contentDescription = null, tint = c.ink2)
                }
            }
        }
    }
}

// ---------- account & settings ----------

@Composable
fun AccountScreen(
    vm: AppVM, db: LocalDb, account: AccountState, sync: SyncStatus, settings: LynxSettings,
    onBack: () -> Unit, onSignIn: () -> Unit,
) {
    val c = lynx
    val ctx = LocalContext.current
    var signOutDialog by remember { mutableStateOf(false) }
    var deleteDialog by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var refresh by remember { mutableIntStateOf(0) }
    var passkeys by remember { mutableStateOf<List<PasskeyInfo>>(emptyList()) }
    var passkeyBusy by remember { mutableStateOf(false) }
    var removingPasskey by remember { mutableStateOf<PasskeyInfo?>(null) }
    var renamingPasskey by remember { mutableStateOf<PasskeyInfo?>(null) }
    fun loadPasskeys() = vm.run { passkeys = vm.g.sync.passkeys.list() }
    LaunchedEffect(account.userId, account.needsSignIn) { if (account.userId != null && !account.needsSignIn) loadPasskeys() }
    // Re-read permission state when coming back from system settings
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val obs = LifecycleEventObserver { _, e -> if (e == Lifecycle.Event.ON_RESUME) refresh++ }
        owner.lifecycle.addObserver(obs)
        onDispose { owner.lifecycle.removeObserver(obs) }
    }
    val notifLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { refresh++ }
    val btLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { refresh++ }
    val locLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { refresh++ }
    val bgLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { refresh++ }

    Column(Modifier.fillMaxSize().background(c.bg)) {
        ScreenHeader("Account", onBack = onBack)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Sp.s14).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(Sp.s10)) {
            if (account.userId != null) {
                val me = db.members.firstOrNull { it.userId == account.userId }?.profile
                Panel {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Sp.s14)) {
                        Avatar(me?.displayName ?: account.email, size = 44.dp)
                        Column(Modifier.weight(1f)) {
                            Text(me?.displayName?.ifBlank { null } ?: account.email?.substringBefore('@') ?: "You", style = LynxType.title, color = c.fg)
                            Text(account.email ?: "", style = LynxType.caption, color = c.muted)
                        }
                    }
                    Spacer(Modifier.height(Sp.s10))
                    Hairline()
                    Spacer(Modifier.height(Sp.s10))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            val status = when {
                                account.needsSignIn -> "Session expired · sign in again to sync"
                                sync.running -> "Syncing…"
                                sync.error != null -> sync.error
                                sync.lastSyncAt != null -> "Synced ${Fmt.dayWord(sync.lastSyncAt.atZone(Fmt.zone).toLocalDate(), java.time.LocalDate.now())} ${Fmt.time(sync.lastSyncAt)}"
                                else -> "Not synced yet"
                            }
                            Text(status, style = LynxType.mono, color = if (sync.error != null && !sync.running) c.ink2 else c.muted)
                            val pending = db.dirtyLists.size + db.dirtyReminders.size
                            if (pending > 0) Text("$pending change${if (pending == 1) "" else "s"} waiting to upload", style = LynxType.caption, color = c.muted)
                        }
                        if (account.needsSignIn) InkPill("Sign in", Icons.AutoMirrored.Rounded.ArrowForward, onClick = onSignIn)
                        else RoundIconButton(Icons.Rounded.Sync, "Sync now", filled = false) { vm.run { vm.g.sync.syncNow(forceManifest = true) } }
                    }
                }
            } else {
                Panel {
                    Text("Sync and share", style = LynxType.title, color = c.fg)
                    Text("Everything works on this phone. An account adds sync between devices and shared lists.", style = LynxType.body, color = c.muted)
                    Spacer(Modifier.height(Sp.s10))
                    InkPill("Sign in", Icons.AutoMirrored.Rounded.ArrowForward, onClick = onSignIn)
                }
            }

            SectionLabel("Alerts")
            Panel(padding = 0.dp) {
                val allDay = runCatching { LocalTime.parse(settings.allDayAlertTime) }.getOrDefault(LocalTime.of(9, 0))
                MenuRow("All-day alert time", Fmt.time(allDay), (6..12).map { h -> Fmt.time(LocalTime.of(h, 0)) to LocalTime.of(h, 0) }) { t ->
                    vm.repo.updateSettings { it.copy(allDayAlertTime = t.toString()) }
                }
                Hairline()
                MenuRow("Default early alert", Fmt.earlyLabel(settings.defaultEarlyAlert), listOf(null, 5, 15, 30, 60).map { Fmt.earlyLabel(it) to it }) { m ->
                    vm.repo.updateSettings { it.copy(defaultEarlyAlert = m) }
                }
                Hairline()
                Column(Modifier.padding(horizontal = Sp.s14, vertical = Sp.s10), verticalArrangement = Arrangement.spacedBy(Sp.s6)) {
                    Text("Default snooze", style = LynxType.rowMedium, color = c.fg)
                    Text("Notifications always offer 10 min and 1 h", style = LynxType.caption, color = c.muted)
                    CapsuleTabs(listOf(5, 10, 15, 30, 60).map { it to "$it min" }, settings.defaultSnooze, small = true) { m -> vm.repo.updateSettings { it.copy(defaultSnooze = m) } }
                }
                Hairline()
                SettingRow("Show completed in lists") { LynxSwitch(settings.showCompleted, { v -> vm.repo.updateSettings { it.copy(showCompleted = v) } }) }
                Hairline()
                val lists = db.visibleLists()
                MenuRow("Default list", lists.firstOrNull { it.id == settings.defaultListId }?.name ?: lists.firstOrNull()?.name ?: "Reminders", lists.map { it.name to it.id }) { id ->
                    vm.repo.updateSettings { it.copy(defaultListId = id) }
                }
            }

            SectionLabel("Permissions")
            androidx.compose.runtime.key(refresh) {
                Panel(padding = 0.dp) {
                    PermRow("Notifications", "Needed for every alert", Perms.notifications(ctx)) {
                        if (Build.VERSION.SDK_INT >= 33) notifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS) else openAppSettings(ctx)
                    }
                    Hairline()
                    val exact = vm.g.alarms.canExact()
                    PermRow("Alarms on time", if (exact) "Alerts fire at the exact minute" else "Without it Android may delay alerts by several minutes", exact) {
                        if (Build.VERSION.SDK_INT >= 31) ctx.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:" + ctx.packageName)))
                    }
                    Hairline()
                    val fine = Perms.fineLocation(ctx)
                    val bg = Perms.backgroundLocation(ctx)
                    PermRow("Location, all the time", "For arrive / leave reminders while the app is closed", fine && bg) {
                        if (!fine) locLauncher.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
                        else bgLauncher.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                    }
                    Hairline()
                    PermRow("Nearby devices", "For Bluetooth connect / disconnect reminders", Perms.bluetooth(ctx)) {
                        if (Build.VERSION.SDK_INT >= 31) btLauncher.launch(Manifest.permission.BLUETOOTH_CONNECT)
                    }
                    Hairline()
                    PermRow("Usage access", "For “when I open an app” reminders", Perms.usageAccess(ctx)) {
                        ctx.startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                    }
                }
            }

            if (account.userId != null && !account.needsSignIn) {
                SectionLabel("Passkeys")
                Panel(padding = 0.dp) {
                    for (p in passkeys) {
                        val added = "Added " + Fmt.dayWord(p.createdAt.atZone(Fmt.zone).toLocalDate(), java.time.LocalDate.now()).let { if (it == "Today" || it == "Yesterday") it.lowercase() else it }
                        SettingRow(p.name ?: "Passkey", added, onClick = { renamingPasskey = p }) {
                            TextAction("Rename") { renamingPasskey = p }
                            TextAction("Remove", color = c.signal) { removingPasskey = p }
                        }
                        Hairline()
                    }
                    SettingRow(
                        if (passkeyBusy) "Waiting for passkey…" else "Add a passkey",
                        if (passkeys.isEmpty()) "Sign in with your face, fingerprint or screen lock instead of a password" else null,
                        onClick = {
                            if (!passkeyBusy) {
                                passkeyBusy = true; error = null
                                vm.run(onError = { error = it.ifEmpty { null }; passkeyBusy = false }, onDone = { passkeyBusy = false; loadPasskeys() }) {
                                    vm.g.sync.passkeys.add(AppVM.activityOf(ctx))
                                }
                            }
                        },
                    ) {
                        Icon(Icons.Rounded.Add, contentDescription = null, tint = c.ink2)
                    }
                }
            }

            if (account.userId != null) {
                SectionLabel("Account")
                Panel(padding = 0.dp) {
                    SettingRow("Sign out", "Choose to keep a local copy or remove data", onClick = { signOutDialog = true })
                    Hairline()
                    SettingRow("Delete account", "Deletes the account and everything you own", onClick = { deleteDialog = true })
                }
            }
            error?.let { Text(it, style = LynxType.caption, color = c.signal) }
            Text("Lynx Reminders ${com.mansfera.lynxreminders.BuildConfig.VERSION_NAME}", style = LynxType.mono, color = c.muted, modifier = Modifier.padding(Sp.s4))
            Spacer(Modifier.height(Sp.s24))
        }
    }

    if (signOutDialog) {
        LynxDialog(
            title = "Sign out?",
            text = "Keep a local copy to go on using your reminders on this phone without syncing, or remove them from this device. Nothing is deleted from your account.",
            onDismiss = { signOutDialog = false },
            actions = listOf(
                "Cancel" to { signOutDialog = false },
                "Remove from this device" to { signOutDialog = false; vm.run(onError = { error = it }) { vm.g.sync.signOut(keepLocal = false) } },
                "Keep a local copy" to { signOutDialog = false; vm.run(onError = { error = it }) { vm.g.sync.signOut(keepLocal = true) } },
            ),
        )
    }
    removingPasskey?.let { p ->
        LynxDialog(
            title = "Remove passkey?",
            text = "You can't sign in with it any more. It stays in your password manager until you delete it there.",
            onDismiss = { removingPasskey = null },
            actions = listOf(
                "Cancel" to { removingPasskey = null },
                "Remove" to {
                    removingPasskey = null
                    vm.run(onError = { error = it }, onDone = { loadPasskeys() }) { vm.g.sync.passkeys.remove(p.id) }
                },
            ),
        )
    }
    renamingPasskey?.let { p ->
        var name by remember(p.id) { mutableStateOf(p.name.orEmpty()) }
        val save = {
            if (name.isNotBlank()) {
                renamingPasskey = null
                vm.run(onError = { error = it }, onDone = { loadPasskeys() }) { vm.g.sync.passkeys.rename(p.id, name) }
            }
        }
        LynxDialog(
            title = "Rename passkey",
            text = "A name that tells you where it's saved, like the phone or password manager.",
            onDismiss = { renamingPasskey = null },
            actions = listOf("Cancel" to { renamingPasskey = null }, "Save" to save),
        ) {
            LynxField(name, { name = it.take(60) }, "Passkey name", onDone = save)
        }
    }
    if (deleteDialog) {
        LynxDialog(
            title = "Delete account?",
            text = "This deletes your account, your lists and reminders on the server and on this phone. Lists other people own stay with them. This can't be undone.",
            onDismiss = { deleteDialog = false },
            actions = listOf(
                "Cancel" to { deleteDialog = false },
                "Delete account" to { deleteDialog = false; vm.run(onError = { error = it }) { vm.g.sync.deleteAccount() } },
            ),
        )
    }
}

@Composable
private fun PermRow(title: String, detail: String, granted: Boolean, onGrant: () -> Unit) {
    val c = lynx
    SettingRow(title, detail, onClick = if (granted) null else onGrant) {
        if (granted) Icon(Icons.Rounded.Check, "Granted", tint = c.fg) else Text("Allow", style = LynxType.label, color = c.fg)
    }
}

fun openAppSettings(ctx: android.content.Context) {
    ctx.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + ctx.packageName)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

/** Alert dialog on Lynx tokens: actions stacked right-aligned, the last one is the primary. */
@Composable
fun LynxDialog(
    title: String, text: String, onDismiss: () -> Unit, actions: List<Pair<String, () -> Unit>>,
    content: (@Composable () -> Unit)? = null,
) {
    val c = lynx
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = c.panel,
        title = { Text(title, style = LynxType.title, color = c.fg) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Sp.s10)) {
                Text(text, style = LynxType.body, color = c.ink2)
                content?.invoke()
            }
        },
        confirmButton = {
            Column(horizontalAlignment = Alignment.End) {
                actions.forEachIndexed { i, (label, f) ->
                    TextAction(label, color = if (i == actions.lastIndex) c.fg else c.muted, onClick = f)
                }
            }
        },
    )
}

// ---------- list editor ----------

@Composable
fun ListEditScreen(vm: AppVM, db: LocalDb, id: String?, signedIn: Boolean, onDone: (String?) -> Unit, onBack: () -> Unit) {
    val c = lynx
    val existing = id?.let { db.lists[it] }
    var name by remember { mutableStateOf(existing?.name ?: "") }
    var color by remember { mutableStateOf(existing?.color ?: "blue") }
    var icon by remember { mutableStateOf(existing?.icon ?: "list") }
    var confirm by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val isOwner = existing == null || existing.ownerId == db.me

    fun save() {
        if (name.isBlank()) return
        if (existing == null) onDone(vm.repo.createList(name, color, icon).id)
        else { vm.repo.updateList(existing.id) { it.copy(name = name.trim(), color = color, icon = icon) }; onDone(existing.id) }
    }

    Column(Modifier.fillMaxSize().background(c.bg).imePadding()) {
        ScreenHeader(if (existing == null) "New list" else "Edit list", onBack = onBack) {
            InkPill("Save", Icons.Rounded.Check, enabled = name.isNotBlank()) { save() }
        }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Sp.s14).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(Sp.s10)) {
            Panel {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Sp.s14)) {
                    ListBadge(c.listColor(color), icon, size = 44.dp)
                    LynxField(name, { name = it }, "List name", Modifier.weight(1f), style = LynxType.title, onDone = { save() })
                }
            }
            SectionLabel("Color")
            Panel {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(Sp.s10), verticalArrangement = Arrangement.spacedBy(Sp.s10)) {
                    ListColors.all.forEach { tok ->
                        val on = tok == color
                        Box(
                            Modifier.size(44.dp).clip(CircleShape)
                                .border(2.dp, if (on) c.fg else androidx.compose.ui.graphics.Color.Transparent, CircleShape)
                                .padding(5.dp).clip(CircleShape).background(c.listColor(tok))
                                .clickable(role = Role.RadioButton) { color = tok }
                                .semantics { contentDescription = tok + if (on) ", selected" else "" },
                        )
                    }
                }
            }
            SectionLabel("Icon")
            Panel {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(Sp.s10), verticalArrangement = Arrangement.spacedBy(Sp.s10)) {
                    ListIcons.all.forEach { k ->
                        val on = k == icon
                        Box(
                            Modifier.size(44.dp).clip(CircleShape).background(if (on) c.fg else c.sunk)
                                .clickable(role = Role.RadioButton) { icon = k }
                                .semantics { contentDescription = k + if (on) ", selected" else "" },
                            contentAlignment = Alignment.Center,
                        ) { Icon(listIcon(k), null, tint = if (on) c.bg else c.fg, modifier = Modifier.size(22.dp)) }
                    }
                }
            }
            if (existing != null) {
                if (isOwner) TextAction("Delete list", color = c.ink2) { confirm = true }
                else if (signedIn) TextAction("Leave list", color = c.ink2) {
                    vm.run(onError = { error = it }, onDone = { onDone(null) }) { vm.g.sync.remote.leaveList(existing.id); vm.g.sync.syncNow(forceManifest = true) }
                }
            }
            error?.let { Text(it, style = LynxType.caption, color = c.signal) }
            Spacer(Modifier.height(Sp.s24))
        }
    }
    if (confirm && existing != null) {
        LynxDialog(
            "Delete “${existing.name}”?",
            "The list and its reminders are removed" + (if (db.isShared(existing.id)) " for everyone it is shared with." else ".") + " Deleted items are kept on the server for 30 days.",
            onDismiss = { confirm = false },
            actions = listOf("Cancel" to { confirm = false }, "Delete list" to { confirm = false; vm.repo.deleteList(existing.id); onDone(null) }),
        )
    }
}

// ---------- sharing ----------

/** The same shape the server accepts, plus a dot in the domain. */
private val EMAIL = Regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$")

@Composable
fun ShareScreen(vm: AppVM, db: LocalDb, listId: String?, reminderId: String?, onBack: () -> Unit) {
    val c = lynx
    var email by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var msg by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val remote = vm.g.sync.remote
    val list = listId?.let { db.lists[it] }
    val reminder = reminderId?.let { db.reminders[it] }
    val isOwner = list?.ownerId == db.me

    // Two seconds after typing stops, ask the server what sharing would do (share_preview, SPEC §3).
    // Invite turns on once it answers "added" or "invited", or the check couldn't run (offline).
    var checked by remember { mutableStateOf<Pair<String, String>?>(null) }
    var checking by remember { mutableStateOf(false) }
    val looksLikeEmail = EMAIL.matches(email)
    val status = checked?.takeIf { it.first == email }?.second
    val canShare = !busy && looksLikeEmail && status in setOf("added", "invited", "unknown")
    LaunchedEffect(email) {
        checking = false
        if (email.isEmpty()) return@LaunchedEffect
        delay(2_000)  // a new keystroke restarts this effect, cancelling the wait
        if (!looksLikeEmail) { checked = email to "invalid"; return@LaunchedEffect }
        checking = true
        val answer = try {
            remote.sharePreview(email, listId = list?.id, reminderId = if (list == null) reminderId else null).status
        } catch (e: CancellationException) { throw e } catch (e: Exception) { "unknown" }
        checked = email to answer
        checking = false
    }

    fun invite() {
        if (!canShare) return
        val e = email
        busy = true; error = null; msg = null
        vm.run(onError = { error = it; busy = false }, onDone = { busy = false }) {
            val res = if (list != null) remote.shareList(list.id, e) else remote.shareReminder(reminderId!!, e)
            msg = when (res.status) {
                "added" -> "$e can see it now."
                "invited" -> "$e has no account yet. They get access when they sign up."
                else -> "$e already has access."
            }
            email = ""
            vm.g.sync.syncNow(forceManifest = true)
        }
    }

    fun act(block: suspend () -> Unit, after: String? = null) {
        busy = true; error = null; msg = null
        vm.run(onError = { error = it; busy = false }, onDone = { busy = false; msg = after }) { block(); vm.g.sync.syncNow(forceManifest = true) }
    }

    Column(Modifier.fillMaxSize().background(c.bg).imePadding()) {
        ScreenHeader(if (list != null) "Share “${list.name}”" else "Share reminder", subtitle = reminder?.title, onBack = onBack)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Sp.s14).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(Sp.s10)) {
            if (list != null && !isOwner) {
                Text("Only the owner can invite people to this list.", style = LynxType.body, color = c.muted)
            } else {
                Panel {
                    Text(if (list != null) "Everyone you add can see and edit every reminder in this list." else "They see this reminder and its subtasks in Shared with me. Your list stays private.", style = LynxType.body, color = c.muted)
                    Spacer(Modifier.height(Sp.s10))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        LynxField(email, { email = it.trim() }, "Email address", Modifier.weight(1f), keyboardType = KeyboardType.Email, onDone = ::invite)
                        Spacer(Modifier.size(Sp.s6))
                        InkPill("Invite", Icons.AutoMirrored.Rounded.ArrowForward, enabled = canShare, onClick = ::invite)
                    }
                    val hint = when {
                        checking -> "Checking…" to false
                        status == "added" -> "Has a Lynx account: they get access right away." to false
                        status == "invited" -> "No Lynx account yet: they get access when they sign up with this email." to false
                        status == "already" -> "Already has access." to true
                        status == "invalid" -> "Not an email address." to true
                        else -> null
                    }
                    hint?.let { (text, warn) ->
                        Spacer(Modifier.height(Sp.s6))
                        Text(text, style = LynxType.caption, color = if (warn) c.signal else c.muted)
                    }
                }
            }
            msg?.let { Text(it, style = LynxType.caption, color = c.muted, modifier = Modifier.padding(horizontal = Sp.s4)) }
            error?.let { Text(it, style = LynxType.caption, color = c.signal, modifier = Modifier.padding(horizontal = Sp.s4)) }

            SectionLabel("People")
            Panel(padding = 0.dp) {
                val people: List<Triple<String, String?, String>> = if (list != null) {
                    db.membersOf(list.id).sortedBy { if (it.role == "owner") 0 else 1 }.map { Triple(it.userId, it.profile?.displayName?.ifBlank { null } ?: it.profile?.email, if (it.role == "owner") "Owner" else "Can edit") }
                } else {
                    db.shares.filter { it.reminderId == reminderId }.map { Triple(it.userId, it.profile?.displayName?.ifBlank { null } ?: it.profile?.email, "Shared") }
                }
                if (people.isEmpty()) Text("Only you so far.", style = LynxType.body, color = c.muted, modifier = Modifier.padding(Sp.s14))
                people.forEachIndexed { i, (uid, name, role) ->
                    if (i > 0) Hairline(Modifier.padding(start = 56.dp))
                    Row(Modifier.fillMaxWidth().padding(horizontal = Sp.s14, vertical = Sp.s10), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Sp.s14)) {
                        Avatar(name, size = 30.dp)
                        Column(Modifier.weight(1f)) {
                            Text((name ?: "Someone") + if (uid == db.me) " (me)" else "", style = LynxType.row, color = c.fg)
                            Text(role, style = LynxType.caption, color = c.muted)
                        }
                        when {
                            list != null && uid == db.me && !isOwner -> TextAction("Leave", color = c.ink2) { act({ remote.leaveList(list.id) }); onBack() }
                            list != null && isOwner && uid != db.me -> TextAction("Remove", color = c.ink2) { act({ remote.unshareList(list.id, uid) }) }
                            list == null -> TextAction(if (uid == db.me) "Leave" else "Remove", color = c.ink2) { act({ remote.unshareReminder(reminderId!!, uid) }) }
                        }
                    }
                }
            }
            val invites = db.invites.filter { (list != null && it.listId == list.id) || (reminderId != null && it.reminderId == reminderId) }
            if (invites.isNotEmpty()) {
                SectionLabel("Invited")
                Panel(padding = 0.dp) {
                    invites.forEachIndexed { i, inv ->
                        if (i > 0) Hairline()
                        Row(Modifier.fillMaxWidth().padding(horizontal = Sp.s14, vertical = Sp.s10), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(inv.email, style = LynxType.row, color = c.fg)
                                Text("Invited · pending", style = LynxType.caption, color = c.muted)
                            }
                            TextAction("Cancel", color = c.ink2) { act({ remote.cancelInvite(inv.id) }) }
                        }
                    }
                }
            }
            Spacer(Modifier.height(Sp.s24))
        }
    }
}
