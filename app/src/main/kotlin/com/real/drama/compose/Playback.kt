package com.real.drama.compose

import android.graphics.SurfaceTexture
import android.view.Surface
import android.view.TextureView
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.ui.semantics.onClick
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.layout.layout
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.key.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import kotlin.math.ceil
import kotlin.math.roundToInt

data class PlaybackState(val position: Double = 0.0, val duration: Double = 0.0, val playing: Boolean = false, val buffering: Boolean = true,
    val completed: Boolean = false, val width: Double = 0.0, val height: Double = 0.0, val error: String? = null, val buffered: Double = 0.0,
    val positionRevision: Long = 0L)

internal fun playbackSnapshot(values: DoubleArray, intent: Boolean, previousError: String?): PlaybackState {
    require(values.size == 11)
    fun number(index: Int) = values[index].takeIf { it.isFinite() && it >= 0 } ?: 0.0
    val completed = values[6] == 1.0
    val playing = intent && values[5] == 0.0 && !completed
    val rotated = kotlin.math.abs(values[10] % 180.0) == 90.0
    return PlaybackState(number(0), number(1), playing, playing && (values[7] == 1.0 || values[8] == 1.0),
        completed, number(if (rotated) 3 else 2), number(if (rotated) 2 else 3),
        if (values[9] < 0) "媒体播放失败（${values[9].toInt()}）" else previousError, number(4))
}

internal fun scrubPosition(start: Double, distance: Float, width: Int, duration: Double): Double =
    if (width <= 0 || !duration.isFinite() || duration <= 0) start else
        (start + distance / width * minOf(duration, 180.0)).coerceIn(0.0, duration)

internal fun feedCacheSeconds(duration: Double): Int =
    if (!duration.isFinite() || duration <= 0.0) 6 else
        (duration * .30).roundToInt().coerceIn(3, 24).coerceAtMost(ceil(duration).toInt())

internal suspend fun androidx.compose.ui.input.pointer.PointerInputScope.detectPlaybackScrub(
    state: () -> PlaybackState, preview: (Float?) -> Unit, seek: (Double) -> Unit,
) {
    var start = 0.0
    var duration = 0.0
    var distance = 0f
    var target: Double? = null
    try {
        detectHorizontalDragGestures(
            onDragStart = { start = state().position; duration = state().duration; distance = 0f; target = null },
            onHorizontalDrag = { change, amount ->
                if (duration > 0) {
                    change.consume(); distance += amount
                    target = scrubPosition(start, distance, size.width, duration)
                    preview(target?.toFloat())
                }
            },
            onDragEnd = { val value = target; target = null; preview(null); if (value != null) seek(value) },
            onDragCancel = { target = null; preview(null) },
        )
    } finally { preview(null) }
}
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LegacySlider(
    value: Float, change: (Float) -> Unit, finish: () -> Unit, maximum: Float,
    modifier: Modifier = Modifier, buffered: Float = 0f, feed: Boolean = false, trackOffsetY: Dp = 0.dp,
) {
    val range = maximum.coerceAtLeast(1f)
    val thumbSize = if (feed) 10.dp else 12.dp
    Slider(value.coerceIn(0f, range), change, modifier, enabled = maximum > 0, onValueChangeFinished = finish, valueRange = 0f..range,
        thumb = { Spacer(Modifier.size(thumbSize)) },
        track = { slider -> Canvas(Modifier.fillMaxWidth().height(thumbSize)) {
            val y = size.height / 2 + trackOffsetY.toPx()
            val stroke = (if (feed) 2.dp else 3.dp).toPx()
            val thumb = androidx.compose.ui.geometry.Offset(size.width * slider.value / range, y)
            drawLine(Color.White.copy(alpha = if (feed) .38f else .25f), androidx.compose.ui.geometry.Offset(0f, y), androidx.compose.ui.geometry.Offset(size.width, y), strokeWidth = stroke)
            drawLine(Color.White.copy(alpha = .38f), androidx.compose.ui.geometry.Offset(0f, y), androidx.compose.ui.geometry.Offset(size.width * (buffered / range).coerceIn(0f, 1f), y), strokeWidth = stroke)
            drawLine(Color.White, androidx.compose.ui.geometry.Offset(0f, y), thumb, strokeWidth = stroke)
            drawCircle(Color.White, radius = thumbSize.toPx() / 2, center = thumb)
        } })
}

@Composable
internal fun PlaybackTool(
    label: String, width: Int = 36, enabled: Boolean = true, onClick: () -> Unit, content: @Composable () -> Unit,
) {
    val shape = androidx.compose.foundation.shape.RoundedCornerShape(18.dp)
    Box(
        Modifier.size((if (width < 40) 48 else width + 8).dp, 48.dp)
            .semantics { contentDescription = label }.hapticClickable(enabled = enabled, role = androidx.compose.ui.semantics.Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(width.dp, 36.dp).background(Color.Black.copy(alpha = .22f), shape)
                .border(1.dp, Color.White.copy(alpha = .08f), shape),
            contentAlignment = Alignment.Center,
        ) {
            CompositionLocalProvider(LocalContentColor provides Color.White.copy(alpha = if (enabled) .92f else .36f)) {
                ProvideTextStyle(TextStyle(fontSize = 13.5.sp, lineHeight = 13.5.sp, fontWeight = appTextWeight(FontWeight.Bold)), content)
            }
        }
    }
}
@Composable
fun FeedAction(icon: String, label: String, selected: Boolean = false, compact: Boolean = false, action: () -> Unit) {
    Column(Modifier.width(48.dp).heightIn(min = 48.dp)
        .semantics(mergeDescendants = true) { contentDescription = label }
        .hapticClickable(role = androidx.compose.ui.semantics.Role.Button, onClick = action),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Glyph(icon, color = if (selected) Color(0xffff4081) else Color.White)
        if (!compact) Text(label, Modifier.padding(top = 2.dp), color = Color.White, fontSize = 11.sp, lineHeight = 14.sp,
            style = LocalTextStyle.current.copy(shadow = androidx.compose.ui.graphics.Shadow(Color.Black, blurRadius = 6f)))
    }
}
class MpvPlayer(private val preferences: JSONObject, observeInitially: Boolean = true, feed: Boolean = false) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private var handle = 0L
    private var surface: Surface? = null
    private var texture: SurfaceTexture? = null
    @Volatile private var requestedTexture: SurfaceTexture? = null
    internal val renderLimit = if (preferences.optBoolean("lowMemory")) 960 else 1920
    private var pending: JSONObject? = null
    private var start = 0.0
    @Volatile private var intent = false
    private var playbackRate = preferences.optDouble("speed", 1.0)
    private val adaptiveCache = feed && !preferences.optBoolean("lowMemory")
    private var cacheWindow = 0
    @Volatile private var closed = false
    private val observing = MutableStateFlow(observeInitially)
    fun observe(value: Boolean) { observing.value = value }
    val state = MutableStateFlow(PlaybackState())
    internal val surfaceAttached = MutableStateFlow(false)
    private fun command(vararg values: String): Int = if (handle == 0L) -1 else NativeBridge.playerCommand(handle, values.map { it.toByteArray() }.toTypedArray())
    private fun get(name: String) = NativeBridge.playerGet(handle, name.toByteArray()).toString(Charsets.UTF_8)
    fun attach(value: SurfaceTexture, width: Int, height: Int) {
        if (closed) return
        requestedTexture = value
        scope.launch(start = CoroutineStart.UNDISPATCHED) { try { mutex.withLock {
            yield()
            if (closed || requestedTexture !== value || value.isReleased) return@withLock
            if (texture === value && handle != 0L) return@withLock
            if (handle != 0L) disconnectSurface()
            surface?.release()
            value.setDefaultBufferSize(width, height)
            texture = value; surface = Surface(value)
            handle = NativeBridge.createPlayer(surface!!, preferences.optBoolean("hardwareDecoding", true), preferences.optBoolean("lowMemory"))
            check(handle != 0L) { "无法初始化播放器" }
            command("set", "android-surface-size", "${width}x$height")
            val decoder = when (preferences.text("hardwareDecoder")) { "copy" -> "auto-copy"; "mediaCodec" -> "mediacodec"; "mediaCodecCopy" -> "mediacodec-copy"; else -> "auto-safe" }
            command("set", "hwdec", if (preferences.optBoolean("hardwareDecoding", true)) decoder else "no")
            command("set", "speed", playbackRate.toString())
            surfaceAttached.value = true
            pending?.let { openLocked(it, start) }
        } } catch (cancel: CancellationException) { throw cancel } catch (error: Exception) { state.value = state.value.copy(buffering = false, error = error.message ?: "无法初始化播放器") } }
    }
    fun detach(value: SurfaceTexture) {
        if (requestedTexture === value) requestedTexture = null
        CoroutineScope(Dispatchers.IO).launch(start = CoroutineStart.UNDISPATCHED) { mutex.withLock {
            yield()
            try {
                if (texture === value) {
                    try { if (handle != 0L) disconnectSurface() }
                    finally { surface?.release(); surface = null; texture = null }
                }
            } catch (error: Exception) {
                state.value = state.value.copy(playing = false, buffering = false, error = error.message ?: "无法释放视频画面")
            } finally { withContext(Dispatchers.Main) { value.release() } }
        } }
    }
    private fun disconnectSurface() {
        surfaceAttached.value = false
        val previous = handle
        try { get("time-pos").toDoubleOrNull()?.let { start = it } }
        finally { handle = 0; NativeBridge.destroyPlayer(previous) }
    }
    init {
        scope.launch {
            while (isActive) {
                observing.first { it }
                mutex.withLock {
                    if (!closed && observing.value && handle != 0L && pending != null) {
                        try {
                            val snapshot = playbackSnapshot(NativeBridge.playerSnapshot(handle), intent, state.value.error)
                            if (adaptiveCache && snapshot.playing && !snapshot.buffering) setFeedCache(feedCacheSeconds(snapshot.duration))
                            state.value = snapshot.copy(positionRevision = state.value.positionRevision)
                        } catch (error: Exception) {
                            state.value = state.value.copy(playing = false, buffering = false, error = error.message ?: "无法读取播放器状态")
                        }
                    }
                }
                delay(if (state.value.playing || state.value.buffering || adaptiveCache && state.value.width == 0.0) 250 else 1000)
            }
        }
    }
    suspend fun open(plan: JSONObject, position: Double = 0.0) = withContext(Dispatchers.IO) { mutex.withLock {
        if (closed) return@withLock
        pending = plan; start = position
        state.value = PlaybackState(position = position, playing = intent, buffering = intent, positionRevision = state.value.positionRevision + 1)
        if (handle != 0L) openLocked(plan, position)
    } }
    private fun openLocked(plan: JSONObject, position: Double) {
        val address = plan.getString("url")
        require(address.startsWith("https://") || address.startsWith("http://") || address.startsWith("/") || address.startsWith("file://")) { "媒体地址无效" }
        command("stop")
        if (adaptiveCache) {
            cacheWindow = 0
            setFeedCache(if (intent) feedCacheSeconds(0.0) else 2)
        }
        val headers = plan.optJSONObject("headers") ?: JSONObject()
        val encoded = headers.keys().asSequence().map { key ->
            val value = headers.getString(key); require(!key.contains('\n') && !value.contains('\n') && !value.contains('\r'))
            "$key: $value".replace("\\", "\\\\").replace(",", "\\,")
        }.joinToString(",")
        command("set", "http-header-fields", encoded)
        val decryption = plan.text("decryptionKey")
        require(decryption.isEmpty() || decryption.matches(Regex("[0-9a-fA-F]{32}")))
        command("set", "demuxer-lavf-o", "seg_max_retry=3,strict=experimental,allowed_extensions=ALL,protocol_whitelist=[http,https,tcp,tls,crypto,data,file]" + if (decryption.isEmpty()) "" else ",decryption_key=$decryption")
        command("set", "network-timeout", "20")
        command("set", "start", position.coerceAtLeast(0.0).toString())
        command("change-list", "audio-files", "clr", "")
        plan.text("audioUrl").takeIf { it.isNotEmpty() }?.let { command("change-list", "audio-files", "append", it) }
        command("set", "pause", if (intent) "no" else "yes")
        check(command("loadfile", address, "replace") >= 0) { "无法打开媒体" }
        command("set", "pause", if (intent) "no" else "yes")
    }
    private fun setFeedCache(seconds: Int) {
        if (seconds == cacheWindow) return
        cacheWindow = seconds
        command("set", "cache-secs", seconds.toString())
        command("set", "demuxer-hysteresis-secs", (seconds / 2.0).toString())
    }
    suspend fun play(value: Boolean) {
        intent = value
        withContext(Dispatchers.IO) { mutex.withLock {
            command("set", "pause", if (intent) "no" else "yes")
            state.value = state.value.copy(playing = intent && !state.value.completed, buffering = intent && state.value.buffering)
        } }
    }
    suspend fun seek(seconds: Double) = withContext(Dispatchers.IO) { mutex.withLock {
        val target = seconds.coerceIn(0.0, state.value.duration.takeIf { it > 0 } ?: Double.MAX_VALUE)
        start = target
        if (command("seek", target.toString(), "absolute+exact") >= 0) {
            state.value = state.value.copy(position = target, completed = false, positionRevision = state.value.positionRevision + 1)
        }
    } }
    suspend fun rate(speed: Double) = withContext(Dispatchers.IO) { mutex.withLock { playbackRate = speed; command("set", "speed", speed.toString()); Unit } }
    suspend fun volume(value: Double) = withContext(Dispatchers.IO) { mutex.withLock { command("set", "volume", value.coerceIn(0.0, 100.0).toString()); Unit } }
    fun close() {
        closed = true
        requestedTexture = null
        surfaceAttached.value = false
        scope.launch {
            try { mutex.withLock {
                try {
                    val previous = handle; handle = 0
                    if (previous != 0L) NativeBridge.destroyPlayer(previous)
                } finally { surface?.release(); surface = null }
            } } catch (error: Exception) {
                state.value = state.value.copy(playing = false, buffering = false, error = error.message ?: "无法关闭播放器")
            } finally { scope.cancel() }
        }
    }
}
data class PlayerActions(val episode: Int, val episodes: () -> Unit)

internal suspend fun androidx.compose.ui.input.pointer.PointerInputScope.detectPlaybackTaps(
    doubleTapSlop: Float,
    onHold: () -> (() -> Unit)? = { null },
    onTap: () -> Boolean,
    onDoubleTap: (androidx.compose.ui.geometry.Offset) -> Unit,
) {
    var firstTap: androidx.compose.ui.geometry.Offset? = null
    var firstTime = 0L
    awaitEachGesture {
        val down = awaitFirstDown()
        down.consume()
        var up: androidx.compose.ui.input.pointer.PointerInputChange? = null
        val endedBeforeHold = withTimeoutOrNull(350) { up = waitForUpOrCancellation(); true } == true
        if (!endedBeforeHold) {
            firstTap = null
            val restore = onHold()
            try { waitForUpOrCancellation()?.consume() } finally { restore?.invoke() }
            return@awaitEachGesture
        }
        val tap = up
        if (tap == null) {
            firstTap = null
            return@awaitEachGesture
        }
        tap.consume()
        if (tap.uptimeMillis - down.uptimeMillis >= 350) {
            firstTap = null
            return@awaitEachGesture
        }
        val position = tap.position
        val now = tap.uptimeMillis
        val first = firstTap
        if (first != null && now - firstTime in viewConfiguration.doubleTapMinTimeMillis..viewConfiguration.doubleTapTimeoutMillis &&
            (position - first).getDistance() <= doubleTapSlop
        ) {
            firstTap = null
            onDoubleTap(position)
        } else {
            firstTap = position.takeIf { onTap() }
            firstTime = now
        }
    }
}

@Composable
fun VideoSurface(player: MpvPlayer, modifier: Modifier = Modifier, onFrameReady: ((Boolean) -> Unit)? = null) {
    val state by player.state.collectAsState()
    val latestOnFrameReady by rememberUpdatedState(onFrameReady)
    AndroidView(factory = { context ->
        FittedVideoTexture(context, player, if (onFrameReady == null) null else { ready -> latestOnFrameReady?.invoke(ready) })
    }, modifier = modifier,
        update = { it.setVideoAspect(if (state.width > 0 && state.height > 0) (state.width / state.height).toFloat() else 0f) })
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun PlayerPane(detail: Detail, initialIndex: Int = 0, active: Boolean = true, feed: Boolean = false, modifier: Modifier = Modifier, initialPosition: Double? = null,
    handoff: LanPreparedPlayback? = null, localPlan: JSONObject? = null, mediaId: String = "", localOnly: Boolean = false,
    selectedIndex: Int? = null, onIndexChanged: (Int) -> Unit = {}, externalFull: Boolean? = null, externalClean: Boolean? = null,
    takeFeedPlan: (suspend (Drama, Episode, Int, () -> Boolean) -> JSONObject?)? = null,
    feedPreview: (@Composable (Modifier) -> Unit)? = null,
    warmFeed: Boolean = false, onMediaOpened: () -> Unit = {},
    commentsProgress: State<Float>? = null, commentsVideoHeight: Dp = 0.dp,
    onVideoAspectRatio: (Double) -> Unit = {},
    onControls: (PlayerActions?) -> Unit = {}, onClean: (Boolean) -> Unit = {}, onBoost: (Boolean) -> Unit = {}, onFullScreen: (Boolean) -> Unit = {}, onComments: () -> Unit = {}, onCreator: () -> Unit = {}, onNext: () -> Unit = {}, onBack: () -> Unit = {}, onUnavailable: () -> Unit = {}, onAvailable: () -> Unit = {}) {
    val repo = LocalRepository.current; val action = rememberAction(); val context = LocalContext.current; val nav = LocalNavigate.current
    val rawPreferences = repo.store.text("playback", "{}")
    val preferences = remember(rawPreferences) { JSONObject(rawPreferences) }
    val television = !feed && televisionMode()
    val player = remember(detail.drama.id) { MpvPlayer(preferences, observeInitially = active || !feed, feed = feed) }
    var videoFrameReady by remember(player) { mutableStateOf(false) }
    val state by player.state.collectAsState()
    val surfaceAttached by player.surfaceAttached.collectAsState()
    val canOpenFeed by rememberUpdatedState(active || surfaceAttached)
    var index by remember(detail.drama.id) { mutableIntStateOf(initialIndex.coerceIn(0, (detail.episodes.size - 1).coerceAtLeast(0))) }
    var plan by remember(detail.drama.id) { mutableStateOf<JSONObject?>(null) }
    var failure by remember(detail.drama.id) { mutableStateOf<String?>(null) }
    var failedWhileWarming by remember(player, index) { mutableStateOf(false) }
    var loading by remember { mutableStateOf(true) }
    var loadingLabel by remember { mutableStateOf("正在准备播放") }
    var reload by remember { mutableIntStateOf(0) }
    var quality by remember { mutableIntStateOf(preferences.optInt(if (feed) "homeQuality" else "quality")) }
    var playbackQuality by remember { mutableIntStateOf(quality) }
    var speed by remember { mutableDoubleStateOf(preferences.optDouble("speed", 1.0)) }
    var localClean by remember { mutableStateOf(false) }
    val clean = externalClean ?: localClean
    val currentClean by rememberUpdatedState(clean)
    fun setClean(value: Boolean) {
        if (externalClean == null) localClean = value else onClean(value)
    }
    var boost by remember { mutableStateOf(false) }
    var localFull by remember(television) { mutableStateOf(television) }
    val full = externalFull ?: localFull
    var locked by remember(player) { mutableStateOf(false) }
    var lockVisible by remember(player) { mutableStateOf(true) }
    var dragging by remember(player, index) { mutableStateOf<Float?>(null) }
    var adjusting by remember(player) { mutableStateOf(false) }
    var interaction by remember { mutableIntStateOf(0) }
    val toggleFullscreen = {
        locked = false; setClean(false); interaction++
        if (externalFull == null) localFull = !full
        onFullScreen(!full)
    }
    var menu by remember { mutableStateOf("") }
    val danmaku by repo.danmaku.collectAsState()
    var hint by remember { mutableStateOf("") }
    var liked by remember(detail.drama.id) { mutableStateOf(detail.drama.id in repo.recommendations.likes) }
    var likePulse by remember { mutableIntStateOf(0) }
    var showLike by remember { mutableStateOf(false) }
    val likeScale = remember { androidx.compose.animation.core.Animatable(.55f) }
    var volume by remember { mutableDoubleStateOf(100.0) }
    val scope = rememberCoroutineScope()
    val rootFocus = remember { FocusRequester() }
    var keyboardHold by remember { mutableStateOf<Job?>(null) }
    var keyboardHeld by remember { mutableStateOf(false) }
    var savedVolume by remember { mutableDoubleStateOf(100.0) }
    val preloader = remember(player) { PlaybackPreloader(repo, scope) }
    val preloadStatus by preloader.status.collectAsState()
    var openedEpisode by remember(player) { mutableStateOf<Episode?>(null) }
    var initialPositionApplied by remember(player) { mutableStateOf(false) }
    var recoveryAttempts by remember(detail.drama.id, index) { mutableIntStateOf(0) }
    val lifecycle = LocalLifecycleOwner.current
    var foreground by remember(lifecycle) { mutableStateOf(lifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) }
    val latestActive by rememberUpdatedState(active)
    val epoch = remember(detail.drama.id) { repo.store.epoch }
    suspend fun recordProgress(episode: Episode, state: PlaybackState) {
        if (mediaId.isEmpty()) repo.store.progress(detail.drama, episode.number, state.position, state.duration, epoch)
        else repo.store.mediaProgress(mediaId, detail.drama, episode.number, state.position, state.duration, epoch)
    }
    val episode = detail.episodes.getOrNull(index)
    val source = repo.source(detail.drama.source)
    val episodic = source?.kind == "drama" || detail.episodes.size > 1
    val holdSpeed = if (source?.kind == "live") 1.0 else 2.0
    LaunchedEffect(selectedIndex) { selectedIndex?.let { index = it.coerceIn(0, (detail.episodes.size - 1).coerceAtLeast(0)) } }
    LaunchedEffect(index) { onIndexChanged(index) }
    LaunchedEffect(boost) { onBoost(boost) }
    DisposableEffect(active, episode) {
        if (active) onControls(PlayerActions(episode?.number ?: 1, { menu = "episodes" }))
        onDispose { if (active) onControls(null) }
    }
    LaunchedEffect(likePulse) {
        if (likePulse > 0) {
            likeScale.snapTo(.55f)
            showLike = true
            likeScale.animateTo(1.15f, androidx.compose.animation.core.tween(360, easing = androidx.compose.animation.core.CubicBezierEasing(.175f, .885f, .32f, 1.275f)))
            showLike = false
        }
    }
    LaunchedEffect(hint) { if (hint.isNotEmpty()) { delay(1200); hint = "" } }
    val currentPlan by rememberUpdatedState(plan)
    val currentEpisode by rememberUpdatedState(episode)
    val currentOpenedEpisode by rememberUpdatedState(openedEpisode)
    val currentState by rememberUpdatedState(state)
    var pausedByUser by remember { mutableStateOf(false) }
    var audioAllowed by remember { mutableStateOf(true) }
    val shouldPlay = active && foreground && audioAllowed && !pausedByUser
    val showBuffering = shouldPlay && state.buffering
    val feedWaiting = feed && active && foreground && failure == null && (loading || shouldPlay && !state.completed && state.error == null &&
        (showBuffering || !videoFrameReady && state.width == 0.0))
    var feedLoadingVisible by remember { mutableStateOf(false) }
    var feedLoadingTimedOut by remember(plan, reload) { mutableStateOf(false) }
    LaunchedEffect(feedWaiting) {
        if (feedWaiting) {
            delay(180)
            feedLoadingVisible = true
        } else {
            feedLoadingVisible = false
        }
    }
    LaunchedEffect(feedWaiting, plan, reload, state.position) {
        feedLoadingTimedOut = false
        if (feedWaiting) {
            delay(12000)
            feedLoadingTimedOut = true
        }
    }
    val playbackFailure = failure ?: if (feedLoadingTimedOut) "本条视频加载超时" else null
    fun wantsPlayback() = latestActive && foreground && audioAllowed && !pausedByUser
    var requestFocus by remember { mutableStateOf<(() -> Boolean)?>(null) }
    var feedFeedback by remember { mutableIntStateOf(0) }
    LaunchedEffect(feedFeedback) { if (feedFeedback > 0) { delay(1000); feedFeedback = 0 } }
    fun setPaused(pause: Boolean) {
        pausedByUser = pause
        if (!pausedByUser) audioAllowed = requestFocus?.invoke() == true
        if (feed) feedFeedback++
        interaction++
        action { player.play(wantsPlayback()) }
    }
    fun togglePlayback() {
        if (currentState.completed) {
            setPaused(false)
            action { player.seek(0.0); player.play(wantsPlayback()) }
        } else setPaused(!pausedByUser && (audioAllowed || currentState.playing))
    }
    DisposableEffect(active, foreground, player) {
        val manager = context.getSystemService(android.media.AudioManager::class.java)
        val focus = android.media.AudioFocusRequest.Builder(android.media.AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_MEDIA).setContentType(android.media.AudioAttributes.CONTENT_TYPE_MOVIE).build())
            .setOnAudioFocusChangeListener { change ->
                audioAllowed = change == android.media.AudioManager.AUDIOFOCUS_GAIN
                if (change == android.media.AudioManager.AUDIOFOCUS_LOSS) pausedByUser = true
            }.build()
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(c: android.content.Context?, intent: android.content.Intent?) { pausedByUser = true; scope.launch { player.play(false) } }
        }
        if (active && foreground) {
            requestFocus = { manager.requestAudioFocus(focus) == android.media.AudioManager.AUDIOFOCUS_REQUEST_GRANTED }
            audioAllowed = manager.requestAudioFocus(focus) == android.media.AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            androidx.core.content.ContextCompat.registerReceiver(context, receiver, android.content.IntentFilter(android.media.AudioManager.ACTION_AUDIO_BECOMING_NOISY), androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED)
        }
        onDispose { if (active && foreground) { requestFocus = null; manager.abandonAudioFocusRequest(focus); context.unregisterReceiver(receiver) } }
    }
    val view = LocalView.current
    val touchFeedback = rememberTouchFeedback()
    DisposableEffect(active, player) {
        val window = (context as? android.app.Activity)?.window
        val brightness = window?.attributes?.screenBrightness
        onDispose { if (active && window != null && brightness != null) { val attributes = window.attributes; attributes.screenBrightness = brightness; window.attributes = attributes } }
    }
    LaunchedEffect(active, clean, menu, commentsProgress) { if (active && commentsProgress == null && menu.isEmpty() && (clean || !television)) rootFocus.requestFocus() }
    DisposableEffect(active) { onDispose { keyboardHold?.cancel(); keyboardHold = null; keyboardHeld = false; if (boost) { boost = false; action { player.rate(speed) } } } }
    DisposableEffect(active, state.playing) {
        if (active && state.playing) view.keepScreenOn = true
        onDispose { if (active) view.keepScreenOn = false }
    }
    val orientation = when {
        television || state.width > 0 && state.height > 0 && state.width > state.height -> android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        state.width > 0 && state.height > 0 -> android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
        else -> android.content.pm.ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    }
    val aspectRatio = if (state.width > 0 && state.height > 0) state.width / state.height else 0.0
    LaunchedEffect(feed, active, aspectRatio) { if (feed && active && aspectRatio.isFinite()) onVideoAspectRatio(aspectRatio) }
    DisposableEffect(full, active, orientation, feed) {
        val activity = context as? android.app.Activity
        val original = activity?.requestedOrientation
        if (!feed && full && active && activity != null) activity.requestedOrientation = orientation
        onDispose {
            if (!feed && full && active && activity != null && original != null) activity.requestedOrientation = original
        }
    }
    ImmersiveBars(full && active && !feed)
    DisposableEffect(player, episode, active) {
        val host = episode?.takeIf { active && mediaId.isEmpty() }?.let { LanPlaybackHost(player, detail.drama, it, { player.state.value }, { pausedByUser = true; player.play(false) }) }
        if (host != null) repo.lan.playback = host
        onDispose { if (repo.lan.playback === host) repo.lan.playback = null }
    }
    DisposableEffect(player, lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            foreground = lifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
            if (event == Lifecycle.Event.ON_STOP) action { player.play(false) }
        }
        lifecycle.lifecycle.addObserver(observer)
        onDispose {
            lifecycle.lifecycle.removeObserver(observer); preloader.clear(); player.close(); onBoost(false)
            (context.applicationContext as DramaApplication).scope.launch {
                currentOpenedEpisode?.let { recordProgress(it, currentState) }
                repo.release(currentPlan)
            }
        }
    }
    LaunchedEffect(shouldPlay) { player.play(shouldPlay) }
    LaunchedEffect(active, foreground, warmFeed) {
        player.observe(foreground && (active || warmFeed))
        if (foreground && !active && warmFeed) {
            withTimeoutOrNull(6500) { player.state.first { it.width > 0 && it.height > 0 || it.error != null } }
            player.observe(false)
        }
    }
    LaunchedEffect(feed, active, preferences.optInt("homeQuality")) {
        if (feed && active) {
            quality = preferences.optInt("homeQuality")
            if (plan?.optBoolean("local") != true) playbackQuality = quality
        }
    }
    LaunchedEffect(clean, state.playing, state.buffering, menu, feed, dragging != null, adjusting, interaction) {
        if (!feed && !clean && state.playing && !state.buffering && menu.isEmpty() && dragging == null && !adjusting) { delay(4000); setClean(true) }
    }
    LaunchedEffect(locked, lockVisible, interaction) { if (locked && lockVisible) { delay(3000); lockVisible = false } }
    LaunchedEffect(full) { if (!full) locked = false }
    LaunchedEffect(active) { if (!active) { dragging = null; adjusting = false } }
    LaunchedEffect(detail.drama.id, index, playbackQuality, reload) {
        loading = true; failure = null; failedWhileWarming = false
        if (episode == null) { loading = false; failure = "没有可播放的分集"; return@LaunchedEffect }
        try {
            val continuingPosition = openedEpisode?.takeIf { it.number == episode.number }?.let { player.state.value.position }
            openedEpisode?.let { recordProgress(it, player.state.value) }; openedEpisode = null
            repo.release(plan); plan = null
            val saved = if (mediaId.isEmpty()) repo.store.watch(detail.drama) else repo.store.json("mediaHistory").optJSONObject(mediaId)
            val position = continuingPosition ?: if (!initialPositionApplied && initialPosition != null) initialPosition else if (saved?.optInt("episode") == episode.number && !(saved.optDouble("duration") > 1 && saved.optDouble("position") >= saved.optDouble("duration") - 1)) saved.optDouble("position") else 0.0
            val prepared = handoff?.takeIf { !it.consumed && !it.cancelled && it.epoch == repo.store.epoch && it.index == index }
            val resolved = localPlan ?: prepared?.plan ?: if (localOnly) NativeBridge.call(obj("action" to "localPlayback", "drama" to detail.drama.json, "index" to episode.number)).also { require(it.optBoolean("local") && it.text("url").isNotEmpty()) { "本地视频不可用，请检查已下载文件" } } else (if (reload == 0) takeFeedPlan?.invoke(detail.drama, episode, playbackQuality) { canOpenFeed } ?: preloader.take(detail.drama, episode, playbackQuality) else null) ?: repo.resolve(detail.drama, episode, playbackQuality, online = reload > 0)
            try {
                ensureActive(); plan = resolved
                if (prepared != null) { prepared.consumed = true; prepared.stop = { player.play(false) } }
                player.play(wantsPlayback())
                player.open(resolved, prepared?.position ?: position)
                player.play(wantsPlayback())
                openedEpisode = episode; initialPositionApplied = true; player.rate(speed)
            }
            catch (error: Throwable) { repo.release(resolved); throw error }
        } catch (cancel: CancellationException) { throw cancel }
        catch (error: Exception) {
            failedWhileWarming = feed && !latestActive
            failure = error.message ?: "播放失败"
        }
        finally { loading = false; loadingLabel = "正在准备播放" }
    }
    LaunchedEffect(player, index) {
        while (true) { delay(5000); if (latestActive && openedEpisode != null) recordProgress(openedEpisode!!, player.state.value) }
    }
    val preloadEligible = !feed && active && foreground && localPlan == null && preferences.optBoolean("preload", true) && !preferences.optBoolean("lowMemory") && plan?.optBoolean("local") == false && !loading && failure == null && index < detail.episodes.lastIndex
    val preloadWindow = state.duration > 0 && state.position >= 2 && (state.position >= state.duration / 2 || state.duration - state.position <= 45) && state.buffered - state.position >= 5
    LaunchedEffect(index, quality, preloadEligible, preloadWindow, state.playing, state.buffering) {
        if (!preloadEligible) { if (openedEpisode == episode) preloader.clear() }
        else if (!state.playing || state.buffering) preloader.pause()
        else if (preloadWindow) preloader.prepare(detail.drama, detail.episodes[index + 1], quality)
    }
    LaunchedEffect(state, handoff) {
        if (handoff != null && !handoff.started.isCompleted && handoff.consumed && !handoff.cancelled) {
            if (state.error != null) handoff.started.completeExceptionally(IllegalStateException(state.error))
            else if (state.playing && !state.buffering && kotlin.math.abs(state.position - handoff.position) < 5) {
                if (handoff.firstPosition == null) handoff.firstPosition = state.position
                if (state.position >= handoff.firstPosition!! + .15) handoff.started.complete(state.position)
            }
        }
    }
    LaunchedEffect(state.completed, commentsProgress) {
        if (state.completed && active && commentsProgress == null && preferences.optBoolean("autoAdvance", true)) {
            if (index + 1 < detail.episodes.size) index++ else if (feed) onNext()
        }
    }
    LaunchedEffect(feed, active, openedEpisode, loading, failure) {
        if (feed && active && openedEpisode != null && !loading && failure == null) onMediaOpened()
    }
    LaunchedEffect(failure, active) {
        if (feed && active && failure != null) {
            if (failedWhileWarming) {
                failure = null
                reload++
            } else onUnavailable()
        }
    }
    LaunchedEffect(active, state.playing, state.buffering, aspectRatio > 0) {
        if (feed && active && !state.buffering && (state.playing || aspectRatio > 0)) onAvailable()
    }
    LaunchedEffect(state.error, !feed || active) {
        if ((!feed || active) && state.error != null && plan != null) {
            val current = plan!!
            if (current.optInt("routeIndex") + 1 < current.optInt("routeCount")) {
                try {
                    loading = true
                    loadingLabel = "正在切换备用线路"
                    val next = repo.fallback(current)
                    plan = next
                    player.open(next, state.position)
                }
                catch (cancel: CancellationException) { throw cancel } catch (_: Exception) { failure = state.error }
                finally { loading = false; loadingLabel = "正在准备播放" }
            } else if (!localOnly && localPlan == null && !current.optBoolean("local") && recoveryAttempts < 1) { recoveryAttempts++; loadingLabel = "正在重新获取播放地址"; reload++ }
            else failure = state.error
        }
    }
    if (!feed && full && !television) androidx.activity.compose.BackHandler {
        if (locked) { locked = false; setClean(false) } else toggleFullscreen()
    }
    BoxWithConstraints(modifier.background(Color.Black).onPreviewKeyEvent { event ->
        if (!active || commentsProgress != null || event.isAltPressed || event.isMetaPressed || event.isShiftPressed || event.isCtrlPressed) false
        else if (!television && event.key == Key.DirectionRight) {
            if (event.type == KeyEventType.KeyDown && !keyboardHeld) {
                keyboardHeld = true; keyboardHold = scope.launch { delay(350); if (currentState.playing) { boost = true; player.rate(holdSpeed) } }
            } else if (event.type == KeyEventType.KeyUp && keyboardHeld) {
                keyboardHeld = false; keyboardHold?.cancel(); keyboardHold = null
                if (boost) { boost = false; action { player.rate(speed) } } else action { player.seek((currentState.position + 5).coerceAtMost(currentState.duration.coerceAtLeast(0.0))) }
            }; true
        } else if (event.type != KeyEventType.KeyDown) false else when (event.key) {
            Key.MediaPlayPause, Key.Spacebar -> { togglePlayback(); true }
            Key.MediaPlay, Key.MediaPause -> { if (state.playing != (event.key == Key.MediaPlay)) togglePlayback(); true }
            Key.MediaNext -> { if (index < detail.episodes.lastIndex) index++; true }
            Key.MediaPrevious -> { if (index > 0) index--; true }
            Key.DirectionLeft, Key.DirectionRight -> if (clean || !television) { val delta = if (event.key == Key.DirectionLeft) { if (television) -10 else -5 } else 10; action { player.seek((currentState.position + delta).coerceIn(0.0, currentState.duration.coerceAtLeast(0.0))) }; true } else false
            Key.DirectionCenter, Key.Enter -> if (clean) { setClean(false); true } else false
            Key.DirectionUp, Key.DirectionDown -> if (television) { if (clean) { setClean(false); true } else false } else { volume = (volume + if (event.key == Key.DirectionUp) 5 else -5).coerceIn(0.0, 100.0); action { player.volume(volume) }; hint = "音量 ${volume.toInt()}%"; true }
            Key.M -> { if (volume > 0) { savedVolume = volume; volume = 0.0 } else volume = savedVolume; action { player.volume(volume) }; true }
            Key.F, Key.F11 -> if (television) false else { toggleFullscreen(); true }
            else -> false
        }
    }.focusRequester(rootFocus).focusable()) {
        val videoTop = if (aspectRatio > 0.0 && aspectRatio.isFinite()) {
            ((maxHeight - maxWidth / aspectRatio.toFloat()) / 2).coerceAtLeast(0.dp)
        } else 0.dp
        val detailToolbar = Modifier.align(Alignment.TopCenter).fillMaxWidth().then(
            if (!feed && full && !television) {
                val insets = WindowInsets.displayCutout.union(WindowInsets.statusBarsIgnoringVisibility)
                    .only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal)
                Modifier.windowInsetsPadding(insets).layout { measurable, constraints ->
                    val bar = measurable.measure(constraints)
                    val top = maxOf(2.dp.roundToPx(), videoTop.roundToPx() - insets.getTop(this) - bar.height - 16.dp.roundToPx())
                        .coerceAtMost((constraints.maxHeight - bar.height).coerceAtLeast(0))
                    layout(bar.width, bar.height + top) { bar.placeRelative(0, top) }
                }
            } else Modifier,
        ).padding(horizontal = 8.dp)
        Box(Modifier.matchParentSize().then(if (commentsProgress == null) Modifier else Modifier.graphicsLayer {
            val progress = commentsProgress.value
            val targetHeight = commentsVideoHeight.toPx().coerceAtMost(size.height)
            val fittedHeight = if (aspectRatio > 0.0) minOf(size.height, size.width / aspectRatio.toFloat()) else size.height
            val targetScale = if (fittedHeight > 0f) (targetHeight / fittedHeight).coerceAtMost(1f) else 1f
            val scale = 1f + (targetScale - 1f) * progress
            scaleX = scale
            scaleY = scale
            translationY = (targetHeight - size.height) * .5f * progress
        })) {
            VideoSurface(player, Modifier.fillMaxSize(), if (feedPreview == null) null else { ready -> videoFrameReady = ready })
            if (!videoFrameReady) feedPreview?.invoke(Modifier.matchParentSize())
            if (active && danmaku && episode != null && "danmaku" in source?.capabilities.orEmpty() && !localOnly && plan?.optBoolean("local") == false && !loading && failure == null && (!feed || !clean)) DanmakuOverlay(detail.drama, episode, state, if (boost) holdSpeed else speed)
        }
        Box(Modifier.fillMaxSize().pointerInput(player, speed, feed, holdSpeed, active, loading, playbackFailure, externalClean, locked, commentsProgress) {
            if (!active || commentsProgress != null) return@pointerInput
            if (locked) { detectTapGestures { lockVisible = true; interaction++ }; return@pointerInput }
            if (loading || playbackFailure != null || feed && externalClean == true) return@pointerInput
            var wasPaused = false
            detectPlaybackTaps(android.view.ViewConfiguration.get(context).scaledDoubleTapSlop.toFloat(),
                onHold = {
                    if (!currentState.playing || currentState.completed || pausedByUser) null else {
                        boost = true
                        action { player.rate(if (boost) holdSpeed else speed) }
                        val restore: () -> Unit = {
                            boost = false
                            action { player.rate(speed) }
                        }
                        restore
                    }
                },
                onTap = {
                    if (boost) false else {
                        touchFeedback()
                        if (feed) {
                            wasPaused = pausedByUser
                            togglePlayback()
                        } else {
                            setClean(!currentClean)
                            interaction++
                        }
                        true
                    }
                },
                onDoubleTap = { position ->
                    if (feed) {
                        setPaused(wasPaused)
                        if (!liked) { repo.recommendations.like(detail.drama); liked = true }
                        likePulse++
                    } else if (!boost) {
                        setClean(false)
                        if (position.x < size.width * .35f || position.x > size.width * .65f) {
                            val delta = if (position.x < size.width * .35f) -10 else 10
                            action { player.seek((currentState.position + delta).coerceIn(0.0, currentState.duration.coerceAtLeast(0.0))) }
                            hint = if (delta < 0) "后退 10 秒" else "前进 10 秒"
                        } else togglePlayback()
                    }
                },
            )
        }.then(if (feed || locked || !active || loading || failure != null) Modifier else Modifier.pointerInput(player) {
            detectPlaybackScrub({ currentState }, { dragging = it }, { target -> interaction++; action { player.seek(target) } })
        }.pointerInput(player) {
            var left = false
            try { detectVerticalDragGestures(onDragStart = { left = it.x < size.width / 2; adjusting = true },
                onDragEnd = { adjusting = false; interaction++ }, onDragCancel = { adjusting = false }, onVerticalDrag = { change, amount ->
                change.consume()
                if (left) {
                    (context as? android.app.Activity)?.let { activity -> val attrs = activity.window.attributes; val base = attrs.screenBrightness.takeIf { it >= 0 } ?: runCatching { android.provider.Settings.System.getInt(activity.contentResolver, android.provider.Settings.System.SCREEN_BRIGHTNESS) / 255f }.getOrDefault(.5f); attrs.screenBrightness = (base - amount / size.height * 1.2f).coerceIn(.02f, 1f); activity.window.attributes = attrs; hint = "亮度 ${(attrs.screenBrightness * 100).toInt()}%" }
                } else { volume = (volume - amount / size.height * 100).coerceIn(0.0, 100.0); hint = "音量 ${volume.toInt()}%"; action { player.volume(volume) } }
            }) } finally { adjusting = false }
        }))
        val playbackTitle = buildString {
            append(detail.drama.title)
            if (episodic) append(" · 第 ${episode?.number ?: 1} 集")
            if (plan?.optBoolean("local") == true) append(" · 本地")
            if (episode?.json?.optBoolean("vip") == true) append(" · VIP 试看")
            val route = plan?.optInt("routeIndex") ?: 0
            if (route > 0) append(" · 线路 ${route + 1}")
        }
        val enabled = !loading && playbackFailure == null

        val controlsVisible = (!clean || !shouldPlay || state.completed || menu.isNotEmpty()) && !boost && !locked
        if (controlsVisible && television) TelevisionPlayerControls(playbackTitle, state.copy(playing = shouldPlay && !state.completed, buffering = showBuffering), index > 0, index + 1 < detail.episodes.size, episodic,
            onBack = onBack, onToggle = { togglePlayback() }, onPrevious = { index-- }, onNext = { index++ }, onEpisodes = { menu = "episodes" }, onSettings = { menu = "settings" }, onSeek = { target -> action { player.seek(target) } })
        if ((if (feed) !clean && !boost && commentsProgress == null else controlsVisible) && !television) CompositionLocalProvider(LocalContentColor provides Color.White) {
            if (!feed) {
                Box(Modifier.matchParentSize().background(androidx.compose.ui.graphics.Brush.verticalGradient(
                    0f to Color(0xaa000000), .45f to Color.Transparent, 1f to Color(0xe6000000),
                )))
                if (!full || !loading && failure == null) Row(detailToolbar, verticalAlignment = Alignment.CenterVertically) {
                    val exitLabel = if (full) "退出全屏" else "返回"
                    IconButton(hapticClick { if (full) toggleFullscreen() else onBack() }, Modifier.size(48.dp)) {
                        Glyph(if (full) "arrow_back_rounded" else "arrow_back_ios_new_rounded", exitLabel)
                    }
                    Text(playbackTitle, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    IconAction("settings_rounded", "播放设置") { menu = "settings" }
                }
                if (maxHeight >= 168.dp && enabled && !showBuffering && dragging == null) Row(Modifier.align(androidx.compose.ui.BiasAlignment(0f, -.15f)), verticalAlignment = Alignment.CenterVertically) {
                    if (episodic) IconAction("skip_previous_rounded", "上一集", index > 0) { index-- }
                    Spacer(Modifier.width(12.dp))
                    FilledIconButton(hapticClick { togglePlayback() }, modifier = Modifier.size(54.dp), colors = IconButtonDefaults.filledIconButtonColors(containerColor = Color.White.copy(alpha = .18f), contentColor = Color.White)) { Glyph(if (state.completed) "replay_rounded" else if (shouldPlay) "pause_rounded" else "play_arrow_rounded", if (state.completed) "重新播放" else if (shouldPlay) "暂停播放" else "开始播放", size = 38) }
                    Spacer(Modifier.width(12.dp))
                    if (episodic) IconAction("skip_next_rounded", "下一集", index + 1 < detail.episodes.size) { index++ }
                }
            }
            val position = dragging ?: state.position.toFloat().coerceIn(0f, state.duration.toFloat().coerceAtLeast(1f))
            val seek: (Float) -> Unit = { dragging = it }
            val finishSeek: () -> Unit = { val target = dragging; dragging = null; interaction++; if (target != null) action { player.seek(target.toDouble()) } }
            if (feed) {
                val compact = androidx.compose.ui.platform.LocalConfiguration.current.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
                val description = Modifier.align(Alignment.BottomStart).padding(start = 16.dp, end = 84.dp, bottom = 27.dp)
                if ("creator" in source?.capabilities.orEmpty()) VideoAuthorPanel(detail.drama, onCreator, description, glass = true)
                else Column(description.combinedClickable(
                    onClick = hapticClick { nav(Route("detail", detail.drama)) },
                    onDoubleClick = hapticClick { if (!liked) { repo.recommendations.like(detail.drama); liked = true }; likePulse++ },
                ).padding(horizontal = 4.dp, vertical = 6.dp)) {
                    val shadow = LocalTextStyle.current.copy(shadow = androidx.compose.ui.graphics.Shadow(Color.Black, blurRadius = 8f))
                    Text(detail.drama.title, color = Color.White, fontSize = 17.sp, fontWeight = appTextWeight(FontWeight.ExtraBold), maxLines = 1, overflow = TextOverflow.Ellipsis, style = shadow)
                    val caption = when (source?.kind) {
                        "drama" -> "${detail.drama.json.text("category").ifEmpty { "短剧" }} · 第 ${episode?.number ?: 1} 集"
                        "live" -> "直播 · ${source.name}"
                        else -> "视频 · ${source?.name.orEmpty()}"
                    }
                    Text(caption, color = Color.White, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, style = shadow)
                }
                Column(Modifier.align(Alignment.BottomEnd).padding(end = 8.dp, bottom = if (compact) 48.dp else 34.dp), verticalArrangement = Arrangement.spacedBy(if (compact) 8.dp else 20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    FeedAction(if (liked) "favorite_rounded" else "favorite_border_rounded", "喜欢", liked, compact) { repo.recommendations.like(detail.drama); liked = !liked }
                    if (source?.capabilities?.contains("comments") == true) FeedAction("chat_bubble_outline_rounded", "评论", compact = compact, action = onComments)
                    val saved = repo.store.favorites().any { it.id == detail.drama.id }
                    FeedAction(if (saved) "bookmark_rounded" else "bookmark_border_rounded", if (source?.kind == "drama") "追剧" else "收藏", saved, compact) { action { repo.store.favorite(detail.drama) } }
                    if (detail.drama.source == "hongguo") FeedAction("not_interested_rounded", "不喜欢", compact = compact) {
                        action {
                            val disliked = repo.store.list("feedNotInterested").strings() + "${detail.drama.source}:${detail.drama.id}"
                            repo.store.set("feedNotInterested", org.json.JSONArray(disliked.distinct()))
                            repo.recommendations.notInterested(detail.drama)
                            liked = false
                            onNext()
                        }
                    }
                }
                if (state.duration > 0 && source?.kind != "live") {
                    if (source?.feedSeek == true) {
                        LegacySlider(position, seek, finishSeek, state.duration.toFloat(), Modifier.align(Alignment.BottomCenter).padding(horizontal = 16.dp).fillMaxWidth().height(30.dp), feed = true)
                        if (dragging != null) Text("${formatPosition(position.toDouble())} / ${formatPosition(state.duration)}",
                            Modifier.align(Alignment.BottomCenter).padding(bottom = 32.dp).background(Color.Black.copy(alpha = .72f), androidx.compose.foundation.shape.RoundedCornerShape(16.dp)).padding(horizontal = 10.dp, vertical = 5.dp),
                            color = Color.White, fontSize = 12.sp, style = LocalTextStyle.current.copy(fontFeatureSettings = "tnum"))
                    } else Canvas(Modifier.align(Alignment.BottomCenter).padding(start = 16.dp, end = 16.dp, bottom = 12.dp).fillMaxWidth().height(2.dp)) {
                        drawRect(Color.White.copy(alpha = .38f))
                        drawRect(Color.White, size = androidx.compose.ui.geometry.Size(size.width * (state.position / state.duration).toFloat().coerceIn(0f, 1f), size.height))
                    }
                }
                if ((pausedByUser || !state.playing || feedFeedback > 0) && enabled && !showBuffering && maxHeight >= 220.dp) {
                    Box(Modifier.align(Alignment.Center).size(54.dp)
                        .playerGlass(androidx.compose.foundation.shape.CircleShape)
                        .semantics { onClick { touchFeedback(); togglePlayback(); true } }, contentAlignment = Alignment.Center) {
                        CompositionLocalProvider(LocalContentColor provides Color.White) {
                        Glyph(if (shouldPlay) "pause_rounded" else "play_arrow_rounded", if (shouldPlay) "暂停播放" else "开始播放", size = 38)
                        }
                    }
                }
            } else {
                val controlsWidth = maxWidth - 24.dp
                Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().then(if (full) Modifier.navigationBarsPadding() else Modifier).padding(horizontal = 12.dp)) {
                    LegacySlider(
                        position, seek, finishSeek, state.duration.toFloat(), Modifier.fillMaxWidth().height(24.dp),
                        buffered = state.buffered.toFloat(), trackOffsetY = if (full) 0.dp else 4.dp,
                    )
                    Row(Modifier.horizontalScroll(rememberScrollState()).widthIn(min = controlsWidth), verticalAlignment = Alignment.CenterVertically) {
                        Text("${formatPosition(position.toDouble())} / ${formatPosition(state.duration)}", Modifier.widthIn(min = 96.dp).padding(end = 8.dp), fontSize = 12.sp, maxLines = 1, color = Color.White.copy(alpha = .82f), style = LocalTextStyle.current.copy(fontFeatureSettings = "tnum"))
                        Spacer(Modifier.weight(1f))
                        if (full && !localOnly && plan?.optBoolean("local") != true && source?.capabilities?.contains("danmaku") == true) {
                            PlaybackTool(if (danmaku) "关闭弹幕" else "开启弹幕", 42, onClick = { repo.danmaku.value = !danmaku }) { Text(if (danmaku) "弹" else "弹×") }
                        }
                        PlaybackTool("倍速", 50, enabled, { menu = "speed" }) { Text("${speed}x") }
                        if (plan?.optBoolean("local") == false && plan?.array("qualities")?.length()?.let { it > 0 } == true) PlaybackTool("清晰度", 52, enabled, { menu = "quality" }) {
                            Text(if (plan?.optBoolean("local") == true) "本地原画" else if (quality == 0) "自动" else "${quality}P", maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        if (full && episodic) PlaybackTool("选集", enabled = enabled, onClick = { menu = "episodes" }) { Glyph("grid_view_rounded", size = 22) }
                        PlaybackTool(if (full) "退出全屏" else "全屏", enabled = enabled, onClick = toggleFullscreen) {
                            Glyph(if (full) "fullscreen_exit_rounded" else "fullscreen_rounded", size = 22)
                        }
                    }
                }
            }
        }
        if (!feed && dragging != null) Text("${formatPosition(dragging!!.toDouble())} / ${formatPosition(state.duration)}",
            Modifier.align(Alignment.Center).background(Color.Black.copy(alpha = .78f), androidx.compose.foundation.shape.RoundedCornerShape(12.dp)).padding(horizontal = 20.dp, vertical = 12.dp),
            color = Color.White, style = MaterialTheme.typography.titleMedium.copy(fontFeatureSettings = "tnum"))
        if (!feed && full && !television && (locked && lockVisible || !locked && controlsVisible)) {
            Box(Modifier.align(Alignment.CenterStart).padding(12.dp)) {
                PlaybackTool(if (locked) "解锁控制" else "锁定控制", onClick = {
                    locked = !locked; lockVisible = true; interaction++; setClean(locked)
                }) { Glyph(if (locked) "lock_rounded" else "lock_open_rounded", size = 22) }
            }
        }
        val portraitBoost = boost && full && state.width > 0 && state.width < state.height
        val topLetterbox = if (portraitBoost) videoTop else 0.dp
        val feedback = if (boost) "${holdSpeed.toInt()} 倍速 · 松开恢复" else hint
        if (feedback.isNotEmpty() && !(boost && feed) && (!portraitBoost || topLetterbox >= 48.dp)) {
            Box(
                if (portraitBoost) Modifier.align(Alignment.TopCenter).height(topLetterbox)
                else Modifier.align(androidx.compose.ui.BiasAlignment(0f, -.5f)).padding(16.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(feedback, Modifier.background(Color.Black.copy(alpha = if (boost) .18f else .87f), androidx.compose.foundation.shape.RoundedCornerShape(10.dp)).padding(horizontal = 16.dp, vertical = 10.dp), color = Color.White)
            }
        }
        val showLoading = if (feed) feedWaiting && feedLoadingVisible else loading || showBuffering && !state.completed
        if (showLoading && commentsProgress == null && playbackFailure == null) Box(
            Modifier.matchParentSize().then(if (!feed && loading) Modifier.background(Color.Black.copy(alpha = .78f)) else Modifier),
            contentAlignment = Alignment.Center,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                LoadingRing()
                if (loading) {
                    Spacer(Modifier.height(16.dp))
                    Text(loadingLabel, color = Color.White)
                }
            }
        }
        if (playbackFailure != null && commentsProgress == null) Box(Modifier.matchParentSize().background(Color.Black.copy(alpha = .9f))) {
            CompositionLocalProvider(LocalContentColor provides Color.White) {
                StatusPanel("暂时无法播放", playbackFailure, if (localOnly || localPlan != null) "重试本地播放" else "重试播放",
                    { loadingLabel = "正在准备播放"; reload++ }, icon = "play_disabled_rounded")
            }
        }
        if (showLike && !clean && !boost && commentsProgress == null) Glyph("favorite_rounded", modifier = Modifier.align(Alignment.Center).scale(likeScale.value),
            color = Color(0xffff4081).copy(alpha = .92f), size = 104)
        if ((loading || failure != null) && full && !television && !feed) {
            Row(detailToolbar, verticalAlignment = Alignment.CenterVertically) {
                CompositionLocalProvider(LocalContentColor provides Color.White) {
                    IconAction("arrow_back_rounded", "退出全屏", action = toggleFullscreen)
                    Spacer(Modifier.weight(1f))
                    if (episodic) TextButton(hapticClick { menu = "episodes" }) { Text("选集") }
                }
            }
        }
    }
    if (menu in setOf("episodes", "speed", "quality", "settings")) {
        PlaybackMenu(
            menu, detail.episodes, index, speed, quality,
            plan?.array("qualities")?.let { q -> (0 until q.length()).map { q.optInt(it) } }.orEmpty(),
            plan?.optInt("quality") ?: 0, plan?.optBoolean("local") == true,
            repo.store.favorites().any { it.id == detail.drama.id }, source?.kind == "drama",
            preferences.optBoolean("preload", true), preferences.optBoolean("autoAdvance", true),
            preloadStatus, television, scope, onDismiss = { menu = ""; rootFocus.requestFocus() },
            onEpisode = { index = it },
            onChange = { key, value ->
                val setting = if (key == "quality" && feed) "homeQuality" else key
                repo.store.set("playback", repo.store.json("playback").put(setting, value))
                if (key == "speed") { speed = value as Double; player.rate(speed) }
                if (key == "quality") {
                    quality = value as Int
                    if (plan?.optBoolean("local") != true) playbackQuality = quality
                }
            },
            onFavorite = { repo.store.favorite(detail.drama) },
            feed = feed, episodic = episodic,
        )
    }
    if (menu == "devices") LanDevicesDialog(onDismiss = { menu = "" }, onConnected = { action { repo.lan.playback?.let { repo.lan.sendPlayback(it, false) }; menu = "" } })
}

internal fun danmakuPosition(position: Double, elapsedSeconds: Double, playing: Boolean, speed: Double): Double =
    position + if (playing) elapsedSeconds.coerceIn(0.0, .5) * speed else 0.0

internal class DanmakuFlight {
    internal data class Bullet(val text: String, val launchedAt: Double)

    private var rows: List<Pair<Double, String>>? = null
    private var next = 0
    private var frame = 0L
    private var running = false
    private var rate = 1.0
    private val lanes = arrayOfNulls<Bullet>(4)
    private var travel = 0.0

    fun draw(
        rows: List<Pair<Double, String>>, position: Double, frame: Long, running: Boolean, speed: Double,
        render: (lane: Int, text: String, fraction: Float) -> Unit,
    ) {
        if (this.running && running) travel += ((frame - this.frame) / 1e9).coerceIn(0.0, .05) * rate
        this.frame = frame
        this.running = running
        rate = speed
        if (this.rows !== rows) {
            this.rows = rows
            next = rows.indexOfFirst { it.first >= position }.takeIf { it >= 0 } ?: rows.size
        }
        for (lane in lanes.indices) {
            val bullet = lanes[lane] ?: continue
            if (travel - bullet.launchedAt >= 6.0) lanes[lane] = null
        }
        while (running && next < rows.size && rows[next].first <= position) {
            val lane = lanes.indexOfFirst { it == null }
            val text = rows[next++].second
            if (lane >= 0) lanes[lane] = Bullet(text, travel)
        }
        for (lane in lanes.indices) {
            val bullet = lanes[lane] ?: continue
            render(lane, bullet.text, ((travel - bullet.launchedAt) / 6.0).toFloat())
        }
    }
}

@Composable
fun DanmakuOverlay(drama: Drama, episode: Episode, state: PlaybackState, speed: Double = 1.0) {
    val repo = LocalRepository.current
    val window = repo.source(drama.source)?.danmakuWindowMs ?: 32_000
    val page = ((state.position * 1000).toLong() / window) * window
    var rows by remember(drama.id, episode.id) { mutableStateOf(emptyList<Pair<Double, String>>()) }
    val message = LocalMessage.current
    LaunchedEffect(drama.id, episode.id, page) {
        try { rows = repo.runtime.execute(drama.source, "danmaku", obj("drama" to drama.json, "chapter" to episode.json, "positionMs" to page)).array("items").objects().take(2000)
            .map { it.optLong("positionMs") / 1000.0 to it.text("text").take(120) }.sortedBy { it.first } }
        catch (cancel: CancellationException) { throw cancel } catch (_: Exception) { message("弹幕暂时无法加载，视频播放不受影响") }
    }
    val density = androidx.compose.ui.platform.LocalDensity.current
    val paint = remember(density) { android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
        color = android.graphics.Color.WHITE; textSize = with(density) { 16.sp.toPx() }
        setShadowLayer(with(density) { 2.dp.toPx() }, 0f, 0f, android.graphics.Color.BLACK)
    } }
    val running = state.playing && !state.buffering
    val flight = remember(drama.id, episode.id, state.positionRevision) { DanmakuFlight() }
    val sampledAt = remember(state.position, state.positionRevision, running) { System.nanoTime() }
    var frame by remember { mutableLongStateOf(sampledAt) }
    LaunchedEffect(running) {
        if (running) while (isActive) withFrameNanos { frame = System.nanoTime() }
    }
    Canvas(Modifier.fillMaxSize()) {
        val now = frame
        val position = danmakuPosition(state.position, (now - sampledAt) / 1e9, running, speed)
        drawContext.canvas.save()
        drawContext.canvas.clipRect(0f, 0f, size.width, size.height)
        flight.draw(rows, position, now, running, speed) { lane, text, fraction ->
            val x = size.width - fraction * (size.width + paint.measureText(text))
            drawContext.canvas.nativeCanvas.drawText(text, x, 12.dp.toPx() + paint.textSize + lane * 30.dp.toPx(), paint)
        }
        drawContext.canvas.restore()
    }
}
