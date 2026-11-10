package com.real.drama.compose

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject

val downloadFilterLabels = linkedMapOf("all" to "全部任务", "pending" to "未完成", "active" to "进行中", "paused" to "已暂停", "failed" to "失败", "completed" to "已下载", "archived" to "已保留视频")
fun downloadActive(job: JSONObject) = job.text("state") in setOf("queued", "downloading")
fun downloadableCommand(job: JSONObject, command: String) = when (command) { "pause" -> downloadActive(job); "resume" -> job.text("state") in setOf("failed", "paused"); "archive" -> job.text("state") == "completed" && !job.optBoolean("archived"); "restore" -> job.text("state") == "completed" && job.optBoolean("archived"); "remove" -> true; else -> false }
fun downloadCollections(jobs: List<JSONObject>, query: String, filter: String, release: String, sourceName: (String) -> String): List<List<JSONObject>> {
    val terms = query.trim().lowercase().split(Regex("\\s+")).filter(String::isNotEmpty)
    return jobs.filter { row -> val drama = row.getJSONObject("drama"); val state = row.text("state")
        val text = "${drama.text("title")} ${sourceName(drama.text("source"))} ${drama.text("category")}".lowercase()
        row.optBoolean("archived") == (filter == "archived") && (release.isEmpty() || drama.text("releaseStatus") == release || release == "finished" && drama.text("releaseStatus") == "completed") && terms.all(text::contains) && when (filter) { "all", "archived" -> true; "pending" -> state != "completed"; "active" -> downloadActive(row); else -> state == filter }
    }.groupBy { it.getJSONObject("drama").text("id") }.values.map { it.sortedBy { row -> row.optInt("index") } }.sortedByDescending { rows -> rows.maxOf { it.optLong("created") } }
}

@Composable
fun DownloadsScreen(back: () -> Unit) {
    val repo = LocalRepository.current; val nav = LocalNavigate.current; val action = rememberAction(); val scope = rememberCoroutineScope(); val message = LocalMessage.current
    val epoch = remember { repo.store.epoch }
    var jobs by remember { mutableStateOf(emptyList<JSONObject>()) }; var error by remember { mutableStateOf<String?>(null) }; var loading by remember { mutableStateOf(true) }
    var query by remember { mutableStateOf("") }; var filter by remember { mutableStateOf("all") }; var release by remember { mutableStateOf("") }
    var selected by remember { mutableStateOf(setOf<String>()) }; var selecting by remember { mutableStateOf(false) }; var expanded by remember { mutableStateOf(setOf<String>()) }
    var filters by remember { mutableStateOf(false) }; var queueMenu by remember { mutableStateOf(false) }; var removal by remember { mutableStateOf<List<JSONObject>?>(null) }
    var busy by remember { mutableStateOf(false) }; var stop by remember { mutableStateOf(false) }; var operation by remember { mutableStateOf("") }; var retry by remember { mutableStateOf<String?>(null) }
    val allowed = repo.store.epoch == epoch && repo.store.canDownload
    suspend fun refresh() { try { val rows = repo.downloads(); if (epoch == repo.store.epoch) { jobs = rows; selected = selected.intersect(rows.map { it.text("id") }.toSet()); error = null } } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { error = e.message } finally { loading = false } }
    LaunchedEffect(Unit) { while (true) { refresh(); delay(2000) } }
    fun select(rows: List<JSONObject>) { val ids = rows.map { it.text("id") }.toSet(); selecting = true; selected = if (selected.containsAll(ids)) selected - ids else selected + ids }
    fun batch(command: String, rows: List<JSONObject>, confirmed: Boolean = false) {
        if (busy || !allowed) return
        val targets = rows.filter { downloadableCommand(it, command) }
        if (targets.isEmpty()) { message("没有适合此操作的任务"); return }
        if (command == "remove" && !confirmed) { removal = targets; return }
        busy = true; stop = false; retry = null
        scope.launch { val pending = targets.map { it.text("id") }.toMutableSet(); val failures = mutableListOf<String>()
            try {
                for ((i, chunk) in targets.chunked(500).withIndex()) {
                    if (stop || epoch != repo.store.epoch || !repo.store.canDownload) break
                    operation = "正在处理 ${minOf(i * 500 + chunk.size, targets.size)}/${targets.size} 项"
                    try { val result = repo.controlDownloadBatch(command, chunk); pending.removeAll(result.array("completed").strings().toSet()); result.optJSONObject("failures")?.let { data -> data.keys().forEach { failures.add(data.text(it)) } } }
                    catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { failures.add(e.message ?: "操作失败") }
                }
                if (pending.isNotEmpty()) { selected = pending; selecting = true; retry = command; message(if (failures.isEmpty()) "已停止，未处理的任务保留" else failures.distinct().joinToString("；")) } else { selected = selected - targets.map { it.text("id") }.toSet(); message("已处理 ${targets.size} 项") }
                refresh()
            } finally { busy = false; operation = "" }
        }
    }
    fun update(drama: Drama) {
        if (busy || !allowed) return; busy = true; stop = false
        action { try {
            operation = "正在读取 ${drama.title} 的最新分集"; val detail = repo.detail(drama, true)
            val preferences = repo.store.json("downloadPreferences"); val episodes = detail.episodes.filter { preferences.optBoolean("includeVip") || !it.json.optBoolean("vip") }.distinctBy { it.number }
            require(episodes.isNotEmpty()) { "暂未取得分集，请更新资料后重试" }; var added = 0
            for ((i, chunk) in episodes.chunked(500).withIndex()) { check(!stop && epoch == repo.store.epoch && repo.store.canDownload) { "更新已停止；已加入的任务保留" }; operation = "正在检查 ${drama.title} · ${minOf(i * 500 + chunk.size, episodes.size)}/${episodes.size} 集"; added += repo.enqueue(detail, chunk, preferences.optInt("quality"), update = true) }
            message(if (added == 0) "本剧暂无需要补充的分集" else "已加入 $added 集；已有完整文件和暂停中的任务保留"); refresh()
        } finally { busy = false; operation = "" } }
    }
    fun play(job: JSONObject) {
        val complete = jobs.filter { it.text("state") == "completed" && it.getJSONObject("drama").text("id") == job.getJSONObject("drama").text("id") }.sortedBy { it.optInt("index") }
        nav(Route("downloadPlayback", Drama(job.getJSONObject("drama")), payload = obj("jobs" to JSONArray(complete), "index" to complete.indexOfFirst { it.text("id") == job.text("id") })))
    }
    val groups = downloadCollections(jobs, query, filter, release) { repo.source(it)?.name.orEmpty() }
    if (!allowed) { StatusPanel("当前用户无权访问下载", "请返回后重新操作。"); return }
    Page(if (selecting) "已选 ${selected.size} 项" else "下载合集", back, actions = {
        if (selecting) { IconAction("select_all_rounded", "全选当前", !busy) { select(groups.flatten()) }; IconAction("close_rounded", "退出多选", !busy) { selecting = false; selected = emptySet(); retry = null } }
        else { IconAction("filter_list_rounded", "筛选下载合集") { filters = true }; IconAction("checklist_rounded", "多选下载任务") { selecting = true }; IconAction("video_library_outlined", "本地媒体与合并") { nav(Route("localMedia")) } }
        Box { IconAction("more_vert_rounded", "队列操作", !busy) { queueMenu = true }; DropdownMenu(queueMenu, { queueMenu = false }) { linkedMapOf("pause" to "全部暂停", "resume" to "全部继续", "archive" to "清理已完成任务，保留视频", "refresh" to "刷新记录").forEach { (id, label) -> DropdownMenuItem(text = { Text(label) }, onClick = hapticClick { queueMenu = false; if (id == "refresh") action { refresh() } else batch(id, jobs) }) } } }
    }) { padding -> Column(Modifier.fillMaxSize().padding(padding)) {
        OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), placeholder = { Text("搜索剧名、站源或分类") }, leadingIcon = { Glyph("search_rounded") }, trailingIcon = { if (query.isNotEmpty()) IconAction("close_rounded", "清空搜索") { query = "" } }, singleLine = true, textStyle = MaterialTheme.typography.bodyLarge, colors = legacyTextFieldColors(), shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp))
        Text("${groups.size} 部 · ${groups.sumOf { it.size }} 集" + if (filter == "archived") " · 已清理任务，视频仍保留" else "", Modifier.padding(horizontal = 18.dp, vertical = 4.dp), style = MaterialTheme.typography.bodySmall)
        if (busy) { LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp)); Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) { Text(operation, Modifier.weight(1f), maxLines = 2); TextButton(hapticClick { stop = true }) { Text("停止") } } }
        if (error != null && jobs.isNotEmpty()) Text(error!!, Modifier.padding(12.dp))
        Box(Modifier.weight(1f)) {
            if (loading) Loading() else if (groups.isEmpty()) StatusPanel(if (error != null && jobs.isEmpty()) "无法读取下载记录" else if (jobs.isEmpty()) "还没有下载任务" else "暂无符合条件的任务", error ?: "在剧集详情选择下载，或调整筛选查看已保留的视频。", onRetry = if (error != null) ({ action { refresh() } }) else null, icon = if (error != null) "movie_filter_outlined" else "download_outlined")
            else LazyColumn(contentPadding = PaddingValues(start = 12.dp, top = 4.dp, end = 12.dp, bottom = 20.dp)) {
                groups.forEach { group -> val drama = Drama(group.first().getJSONObject("drama")); val id = drama.id
                    item(key = id) { var menu by remember { mutableStateOf(false) }; val count = group.count { it.text("id") in selected }; val active = group.count(::downloadActive); val failed = group.count { it.text("state") == "failed" }
                        LegacyCard(Modifier.padding(4.dp)) { ListItem(modifier = Modifier.hapticClickable { expanded = if (id in expanded) expanded - id else expanded + id }, leadingContent = {
                            if (selecting) TriStateCheckbox(if (count == 0) ToggleableState.Off else if (count == group.size) ToggleableState.On else ToggleableState.Indeterminate, onClick = hapticClick { select(group) }, enabled = !busy) else Glyph(if (id in expanded) "folder_open_rounded" else "folder_rounded")
                        }, headlineContent = { Text(drama.title, maxLines = 2, overflow = TextOverflow.Ellipsis, fontWeight = appTextWeight(FontWeight.SemiBold)) }, supportingContent = { Text("${group.count { it.text("state") == "completed" }}/${group.size} 集已下载 · ${formatBytes(group.sumOf { it.optLong("bytes") })}" + (if (active > 0) " · $active 项进行中" else "") + (if (failed > 0) " · $failed 项失败" else "")) }, trailingContent = {
                            Box { IconAction("more_vert_rounded", "${drama.title} · 合集操作", !busy) { menu = true }; DropdownMenu(menu, { menu = false }) {
                                val options = linkedMapOf("update" to "更新本剧 · 补充新增与缺失", "select" to "选择本合集", "pause" to "暂停本合集", "resume" to "继续 / 重试本合集", "archive" to "清理已完成任务，保留视频"); if (filter == "archived") options["restore"] = "恢复到任务列表"; options["remove"] = "取消任务并删除视频"
                                options.forEach { (command, label) -> DropdownMenuItem(text = { Text(label) }, onClick = hapticClick { menu = false; when (command) { "update" -> update(drama); "select" -> select(group); else -> batch(command, group) } }) }
                            } }
                        }, colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) }
                    }
                    if (id in expanded) items(group, key = { it.text("id") }) { job -> var menu by remember { mutableStateOf(false) }; val completed = job.text("state") == "completed"
                        LegacyCard(Modifier.padding(start = 16.dp, top = 4.dp, end = 4.dp, bottom = 4.dp)) { Column {
                            ListItem(modifier = Modifier.hapticClickable(enabled = !busy && (selecting || completed)) { if (selecting) select(listOf(job)) else play(job) }, leadingContent = { if (selecting) Checkbox(job.text("id") in selected, hapticToggle { select(listOf(job)) }, enabled = !busy) else Glyph(if (completed) "offline_pin_outlined" else if (job.text("state") == "failed") "error_outline" else "downloading_rounded") }, headlineContent = { Text("第 ${job.optInt("index")} 集" + if (job.getJSONObject("chapter").optBoolean("vip")) " · VIP" else "") }, supportingContent = {
                                Text("${if (job.optBoolean("archived")) "已保留视频" else stateLabel(job.text("state"))} · ${formatBytes(job.optLong("bytes"))}" + (if (job.optInt("actualQuality") > 0) " · ${job.optInt("actualQuality")}P" else "") + (if (job.text("error").isNotEmpty()) "\n${job.text("error")}" else ""))
                            }, trailingContent = { if (!selecting) Box { IconAction("more_vert_rounded", "分集操作", !busy) { menu = true }; DropdownMenu(menu, { menu = false }) {
                                val options = linkedMapOf<String, String>(); if (completed) options["play"] = "本地播放"; if (downloadActive(job)) options["pause"] = "暂停"; if (downloadableCommand(job, "resume")) options["resume"] = "继续 / 重试"; if (completed) options[if (job.optBoolean("archived")) "restore" else "archive"] = if (job.optBoolean("archived")) "恢复任务" else "清理任务，保留视频"; options["remove"] = if (completed) "删除视频" else "取消下载"
                                options.forEach { (command, label) -> DropdownMenuItem(text = { Text(label) }, onClick = hapticClick { menu = false; if (command == "play") play(job) else batch(command, listOf(job)) }) }
                            } } }, colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow))
                            if (!completed) {
                                val progress = job.optDouble("progress", 0.0).toFloat().coerceIn(0f, 1f)
                                val track = Modifier.fillMaxWidth().height(2.dp)
                                if (progress == 0f && downloadActive(job)) LinearProgressIndicator(track)
                                else LinearProgressIndicator(progress = { progress }, modifier = track)
                            }
                        } }
                    }
                }
            }
        }
        if (selecting) Surface(color = MaterialTheme.colorScheme.surfaceContainerHighest) {
            FlowRow(Modifier.fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.Center) {
                if (busy) TextButton(hapticClick { stop = true }) { Text("停止批量操作") }
                else {
                    linkedMapOf("pause" to "暂停", "resume" to "继续 / 重试", "archive" to "保留视频", "remove" to "删除").forEach { (command, label) ->
                        TextButton(hapticClick { batch(command, jobs.filter { it.text("id") in selected }) }, enabled = selected.isNotEmpty()) { Text(label) }
                    }
                    retry?.let { command -> Button(hapticClick { batch(command, jobs.filter { it.text("id") in selected }) }) { Text("重试失败项") } }
                }
            }
        }
    } }
    if (filters) { var state by remember { mutableStateOf(filter) }; var status by remember { mutableStateOf(release) }
        LegacyAlertDialog(onDismissRequest = { filters = false }, title = { Text("筛选下载合集") }, text = { Column(Modifier.verticalScroll(rememberScrollState())) { Text("任务状态"); Spacer(Modifier.height(8.dp)); FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) { downloadFilterLabels.forEach { (id, label) -> LegacyChip(state == id, { state = id }, label = { Text(label) }) } }; Spacer(Modifier.height(20.dp)); Text("剧集状态"); FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) { listOf("" to "全部", "ongoing" to "连载中", "finished" to "已完结").forEach { (id, label) -> LegacyChip(status == id, { status = id }, label = { Text(label) }) } } } }, confirmButton = { TextButton(hapticClick { filter = state; release = status; filters = false }) { Text("应用") } }, dismissButton = { TextButton(hapticClick { filters = false }) { Text("取消") } })
    }
    removal?.let { rows -> val completed = rows.count { it.text("state") == "completed" }; LegacyAlertDialog(onDismissRequest = { removal = null }, title = { Text(if (completed > 0) "删除所选视频？" else "取消所选下载？") }, text = { Text("共 ${rows.size} 项${if (completed > 0) "，包含 $completed 个已下载视频" else ""}，文件也会删除。\n需要保留视频时，请选择“清理任务，保留视频”。") }, confirmButton = { Button(hapticClick { removal = null; batch("remove", rows, true) }) { Text("确认删除") } }, dismissButton = { TextButton(hapticClick { removal = null }) { Text("保留") } }) }
}

@Composable
fun DownloadPlaybackScreen(drama: Drama, payload: JSONObject, back: () -> Unit) {
    val detail = remember(payload) { Detail(drama, payload.array("jobs").objects().map { Episode(it.getJSONObject("chapter"), it.getInt("index")) }) }
    PlayerScreen(drama, back, payload, suppliedDetail = detail, localOnly = true)
}
