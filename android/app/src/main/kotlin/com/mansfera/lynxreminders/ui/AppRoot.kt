package com.mansfera.lynxreminders.ui

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsTopHeight
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.mansfera.lynxreminders.core.QuickAddParser
import com.mansfera.lynxreminders.core.ReminderRow
import com.mansfera.lynxreminders.core.SmartList
import com.mansfera.lynxreminders.triggers.Perms
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

@Composable
fun AppRoot(vm: AppVM) {
    val c = lynx
    val ctx = LocalContext.current
    val db by vm.db.collectAsStateWithLifecycle()
    val device by vm.device.collectAsStateWithLifecycle()
    val account by vm.account.collectAsStateWithLifecycle()
    val sync by vm.syncStatus.collectAsStateWithLifecycle()
    val now by vm.now.collectAsStateWithLifecycle()
    val settings = device.settings
    var goalPrompt by remember { mutableStateOf<ReminderRow?>(null) }
    var permTick by remember { mutableIntStateOf(0) }

    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lifecycle) { lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) { vm.tick(); permTick++ } }

    val notifLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { permTick++ }
    val top = vm.stack.lastOrNull() ?: Route.Home
    // Ask for notifications once the user is past the welcome screen
    LaunchedEffect(top is Route.Welcome) {
        if (top !is Route.Welcome && Build.VERSION.SDK_INT >= 33 && !Perms.notifications(ctx)) notifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    val handlers = RowHandlers(
        onToggle = { r ->
            val openSubs = db.subtasksOf(r.id).count { it.isOpen }
            if (r.isOpen && r.parentId == null && openSubs > 0) goalPrompt = r else vm.repo.toggle(r.id)
        },
        onOpen = { vm.push(Route.Editor(it.id)) },
    )

    fun quickAdd(text: String, route: Route?) {
        val listId = (route as? Route.ListR)?.id
        var q = QuickAddParser.parse(text, Instant.now(), ZoneId.systemDefault(), db.visibleLists())
        if (route == Route.Smart(SmartList.TODAY) && q.dueAt == null) {
            q = q.copy(dueAt = LocalDate.now().atStartOfDay(ZoneId.systemDefault()).toInstant(), allDay = true)
        }
        val r = vm.repo.addQuick(q, listId)
        if (route == Route.Smart(SmartList.FLAGGED)) vm.repo.setFlag(r.id, true)
    }

    val banner: (@Composable () -> Unit)? = remember(permTick, settings) {
        when {
            !Perms.notifications(ctx) -> ({
                Notice("Notifications are off. Reminders can't alert you.", "Turn on") {
                    if (Build.VERSION.SDK_INT >= 33) notifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS) else openAppSettings(ctx)
                }
            })
            !vm.g.alarms.canExact() -> ({
                Notice("Alerts may arrive a few minutes late without the alarms permission.", "Allow") {
                    if (Build.VERSION.SDK_INT >= 31) ctx.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:" + ctx.packageName)))
                }
            })
            else -> null
        }
    }

    BackHandler(enabled = vm.stack.size > 1) { vm.pop() }

    BoxWithConstraints(Modifier.fillMaxSize().background(c.bg)) {
        val wide = maxWidth >= 840.dp
        // Wide: home, lists and the editor share one list-detail screen, which animates inside itself.
        val isMain = { r: Route -> r == Route.Home || r is Route.Smart || r is Route.ListR || r is Route.Editor }
        AnimatedContent(
            targetState = top,
            contentKey = { r -> if (wide && isMain(r)) Route.Home else r },
            transitionSpec = { screenTransition(vm.lastNav) },
            label = "screen",
        ) { route ->
            when (route) {
                Route.Welcome -> WelcomeScreen(
                    onSignIn = { vm.push(Route.Auth) },
                    onContinue = { vm.repo.updateSettings { it.copy(welcomeDone = true) }; vm.reset(Route.Home) },
                )
                Route.Auth -> AuthScreen(vm, onBack = { vm.pop() }, onDone = {
                    vm.repo.updateSettings { it.copy(welcomeDone = true) }
                    if (vm.stack.any { it == Route.Welcome }) vm.reset(Route.Home) else vm.pop()
                })
                Route.Account -> AccountScreen(vm, db, account, sync, settings, onBack = { vm.pop() }, onSignIn = { vm.push(Route.Auth) })
                Route.Search -> SearchScreen(db, now, handlers, onBack = { vm.pop() })
                is Route.Share -> ShareScreen(vm, db, route.listId, route.reminderId, onBack = { vm.pop() })
                is Route.ListEdit -> ListEditScreen(vm, db, route.id, account.signedIn, onBack = { vm.pop() }, onDone = { id ->
                    vm.pop()
                    if (id == null) vm.reset(Route.Home)
                    else if (route.id == null) vm.push(Route.ListR(id))
                })
                else -> {
                    val listRoute = vm.stack.lastOrNull { it is Route.Smart || it is Route.ListR }
                    val editor = top as? Route.Editor
                    var pulling by remember { mutableStateOf(false) }
                    val pull = @Composable { content: @Composable () -> Unit ->
                        SyncPull(account.signedIn && !account.needsSignIn, pulling, onRefresh = {
                            pulling = true
                            vm.run(onError = { pulling = false }, onDone = { pulling = false }) { vm.g.sync.syncNow(forceManifest = true) }
                        }, content)
                    }
                    val home = @Composable { showQuickAdd: Boolean, selected: Route? -> pull {
                        HomeScreen(
                            db, now, account.signedIn, selected, banner,
                            onOpen = { r ->
                                if (wide && (r is Route.Smart || r is Route.ListR)) { vm.reset(Route.Home); vm.push(r) } else vm.push(r)
                            },
                            onQuickAdd = { quickAdd(it, null) },
                            onNewReminder = { vm.push(Route.Editor(null)) },
                            onMoveList = { id, up ->
                                val idx = db.visibleLists().indexOfFirst { it.id == id }
                                vm.repo.moveList(id, if (up) idx - 1 else idx + 1)
                            },
                            showQuickAdd = showQuickAdd,
                        )
                    } }
                    val list = @Composable { r: Route, back: (() -> Unit)? -> pull {
                        ListScreen(
                            r, db, now, settings.showCompleted, account.signedIn, handlers, onBack = back,
                            onEditList = { vm.push(Route.ListEdit(it)) },
                            onShareList = { vm.push(Route.Share(listId = it)) },
                            onQuickAdd = { quickAdd(it, r) },
                            onNewReminder = { vm.push(Route.Editor(null, listId = (r as? Route.ListR)?.id)) },
                        )
                    } }
                    val editorView = @Composable { e: Route.Editor, inPane: Boolean ->
                        EditorScreen(e, db, now, vm.repo, account.signedIn, handlers, onClose = { vm.pop() }, onShare = { vm.push(Route.Share(reminderId = it)) }, inPane = inPane)
                    }
                    if (!wide) {
                        when (route) {
                            is Route.Smart, is Route.ListR -> list(route) { vm.pop() }
                            is Route.Editor -> editorView(route, false)
                            else -> home(true, null)
                        }
                    } else {
                        // List-detail: sidebar (home) · list · reminder editor. The sidebar stays still.
                        val shown = listRoute ?: Route.Smart(SmartList.TODAY)
                        val paneEditor = lastNonNull(editor)
                        Row(Modifier.fillMaxSize()) {
                            Box(Modifier.width(380.dp).fillMaxHeight()) { home(false, shown) }
                            VHairline()
                            Crossfade(shown, Modifier.weight(1f).fillMaxHeight(), animationSpec = Motion.enter(), label = "list") { r -> list(r, null) }
                            // The pane slides in from the right edge, pushing the list narrower, and back out.
                            AnimatedVisibility(
                                visible = editor != null,
                                enter = expandHorizontally(Motion.enter(), expandFrom = Alignment.Start) + fadeIn(Motion.enter()),
                                exit = shrinkHorizontally(Motion.exit(Motion.SCREEN), shrinkTowards = Alignment.Start) + fadeOut(Motion.exit()),
                            ) {
                                Row(Modifier.fillMaxHeight()) {
                                    VHairline()
                                    Crossfade(paneEditor, Modifier.width(440.dp).fillMaxHeight(), animationSpec = Motion.enter(Motion.MICRO), label = "editor") { e ->
                                        if (e != null) editorView(e, true)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Edge-to-edge: scrolled content passes under a bg-colored status bar strip instead of colliding with the icons
    Box(Modifier.fillMaxWidth().windowInsetsTopHeight(WindowInsets.statusBars).background(c.bg.copy(alpha = 0.96f)))

    goalPrompt?.let { g ->
        val n = db.subtasksOf(g.id).count { it.isOpen }
        LynxDialog(
            title = "Complete all $n open subtasks too?",
            text = "“${g.title}” is a goal. You can complete just the goal and keep the open subtasks.",
            onDismiss = { goalPrompt = null },
            actions = listOf(
                "Cancel" to { goalPrompt = null },
                "Only the goal" to { vm.repo.complete(g.id, withSubtasks = false); goalPrompt = null },
                "Complete all" to { vm.repo.complete(g.id, withSubtasks = true); goalPrompt = null },
            ),
        )
    }
}

/** Sunk row (r 16) like Lynx Battery's Low Power row: a sentence and one action. */
@Composable
fun Notice(text: String, action: String, onAction: () -> Unit) {
    val c = lynx
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(c.sunk).clickable(onClick = onAction)
            .heightIn(min = 52.dp).padding(horizontal = Sp.s14, vertical = Sp.s10),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, style = LynxType.body, color = c.fg, modifier = Modifier.weight(1f).padding(end = Sp.s10))
        Text(action, style = LynxType.label, color = c.fg)
    }
}
