package com.real.drama.compose

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun TelevisionEpisodeGrid(episodes: List<Episode>, current: Int, choose: (Int) -> Unit) {
    val grid = rememberLazyGridState(initialFirstVisibleItemIndex = current.coerceAtLeast(0))
    val colors = MaterialTheme.colorScheme
    BoxWithConstraints(Modifier.fillMaxSize()) {
        LazyVerticalGrid(
            GridCells.Fixed(((maxWidth.value - 12) / 96).toInt().coerceIn(1, 8)),
            state = grid, contentPadding = PaddingValues(6.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            itemsIndexed(episodes, key = { _, episode -> episode.number }) { index, episode ->
                val focus = remember { FocusRequester() }; var focused by remember { mutableStateOf(false) }
                LaunchedEffect(Unit) { if (index == current) focus.requestFocus() }
                val selected = index == current
                Surface(onClick = hapticClick { choose(index) }, modifier = Modifier.height(64.dp).focusRequester(focus).onFocusChanged { focused = it.isFocused },
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(14.dp),
                    color = when { selected -> colors.primaryContainer; focused -> colors.surfaceContainerHighest; else -> Color.Transparent },
                    contentColor = colors.onSurface,
                    border = BorderStroke(2.dp, if (focused || selected) colors.primary else colors.outlineVariant)) {
                    Row(Modifier.fillMaxSize().padding(4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
                        Text("${episode.number}", fontSize = 20.sp, fontWeight = appTextWeight(if (selected) FontWeight.Bold else FontWeight.Medium), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (episode.json.optBoolean("vip")) { Spacer(Modifier.width(4.dp)); Glyph("workspace_premium_rounded", "VIP 试看", color = colors.tertiary, size = 18) }
                    }
                }
            }
        }
    }
}

@Composable
fun BoxScope.TelevisionPlayerControls(title: String, state: PlaybackState, previous: Boolean, next: Boolean, episodic: Boolean, onBack: () -> Unit, onToggle: () -> Unit, onPrevious: () -> Unit, onNext: () -> Unit, onEpisodes: () -> Unit, onSettings: () -> Unit, onSeek: (Double) -> Unit) {
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xCC000000), Color.Transparent, Color(0xEE000000)))))
    Row(Modifier.align(Alignment.TopCenter).fillMaxWidth().padding(top = 12.dp, start = 24.dp, end = 24.dp), verticalAlignment = Alignment.CenterVertically) {
        TelevisionNavigationButton("返回", "arrow_back_rounded", fill = false, onClick = onBack); Spacer(Modifier.width(16.dp))
        Text(title, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 22.sp, fontWeight = appTextWeight(FontWeight.SemiBold), color = Color.White)
    }
    Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(start = 28.dp, end = 28.dp, bottom = 18.dp)) {
        Column(Modifier.onPreviewKeyEvent { event -> if (event.type == KeyEventType.KeyDown && event.key in listOf(Key.DirectionLeft, Key.DirectionRight)) { onSeek((state.position + if (event.key == Key.DirectionLeft) -10 else 10).coerceIn(0.0, state.duration.coerceAtLeast(0.0))); true } else false }.hapticClickable(onClick = onToggle).padding(4.dp)) {
            Box { LinearProgressIndicator(progress = { (state.buffered / state.duration.coerceAtLeast(1.0)).toFloat().coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth().height(5.dp), color = Color.White.copy(alpha = .38f), trackColor = Color.White.copy(alpha = .24f)); LinearProgressIndicator(progress = { (state.position / state.duration.coerceAtLeast(1.0)).toFloat().coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth().height(5.dp), trackColor = Color.Transparent) }
            Row(Modifier.fillMaxWidth()) { Text("${formatPosition(state.position)} / ${formatPosition(state.duration)}", color = Color.White, fontSize = 16.sp); Spacer(Modifier.weight(1f)); Text("左右快进 · 确认暂停", color = Color.White.copy(alpha = .7f), fontSize = 14.sp) }
        }
        Spacer(Modifier.height(8.dp))
        Row(Modifier.horizontalScroll(rememberScrollState())) {
            if (episodic) TelevisionNavigationButton("上一集", "skip_previous_rounded", fill = false, enabled = previous, onClick = onPrevious)
            TelevisionNavigationButton(if (state.completed) "重播" else if (state.playing) "暂停" else "播放", if (state.completed) "replay_rounded" else if (state.playing) "pause_rounded" else "play_arrow_rounded", autofocus = true, fill = false, onClick = onToggle)
            if (episodic) TelevisionNavigationButton("下一集", "skip_next_rounded", fill = false, enabled = next, onClick = onNext)
            if (episodic) TelevisionNavigationButton("选集", "grid_view_rounded", fill = false, onClick = onEpisodes)
            TelevisionNavigationButton("播放设置", "tune_rounded", fill = false, onClick = onSettings)
        }
        Spacer(Modifier.height(6.dp)); Text("控制条隐藏后：左右快进 10 秒，上下或确认键显示控制条", color = Color.White.copy(alpha = .7f), fontSize = 13.sp)
    }
}
