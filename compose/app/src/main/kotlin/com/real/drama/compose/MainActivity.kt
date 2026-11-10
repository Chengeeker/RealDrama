package com.real.drama.compose

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.SystemBarStyle
import androidx.compose.animation.*
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.animateIntAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.updateTransition
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.layout.layout
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.hideFromAccessibility
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt

private val flutterEaseOutCubic = CubicBezierEasing(.215f, .61f, .355f, 1f)
private val flutterEaseInCubic = CubicBezierEasing(.55f, .055f, .675f, .19f)
private val flutterTabExit = Easing { 1f - flutterEaseInCubic.transform(1f - it) }

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val startupBars = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
        enableEdgeToEdge(startupBars, startupBars)
        val repo = (application as DramaApplication).repository
        lifecycleScope.launch { repo.open() }
        setContent {
            CompositionLocalProvider(LocalRepository provides repo) {
                DramaTheme(repo.store) {
                    val light = MaterialTheme.colorScheme.surface.luminance() > .5f
                    SideEffect {
                        val bars = androidx.core.view.WindowCompat.getInsetsController(window, window.decorView)
                        bars.isAppearanceLightStatusBars = light
                        bars.isAppearanceLightNavigationBars = light
                    }
                    App(repo)
                }
            }
        }
    }
}
@Composable
fun App(repo: Repository) {
    val ready by repo.ready.collectAsState()
    val error by repo.startupError.collectAsState()
    val locked by repo.store.locked.collectAsState()
    val values = repo.store.values
    val stack = remember { mutableStateListOf<Route>() }
    var entering by remember { mutableStateOf<Route?>(null) }
    var closing by remember { mutableStateOf<Route?>(null) }
    val snackbar = remember { SnackbarHostState() }; val scope = rememberCoroutineScope()
    fun back() { if (closing == null) closing = stack.lastOrNull() }
    val navigate: (Route) -> Unit = { route ->
        if (closing != null && stack.lastOrNull() === closing) stack.removeAt(stack.lastIndex)
        closing = null
        stack.add(route)
        entering = route
    }
    val owner = LocalLifecycleOwner.current
    DisposableEffect(repo.lan) {
        repo.lan.receivePlayback = { incoming -> navigate(Route("playback", incoming.detail!!.drama, payload = obj("handoff" to incoming.id))) }
        val observer = LifecycleEventObserver { _, _ -> scope.launch { if (repo.ready.value) repo.lan.reconcile(owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) } }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer); repo.lan.receivePlayback = null; repo.lan.scope.launch { repo.lan.reconcile(false) } }
    }
    LaunchedEffect(ready, locked, repo.store.epoch, values.text(repo.store.key("lanSettings"))) { if (ready) repo.lan.reconcile(owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) }
    LaunchedEffect(locked, repo.store.active, ready) { entering = null; closing = null; stack.clear(); repo.recommendations.reset(); if (ready && !locked) repo.recommendations.recent.addAll(repo.store.exposureHistory()) }
    LaunchedEffect(repo.store.epoch) { repo.maintenance.cancelAll(); repo.runtime.cancel(); repo.mediaLibrary.pause(); if (stack.any { it.drama?.let { drama -> !repo.store.allowed(drama.source) } == true }) { entering = null; closing = null; stack.clear() } }
    BackHandler(stack.isNotEmpty(), onBack = ::back)
    CompositionLocalProvider(LocalNavigate provides navigate, LocalMessage provides { message -> scope.launch { snackbar.showSnackbar(message) } }) {
        Surface(Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize()) {
                when {
                    error != null && repo.store.readError != null -> RecoveryScreen()
                    error != null -> StatusPanel("启动失败", error!!, onRetry = { scope.launch { repo.open() } })
                    !ready -> Loading()
                    locked -> LoginScreen()
                    else -> {
                        val activeIndex = stack.lastIndex - if (closing != null) 1 else 0
                        key(repo.store.active) { RootTabs(active = activeIndex < 0) }
                        stack.forEachIndexed { index, route ->
                            key(route) {
                                val exiting = closing === route
                                val progress = remember { Animatable(0f) }
                                val direction = if (LocalLayoutDirection.current == LayoutDirection.Ltr) 1f else -1f
                                LaunchedEffect(exiting) {
                                    val target = if (exiting) 0f else 1f
                                    val duration = (300 * abs(target - progress.value)).roundToInt()
                                    progress.animateTo(target, tween(duration, easing = LinearEasing))
                                    if (exiting) {
                                        if (stack.lastOrNull() === route && closing === route) {
                                            stack.removeAt(stack.lastIndex)
                                            closing = null
                                            if (entering === route) entering = null
                                        }
                                    } else {
                                        if (entering === route) entering = null
                                    }
                                }
                                val visible = index == stack.lastIndex || index == stack.lastIndex - 1 && (entering != null || closing != null)
                                CompositionLocalProvider(LocalScreenActive provides (index == activeIndex)) {
                                    Surface(
                                        Modifier.fillMaxSize().retainedVisible(visible)
                                            .graphicsLayer { translationX = size.width * (1f - flutterEaseOutCubic.transform(progress.value)) * direction },
                                    ) { Destination(route) { if (stack.lastOrNull() === route) back() } }
                                }
                            }
                        }
                    }
                }
                SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).navigationBarsPadding())
            }
        }
    }
}
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun RootTabs(active: Boolean) {
    val repo = LocalRepository.current
    var tab by rememberSaveable { mutableIntStateOf(listOf("home", "discover", "following", "settings").indexOf(repo.store.text("startupDestination", "discover", true)).coerceAtLeast(0)) }
    var feedMounted by rememberSaveable { mutableStateOf(tab == 0) }
    var discoverMounted by rememberSaveable { mutableStateOf(tab == 1) }
    var previousTab by remember { mutableIntStateOf(tab) }
    var clean by remember { mutableStateOf(false) }
    fun selectTab(next: Int) {
        if (next == tab) return
        previousTab = tab
        tab = next
        clean = false
        if (next == 0) feedMounted = true
        if (next == 1) discoverMounted = true
    }
    val navigate = LocalNavigate.current
    var full by remember { mutableStateOf(false) }
    var boost by remember { mutableStateOf(false) }
    var selecting by remember { mutableStateOf(false) }
    val television = televisionMode()
    val labels = listOf("首页", "发现", "收藏", "设置")
    val tabTransition = updateTransition(tab, label = "main destination")
    val layoutSign = if (LocalLayoutDirection.current == LayoutDirection.Ltr) 1f else -1f
    var commentDrama by remember { mutableStateOf<Drama?>(null) }
    var commentsOpen by remember { mutableStateOf(false) }
    val commentProgress = remember { mutableFloatStateOf(0f) }
    val commentScope = rememberCoroutineScope()
    var commentAnimation by remember { mutableStateOf<Job?>(null) }
    val commentsVisible = commentDrama != null && active && tab == 0
    fun animateComments(expanded: Boolean) {
        commentAnimation?.cancel()
        commentsOpen = expanded
        commentAnimation = commentScope.launch {
            animate(commentProgress.floatValue, if (expanded) 1f else 0f,
                animationSpec = tween(if (expanded) 300 else 260, easing = flutterEaseOutCubic),
            ) { value, _ -> commentProgress.floatValue = value }
            if (!expanded) commentDrama = null
        }
    }
    LaunchedEffect(active, tab) {
        if (!active || tab != 0) {
            commentAnimation?.cancel()
            commentsOpen = false
            commentProgress.floatValue = 0f
            commentDrama = null
        }
    }
    val closeComments = { if (commentsOpen) animateComments(false) }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val compact = !television && maxWidth < 840.dp
        val rail = !full && (television || maxWidth >= 840.dp)
        val sheetHeight = maxHeight * if (maxHeight < 480.dp) .62f else .65f
        val statusTop = if (full) 0.dp else WindowInsets.statusBarsIgnoringVisibility.asPaddingValues().calculateTopPadding()
        val commentsVideoHeight = (maxHeight - sheetHeight - statusTop).coerceAtLeast(1.dp)
        val showTab: @Composable (Int, Modifier, Boolean) -> Unit = { page, bodySlide, headerVisible ->
            CompositionLocalProvider(LocalScreenActive provides (active && page == tab)) {
                when (page) {
                    1 -> DiscoverScreen(compact, onSelectionChanged = { selecting = it }, bodyModifier = bodySlide, headerVisible = headerVisible)
                    2 -> Scaffold(containerColor = Color.Transparent, topBar = {
                        if (headerVisible) TopAppBar(title = { Text("我的收藏 · ${repo.store.favorites().size + repo.store.list("followedCreators").length()}") },
                            expandedHeight = 56.dp, actions = { IconAction("sync_rounded", "收藏与观看进度同步") { navigate(Route("lan")) } })
                        else Spacer(Modifier.height(56.dp))
                    }) { insets ->
                        Surface(Modifier.fillMaxSize().padding(insets).then(bodySlide)) { LibraryScreen(false) }
                    }
                    3 -> Surface(Modifier.fillMaxSize().then(bodySlide)) { SettingsScreen() }
                    else -> Unit
                }
            }
        }
        Row(Modifier.fillMaxSize().then(if (commentsVisible) Modifier.semantics { hideFromAccessibility() } else Modifier)) {
            if (rail && television) {
                Column(Modifier.width(164.dp).fillMaxHeight().padding(start = 8.dp, top = 24.dp, end = 8.dp, bottom = 12.dp)) {
                    labels.forEachIndexed { i, name -> TelevisionNavigationButton(name, listOf("play_arrow_rounded", "explore_rounded", "bookmark_rounded", "settings_rounded")[i], tab == i, i == 0) { selectTab(i) } }
                }
                VerticalDivider()
            } else if (rail) NavigationRail {
                Spacer(Modifier.height(24.dp))
                labels.forEachIndexed { i, name -> NavigationRailItem(selected = tab == i, onClick = hapticClick { selectTab(i) }, icon = { Glyph(if (tab == i) listOf("play_arrow_rounded", "explore", "bookmark_rounded", "settings_rounded")[i] else listOf("play_arrow_rounded", "explore_outlined", "bookmark_border_rounded", "settings_outlined")[i], name) }, label = { Text(name) }) }
            }
            Column(Modifier.weight(1f).fillMaxHeight()) {
                Box(Modifier.weight(1f).fillMaxWidth().clipToBounds().then(when {
                    full -> Modifier
                    tab == 0 -> Modifier.windowInsetsPadding(WindowInsets.statusBarsIgnoringVisibility)
                    else -> Modifier.statusBarsPadding()
                })) {
                    val feedOffset = tabTransition.animateFloat(transitionSpec = {
                        if (!compact) snap() else tween(260, easing = flutterEaseOutCubic)
                    }, label = "feed slide") { if (it == 0) 0f else 1f }
                    val feedSliding by remember(feedOffset) { derivedStateOf { feedOffset.value < 1f } }
                    val feedVisible = tab == 0 || compact && feedSliding
                    val feedSlide = if (compact) Modifier.graphicsLayer { translationX = -layoutSign * size.width * feedOffset.value } else Modifier
                    if (feedMounted) Box(Modifier.fillMaxSize().zIndex(if (tab == 0) 1f else 0f)
                        .retainedVisible(feedVisible).then(feedSlide)) {
                        FeedScreen(active && tab == 0, full, clean, onClean = { clean = it }, onBoost = { boost = it },
                            commentsProgress = commentProgress.takeIf { commentsVisible }, commentsVideoHeight = commentsVideoHeight,
                            onComments = { drama ->
                                if (commentDrama == null) {
                                    commentDrama = drama
                                    animateComments(true)
                                }
                            },
                        ) { full = it }
                    }
                    if (discoverMounted) {
                        val discoverOffset = tabTransition.animateFloat(transitionSpec = {
                            if (!compact) snap() else tween(260, easing = flutterEaseOutCubic)
                        }, label = "discover slide") { if (it == 1) 0f else if (it > 1) -layoutSign else layoutSign }
                        val discoverVisible = tab == 1 || compact && tabTransition.currentState == 1 && kotlin.math.abs(discoverOffset.value) < 1f
                        Box(Modifier.fillMaxSize().zIndex(if (tab == 1) 1f else 0f).retainedVisible(discoverVisible)) {
                            showTab(1, Modifier.graphicsLayer { translationX = size.width * discoverOffset.value }, tab == 1)
                        }
                    }
                    if (compact) tabTransition.AnimatedContent(Modifier.fillMaxSize(), transitionSpec = {
                        EnterTransition.None togetherWith ExitTransition.None
                    }) { page ->
                        if (page == 0 || page == 1) Spacer(Modifier.fillMaxSize())
                        else {
                            val offset = transition.animateFloat(transitionSpec = {
                                tween(260, easing = if (targetState == EnterExitState.Visible) flutterEaseOutCubic else flutterTabExit)
                            }, label = "tab body slide") { phase ->
                                when (phase) {
                                    EnterExitState.PreEnter -> if (page > previousTab) layoutSign else -layoutSign
                                    EnterExitState.Visible -> 0f
                                    EnterExitState.PostExit -> if (page > tab) layoutSign else -layoutSign
                                }
                            }
                            showTab(page, Modifier.graphicsLayer { translationX = size.width * offset.value }, page == tab)
                        }
                    }
                    else if (tab > 1) showTab(tab, Modifier, true)
                }
                if (!full && !rail && !(tab == 1 && selecting)) {
                    val colors = MaterialTheme.colorScheme
                    val hidden = tab == 0 && (clean || boost || commentsVisible)
                    val insets = if (tab == 0) WindowInsets.navigationBarsIgnoringVisibility else WindowInsets.navigationBars
                    val indicator = animateFloatAsState(tab.toFloat(), tween(240, easing = flutterEaseOutCubic), label = "tab selection")
                    Row(Modifier.fillMaxWidth().background(if (hidden) Color.Black else colors.surfaceContainerLow)
                        .windowInsetsPadding(insets.union(WindowInsets(bottom = 4.dp))).height(48.dp)
                        .drawBehind {
                            if (!hidden) {
                                val cellWidth = size.width / labels.size
                                val inset = 4.dp.toPx()
                                val slot = if (layoutSign > 0) indicator.value else labels.lastIndex - indicator.value
                                if (cellWidth > 2 * inset && size.height > 2 * inset) drawRoundRect(
                                    colors.secondaryContainer, Offset(cellWidth * slot + inset, inset),
                                    Size(cellWidth - 2 * inset, size.height - 2 * inset), CornerRadius(18.dp.toPx()),
                                )
                            }
                        }) {
                        if (!hidden) labels.forEachIndexed { i, name ->
                            val selectedTab = tab == i
                            Box(Modifier.weight(1f).fillMaxHeight().padding(4.dp).clip(RoundedCornerShape(18.dp))
                                .semantics { selected = selectedTab }
                                .hapticClickable(role = Role.Tab) { selectTab(i) }, contentAlignment = Alignment.Center) {
                                BottomTabLabel(name, selectedTab)
                            }
                        }
                    }
                }
            }
        }
        BackHandler(enabled = commentsVisible, onBack = closeComments)
        if (commentsVisible) {
            Box(Modifier.matchParentSize().pointerInput(Unit) { detectTapGestures { closeComments() } })
            val density = LocalDensity.current
            val sheetHeightPx = with(density) { sheetHeight.toPx().coerceAtLeast(1f) }
            val dismissVelocity = with(density) { 700.dp.toPx() }
            FeedCommentsPanel(requireNotNull(commentDrama), modifier = Modifier.align(Alignment.BottomCenter)
                .widthIn(max = 640.dp).fillMaxWidth().height(sheetHeight).graphicsLayer {
                    translationY = size.height * (1f - commentProgress.floatValue)
                },
                headerModifier = Modifier.draggable(
                    state = rememberDraggableState { delta ->
                        commentProgress.floatValue = (commentProgress.floatValue - delta / sheetHeightPx).coerceIn(0f, 1f)
                    },
                    orientation = Orientation.Vertical, enabled = commentsOpen,
                    onDragStarted = { if (commentsOpen) commentAnimation?.cancel() },
                    onDragStopped = { velocity ->
                        if (commentsOpen) animateComments(commentProgress.floatValue >= .80f && velocity <= dismissVelocity)
                    },
                ),
                back = closeComments,
            )
        }
    }
}

@Composable
private fun BottomTabLabel(name: String, selected: Boolean) {
    val colors = MaterialTheme.colorScheme
    val color by animateColorAsState(if (selected) colors.onSecondaryContainer else colors.onSurfaceVariant, tween(150), label = "tab label color")
    val weight by animateIntAsState(appTextWeight(if (selected) FontWeight.Bold else FontWeight.Medium).weight, tween(150), label = "tab label weight")
    Text(name, fontSize = 14.sp, fontWeight = FontWeight(weight), color = color)
}
@Composable
fun Destination(route: Route, back: () -> Unit) {
    when (route.page) {
        "detail" -> if (requireNotNull(route.drama).source in setOf("douyin", "douyin-live")) CreatorScreen(route.drama, back) else DetailScreen(route.drama, back, route.payload.optBoolean("download"))
        "playback" -> if (LocalRepository.current.source(requireNotNull(route.drama).source)?.kind == "live") LiveScreen(route.drama, back) else PlayerScreen(route.drama, back, route.payload)
        "downloadPicker" -> DownloadPickerScreen(requireNotNull(route.drama), back)
        "creator" -> CreatorScreen(requireNotNull(route.drama), back)
        "comments" -> CommentsScreen(requireNotNull(route.drama), back)
        "history" -> LibraryScreen(true, back = back)
        "rankings" -> RankingsScreen(back, route.source)
        "subscriptions" -> SubscriptionsScreen(back)
        "sources" -> SourcesScreen(back)
        "sourceSettings" -> AccountSettings(route.source, back)
        "profiles" -> ProfilesScreen(back)
        "licenses" -> LicenseScreen(back)
        "networkDiagnostics" -> NetworkDiagnosticsScreen(back)
        "downloads" -> DownloadsScreen(back)
        "downloadPlayback" -> DownloadPlaybackScreen(requireNotNull(route.drama), route.payload, back)
        "batchDownloads" -> BatchDownloadScreen(route.payload.array("dramas").objects().map(::Drama), back)
        "localMedia" -> LocalMediaScreen(back)
        "mergeQueue" -> MergeQueueScreen(back, route.payload.optBoolean("add"))
        "localPlayback" -> LocalPlaybackScreen(route.payload, back)
        "webdav" -> WebDavScreen(back)
        "lan" -> LanScreen(back)
        "lanConflicts" -> LanConflictsScreen(back)
        else -> SettingsPage(route.page, back)
    }
}
val LocalScreenActive = staticCompositionLocalOf { true }
fun Modifier.retainedVisible(visible: Boolean) = layout { measurable, constraints ->
    val child = measurable.measure(constraints)
    layout(child.width, child.height) { if (visible) child.placeRelative(0, 0) }
}
