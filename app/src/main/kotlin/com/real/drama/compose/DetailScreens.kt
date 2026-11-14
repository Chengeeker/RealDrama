package com.real.drama.compose

import android.app.Activity
import android.content.pm.ActivityInfo
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import kotlinx.coroutines.*
import org.json.JSONObject

internal fun playerSections(kind: String, count: Int, capabilities: Set<String>, local: Boolean, canDownload: Boolean): List<Pair<String, String>> = buildList {
    if (kind == "drama" || count > 1) add("episodes" to if (kind == "video") "分集" else "选集")
    add("synopsis" to "简介")
    if (!local && "comments" in capabilities) add("comments" to "评论")
    if (!local && "creator" in capabilities) add("creator" to "作者")
    if (!local && canDownload && "download" in capabilities) add("download" to "下载")
}

@Composable
fun PlayerScreen(drama: Drama, back: () -> Unit, payload: JSONObject = JSONObject(), suppliedDetail: Detail? = null, localOnly: Boolean = false, localPlan: JSONObject? = null, mediaId: String = "") {
    val repo = LocalRepository.current; val action = rememberAction(); val nav = LocalNavigate.current
    val handoff = payload.text("handoff")
    val incoming = remember(handoff) { repo.lan.prepared?.takeIf { handoff.isNotEmpty() && it.id == handoff } }
    var detail by remember(drama.id) { mutableStateOf(incoming?.detail ?: suppliedDetail) }
    var error by remember { mutableStateOf<String?>(null) }
    var generation by remember { mutableIntStateOf(0) }
    val television = televisionMode()
    var fullscreen by remember { mutableStateOf(false) }
    val full = television || fullscreen
    var tab by remember(drama.id) { mutableStateOf("") }
    var accepted by remember(drama.id) { mutableStateOf(incoming != null || localOnly || payload.optBoolean("vipAccepted")) }
    var pending by remember { mutableStateOf<Int?>(null) }
    var index by remember(drama.id) { mutableIntStateOf(incoming?.index ?: if (suppliedDetail != null) payload.optInt("index", 0).coerceIn(0, suppliedDetail.episodes.lastIndex.coerceAtLeast(0)) else 0) }
    LaunchedEffect(drama.id, generation) {
        if (suppliedDetail != null || incoming != null) return@LaunchedEffect
        error = null
        try { val loaded = repo.detail(drama, generation > 0); if (detail == null) index = if (payload.has("index")) payload.getInt("index").coerceIn(0, loaded.episodes.lastIndex.coerceAtLeast(0)) else resumeEpisodeIndex(loaded.episodes, repo.store.watch(drama)); detail = loaded; if (!accepted) { if (loaded.episodes.getOrNull(index)?.json?.optBoolean("vip") == true && drama.source != "dsd") pending = index else accepted = true } }
        catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { error = e.message }
    }
    val source = repo.source(drama.source)
    BoxWithConstraints(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface).then(if (full) Modifier else Modifier.systemBarsPadding())) {
        val playerHeight = minOf(maxWidth * 9 / 16, maxHeight * .56f)
        val wide = maxWidth >= 840.dp || maxWidth > maxHeight * 1.3f
        val panelWidth = if (maxWidth >= 840.dp) 312.dp else 210.dp
        androidx.compose.ui.layout.Layout(modifier = Modifier.fillMaxSize().clipToBounds(), content = {
            val loaded = detail
            if (loaded == null) {
                Column { Row { IconAction("arrow_back_rounded", "返回", action = back) }; if (error != null) StatusPanel("暂时无法播放", error!!, onRetry = { generation++ }) else Loading() }
            } else if (loaded.episodes.isEmpty()) { StatusPanel("暂时无法播放", "暂时没有可播放的集数", onRetry = { generation++ })
            } else if (!accepted) { Loading()
            } else {
                PlayerPane(loaded, index, initialPosition = if (payload.optBoolean("resume", true)) null else 0.0, active = LocalScreenActive.current, handoff = incoming, localOnly = localOnly, localPlan = localPlan, mediaId = mediaId, selectedIndex = index, onIndexChanged = { index = it },
                    modifier = Modifier.fillMaxSize().clipToBounds(), onBack = back,
                    onFullScreen = { fullscreen = it }, onCreator = { nav(Route("creator", loaded.drama)) })
                Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface).clipToBounds()) {
                if (!full) {
                    val tabs = playerSections(source?.kind.orEmpty(), loaded.episodes.size, source?.capabilities.orEmpty().toSet(), localOnly || localPlan != null, repo.store.canDownload)
                    val selectedTab = tab.takeIf { key -> tabs.any { it.first == key } } ?: tabs.first().first
                    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp).height(48.dp)) {
                        tabs.forEach { (key, label) -> Column(Modifier.widthIn(min = 56.dp).fillMaxHeight().hapticClickable(role = androidx.compose.ui.semantics.Role.Tab) { tab = key }.padding(horizontal = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) { Text(label, fontSize = 13.sp, fontWeight = appTextWeight(if (selectedTab == key) FontWeight.Bold else FontWeight.Medium), color = if (selectedTab == key) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) }
                            Box(Modifier.width(24.dp).height(2.dp).background(if (selectedTab == key) MaterialTheme.colorScheme.primary else androidx.compose.ui.graphics.Color.Transparent))
                        } }
                    }
                    Box(Modifier.weight(1f).padding(start = 8.dp, top = 6.dp, end = 8.dp, bottom = 8.dp).clip(RoundedCornerShape(8.dp))) {
                        when (selectedTab) {
                            "episodes" -> EpisodeGrid(loaded.episodes, index, compact = !wide, onSelect = { index = it })
                            "creator" -> CreatorScreen(loaded.drama, back, embedded = true)
                            "comments" -> CommentsContent(loaded.drama)
                            "download" -> DownloadPicker(loaded)
                            else -> Synopsis(loaded)
                        }
                    }
                }
                }
            }
        }) { children, constraints ->
            val width = constraints.maxWidth; val height = constraints.maxHeight
            val panel = if (full || children.size < 2) 0 else if (wide) panelWidth.roundToPx().coerceAtMost(width) else (height - playerHeight.roundToPx()).coerceAtLeast(0)
            val video = children.first().measure(androidx.compose.ui.unit.Constraints.fixed(if (wide && !full) width - panel else width, if (!wide && !full) height - panel else height))
            val side = children.getOrNull(1)?.measure(androidx.compose.ui.unit.Constraints.fixed(if (wide) panel else width, if (wide) height else panel))
            layout(width, height) { video.placeRelative(0, 0); if (side != null && !full) side.placeRelative(if (wide) width - panel else 0, if (wide) 0 else height - panel) }
        }
    }
    if (pending != null) VipDialog(onDismiss = { pending = null; back() }, onConfirm = { pending = null; accepted = true })
}

@Composable
fun EpisodeGrid(episodes: List<Episode>, current: Int = -1, selected: Set<Int>? = null, compact: Boolean = true, onSelect: (Int) -> Unit) {
    val grid = rememberLazyGridState()
    var jump by remember { mutableStateOf(false) }; var number by remember { mutableStateOf("") }; var error by remember { mutableStateOf(false) }
    var page by remember { mutableIntStateOf((current.coerceAtLeast(0) / 50).coerceAtMost(((episodes.size - 1).coerceAtLeast(0)) / 50)) }
    val pageCount = (episodes.size + 49) / 50
    val start = if (compact) 0 else page * 50
    val visible = if (compact) episodes else episodes.drop(start).take(50)
    fun locate(index: Int) { if (!compact) page = index / 50; grid.requestScrollToItem(if (compact) index else index % 50) }
    LaunchedEffect(current) { if (current in episodes.indices) locate(current) }
    Column(Modifier.fillMaxSize()) {
        if (!compact) Column(Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("选集 · ${episodes.size} 集", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                if (current in episodes.indices) TextButton(hapticClick { locate(current) }) { Text("定位当前") }
                IconAction("pin_outlined", "跳转集数", episodes.isNotEmpty()) { jump = true }
            }
            if (pageCount > 1) Row(verticalAlignment = Alignment.CenterVertically) {
                IconAction("chevron_left_rounded", "上一组选集", page > 0) { locate((page - 1) * 50) }
                Box(Modifier.weight(1f)) { SettingsDropdown(page.toString(), (0 until pageCount).map { it.toString() to "第 ${episodes[it * 50].number}–${episodes[minOf(it * 50 + 49, episodes.lastIndex)].number} 集" }, filled = false) { locate(it.toInt() * 50) } }
                IconAction("chevron_right_rounded", "下一组选集", page + 1 < pageCount) { locate((page + 1) * 50) }
            }
        }
        if (compact && pageCount > 1) LazyRow(Modifier.height(34.dp), contentPadding = PaddingValues(start = 4.dp, end = 4.dp, top = 2.dp, bottom = 3.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            items(pageCount) { index ->
                val active = (grid.firstVisibleItemIndex / 50) == index
                Surface(onClick = hapticClick { locate(index * 50) }, shape = RoundedCornerShape(10.dp), color = if (active) MaterialTheme.colorScheme.secondaryContainer else androidx.compose.ui.graphics.Color.Transparent, border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
                    Text("${episodes[index * 50].number}–${episodes[minOf(index * 50 + 49, episodes.lastIndex)].number}", Modifier.padding(horizontal = 10.dp, vertical = 4.dp), fontSize = 12.sp)
                }
            }
        }
        BoxWithConstraints(Modifier.weight(1f)) {
            val scaled = with(LocalDensity.current) { (if (compact) 14.sp else 20.sp).toDp().value }
            val television = televisionMode()
            val digits = visible.maxOfOrNull { it.number.toString().length } ?: 1
            val columns = if (compact) ((maxWidth.value - 12) / maxOf(40f, scaled * digits * .62f + 22)).toInt().coerceIn(5, if (television) 12 else 10) else ((maxWidth.value - 36) / maxOf(if (television) 100f else 82f, scaled * digits * .65f + 40)).toInt().coerceIn(1, 12)
            LazyVerticalGrid(GridCells.Fixed(columns), state = grid, contentPadding = if (compact) PaddingValues(start = 4.dp, top = 4.dp, end = 4.dp, bottom = 12.dp) else PaddingValues(start = 18.dp, top = 2.dp, end = 18.dp, bottom = 18.dp), horizontalArrangement = Arrangement.spacedBy(if (compact) 6.dp else 8.dp), verticalArrangement = Arrangement.spacedBy(if (compact) 6.dp else 8.dp)) {
                itemsIndexed(visible) { offset, ep ->
                    val index = start + offset; val chosen = selected?.contains(index) ?: (current == index)
                    var focused by remember { mutableStateOf(false) }
                    Surface(onClick = hapticClick { onSelect(index) }, shape = RoundedCornerShape(if (compact) 8.dp else 14.dp), color = when { chosen -> MaterialTheme.colorScheme.primaryContainer; focused -> MaterialTheme.colorScheme.surfaceContainerHighest; else -> androidx.compose.ui.graphics.Color.Transparent },
                        border = BorderStroke(if (compact) 1.2.dp else 2.dp, if (chosen || focused) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant), modifier = Modifier.height(if (compact) maxOf(34f, scaled + 18).dp else maxOf(56f, scaled + 30).dp).onFocusChanged { focused = it.hasFocus }.semantics { contentDescription = "第 ${ep.number} 集" + if (ep.json.optBoolean("vip")) "，VIP 试看" else "" }) {
                        Row(horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                            Text(ep.number.toString(), color = MaterialTheme.colorScheme.onSurface, fontSize = if (compact) 14.sp else 20.sp, fontWeight = appTextWeight(if (chosen) FontWeight.Bold else FontWeight.Medium))
                            if (ep.json.optBoolean("vip")) { Spacer(Modifier.width(if (compact) 2.dp else 4.dp)); Glyph("workspace_premium_rounded", size = if (compact) 15 else 18, color = MaterialTheme.colorScheme.tertiary) }
                        }
                    }
                }
            }
        }
    }
    if (jump) LegacyAlertDialog(onDismissRequest = { jump = false }, title = { Text("跳转到指定集数") }, text = { OutlinedTextField(number, { number = it.filter(Char::isDigit); error = false }, label = { Text("集数") }, isError = error, supportingText = { if (error) Text("没有找到这一集，请输入已有集数") }, keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number), textStyle = MaterialTheme.typography.bodyLarge, colors = legacyTextFieldColors(), shape = RoundedCornerShape(16.dp)) }, confirmButton = { Button(hapticClick { val target = episodes.indexOfFirst { it.number == number.toIntOrNull() }; if (target < 0) error = true else { jump = false; locate(target) } }) { Text("定位") } }, dismissButton = { TextButton(hapticClick { jump = false }) { Text("取消") } })
}

@Composable
fun Synopsis(detail: Detail) {
    val repo = LocalRepository.current; val drama = detail.drama
    val action = rememberAction(); val nav = LocalNavigate.current
    LazyColumn(contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item { Row {
            Cover(drama, Modifier.size(82.dp, 123.dp)); Spacer(Modifier.width(12.dp))
            Column { Text(drama.title, style = MaterialTheme.typography.titleMedium, fontWeight = appTextWeight(FontWeight.Bold))
                Spacer(Modifier.height(6.dp)); Text(dramaMeta(drama, repo.source(drama.source)?.name, true), color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (dramaMetrics(drama).isNotEmpty()) { Spacer(Modifier.height(8.dp)); Text(dramaMetrics(drama), color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        } }
        item { FollowButton(drama) }
        item { FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) { drama.json.array("tags").strings().take(12).forEach { SuggestionChip({}, label = { Text(it) }) } } }
        item { Text(drama.description.ifBlank { "暂无简介" }, lineHeight = 22.sp) }
        if (detail.warning.isNotEmpty()) item { Text(detail.warning, color = MaterialTheme.colorScheme.error) }
    }
}

@Composable
fun FollowButton(drama: Drama, compact: Boolean = true) {
    val repo = LocalRepository.current; val action = rememberAction()
    val saved = repo.store.favorites().any { it.id == drama.id }; var menu by remember { mutableStateOf(false) }
    val series = repo.source(drama.source)?.kind == "drama"
    Box {
        FilledTonalButton(hapticClick { if (series) menu = true else action { repo.store.favorite(drama) } }, modifier = Modifier.heightIn(min = if (compact) 36.dp else 48.dp), shape = if (series) RoundedCornerShape(if (compact) 10.dp else 12.dp) else RoundedCornerShape(50), colors = ButtonDefaults.filledTonalButtonColors(containerColor = if (series && !saved) MaterialTheme.colorScheme.surfaceContainerHighest else MaterialTheme.colorScheme.secondaryContainer), contentPadding = PaddingValues(horizontal = if (compact) 10.dp else 12.dp, vertical = if (compact) 7.dp else 10.dp)) {
            Glyph(if (saved) "bookmark_rounded" else "bookmark_border_rounded", size = 18); Spacer(Modifier.width(6.dp))
            Text(if (series) followLabels[repo.store.json("followStates").optJSONObject(drama.id)?.text("status")] ?: "加入追剧" else if (saved) "已收藏" else "加入收藏")
            if (series) Glyph("expand_more_rounded", size = 16)
        }
        DropdownMenu(menu, { menu = false }) { followLabels.forEach { (status, label) -> DropdownMenuItem(text = { Text(label) }, onClick = hapticClick { menu = false; action { repo.store.followStatus(drama, status) } }) }; if (saved) DropdownMenuItem(text = { Text("取消追剧") }, onClick = hapticClick { menu = false; action { repo.store.favorite(drama) } }) }
    }
}

@Composable
fun DownloadPicker(detail: Detail, embedded: Boolean = true) {
    val repo = LocalRepository.current; val action = rememberAction(); val message = LocalMessage.current
    val preferences = repo.store.json("downloadPreferences")
    var selected by remember(detail.drama.id) { mutableStateOf(detail.episodes.indices.filter { preferences.optBoolean("includeVip", false) || !detail.episodes[it].json.optBoolean("vip") }.take(500).toSet()) }
    var quality by remember { mutableIntStateOf(preferences.optInt("quality")) }; var busy by remember { mutableStateOf(false) }
    if (!repo.store.canDownload) { StatusPanel("下载不可用", "当前用户或当前环境未开放本地下载。"); return }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(start = if (embedded) 10.dp else 18.dp, end = if (embedded) 10.dp else 18.dp, top = if (embedded) 6.dp else 8.dp), verticalAlignment = Alignment.CenterVertically) { Text(if (embedded) "下载选集" else detail.drama.title, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, fontWeight = appTextWeight(FontWeight.Bold), maxLines = 1); Text("已选 ${selected.size}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        FlowRow(Modifier.padding(start = if (embedded) 8.dp else 12.dp, end = if (embedded) 8.dp else 12.dp, top = 6.dp, bottom = 4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            TextButton(hapticClick { selected = detail.episodes.indices.take(500).toSet(); if (detail.episodes.size > 500) message("已选前 500 集；可清空后按分组选择其他集数，或从发现页使用整剧批量下载") }, enabled = !busy) { Text("全选") }
            TextButton(hapticClick { selected = emptySet() }, enabled = !busy && selected.isNotEmpty()) { Text(if (embedded) "清空" else "取消全选") }
            TextButton(hapticClick { selected = detail.episodes.indices.filter { !detail.episodes[it].json.optBoolean("vip") }.take(500).toSet() }, enabled = !busy) { Text("仅非 VIP") }
            Box(Modifier.height(48.dp).padding(start = 4.dp), contentAlignment = Alignment.Center) { Text("画质") }; Box(Modifier.drawBehind { drawLine(androidx.compose.ui.graphics.Color(0x33000000), androidx.compose.ui.geometry.Offset(0f, size.height - 1.dp.toPx()), androidx.compose.ui.geometry.Offset(size.width, size.height - 1.dp.toPx()), 1.dp.toPx()) }) { SettingsDropdown(quality.toString(), listOf("0" to "自动 · 高清", "1080" to "1080P", "720" to "720P", "480" to "480P"), enabled = !busy, filled = false) { quality = it.toInt() } }
        }
        Text("保存源站原始视频；指定画质不可用时自动使用可用版本。", Modifier.padding(horizontal = if (embedded) 10.dp else 18.dp), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (selected.any { detail.episodes[it].json.optBoolean("vip") }) Text("已选 VIP 集可能只能下载试看内容。", Modifier.padding(start = if (embedded) 10.dp else 18.dp, end = if (embedded) 10.dp else 18.dp, top = 6.dp), fontSize = 12.sp, color = MaterialTheme.colorScheme.tertiary)
        Box(Modifier.weight(1f)) { EpisodeGrid(detail.episodes, selected = selected, compact = embedded) { i -> if (!busy) { if (i in selected) selected = selected - i else if (selected.size < 500) selected = selected + i else message("一次最多加入 500 集，请分批下载") } } }
        Button(hapticClick { action { busy = true; try { repo.enqueue(detail, detail.episodes.filterIndexed { i, _ -> i in selected }, quality); selected = emptySet(); message("已加入下载，已有任务自动跳过") } finally { busy = false } } }, Modifier.fillMaxWidth().padding(start = if (embedded) 10.dp else 18.dp, end = if (embedded) 10.dp else 18.dp, bottom = if (embedded) 8.dp else 16.dp), enabled = !busy && selected.isNotEmpty(), contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) { Glyph("download_rounded", size = 18); Spacer(Modifier.width(8.dp)); Text(if (busy) "正在加入下载…" else "加入下载 · ${selected.size} 集") }
    }
}
fun commentText(value: String): String {
    return value.replace(Regex("\\[([^\\[\\]\\r\\n]{1,24})]")) { val name = it.groupValues[1].trim(); commentEmojis[name.lowercase(java.util.Locale.ROOT).replace(Regex("[\\s_-]"), "")] ?: name }
}
@Composable
fun CommentsContent(drama: Drama, onTotal: (Int?) -> Unit = {}) {
    val repo = LocalRepository.current; val action = rememberAction()
    var rows by remember(drama.id) { mutableStateOf(emptyList<JSONObject>()) }
    var cursor by remember(drama.id) { mutableStateOf("0") }; var more by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }; var error by remember { mutableStateOf<String?>(null) }
    var refresh by remember { mutableIntStateOf(0) }
    suspend fun load() { if (busy || !more || rows.size >= 200) return; busy = true; error = null; try {
        val result = repo.runtime.execute(drama.source, "comments", obj("drama" to drama.json, "cursor" to cursor))
        val previous = rows.size; val previousCursor = cursor
        rows = (rows + result.array("items").objects()).distinctBy { it.text("id") }.take(200); cursor = result.text("cursor", "0"); more = result.optBoolean("hasMore") && rows.size > previous && rows.size < 200 && cursor != previousCursor
        onTotal(result.optInt("total").takeIf { result.has("total") })
    } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { error = e.message } finally { busy = false } }
    LaunchedEffect(drama.id, refresh) { load() }
    LazyColumn(Modifier.fillMaxWidth().heightIn(min = 120.dp), contentPadding = PaddingValues(horizontal = 20.dp)) {
        items(rows, key = { it.text("id") }) { row -> Column(Modifier.fillMaxWidth().padding(vertical = 12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (row.text("avatar").isEmpty()) Box(Modifier.size(36.dp).background(MaterialTheme.colorScheme.surfaceContainerHigh, androidx.compose.foundation.shape.CircleShape), contentAlignment = Alignment.Center) { Glyph("person_rounded", size = 20, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                else CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onSurfaceVariant) {
                    Cover(Drama(drama.json.copy().put("cover", row.text("avatar"))), Modifier.size(36.dp).clip(androidx.compose.foundation.shape.CircleShape).background(MaterialTheme.colorScheme.surfaceContainerHigh), avatar = true)
                }
                Spacer(Modifier.width(10.dp)); Text(row.text("author"), Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Glyph("favorite_border_rounded", size = 14); Spacer(Modifier.width(4.dp)); Text("${row.optLong("likes")}", style = MaterialTheme.typography.labelSmall)
            }
            Spacer(Modifier.height(6.dp)); Text(commentText(row.text("text")))
        } }
        when {
            busy -> item { Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(36.dp)) } }
            error != null -> item {
                Column(Modifier.fillMaxWidth().padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(error!!, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    Spacer(Modifier.height(8.dp))
                    TextButton(hapticClick { refresh++ }, contentPadding = PaddingValues(start = 12.dp, end = 16.dp)) {
                        Glyph("refresh_rounded", size = 18); Spacer(Modifier.width(8.dp)); Text("重试")
                    }
                }
            }
            rows.isEmpty() -> item { Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) { Text("暂无文字评论") } }
            more -> item { Box(Modifier.fillMaxWidth().padding(12.dp), contentAlignment = Alignment.Center) { TextButton(hapticClick { action { load() } }) { Text("加载更多评论") } } }
            else -> item { Box(Modifier.fillMaxWidth().padding(20.dp), contentAlignment = Alignment.Center) { Text(if (rows.size >= 200) "已显示前 200 条评论" else "已显示全部可查看评论") } }
        }
    }
}
@Composable
fun CommentsScreen(drama: Drama, back: () -> Unit) { Page("评论", back) { padding -> Box(Modifier.padding(padding)) { CommentsContent(drama) } } }
@Composable
internal fun FeedCommentsPanel(drama: Drama, modifier: Modifier, headerModifier: Modifier = Modifier, back: () -> Unit) {
    var total by remember(drama.id) { mutableStateOf<Int?>(null) }
    Surface(modifier.semantics { paneTitle = "评论" }, color = MaterialTheme.colorScheme.surfaceContainerLow,
        shape = RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp),
    ) {
        Column(Modifier.fillMaxSize().navigationBarsPadding()) {
            Row(headerModifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(total?.let { "评论 · $it" } ?: "评论", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                IconAction("close_rounded", "关闭评论", action = back)
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = .42f))
            Box(Modifier.weight(1f)) { CommentsContent(drama) { total = it } }
        }
    }
}
