package com.real.drama.compose

import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.*
import org.json.JSONObject

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LiveScreen(anchor: Drama, back: () -> Unit) {
    val repo = LocalRepository.current; val nav = LocalNavigate.current; val action = rememberAction(); val scope = rememberCoroutineScope()
    val context = LocalContext.current; val view = LocalView.current; val lifecycle = LocalLifecycleOwner.current
    val player = remember(anchor.id) { MpvPlayer(repo.store.json("playback")) }; val state by player.state.collectAsState()
    var drama by remember { mutableStateOf(anchor) }; var plan by remember { mutableStateOf<JSONObject?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }; var loading by remember { mutableStateOf(true) }; var reload by remember { mutableIntStateOf(0) }
    var paused by remember { mutableStateOf(false) }; var foreground by remember { mutableStateOf(lifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) }
    val active = LocalScreenActive.current && foreground; val latestActive by rememberUpdatedState(active)
    val currentPlan by rememberUpdatedState(plan); var focusAllowed by remember { mutableStateOf(false) }
    val shouldPlay = active && !paused && focusAllowed
    fun wantsPlayback() = latestActive && foreground && !paused && focusAllowed
    var full by remember { mutableStateOf(false) }
    var controls by remember { mutableStateOf(true) }
    var locked by remember { mutableStateOf(false) }
    var lockVisible by remember { mutableStateOf(true) }
    var interaction by remember { mutableIntStateOf(0) }
    val touchFeedback = rememberTouchFeedback()
    val source = repo.source(anchor.source)
    val manager = remember { context.getSystemService(android.media.AudioManager::class.java) }
    val focus = remember(player) { android.media.AudioFocusRequest.Builder(android.media.AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_MEDIA).setContentType(android.media.AudioAttributes.CONTENT_TYPE_MOVIE).build())
        .setOnAudioFocusChangeListener { value -> focusAllowed = value == android.media.AudioManager.AUDIOFOCUS_GAIN; if (value == android.media.AudioManager.AUDIOFOCUS_LOSS) paused = true; scope.launch { player.play(wantsPlayback()) } }.build() }
    fun togglePlayback() {
        paused = !paused && (focusAllowed || state.playing); interaction++
        action {
            if (!paused) focusAllowed = manager.requestAudioFocus(focus) == android.media.AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            player.play(wantsPlayback())
        }
    }
    fun toggleFull() { full = !full; locked = false; controls = true; interaction++ }
    val activity = context as? android.app.Activity
    DisposableEffect(full, active) {
        val original = activity?.requestedOrientation
        onDispose { if (full && active && original != null) activity.requestedOrientation = original }
    }
    LaunchedEffect(full, active, state.width > state.height) {
        if (full && active && activity != null) activity.requestedOrientation = if (state.width > state.height)
            android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
    }
    ImmersiveBars(full && active)
    androidx.activity.compose.BackHandler(full) { if (locked) { locked = false; controls = true } else toggleFull() }
    LaunchedEffect(controls, shouldPlay, state.buffering, loading, failure, interaction) {
        if (controls && shouldPlay && !state.buffering && !loading && failure == null) { delay(4000); controls = false }
    }
    LaunchedEffect(locked, lockVisible, interaction) { if (locked && lockVisible) { delay(3000); lockVisible = false } }
    DisposableEffect(player) {
        val observer = LifecycleEventObserver { _, _ -> foreground = lifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED); if (!foreground) scope.launch { player.play(false) } }
        val receiver = object : android.content.BroadcastReceiver() { override fun onReceive(c: android.content.Context?, intent: android.content.Intent?) { paused = true; scope.launch { player.play(false) } } }
        lifecycle.lifecycle.addObserver(observer)
        androidx.core.content.ContextCompat.registerReceiver(context, receiver, android.content.IntentFilter(android.media.AudioManager.ACTION_AUDIO_BECOMING_NOISY), androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED)
        onDispose { lifecycle.lifecycle.removeObserver(observer); context.unregisterReceiver(receiver); manager.abandonAudioFocusRequest(focus); view.keepScreenOn = false; player.close(); (context.applicationContext as DramaApplication).scope.launch { repo.release(currentPlan) } }
    }
    LaunchedEffect(active) { if (active && !paused) focusAllowed = manager.requestAudioFocus(focus) == android.media.AudioManager.AUDIOFOCUS_REQUEST_GRANTED else if (!active) { manager.abandonAudioFocusRequest(focus); focusAllowed = false } }
    LaunchedEffect(shouldPlay) { player.play(shouldPlay) }
    LaunchedEffect(active) { player.observe(active) }
    DisposableEffect(active, state.playing) { if (active && state.playing) view.keepScreenOn = true; onDispose { view.keepScreenOn = false } }
    LaunchedEffect(anchor.id, reload) {
        loading = true; failure = null
        var resolved: JSONObject? = null
        try {
            repo.release(plan); plan = null
            val epoch = repo.store.epoch
            val data = repo.runtime.execute(anchor.source, "live", obj("drama" to anchor.json))
            check(epoch == repo.store.epoch && repo.store.allowed(anchor.source))
            withContext(NonCancellable) { resolved = NativeBridge.call(obj("action" to "subscriptionPlan", "subscription" to data.getJSONObject("plan").copy().put("source", anchor.source))) }
            ensureActive(); check(epoch == repo.store.epoch)
            drama = data.optJSONObject("drama")?.let(::Drama) ?: anchor
            require(drama.source == anchor.source)
            player.play(wantsPlayback()); player.open(requireNotNull(resolved)); player.play(wantsPlayback()); plan = resolved; resolved = null
        } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { failure = e.message }
        finally { withContext(NonCancellable) { repo.release(resolved) }; loading = false }
    }
    LaunchedEffect(state.error) { if (state.error != null) failure = "直播播放失败，请重试或更换直播间" }
    Scaffold(containerColor = Color.Black, contentWindowInsets = WindowInsets(0), topBar = { if (!full) TopAppBar(title = { Text(drama.title, Modifier.padding(start = 16.dp), maxLines = 1, overflow = TextOverflow.Ellipsis) }, expandedHeight = 56.dp, navigationIcon = { IconAction("arrow_back_rounded", "返回", action = back) }, colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Black, titleContentColor = Color.White, navigationIconContentColor = Color.White)) }) { padding -> Column(Modifier.fillMaxSize().padding(padding)) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
            VideoSurface(player, Modifier.fillMaxSize())
            Box(Modifier.fillMaxSize().pointerInput(locked) { detectTapGestures {
                if (locked) lockVisible = true else { touchFeedback(); controls = !controls }
                interaction++
            } })
            if (!locked && (controls || !shouldPlay || failure != null)) CompositionLocalProvider(LocalContentColor provides Color.White) {
                Box(Modifier.matchParentSize().background(androidx.compose.ui.graphics.Brush.verticalGradient(0f to Color(0x99000000), .5f to Color.Transparent, 1f to Color(0xcc000000))))
                if (full) Row(Modifier.align(Alignment.TopCenter).fillMaxWidth().statusBarsPadding(), verticalAlignment = Alignment.CenterVertically) {
                    IconAction("arrow_back_rounded", "退出全屏") { toggleFull() }
                    Text(drama.title, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                FilledTonalIconButton(hapticClick { togglePlayback() }, Modifier.align(Alignment.Center).size(64.dp), enabled = !loading && failure == null, colors = IconButtonDefaults.filledTonalIconButtonColors(containerColor = Color.White.copy(alpha = .18f), contentColor = Color.White)) { Glyph(if (shouldPlay) "pause_rounded" else "play_arrow_rounded", if (shouldPlay) "暂停直播" else "播放直播", size = 38) }
                Row(Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(if (!shouldPlay) "已暂停" else if (state.buffering) "连接中…" else "直播中", Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
                    PlaybackTool("重新连接", onClick = { reload++; interaction++ }) { Glyph("refresh_rounded") }
                    PlaybackTool(if (full) "退出全屏" else "全屏", onClick = { toggleFull() }) { Glyph(if (full) "fullscreen_exit_rounded" else "fullscreen_rounded") }
                }
            }
            if (shouldPlay && state.buffering && !loading && !controls && failure == null) LoadingRing(Modifier.align(Alignment.Center))
            if (loading || failure != null) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .55f)), contentAlignment = Alignment.Center) {
                if (loading) LoadingRing(size = 38) else Column(Modifier.padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally) { Glyph("live_tv_outlined", color = Color.White, size = 42); Spacer(Modifier.height(14.dp)); Text(failure.orEmpty(), color = Color.White, textAlign = androidx.compose.ui.text.style.TextAlign.Center); Spacer(Modifier.height(14.dp)); Button(hapticClick { reload++ }, contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) { Glyph("refresh_rounded", size = 18); Spacer(Modifier.width(8.dp)); Text("重试") } }
            }
            if (full && (locked && lockVisible || !locked && controls) && !loading && failure == null) Box(Modifier.align(Alignment.CenterStart).padding(12.dp)) {
                PlaybackTool(if (locked) "解锁控制" else "锁定控制", onClick = { locked = !locked; lockVisible = true; controls = !locked; interaction++ }) { Glyph(if (locked) "lock_rounded" else "lock_open_rounded") }
            }
            if (!full && controls) Text("直播", Modifier.padding(16.dp).background(Color(0xffd32f2f), RoundedCornerShape(8.dp)).padding(horizontal = 10.dp, vertical = 6.dp), color = Color.White, fontWeight = appTextWeight(FontWeight.Bold))
        }
        if (!full && "creator" in source?.capabilities.orEmpty()) VideoAuthorPanel(drama, { nav(Route("creator", drama)) }, Modifier.fillMaxWidth().navigationBarsPadding().padding(16.dp))
    } }
}
