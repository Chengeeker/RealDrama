package com.real.drama.compose

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*
import org.json.JSONObject

@Composable
fun LocalMediaScreen(back: () -> Unit) {
    val repo = LocalRepository.current; val action = rememberAction(); val nav = LocalNavigate.current; val scope = rememberCoroutineScope(); val context = LocalContext.current
    val library = repo.mediaLibrary; val media by library.media.collectAsState(); val status by library.status.collectAsState()
    var merged by remember { mutableStateOf(true) }; var jobs by remember { mutableStateOf(emptyList<JSONObject>()) }; var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }; var exporting by remember { mutableStateOf(false) }; var removal by remember { mutableStateOf<JSONObject?>(null) }; var exportJob by remember { mutableStateOf<Job?>(null) }
    suspend fun refresh() { try { jobs = repo.downloads().filter { it.text("state") == "completed" }; error = null } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { error = e.message } finally { loading = false } }
    LaunchedEffect(Unit) { refresh() }
    fun copy(path: String) { context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("媒体路径", path)) }
    val items = media.filter { (it.text("kind") == "merged") == merged && repo.store.allowed(it.getJSONObject("drama").text("source")) }
    Page("本地媒体", back, actions = { IconAction("refresh_rounded", "刷新", status.isEmpty()) { action { refresh() } } }) { padding -> Column(Modifier.fillMaxSize().padding(padding)) {
        FlowRow(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            LegacyChip(merged, { merged = true }, label = { Text("合并成品") }); LegacyChip(!merged, { merged = false }, label = { Text("Emby 导出") })
            Button(hapticClick { if (merged) nav(Route("mergeQueue", payload = obj("add" to true))) else exporting = true }, enabled = merged || status.isEmpty(), contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) { Glyph(if (merged) "merge" else "output", size = 18); Spacer(Modifier.width(8.dp)); Text(if (merged) "合并已下载分集" else "导出已下载分集") }
        }
        if (status.isNotEmpty()) Column(Modifier.padding(horizontal = 20.dp)) { LinearProgressIndicator(Modifier.fillMaxWidth()); Spacer(Modifier.height(8.dp)); Row(verticalAlignment = Alignment.CenterVertically) { Text(status, Modifier.weight(1f)); TextButton(hapticClick { exportJob?.cancel(); action { library.pause() } }) { Text("取消") } } }
        if (error != null) Text(error!!, Modifier.padding(16.dp))
        if (!merged) Column(Modifier.padding(horizontal = 20.dp, vertical = 8.dp)) {
            Text("将 exports 目录加入 Emby 电视节目库，可读取分集名称和海报元数据。自动导出可在设置中开启。")
            TextButton(hapticClick { action { val root = NativeBridge.call(obj("action" to "downloadDirectory")).getString("directory"); copy(java.io.File(root, "exports").path) } }) { Glyph("copy_rounded"); Spacer(Modifier.width(8.dp)); Text("复制 Emby 媒体目录") }
        }
        if (loading) Loading() else if (items.isEmpty()) Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) { Text(if (merged) "合并成品会显示在这里，可直接播放和续播。" else "暂未导出媒体") }
        else LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(start = 12.dp, end = 12.dp, bottom = 16.dp)) {
            items(items, key = { it.text("id") }) { item -> val drama = Drama(item.getJSONObject("drama")); val episodes = item.array("episodes"); val isMerged = item.text("kind") == "merged"
                LegacyCard(Modifier.fillMaxWidth().padding(4.dp)) { Column(Modifier.padding(12.dp)) {
                    Text(drama.title, style = MaterialTheme.typography.titleMedium); Spacer(Modifier.height(6.dp))
                    Text((if (isMerged) "已合并 ${episodes.length()} 集" else if (item.text("kind") == "special") "特别篇 ${item.optInt("specialNumber")} · 第 ${episodes.optInt(0)}–${episodes.optInt(episodes.length() - 1)} 集" else "第 ${episodes.optInt(0)} 集") + " · ${formatBytes(item.optLong("bytes"))}")
                    if (isMerged) { Text("视频转码 ${item.optInt("videoTranscodes")} 集 · 音轨处理 ${item.optInt("audioTranscodes")} 集", style = MaterialTheme.typography.bodySmall)
                        TextButton(hapticClick { exportJob = scope.launch { try { library.exportMerged(item); merged = false; error = null } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { error = e.message } } }, enabled = status.isEmpty()) { Glyph("output_rounded"); Spacer(Modifier.width(8.dp)); Text("导出到 Emby 特别篇") }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        TextButton(hapticClick { nav(Route("localPlayback", payload = item)) }) { Glyph("play_arrow_rounded"); Spacer(Modifier.width(8.dp)); Text(if (isMerged && episodes.length() == drama.json.optInt("episodes")) "全集播放" else "本地播放") }; Spacer(Modifier.weight(1f))
                        IconAction("copy_rounded", "复制文件路径") { action { copy(library.fileFor(item).path) } }; IconAction("delete_outline_rounded", "删除成品", status.isEmpty()) { removal = item }
                    }
                } }
            }
        }
    } }
    if (exporting) LegacyAlertDialog(onDismissRequest = { exporting = false }, title = { Text("导出哪部剧到 Emby？") }, text = { Column(Modifier.heightIn(max = 480.dp).verticalScroll(rememberScrollState())) {
        val groups = jobs.groupBy { it.getJSONObject("drama").text("id") }
        val choices = if (jobs.isEmpty()) emptyList() else listOf("全部已下载 · ${jobs.size} 集" to jobs) + groups.values.map { "${it.first().getJSONObject("drama").text("title")} · 已下载 ${it.size} 集" to it }
        choices.forEach { (label, rows) -> TextButton(hapticClick { exporting = false; merged = false; exportJob = scope.launch { try { for (row in rows) { ensureActive(); library.exportEpisode(row) }; refresh() } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { error = e.message } } }, Modifier.fillMaxWidth()) { Text(label) } }
        if (jobs.isEmpty()) Text("请先下载分集", Modifier.padding(20.dp))
    } }, confirmButton = {})
    removal?.let { item -> LegacyAlertDialog(onDismissRequest = { removal = null }, title = { Text("删除此媒体文件？") }, text = { Text("将删除此成品文件。已单独保存的原分集不受影响。" + if (item.text("kind") !in setOf("merged", "special")) "此分集不再自动导出，需要时可手动重新导出。" else "") }, confirmButton = { Button(hapticClick { action { library.remove(item); removal = null } }) { Text("删除") } }, dismissButton = { TextButton(hapticClick { removal = null }) { Text("保留") } }) }
}

@Composable
fun MergeQueueScreen(back: () -> Unit, addOnOpen: Boolean = false) {
    val repo = LocalRepository.current; val library = repo.mediaLibrary; val action = rememberAction()
    val tasks by library.jobs.collectAsState(); val status by library.status.collectAsState()
    val epoch = remember { repo.store.epoch }
    var adding by remember { mutableStateOf(false) }; var showPicker by remember { mutableStateOf(false) }; var groups by remember { mutableStateOf(emptyList<List<JSONObject>>()) }; var error by remember { mutableStateOf<String?>(null) }
    var selected by remember { mutableStateOf(setOf<String>()) }; var cleanup by remember { mutableStateOf(false) }
    fun add() { if (adding) return; adding = true; action { try { groups = repo.downloads().filter { it.text("state") == "completed" }.groupBy { it.getJSONObject("drama").text("id") }.values.toList(); selected = emptySet(); cleanup = false; showPicker = true } finally { adding = false } } }
    LaunchedEffect(Unit) { if (addOnOpen) add() }
    val allowed = epoch == repo.store.epoch && repo.store.canDownload
    val visible = tasks.filter { it.text("owner") == repo.store.active }
    Page("合并队列", back, actions = { IconAction("add_rounded", "添加多部剧", allowed && !adding) { add() } }) { padding -> Box(Modifier.fillMaxSize().padding(padding)) {
        if (!allowed) StatusPanel("当前用户已切换", "请返回后重新打开合并队列。")
        else if (visible.isEmpty()) StatusPanel("还没有合并任务", "选择多部剧加入队列，依次合并已下载的连续分集。", secondaryAction = { Button(hapticClick { add() }, enabled = !adding, contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) { Glyph("add_rounded", size = 18); Spacer(Modifier.width(8.dp)); Text("添加剧集") } })
        else LazyColumn(contentPadding = PaddingValues(12.dp)) {
            if (adding) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            if (error != null) item { Text(error!!, Modifier.padding(16.dp)) }
            items(visible, key = { it.text("id") }) { task -> val rows = task.array("jobs").objects(); val running = task.text("state") == "running"
                LegacyCard(Modifier.fillMaxWidth().padding(4.dp)) { Column(Modifier.padding(16.dp)) {
                    Text(task.getJSONObject("drama").text("title"), style = MaterialTheme.typography.titleMedium); Spacer(Modifier.height(6.dp))
                    Text("第 ${rows.minOfOrNull { it.optInt("index") } ?: 0}–${rows.maxOfOrNull { it.optInt("index") } ?: 0} 集 · ${stateLabel(task.text("state"))}" + if (task.optBoolean("cleanup")) " · 完成后清理分集" else "")
                    if (running) { Spacer(Modifier.height(10.dp)); LinearProgressIndicator(Modifier.fillMaxWidth()); Spacer(Modifier.height(6.dp)); Text(status) }
                    if (task.text("error").isNotEmpty()) Text(task.text("error"), Modifier.padding(top = 8.dp))
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (task.text("state") in setOf("running", "queued")) TextButton(hapticClick { action { library.control(task.text("id"), "pause") } }) { Glyph("pause_rounded"); Text("暂停") }
                        if (task.text("state") in setOf("paused", "failed")) TextButton(hapticClick { action { library.control(task.text("id"), "resume") } }) { Glyph("play_arrow_rounded"); Text(if (task.text("state") == "failed") "重试" else "继续") }
                        if (task.text("state") !in setOf("completed", "cancelled")) TextButton(hapticClick { action { library.control(task.text("id"), "cancel") } }) { Text("取消任务") }
                        else TextButton(hapticClick { action { library.control(task.text("id"), "forget") } }) { Text("清理记录") }
                    }
                } }
            }
        }
    } }
    if (showPicker) LegacyAlertDialog(onDismissRequest = { if (!adding) showPicker = false }, title = { Text("选择要合并的剧") }, text = { Column(Modifier.heightIn(max = 520.dp)) {
        Text("按已有的连续集数合并，每次最多加入 50 部。中断后可从保存的步骤继续。"); Spacer(Modifier.height(8.dp))
        LazyColumn(Modifier.weight(1f, false)) { items(groups) { rows -> val id = rows.first().getJSONObject("drama").text("id"); val failure = remember(rows) { runCatching { MediaLibrary.validateMerge(rows) }.exceptionOrNull()?.message }
            Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(id in selected, hapticToggle { checked -> if (checked && selected.size < 50) selected = selected + id else selected = selected - id }, enabled = failure == null && !adding); Column(Modifier.weight(1f)) { Text(rows.first().getJSONObject("drama").text("title")); Text(failure ?: "已下载 ${rows.size} 集 · 第 ${rows.minOf { it.optInt("index") }}–${rows.maxOf { it.optInt("index") }} 集", style = MaterialTheme.typography.bodySmall) } }
        } }
        if (groups.isEmpty()) Text("请先下载至少两集连续视频", Modifier.padding(20.dp))
        SwitchRow("完成后删除原分集", cleanup, "仅在成品通过完整解码并保存后删除；默认保留原视频。", !adding) { cleanup = it }
    } }, confirmButton = { Button(hapticClick { adding = true; action { try { groups.filter { it.first().getJSONObject("drama").text("id") in selected }.forEach { rows -> library.enqueue(rows, cleanup); selected = selected - rows.first().getJSONObject("drama").text("id") }; showPicker = false } finally { adding = false } } }, enabled = selected.isNotEmpty() && !adding) { Text("加入队列") } }, dismissButton = { TextButton(hapticClick { showPicker = false }, enabled = !adding) { Text("取消") } })
}
