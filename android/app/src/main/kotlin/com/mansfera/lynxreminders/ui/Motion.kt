package com.mansfera.lynxreminders.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.animation.core.AnimationVector2D
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.VectorConverter
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.round
import androidx.compose.ui.window.DialogWindowProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

// Motion helpers on the tokens in [Motion] (Theme.kt).

// ---------- screens ----------

/** Push: in from the right (8 %) with a fade, the old screen drifts left (4 %) and fades. Pop mirrors it. Reset crossfades. */
fun screenTransition(nav: Nav): ContentTransform = when (nav) {
    Nav.Push -> (slideInHorizontally(Motion.enter()) { (it * 0.08f).roundToInt() } + fadeIn(Motion.enter()))
        .togetherWith(slideOutHorizontally(Motion.enter()) { -(it * 0.04f).roundToInt() } + fadeOut(Motion.exit()))
    Nav.Pop -> (slideInHorizontally(Motion.enter()) { -(it * 0.04f).roundToInt() } + fadeIn(Motion.enter()))
        .togetherWith(slideOutHorizontally(Motion.enter()) { (it * 0.08f).roundToInt() } + fadeOut(Motion.exit()))
        .apply { targetContentZIndex = -1f } // the leaving screen stays on top while it fades
    Nav.Reset -> (fadeIn(Motion.enter()) + scaleIn(Motion.enter(), initialScale = 0.98f)).togetherWith(fadeOut(Motion.exit()))
}

// ---------- expand / collapse ----------

fun expandIn(): EnterTransition = expandVertically(Motion.enter()) + fadeIn(Motion.enter())
fun collapseOut(): ExitTransition = shrinkVertically(Motion.exit(Motion.SCREEN)) + fadeOut(Motion.exit())

/** The last non-null [value], so content can stay on screen while it animates out. */
@Composable
fun <T : Any> lastNonNull(value: T?): T? {
    val last = remember { arrayOfNulls<Any>(1) }
    if (value != null) last[0] = value
    @Suppress("UNCHECKED_CAST")
    return last[0] as T?
}

// ---------- lists ----------

/**
 * Lazy item motion: fades in and out; with [glide] items also move to new places. Lists whose
 * panels resize as rows expand and collapse ([AnimatedRows]) pass false, so the items below follow
 * the panel edge exactly instead of chasing it.
 */
fun LazyItemScope.itemMotion(glide: Boolean = true): Modifier = Modifier.animateItem(
    fadeInSpec = Motion.enter(Motion.MICRO),
    placementSpec = if (glide) Motion.enter<IntOffset>() else null,
    fadeOutSpec = Motion.exit(),
)

/**
 * Rows inside one panel (a plain Column, out of reach of lazy item animation): a new row expands
 * and fades in, a removed one fades and collapses where it was.
 */
@Composable
fun <T> AnimatedRows(items: List<T>, key: (T) -> Any, row: @Composable (item: T, index: Int) -> Unit) {
    // Rows already there on first composition just appear.
    val states = remember { HashMap<Any, MutableTransitionState<Boolean>>().apply { items.forEach { put(key(it), MutableTransitionState(true)) } } }
    var onScreen by remember { mutableStateOf(items) }
    val keys = remember(items) { items.mapTo(HashSet(), key) }
    val rows = remember(items, onScreen) {
        items.toMutableList().apply {
            onScreen.forEachIndexed { i, old -> if (key(old) !in keys) add(i.coerceAtMost(size), old) }
        }
    }
    val gone = HashSet<Any>()
    rows.forEachIndexed { i, item ->
        val k = key(item)
        val state = states.getOrPut(k) { MutableTransitionState(false) }
        val visible = k in keys
        if (state.targetState != visible) state.targetState = visible
        if (!visible && state.isIdle && !state.currentState) gone += k
        key(k) {
            AnimatedVisibility(state, enter = expandIn(), exit = collapseOut()) { row(item, i) }
        }
    }
    SideEffect { onScreen = rows.filter { key(it) !in gone } }
}

/** Glides a child of a plain Column to its new place, e.g. when lists are reordered. */
fun Modifier.animatePlacement(): Modifier = composed {
    val scope = rememberCoroutineScope()
    var anim by remember { mutableStateOf<Animatable<IntOffset, AnimationVector2D>?>(null) }
    var target by remember { mutableStateOf(IntOffset.Zero) }
    onPlaced { coords ->
        val p = coords.positionInParent().round()
        if (anim == null) anim = Animatable(p, IntOffset.VectorConverter)
        target = p
    }.offset {
        val a = anim ?: return@offset IntOffset.Zero
        if (a.targetValue != target) scope.launch { a.animateTo(target, Motion.enter()) }
        a.value - target
    }
}

// ---------- entrances ----------

private val played = HashSet<String>()

/** True only the first time this is composed for [id] since the app started. */
@Composable
fun firstTimeSinceLaunch(id: String): Boolean = remember { played.add(id) }

/**
 * First appearance: each of [blocks] rises 12 dp and fades in, [Motion.STAGGER] ms after the one
 * before (apply with [rise]). With [play] false the blocks are simply there.
 */
@Composable
fun rememberEntrance(blocks: Int, play: Boolean): List<Animatable<Float, AnimationVector1D>> {
    val steps = remember { List(blocks) { Animatable(if (play) 0f else 1f) } }
    LaunchedEffect(steps) {
        steps.forEachIndexed { i, a -> launch { a.animateTo(1f, Motion.enter(delay = i * Motion.STAGGER)) } }
    }
    return steps
}

fun Modifier.rise(step: Animatable<Float, AnimationVector1D>): Modifier = graphicsLayer {
    val p = step.value
    alpha = p
    translationY = (1f - p) * 12.dp.toPx()
}

// ---------- numbers ----------

/**
 * A count that rolls when it changes (like iOS's numeric text transition): the new number slides
 * in from below when it goes up, from above when it goes down. Drawing only, so the layout and
 * the baseline stay put.
 */
@Composable
fun CountText(n: Int, style: TextStyle, color: Color, modifier: Modifier = Modifier) {
    var from by remember { mutableIntStateOf(n) }
    var to by remember { mutableIntStateOf(n) }
    val p = remember { Animatable(1f) }
    LaunchedEffect(n) {
        if (n == to) return@LaunchedEffect
        from = to; to = n
        p.snapTo(0f)
        p.animateTo(1f, Motion.enter())
        from = n
    }
    val dir = if (to > from) 1f else -1f
    Box(modifier) {
        if (from != to) Text("$from", style = style, color = color, modifier = Modifier.graphicsLayer {
            alpha = 1f - p.value
            translationY = -dir * p.value * size.height * 0.3f
        })
        Text("$to", style = style, color = color, modifier = Modifier.graphicsLayer {
            alpha = p.value
            translationY = dir * (1f - p.value) * size.height * 0.3f
        })
    }
}

// ---------- dialogs ----------

/**
 * Motion for a platform dialog window. The window's own animation is switched off (see
 * [DialogWindowMotion]); instead the dim fades and the card ([dialogCard]) scales 0.96 → 1 and
 * fades in. [close] plays that backwards, then runs the action that removes the dialog.
 */
@Stable
class DialogMotion internal constructor(private val scope: CoroutineScope) {
    internal val progress = Animatable(0f)
    private var closing = false

    fun close(then: () -> Unit) {
        if (closing) return
        closing = true
        scope.launch {
            progress.animateTo(0f, Motion.exit())
            then()
            // Still composed two frames later: the action kept the dialog (e.g. Save with an empty name).
            withFrameNanos {}; withFrameNanos {}
            closing = false
            progress.animateTo(1f, Motion.enter())
        }
    }
}

@Composable
fun rememberDialogMotion(): DialogMotion {
    val scope = rememberCoroutineScope()
    val m = remember { DialogMotion(scope) }
    LaunchedEffect(m) { m.progress.animateTo(1f, Motion.enter()) }
    return m
}

fun Modifier.dialogCard(m: DialogMotion): Modifier = graphicsLayer {
    val p = m.progress.value
    alpha = p
    scaleX = 0.96f + 0.04f * p
    scaleY = scaleX
}

/** Call inside the dialog's content: replaces the window's enter/exit animation and fades its dim with [m]. */
@Composable
fun DialogWindowMotion(m: DialogMotion) {
    val window = (LocalView.current.parent as? DialogWindowProvider)?.window ?: return
    val dim = remember(window) { window.attributes.dimAmount }
    DisposableEffect(window) {
        window.setWindowAnimations(0)
        window.setDimAmount(0f)
        onDispose {}
    }
    LaunchedEffect(window) {
        snapshotFlow { m.progress.value }.collect { window.setDimAmount(dim * it) }
    }
}
