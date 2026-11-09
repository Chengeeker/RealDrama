package com.real.drama.compose

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

private val menuSpeeds = listOf(.5, .75, 1.0, 1.25, 1.5, 2.0, 3.0)

@Composable
fun PlaybackMenu(
    section: String, episodes: List<Episode>, index: Int, speed: Double, quality: Int,
    availableQualities: List<Int>, actualQuality: Int, local: Boolean, favorite: Boolean, series: Boolean,
    preload: Boolean, autoAdvance: Boolean, preloadStatus: String, television: Boolean, scope: CoroutineScope,
    onDismiss: () -> Unit, onEpisode: (Int) -> Unit, onChange: suspend (String, Any) -> Unit,
    onFavorite: suspend () -> Unit,
    feed: Boolean = false, episodic: Boolean = episodes.size > 1 || series,
) {
    val screen = LocalConfiguration.current
    val colors = MaterialTheme.colorScheme
    val qualities = (listOf(0) + availableQualities.filter { it > 0 }).distinct()
    val message = LocalMessage.current
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf(false) }
    fun run(block: suspend () -> Unit) {
        if (busy) return
        busy = true
        error = false
        if (television) onDismiss()
        scope.launch {
            try { block() }
            catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) {
                if (television) message("播放偏好未能保存，请重试") else error = true
            }
            finally { busy = false }
        }
    }
    fun choose(i: Int) { onEpisode(i); onDismiss() }
    val episodesTitle = "选集 · 共 ${episodes.size} 集"
    val favoriteLabel = if (series) {
        if (favorite) "取消追剧" else "加入追剧"
    } else if (favorite) "取消收藏" else "加入收藏"
    val favoriteIcon = if (favorite) "bookmark_rounded" else "bookmark_border_rounded"

    if (television) {
        Dialog(onDismiss, DialogProperties(usePlatformDefaultWidth = false)) {
            FlutterDialogDim()
            Surface(
                Modifier.padding(horizontal = 40.dp, vertical = 24.dp).width(if (section == "episodes") 748.dp else 688.dp),
                shape = RoundedCornerShape(28.dp), color = colors.surfaceContainerHigh,
            ) {
                Column(Modifier.padding(horizontal = 24.dp).padding(top = 24.dp, bottom = 24.dp)) {
                    Text(if (section == "episodes") episodesTitle else "播放设置", style = MaterialTheme.typography.headlineSmall)
                    Spacer(Modifier.height(16.dp))
                    Box(Modifier.weight(1f, fill = false)) {
                        if (section == "episodes") {
                            Box(Modifier.width(700.dp).height(screen.screenHeightDp.dp * .55f)) {
                                TelevisionEpisodeGrid(episodes, index, ::choose)
                            }
                        } else Column(Modifier.width(640.dp).verticalScroll(rememberScrollState())) {
                            Text("倍速", fontSize = 18.sp)
                            Spacer(Modifier.height(8.dp))
                            MenuChoices {
                                menuSpeeds.forEach { value ->
                                    TelevisionMenuButton("${value}x", selected = speed == value, autofocus = speed == value) {
                                        run { onChange("speed", value) }
                                    }
                                }
                            }
                            Spacer(Modifier.height(20.dp))
                            Text("清晰度", fontSize = 18.sp)
                            Spacer(Modifier.height(8.dp))
                            MenuChoices {
                                qualities.forEach { value ->
                                    TelevisionMenuButton(if (value == 0) "自动（优先高清）" else "${value}P", selected = quality == value) {
                                        run { onChange("quality", value) }
                                    }
                                }
                            }
                            Spacer(Modifier.height(20.dp))
                            if (episodic) TelevisionMenuButton(if (autoAdvance) "自动连播：开" else "自动连播：关") { run { onChange("autoAdvance", !autoAdvance) } }
                            Spacer(Modifier.height(16.dp))
                            if (episodic && !local) TelevisionMenuButton(if (preload) "下一集预加载：开" else "下一集预加载：关") { run { onChange("preload", !preload) } }
                            Spacer(Modifier.height(8.dp))
                            if (episodic && !local) Text(preloadStatus)
                            Spacer(Modifier.height(20.dp))
                            TelevisionMenuButton(favoriteLabel, icon = favoriteIcon) { run(onFavorite) }
                        }
                    }
                    Spacer(Modifier.height(24.dp))
                    TextButton(hapticClick(onDismiss), Modifier.align(Alignment.End).heightIn(min = 48.dp)) {
                        Text("返回播放", fontSize = 17.sp)
                    }
                }
            }
        }
        return
    }

    Dialog(onDismiss, DialogProperties(usePlatformDefaultWidth = false)) {
        FlutterDialogDim()
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val landscape = maxWidth > maxHeight
            val width = if (landscape) minOf(440.dp, maxWidth * .6f) else 600.dp
            val height = if (landscape) maxHeight else maxHeight * .72f
            Box(Modifier.matchParentSize().pointerInput(onDismiss) { detectTapGestures { onDismiss() } })
            Surface(
                Modifier.align(if (landscape) Alignment.CenterEnd else Alignment.BottomCenter)
                    .padding(12.dp).width(width).then(if (section in setOf("speed", "quality")) Modifier.heightIn(max = height) else Modifier.height(height))
                    .pointerInput(Unit) { detectTapGestures {} },
                shape = RoundedCornerShape(28.dp), color = colors.surface,
            ) {
                Column {
                    Row(Modifier.padding(start = 18.dp, top = 8.dp, end = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        val title = when (section) {
                            "episodes" -> episodesTitle
                            "speed" -> "播放倍速"
                            "quality" -> "清晰度"
                            else -> "播放设置"
                        }
                        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                        IconAction("close_rounded", "关闭菜单", action = onDismiss)
                    }
                    if (busy) LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp))
                    if (error) Text("未能保存设置，请检查存储空间后重试。", Modifier.padding(horizontal = 18.dp, vertical = 8.dp), color = Color(0xffffb4a8))
                    if (section == "episodes") {
                        Box(Modifier.weight(1f)) { EpisodeGrid(episodes, index, compact = false, onSelect = ::choose) }
                    } else Column(Modifier.weight(1f, fill = section == "settings").verticalScroll(rememberScrollState()).padding(start = 18.dp, top = 4.dp, end = 18.dp, bottom = 20.dp)) {
                        if (section == "speed" || section == "settings") {
                            Text("倍速")
                            Spacer(Modifier.height(8.dp))
                            MenuChoices {
                                menuSpeeds.forEach { value ->
                                    LegacyChip(speed == value, { run { onChange("speed", value); if (section == "speed") onDismiss() } }, label = { Text("${value}x") }, enabled = !busy)
                                }
                            }
                            Spacer(Modifier.height(20.dp))
                        }
                        if (section == "quality" || section == "settings") {
                            Text("清晰度")
                            Spacer(Modifier.height(8.dp))
                            Text(
                                when {
                                    local -> "本集正在播放本地原画，画质偏好用于后续在线播放。"
                                    actualQuality > 0 -> "当前播放 ${actualQuality}P"
                                    else -> "使用源站可用画质"
                                },
                                fontSize = 13.sp, lineHeight = 19.5.sp, color = colors.onSurfaceVariant,
                            )
                            Spacer(Modifier.height(8.dp))
                            MenuChoices {
                                qualities.forEach { value ->
                                    LegacyChip(quality == value, { run { onChange("quality", value); if (section == "quality") onDismiss() } },
                                        label = { Text(if (value == 0) "自动（优先最高画质）" else "${value}P") }, enabled = !busy)
                                }
                            }
                            if (quality !in qualities) Text("已保存 ${quality}P 偏好，本集暂无此画质。", Modifier.padding(top = 8.dp), fontSize = 13.sp, lineHeight = 19.5.sp, color = colors.onSurfaceVariant)
                            Spacer(Modifier.height(20.dp))
                        }
                        if (section == "settings") {
                            if (episodic && !local) SwitchRow("下一集预加载", preload, preloadStatus, enabled = !busy, horizontal = 0) { value -> run { onChange("preload", value) } }
                            Spacer(Modifier.height(8.dp))
                            if (episodic || feed) SwitchRow("自动连播", autoAdvance, "关闭后，播放结束停在当前视频", enabled = !busy, horizontal = 0) { value -> run { onChange("autoAdvance", value) } }
                            Spacer(Modifier.height(8.dp))
                            LegacyOutlinedButton({ run(onFavorite) }, enabled = !busy, contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) {
                                Glyph(favoriteIcon, size = 18)
                                Spacer(Modifier.width(8.dp))
                                Text(favoriteLabel)
                            }
                            Spacer(Modifier.height(20.dp))
                            Text(if (feed) "上下滑切换视频，轻点暂停，双击喜欢；清屏时先轻点恢复界面。长按临时 2 倍速，松开恢复。" else "轻点显示控制；双击中间播放或暂停，双击两侧快退或快进 10 秒。横滑定位，左侧上下调亮度，右侧调音量；长按临时 2 倍速，松开恢复。全屏可锁定控制。",
                                fontSize = 13.sp, lineHeight = 20.8.sp, color = colors.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MenuChoices(content: @Composable FlowRowScope.() -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp), content = content)
}

@Composable
private fun TelevisionMenuButton(label: String, selected: Boolean = false, autofocus: Boolean = false, icon: String? = null, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    val colors = MaterialTheme.colorScheme
    LaunchedEffect(autofocus) { if (autofocus) focus.requestFocus() }
    Surface(
        onClick = onClick,
        modifier = Modifier.focusRequester(focus).onFocusChanged { focused = it.isFocused },
        shape = RoundedCornerShape(14.dp),
        color = if (selected || focused) colors.primaryContainer else Color.Transparent,
        contentColor = colors.onSurface,
        border = if (selected || focused) BorderStroke(3.dp, colors.primary) else null,
    ) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            if (icon != null) { Glyph(icon, size = 22); Spacer(Modifier.width(8.dp)) }
            Text(label, fontSize = 17.sp)
        }
    }
}
