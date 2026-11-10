package com.real.drama.compose

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CancellationException

@Composable
fun VipDialog(onDismiss: () -> Unit, onConfirm: () -> Unit) {
    LegacyAlertDialog(onDismissRequest = onDismiss, title = { Text("这是一集 VIP 内容") }, text = { Text("站源可能只提供试看或限制播放。") },
        dismissButton = { TextButton(hapticClick(onDismiss)) { Text("取消") } }, confirmButton = { Button(hapticClick(onConfirm)) { Text("尝试播放") } })
}

fun dramaMeta(drama: Drama, sourceName: String?, category: Boolean = false) = listOfNotNull(sourceName,
    drama.json.optInt("episodes").takeIf { it > 0 }?.let { "共 $it 集" },
    when (drama.json.text("releaseStatus")) { "finished", "completed" -> "已完结"; "ongoing" -> "连载中"; "", "unknown" -> null; else -> "状态未知" },
    drama.json.text("category").takeIf { category && it.isNotEmpty() }).joinToString(" · ")

fun dramaMetrics(drama: Drama) = listOfNotNull(drama.json.text("onlineDate").takeIf(String::isNotEmpty)?.let { "$it 上线" },
    drama.json.text("heat").takeIf(String::isNotEmpty)?.let { "热度 $it" }, drama.json.text("views").takeIf(String::isNotEmpty)?.let { "播放 $it" }).joinToString(" · ")

@Composable
fun DetailScreen(original: Drama, back: () -> Unit, downloadOnOpen: Boolean = false) {
    val repo = LocalRepository.current; val nav = LocalNavigate.current; val action = rememberAction()
    var detail by remember(original.id) { mutableStateOf<Detail?>(null) }; var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(true) }; var generation by remember { mutableIntStateOf(0) }
    var initialAction by remember { mutableStateOf(false) }; var expanded by remember { mutableStateOf(false) }
    var vip by remember { mutableStateOf<Pair<Int, Boolean>?>(null) }
    val drama = detail?.drama ?: original; val episodes = detail?.episodes.orEmpty(); val watch = repo.store.watch(drama)
    val resume = resumeEpisodeIndex(episodes, watch)
    val epoch = remember { repo.store.epoch }; val allowed = epoch == repo.store.epoch && repo.store.allowed(drama.source)
    fun play(index: Int, resume: Boolean) {
        if (!allowed || index !in episodes.indices) return
        if (episodes[index].json.optBoolean("vip") && drama.source != "dsd") vip = index to resume
        else nav(Route("playback", drama, payload = obj("index" to index, "resume" to resume, "vipAccepted" to true)))
    }
    LaunchedEffect(original.id, generation) {
        loading = true; error = null
        try {
            val loaded = repo.detail(original, generation > 0); detail = loaded
            if (!initialAction && downloadOnOpen && loaded.episodes.isNotEmpty() && repo.store.canDownload) { initialAction = true; nav(Route("downloadPicker", loaded.drama)) }
        } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { error = e.message } finally { loading = false }
    }
    Page(drama.title, back, actions = { IconAction("refresh_rounded", "更新剧集信息") { if (!loading && allowed) generation++ } }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                val tv = repo.store.text("displayMode", "auto", true) == "television" || repo.store.text("displayMode", "auto", true) == "auto" && LocalContext.current.packageManager.hasSystemFeature("android.software.leanback")
                val wide = tv || maxWidth >= 960.dp
                val overviewWidth = (maxWidth * .34f).coerceIn(250.dp, 360.dp)
                val status: @Composable () -> Unit = { when { !allowed -> StatusPanel("当前用户无权访问", "请返回剧库后重新选择。"); loading -> Loading(); else -> StatusPanel(if (error != null) "剧集信息暂时不可用" else "暂时没有可播放的集数", error ?: "可以更新剧集信息后重试。", onRetry = { generation++ }) } }
                if (wide) Row(Modifier.widthIn(max = 1200.dp).fillMaxSize()) {
                    Column(Modifier.width(overviewWidth).verticalScroll(rememberScrollState()).padding(20.dp)) { DetailOverview(drama, detail?.warning.orEmpty()) }
                    VerticalDivider()
                    Column(Modifier.weight(1f)) { if (!allowed || loading || error != null || episodes.isEmpty()) status() else { RelatedSeries(drama); EpisodeGrid(episodes, episodes.indexOfFirst { it.number == watch?.optInt("episode") }, compact = false) { play(it, false) } } }
                } else Column(Modifier.widthIn(max = 1200.dp).fillMaxWidth().verticalScroll(rememberScrollState())) {
                    Column(Modifier.padding(start = 20.dp, top = 12.dp, end = 20.dp, bottom = 8.dp)) { DetailOverview(drama, detail?.warning.orEmpty()) }
                    if (!allowed || loading || error != null || episodes.isEmpty()) Box(Modifier.heightIn(min = 240.dp)) { status() }
                    else {
                        RelatedSeries(drama)
                        Surface(onClick = hapticClick { expanded = !expanded }, color = MaterialTheme.colorScheme.surfaceContainer, shape = RoundedCornerShape(8.dp), modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp)) {
                            Row(Modifier.padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                                Glyph("grid_view_rounded"); Spacer(Modifier.width(10.dp))
                                Text("选集 · ${episodes.size} 集" + (watch?.optInt("episode")?.let { " · 当前第 $it 集" } ?: ""), Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleSmall, fontWeight = appTextWeight(FontWeight.Bold))
                                Text(if (expanded) "收起" else "展开"); Glyph(if (expanded) "expand_less_rounded" else "expand_more_rounded")
                            }
                        }
                        if (expanded) DetailEpisodes(episodes, watch?.optInt("episode"), onSelect = { play(it, false) })
                    }
                }
            }
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                Row(Modifier.widthIn(max = 1000.dp).fillMaxWidth().padding(start = 16.dp, top = 10.dp, end = 16.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (repo.store.canDownload && "download" in repo.source(drama.source)?.capabilities.orEmpty()) {
                        FilledTonalIconButton({ nav(Route("downloadPicker", drama)) }, Modifier.size(52.dp), enabled = allowed && !loading && episodes.isNotEmpty()) { Glyph("download_rounded") }; Spacer(Modifier.width(12.dp))
                    }
                    Button(hapticClick { play(resume, true) }, Modifier.weight(1f).heightIn(min = 52.dp), enabled = allowed && !loading && episodes.isNotEmpty()) {
                        Glyph("play_arrow_rounded", size = 26); Spacer(Modifier.width(8.dp)); Text(if (watch != null && episodes.isNotEmpty()) "继续播放 · 第 ${episodes[resume].number} 集" else "立即播放")
                    }
                }
            }
        }
    }
    vip?.let { (index, resume) -> VipDialog({ vip = null }, { vip = null; if (allowed) nav(Route("playback", drama, payload = obj("index" to index, "resume" to resume, "vipAccepted" to true))) }) }
}

@Composable
private fun DetailOverview(drama: Drama, warning: String) {
    val repo = LocalRepository.current; val action = rememberAction(); var expanded by remember { mutableStateOf(false) }
    val colors = MaterialTheme.colorScheme
    Row {
        DramaCover(drama, Modifier.size(92.dp, 138.dp)); Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(drama.title, style = MaterialTheme.typography.titleLarge, fontWeight = appTextWeight(FontWeight.Bold))
            Spacer(Modifier.height(10.dp)); Text(dramaMeta(drama, repo.source(drama.source)?.name), color = colors.onSurfaceVariant, lineHeight = 21.sp)
            if (drama.json.text("category").isNotEmpty()) { Spacer(Modifier.height(6.dp)); Text(drama.json.text("category"), color = colors.onSurfaceVariant) }
            if (drama.source == "huangdou") { Spacer(Modifier.height(6.dp)); Text(if (drama.json.isNull("vip")) "VIP 状态待补齐" else if (drama.json.optBoolean("vip")) "VIP 内容" else "免费内容", style = MaterialTheme.typography.bodySmall) }
        }
    }
    Spacer(Modifier.height(12.dp))
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        FollowButton(drama, compact = false)
        val updates = followUpdateLabel(repo.store.json("followStates").optJSONObject(drama.id))
        if (updates.isNotEmpty()) SuggestionChip(hapticClick { action { repo.store.markUpdatesRead(drama) } }, label = { Text("$updates · 标为已读") })
    }
    val metrics = dramaMetrics(drama)
    if (metrics.isNotEmpty()) { Spacer(Modifier.height(10.dp)); Text(metrics, color = colors.onSurfaceVariant, fontSize = 12.sp) }
    if (drama.json.array("tags").length() > 0) {
        Spacer(Modifier.height(12.dp)); FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            drama.json.array("tags").strings().take(12).forEach { tag -> Surface(shape = RoundedCornerShape(6.dp), color = colors.surfaceContainerHighest) { Text(tag, Modifier.padding(horizontal = 8.dp, vertical = 5.dp), style = MaterialTheme.typography.bodySmall) } }
        }
    }
    if (drama.description.isNotEmpty()) {
        Spacer(Modifier.height(12.dp)); Text(drama.description, color = colors.onSurfaceVariant, lineHeight = 22.4.sp, maxLines = if (expanded) Int.MAX_VALUE else 3, overflow = TextOverflow.Ellipsis)
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) { TextButton(hapticClick { expanded = !expanded }) { Text(if (expanded) "收起简介" else "展开简介") } }
    }
    if (warning.isNotEmpty()) { Spacer(Modifier.height(8.dp)); Text(warning, color = colors.error) }
}

@Composable
private fun RelatedSeries(drama: Drama) {
    val repo = LocalRepository.current; val nav = LocalNavigate.current; val action = rememberAction()
    val entries = seriesEntries(drama, repo.store.list("seriesCandidates").objects().map(::Drama) + repo.store.favorites())
    if (entries.isEmpty()) return
    val notices = repo.store.json("followStates").optJSONObject(drama.id)?.optJSONObject("seriesSeasons")
    Column(Modifier.padding(start = 20.dp, top = 10.dp, end = 20.dp, bottom = 8.dp)) {
        Text("相关推荐", style = MaterialTheme.typography.titleMedium); Spacer(Modifier.height(8.dp))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            entries.forEach { entry -> LegacyChip(entry.drama.id == drama.id, { action { repo.store.markUpdatesRead(drama, entry.drama.id); nav(Route("detail", entry.drama)) } }, enabled = entry.drama.id != drama.id,
                label = { Row(Modifier.widthIn(max = 260.dp), verticalAlignment = Alignment.CenterVertically) { Text("第 ${entry.season} ${entry.unit} · ${entry.drama.title}", Modifier.weight(1f, false), maxLines = 1, overflow = TextOverflow.Ellipsis); if (notices?.optJSONObject(entry.drama.id)?.optBoolean("read") == false) { Spacer(Modifier.width(6.dp)); Glyph("fiber_new_rounded", size = 18, color = MaterialTheme.colorScheme.primary) } } }) }
        }
    }
}

@Composable
private fun DetailEpisodes(episodes: List<Episode>, current: Int?, onSelect: (Int) -> Unit) {
    var page by remember { mutableIntStateOf((episodes.indexOfFirst { it.number == current }.coerceAtLeast(0)) / 50) }
    var jump by remember { mutableStateOf(false) }; var number by remember { mutableStateOf("") }; var invalid by remember { mutableStateOf(false) }
    Row(Modifier.padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) {
        Text("分组"); Row(Modifier.weight(1f).horizontalScroll(rememberScrollState())) { repeat((episodes.size + 49) / 50) { p -> TextButton(hapticClick { page = p }) { Text("${episodes[p * 50].number}–${episodes[minOf(p * 50 + 49, episodes.lastIndex)].number}", color = if (p == page) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) } } }; IconAction("pin_outlined", "跳转集数") { jump = true }
    }
    BoxWithConstraints(Modifier.padding(start = 20.dp, top = 4.dp, end = 20.dp, bottom = 24.dp)) {
        val density = androidx.compose.ui.platform.LocalDensity.current
        val scaled = with(density) { 20.sp.toDp().value }; val digits = episodes.maxOfOrNull { it.number.toString().length } ?: 1
        val columns = (maxWidth.value / maxOf(82f, scaled * digits * .65f + 40)).toInt().coerceIn(1, 12)
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            episodes.indices.drop(page * 50).take(50).chunked(columns).forEach { row -> Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                row.forEach { index -> val ep = episodes[index]; Surface(onClick = hapticClick { onSelect(index) }, modifier = Modifier.weight(1f).height(maxOf(54f, scaled + 30).dp), shape = RoundedCornerShape(12.dp), color = if (ep.number == current) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface, border = BorderStroke(1.dp, if (ep.number == current) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant)) {
                    Row(horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) { Text(ep.number.toString(), fontSize = 20.sp); if (ep.json.optBoolean("vip")) Glyph("workspace_premium_rounded", size = 16, color = MaterialTheme.colorScheme.tertiary) }
                } }; repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
            } }
        }
    }
    if (jump) LegacyAlertDialog(onDismissRequest = { jump = false }, title = { Text("跳转到指定集数") }, text = { OutlinedTextField(number, { number = it.filter(Char::isDigit); invalid = false }, isError = invalid, label = { Text("集数") }, textStyle = MaterialTheme.typography.bodyLarge, colors = legacyTextFieldColors(), shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp)) }, confirmButton = { TextButton(hapticClick { val index = episodes.indexOfFirst { it.number == number.toIntOrNull() }; if (index < 0) invalid = true else { page = index / 50; jump = false } }) { Text("定位") } }, dismissButton = { TextButton(hapticClick { jump = false }) { Text("取消") } })
}

@Composable
fun DownloadPickerScreen(drama: Drama, back: () -> Unit) {
    val repo = LocalRepository.current; var detail by remember { mutableStateOf<Detail?>(null) }; var error by remember { mutableStateOf<String?>(null) }; var generation by remember { mutableIntStateOf(0) }
    LaunchedEffect(drama.id, generation) { try { detail = repo.detail(drama) } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { error = e.message } }
    Page("下载选集", back) { padding -> Box(Modifier.padding(padding)) { detail?.let { DownloadPicker(it, embedded = false) } ?: if (error != null) StatusPanel("剧集信息暂时不可用", error!!, onRetry = { generation++ }) else Loading() } }
}
