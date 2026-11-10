package com.real.drama.compose

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*
import org.json.JSONObject

class BatchItem(val drama: Drama) {
    var detail by mutableStateOf<Detail?>(null)
    var selected by mutableStateOf(true)
    var loading by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    var added by mutableIntStateOf(0)
    var existing by mutableIntStateOf(0)
    val submitted = mutableSetOf<Int>()
    fun episodes(vip: Boolean) = detail?.episodes.orEmpty().filter { vip || !it.json.optBoolean("vip") }.distinctBy { it.number }.sortedBy { it.number }
    fun pending(vip: Boolean) = episodes(vip).filterNot { it.number in submitted }
}
@Composable
fun BatchDownloadScreen(dramas: List<Drama>, back: () -> Unit) {
    val repo = LocalRepository.current; val nav = LocalNavigate.current; val scope = rememberCoroutineScope()
    val epoch = remember { repo.store.epoch }
    val rows = remember { dramas.distinctBy { it.id }.also { require(it.size <= 50) }.map(::BatchItem) }
    var busy by remember { mutableStateOf(false) }; var submitting by remember { mutableStateOf(false) }; var stopping by remember { mutableStateOf(false) }; var stopped by remember { mutableStateOf(false) }; var locked by remember { mutableStateOf(false) }
    var quality by remember { mutableIntStateOf(repo.store.json("downloadPreferences").optInt("quality")) }
    var vip by remember { mutableStateOf(repo.store.json("downloadPreferences").optBoolean("includeVip")) }
    var current by remember { mutableStateOf<BatchItem?>(null) }
    fun valid() = repo.store.epoch == epoch && repo.store.canDownload
    suspend fun prepare() {
        if (busy || !valid()) return
        busy = true; stopping = false; stopped = false
        try { for (row in rows) {
            if (!valid() || stopping) break
            if (!row.selected || row.detail != null) continue
            current = row; row.loading = true; row.error = null
            try {
                check(repo.store.allowed(row.drama.source)) { "当前用户没有此站源权限" }
                val detail = repo.detail(row.drama)
                check(valid() && detail.drama.id == row.drama.id && detail.drama.source == row.drama.source) { "返回的剧集信息不匹配，请重试" }
                require(detail.episodes.isNotEmpty() && detail.episodes.all { it.number > 0 }) { "未取得可下载的分集，请更新资料后重试" }
                row.detail = detail
            } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { row.error = e.message }
            finally { row.loading = false }
        } } finally { busy = false; current = null }
    }
    suspend fun submit() {
        if (busy || !valid()) return
        busy = true; submitting = true; locked = true; stopping = false; stopped = false
        try { for (row in rows.filter { it.selected && it.detail != null }) {
            if (!valid() || stopping) break
            current = row; row.error = null
            for (chunk in row.pending(vip).chunked(500)) {
                if (!valid() || stopping) break
                try { val count = repo.enqueue(row.detail!!, chunk, quality); row.added += count; row.existing += chunk.size - count; row.submitted.addAll(chunk.map { it.number }) }
                catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { row.error = e.message; break }
            }
        } } finally { busy = false; submitting = false; current = null }
    }
    LaunchedEffect(Unit) { prepare() }
    Page("批量下载", back) { padding -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.TopCenter) {
        if (!valid()) StatusPanel("下载权限已变更", "请返回后重新选择短剧。") else Column(Modifier.widthIn(max = 1000.dp).fillMaxSize()) {
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp))
            LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(start = 16.dp, top = 12.dp, end = 16.dp, bottom = 16.dp)) {
                item {
                    Text("${rows.size} 部短剧", style = MaterialTheme.typography.titleLarge); Spacer(Modifier.height(8.dp)); Text("先读取分集，再加入下载。默认选择非 VIP 集，已有任务自动跳过。")
                    Spacer(Modifier.height(12.dp))
                    var qualityMenu by remember { mutableStateOf(false) }
                    Box { LegacyOutlinedButton({ qualityMenu = true }, Modifier.fillMaxWidth(), enabled = !busy && !locked) { Text("下载画质：${if (quality == 0) "自动 · 优先高清" else "${quality}P"}") }
                        DropdownMenu(qualityMenu, { qualityMenu = false }) { listOf(0, 1080, 720, 480).forEach { value -> DropdownMenuItem(text = { Text(if (value == 0) "自动 · 优先高清" else "${value}P") }, onClick = hapticClick { quality = value; qualityMenu = false }) } } }
                    Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(vip, hapticToggle { vip = it }, enabled = !busy && !locked); Column { Text("包含 VIP 分集"); Text("VIP 集可能只能下载试看内容", style = MaterialTheme.typography.bodySmall) } }
                    current?.let { Text("${if (submitting) "正在添加" else "正在读取"}：${it.drama.title}") }
                }
                items(rows, key = { it.drama.id }) { row -> LegacyCard(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(row.selected, hapticToggle { row.selected = it }, enabled = !busy && !locked)
                        Column(Modifier.weight(1f)) {
                            Text(row.detail?.drama?.title ?: row.drama.title)
                            val count = row.episodes(vip).size
                            Text(when { row.loading -> "正在读取分集"; row.error != null -> row.error!!; row.detail == null -> "等待读取分集"; count == 0 -> "没有非 VIP 分集，可手动选择包含 VIP"; else -> listOf("已选 $count 集", "新增 ${row.added} 集", "已有 ${row.existing} 集", row.detail!!.warning).filter { it.isNotEmpty() }.joinToString(" · ") }, color = if (row.error != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                } }
            }
            Column(Modifier.fillMaxWidth().padding(start = 16.dp, top = 8.dp, end = 16.dp, bottom = 16.dp)) {
                Text("新增 ${rows.sumOf { it.added }} 集 · 已有 ${rows.sumOf { it.existing }} 集" + if (stopped) " · 已停止后续添加，已加入任务继续下载" else "")
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (busy) LegacyOutlinedButton({ stopping = true; stopped = true }, enabled = !stopping) { Text(if (stopping) "正在停止…" else "停止后续添加") }
                    else {
                        LegacyOutlinedButton({ scope.launch { prepare() } }, enabled = rows.any { it.selected && it.detail == null }) { Text("重试读取") }
                        Button(hapticClick { scope.launch { submit() } }, enabled = rows.any { it.selected && it.pending(vip).isNotEmpty() }) { Text("加入下载 · ${rows.filter { it.selected }.sumOf { it.pending(vip).size }} 集") }
                    }
                    TextButton(hapticClick { nav(Route("downloads")) }) { Text("查看下载") }
                }
            }
        }
    } }
}
