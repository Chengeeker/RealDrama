package com.real.drama.compose

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.*
import org.json.JSONObject

fun creatorFollowed(store: LocalStore, drama: Drama) = store.list("followedCreators").objects().any { row -> row.text("source") == drama.source && row.text("creatorSecUid").ifEmpty { row.text("creatorId") } == drama.creatorId }

@Composable
fun CreatorScreen(drama: Drama, back: () -> Unit, embedded: Boolean = false) {
    val repo = LocalRepository.current; val nav = LocalNavigate.current; val action = rememberAction(); val scope = rememberCoroutineScope()
    val grid = rememberLazyGridState()
    var rows by remember(drama.id) { mutableStateOf(emptyList<Drama>()) }; var data by remember(drama.id) { mutableStateOf(JSONObject()) }
    var error by remember { mutableStateOf<String?>(null) }; var busy by remember { mutableStateOf(false) }
    var cursor by remember { mutableStateOf("0") }; var more by remember { mutableStateOf(true) }; var generation by remember { mutableIntStateOf(0) }; var job by remember { mutableStateOf<Job?>(null) }
    val epoch = remember { repo.store.epoch }
    fun load(reset: Boolean = false) {
        if (!reset && (busy || !more)) return
        if (reset) job?.cancel()
        val request = ++generation; val requestedCursor = if (reset) "0" else cursor; busy = true; error = null
        job = scope.launch {
            try {
                val result = repo.runtime.execute(drama.source, "creator", obj("drama" to drama.json, "cursor" to requestedCursor))
                if (epoch != repo.store.epoch || request != generation) return@launch
                if (reset) data = result else listOf("name", "avatar").forEach { key -> if (result.text(key).isNotEmpty()) data = data.copy().put(key, result.text(key)) }
                rows = ((if (reset) emptyList() else rows) + result.array("items").objects().map(::Drama).filter { it.source == drama.source && it.id.isNotEmpty() }).distinctBy { it.id }
                cursor = result.text("cursor", "0"); more = result.optBoolean("hasMore") && cursor != requestedCursor
            } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { if (request == generation) error = e.message }
            finally { if (request == generation) busy = false }
        }
    }
    LaunchedEffect(drama.id) { load(true) }
    val nearEnd by remember { derivedStateOf { grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index?.let { it >= grid.layoutInfo.totalItemsCount - 10 } == true } }
    LaunchedEffect(nearEnd, busy, rows.size) { if (nearEnd && !busy && more && error == null) load() }
    val name = data.text("name").ifBlank { drama.creator.ifBlank { "作者主页" } }
    val content: @Composable (PaddingValues) -> Unit = { padding ->
        LazyVerticalGrid(GridCells.Fixed(3), state = grid, modifier = Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(start = 16.dp, top = 12.dp, end = 16.dp, bottom = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                LegacyCard(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp)) {
                    Column(Modifier.padding(18.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            val avatar = data.text("avatar").ifEmpty { drama.json.text("creatorAvatar") }
                            if (avatar.isNotEmpty()) Cover(Drama(drama.json.copy().put("cover", avatar)), Modifier.size(84.dp).clip(CircleShape))
                            else Box(Modifier.size(84.dp).background(MaterialTheme.colorScheme.surfaceContainerHighest, CircleShape), contentAlignment = Alignment.Center) { Glyph("person_rounded", size = 36) }
                            Spacer(Modifier.width(16.dp)); Column(Modifier.weight(1f)) {
                                Text(name, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleLarge); Spacer(Modifier.height(4.dp))
                                val id = data.text("userId").ifEmpty { drama.json.text("creatorId") }; val bili = drama.source == "bilibili"
                                Text(if (id.isEmpty()) if (bili) "哔哩哔哩创作者" else "抖音创作者" else "${if (bili) "UID" else "抖音号"}：$id", color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                        if (data.length() > 0) {
                            Spacer(Modifier.height(20.dp)); FlowRow(horizontalArrangement = Arrangement.spacedBy(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                listOf("likes" to "获赞", "following" to "关注", "followers" to "粉丝").forEach { (key, label) -> if (!data.isNull(key)) { val number = data.optLong(key); Text("${if (number >= 10000) "%.1f万".format(java.util.Locale.ROOT, number / 10000.0) else number.toString()} $label") } }
                            }
                            if (data.text("bio").isNotEmpty()) { Spacer(Modifier.height(14.dp)); Text(data.text("bio"), style = MaterialTheme.typography.bodyLarge) }
                        }
                        Spacer(Modifier.height(16.dp)); FilledTonalButton(hapticClick { action { repo.store.followCreator(drama) } }, Modifier.fillMaxWidth(), enabled = drama.creatorId.isNotEmpty() && "creator" in repo.source(drama.source)?.capabilities.orEmpty()) { Text(if (creatorFollowed(repo.store, drama)) "已关注 · 仅保存在本机" else "关注作者 · 仅保存在本机") }
                        Spacer(Modifier.height(20.dp)); Text("作品 · 已加载 ${rows.size} 条", style = MaterialTheme.typography.titleMedium)
                    }
                }
            }
            items(rows, key = { it.id }) { item -> Column(Modifier.aspectRatio(.64f).clip(RoundedCornerShape(18.dp)).hapticClickable { nav(Route("playback", item)) }) {
                DramaCover(item, Modifier.weight(1f).fillMaxWidth(), radius = 18); Spacer(Modifier.height(7.dp)); Text(item.title, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
            } }
            item(span = { GridItemSpan(maxLineSpan) }) { when {
                busy -> Box(Modifier.height(if (rows.isEmpty()) 240.dp else 64.dp)) { Loading() }
                error != null -> Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) { if (rows.isEmpty()) Glyph("person_search_outlined", size = 42); Text(error!!); Button(hapticClick { load(rows.isEmpty()) }) { Text("重试") } }
                rows.isEmpty() -> Box(Modifier.height(240.dp), contentAlignment = Alignment.Center) { Text("暂时没有可展示的作品") }
            } }
        }
    }
    if (embedded) content(PaddingValues()) else Page("作者主页", back, actions = { IconAction("refresh_rounded", "刷新作品", !busy) { load(true) } }, content = content)
}

data class RankingEntry(val rank: Int, val drama: Drama, val metric: String)
fun rankingEntries(value: JSONObject, source: String): List<RankingEntry> = value.array("items").objects().map { row ->
    val drama = Drama(row.getJSONObject("drama")); require(drama.source == source && drama.id.isNotEmpty() && row.optInt("rank") > 0) { "榜单条目不完整" }
    RankingEntry(row.getInt("rank"), drama, row.text("metric"))
}

@Composable
fun RankingsScreen(back: () -> Unit, initialGroup: String = "") {
    val repo = LocalRepository.current; val nav = LocalNavigate.current; val scope = rememberCoroutineScope(); val list = rememberLazyListState()
    var boards by remember { mutableStateOf(emptyList<JSONObject>()) }; var selected by remember { mutableStateOf<JSONObject?>(null) }
    var rows by remember { mutableStateOf(emptyList<RankingEntry>()) }; var error by remember { mutableStateOf<String?>(null) }; var updated by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }; var more by remember { mutableStateOf(false) }; var page by remember { mutableIntStateOf(0) }; var failedMore by remember { mutableStateOf(false) }
    var generation by remember { mutableIntStateOf(0) }; var job by remember { mutableStateOf<Job?>(null) }; var groupMenu by remember { mutableStateOf(false) }
    val epoch = remember { repo.store.epoch }
    fun load(append: Boolean = false, force: Boolean = false) {
        val board = selected ?: return; if (append && (loading || !more)) return
        job?.cancel(); val request = ++generation; val requested = if (append) page + 1 else 1; loading = true; error = null; failedMore = append
        job = scope.launch { try {
            val result = repo.runtime.execute(board.text("source"), "rankings", obj("board" to board.text("id"), "page" to requested, "force" to force))
            if (request != generation || epoch != repo.store.epoch) return@launch
            val loaded = rankingEntries(result, board.text("source")); val previous = if (append) rows else emptyList()
            rows = (previous + loaded).associateBy { it.drama.id }.values.sortedBy { it.rank }; page = result.optInt("page", requested)
            more = result.optBoolean("hasMore") && page >= requested && (!append || rows.size > previous.size); updated = result.text("updatedText"); error = result.text("warning").ifEmpty { null }
            repo.store.refreshDramas(loaded.map { it.drama }, epoch)
        } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { if (request == generation) error = e.message }
        finally { if (request == generation) loading = false } }
    }
    fun initialize() {
        scope.launch { loading = true; error = null; try {
            boards = repo.available().filter { "rankings" in it.capabilities }.flatMap { source -> repo.runtime.execute(source.id, "rankingBoards").array("items").objects().map { it.copy().put("source", source.id) } }
            selected = boards.firstOrNull { repo.source(it.text("source"))?.catalogGroup == initialGroup } ?: boards.firstOrNull()
        } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { error = e.message } finally { loading = false } }
    }
    LaunchedEffect(Unit) { initialize() }
    LaunchedEffect(selected) { rows = emptyList(); more = false; page = 0; updated = ""; list.requestScrollToItem(0); load() }
    val nearEnd by remember { derivedStateOf { list.layoutInfo.visibleItemsInfo.lastOrNull()?.index?.let { it >= list.layoutInfo.totalItemsCount - 5 } == true } }
    LaunchedEffect(nearEnd, loading, rows.size) { if (nearEnd && more && !loading && error == null) load(true) }
    val source = selected?.text("source"); val group = repo.source(source.orEmpty())?.catalogGroup
    val groups = boards.groupBy { repo.source(it.text("source"))?.catalogGroup ?: it.text("source") }
    val name = repo.source(source.orEmpty())?.catalogName.orEmpty()
    Page(if (name.isEmpty()) "榜单" else "${name}榜单", back, actions = {
        if (groups.size > 1) Box { IconAction("expand_more_rounded", "切换榜单站源") { groupMenu = true }; DropdownMenu(groupMenu, { groupMenu = false }) { groups.values.forEach { entries -> DropdownMenuItem(text = { Text(repo.source(entries.first().text("source"))?.catalogName.orEmpty()) }, onClick = hapticClick { selected = entries.first(); groupMenu = false }) } } }
        IconAction("refresh_rounded", "更新榜单") { if (!loading) { if (selected == null) initialize() else load(force = true) } }
    }) { padding -> Column(Modifier.fillMaxSize().padding(padding)) {
        if (group != null) LazyRow(Modifier.height(50.dp), contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) { items(boards.filter { (repo.source(it.text("source"))?.catalogGroup ?: it.text("source")) == group }) { board -> LegacyChip(selected?.text("id") == board.text("id"), { selected = board }, label = { Text(board.text("name")) }) } }
        if (selected != null) Text(listOf(selected!!.text("description"), updated).filter(String::isNotEmpty).joinToString(" "), Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp), style = MaterialTheme.typography.bodySmall)
        if (loading && rows.isNotEmpty()) LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp))
        if (error != null && rows.isNotEmpty()) Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) { Text(error!!, Modifier.weight(1f), color = MaterialTheme.colorScheme.error); TextButton(hapticClick { load(failedMore, true) }, enabled = !loading) { Text("重试") } }
        if (rows.isEmpty()) { if (loading) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                LoadingRing()
                if (source == "hongguo") {
                    Spacer(Modifier.height(16.dp))
                    Text("正在获取榜单，数据未完整返回时会自动重试")
                }
            }
        } else StatusPanel(if (error == null) "暂无榜单内容" else "榜单暂时无法加载", error ?: "当前站源暂无可显示的榜单。", onRetry = { if (selected == null) initialize() else load(force = true) }) }
        else LazyColumn(state = list, contentPadding = PaddingValues(start = 12.dp, end = 12.dp, bottom = 24.dp)) {
            items(rows.filter { repo.store.allowed(it.drama.source) && !(it.drama.source == "huangdou" && repo.store.bool("hideVip") && it.drama.json.optBoolean("vip")) }, key = { it.drama.id }) { row ->
                Card(onClick = hapticClick { nav(Route("detail", row.drama)) }, modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                    Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(row.rank.toString(), Modifier.width(36.dp), fontSize = 24.sp, fontWeight = appTextWeight(FontWeight.ExtraBold), color = if (row.rank <= 3) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                        DramaCover(row.drama, Modifier.size(72.dp, 108.dp), radius = 8); Spacer(Modifier.width(14.dp))
                        Column(Modifier.weight(1f)) { Text(row.drama.title, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleMedium); if (row.drama.json.text("category").isNotEmpty()) Text(row.drama.json.text("category"), maxLines = 1, overflow = TextOverflow.Ellipsis); if (row.metric.isNotEmpty()) { Spacer(Modifier.height(8.dp)); Text(row.metric, color = MaterialTheme.colorScheme.primary) } }; Glyph("chevron_right_rounded")
                    }
                }
            }
            item { Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { if (loading) LoadingRing() else if (more) LegacyOutlinedButton({ load(true) }) { Text("加载更多") } else Text("已显示全部榜单") } }
        }
    } }
}
