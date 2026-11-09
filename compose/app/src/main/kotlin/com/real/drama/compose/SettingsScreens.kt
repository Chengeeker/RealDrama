package com.real.drama.compose

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.real.drama.BuildConfig
import com.real.drama.R
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.InputStream

fun InputStream.readLimited(limit: Int): ByteArray {
    val output = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(16384)
    while (true) { val count = read(buffer); if (count < 0) break; require(output.size() + count <= limit) { "文件超过允许大小" }; output.write(buffer, 0, count) }
    return output.toByteArray()
}
@Composable
fun SettingsScreen() {
    val repo = LocalRepository.current; val nav = LocalNavigate.current
    val action = rememberAction(); val context = LocalContext.current; var about by remember { mutableStateOf(false) }
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri -> if (uri != null) action {
        val bytes = repo.diagnostics.export()
        withContext(Dispatchers.IO) { context.contentResolver.openOutputStream(uri, "wt")!!.use { it.write(bytes) } }
    } }
    SettingsColumn(embedded = true) {
        SettingsSection("最近观看") { SettingRow("最近观看", "当前设备 · ${repo.store.history().size} 部", "history_rounded", onClick = { nav(Route("history")) }) }
        SettingsSection("站源管理") { SettingRow("站源管理", "订阅与更新、启用与维护", "dns_outlined", onClick = { nav(Route("sourceManagement")) }) }
        SettingsSection("首页与推荐") { SettingRow("首页与推荐", "首页偏好、画质和猜你喜欢", "tune_rounded", onClick = { nav(Route("homeSettings")) }) }
        SettingsSection("播放设置") { SettingRow("播放设置", icon = "play_circle_outline_rounded", onClick = { nav(Route("playbackSettings")) }) }
        SettingsSection("常规") { SettingRow("个性化", icon = "palette_outlined", onClick = { nav(Route("personalization")) }) }
        if (repo.store.canDownload) SettingsSection("下载") { SettingRow("下载设置", icon = "download_rounded", onClick = { nav(Route("downloadSettings")) }) }
        if (repo.store.admin) {
            SettingsSection("管理") { SettingRow("网络与资源", icon = "settings_ethernet_rounded", onClick = { nav(Route("resources")) }) }
            SettingsSection("备份") { SettingRow("备份设置", icon = "backup_outlined", onClick = { nav(Route("backup")) }) }
        }
        SettingsSection("问题排查") { SettingRow("导出日志", icon = "bug_report_outlined", onClick = { export.launch("RealDrama-logs-${System.currentTimeMillis()}.json") }, trailing = { Glyph("file_upload_outlined") }) }
        SettingsSection("关于") { SettingRow("关于应用", icon = "info_outline_rounded", onClick = { about = true }) }
    }
    if (about) Dialog({ about = false }, DialogProperties(usePlatformDefaultWidth = false)) {
        FlutterDialogDim()
        Surface(
            Modifier.padding(horizontal = 40.dp, vertical = 24.dp).widthIn(min = 280.dp, max = 560.dp),
            shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh,
        ) {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Row(Modifier.padding(start = 24.dp, top = 24.dp, end = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                    Image(painterResource(R.drawable.app_icon), "RealDrama 应用图标", Modifier.size(64.dp).clip(RoundedCornerShape(16.dp)))
                    Spacer(Modifier.width(16.dp))
                    Column(Modifier.weight(1f)) {
                        Text("RealDrama", style = MaterialTheme.typography.titleLarge.copy(fontWeight = appTextWeight(FontWeight.SemiBold)), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Spacer(Modifier.height(4.dp))
                        Text("版本 ${BuildConfig.VERSION_NAME}", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                Text("作品收藏、作者关注与观看记录保存在当前设备。作者关注不会修改源站账号。",
                    Modifier.padding(start = 24.dp, top = 20.dp, end = 24.dp, bottom = 8.dp),
                    style = MaterialTheme.typography.bodyMedium)
                FlowRow(
                    Modifier.fillMaxWidth().padding(start = 16.dp, top = 8.dp, end = 16.dp, bottom = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
                ) {
                    TextButton(hapticClick { about = false; nav(Route("licenses")) }) { Text("查看许可") }
                    TextButton(hapticClick { about = false }) { Text("关闭") }
                }
            }
        }
    }
}
@Composable
fun SettingsPage(page: String, back: () -> Unit) {
    val repo = LocalRepository.current; val nav = LocalNavigate.current; val action = rememberAction()
    val titles = mapOf("sourceManagement" to "站源管理", "homeSettings" to "首页与推荐", "playbackSettings" to "播放设置", "personalization" to "个性化", "downloadSettings" to "下载设置", "resources" to "网络与资源", "backup" to "备份设置", "homePreferences" to "首页偏好", "recommendationPreferences" to "猜你喜欢", "downloadPreferences" to "下载偏好", "storage" to "下载目录与空间")
    if (page == "homePreferences") { HomePreferencesScreen(back); return }
    if (page == "resources") { ResourceSettingsScreen(back); return }
    if (page == "backup") { BackupScreen(back); return }
    if (page == "storage") { StorageScreen(back); return }
    if (page == "recommendationPreferences") { RecommendationScreen(back); return }
    Page(titles[page] ?: "设置", back) { padding -> SettingsColumn(padding) {
        when (page) {
            "sourceManagement" -> SettingsSection("站源") {
                SettingRow("订阅与更新", "添加站源、更新程序和管理订阅版本", "extension_outlined", onClick = { nav(Route("subscriptions")) })
                SettingRow("启用与维护", "开关站源、刷新内容目录和检测可用性", "dns_outlined", onClick = { nav(Route("sources")) })
            }
            "homeSettings" -> {
                SettingsSection("首页信息流") {
                    SettingRow("首页偏好", icon = "tune_rounded", onClick = { nav(Route("homePreferences")) })
                    Row(Modifier.padding(horizontal = 16.dp, vertical = 14.dp)) {
                        Box(Modifier.width(40.dp).padding(top = 2.dp)) { Glyph("high_quality_rounded") }; Spacer(Modifier.width(16.dp))
                        Column(Modifier.weight(1f)) { Text("首页画质", style = MaterialTheme.typography.titleMedium); Spacer(Modifier.height(8.dp)); SettingsDropdown(repo.store.json("playback").optInt("homeQuality").toString(), (listOf(0, 2160, 1440, 1080, 720, 480, 360) + repo.store.json("playback").optInt("homeQuality")).distinct().sortedWith(compareBy<Int> { it != 0 }.thenByDescending { it }).map { it.toString() to if (it == 0) "自动最高" else "${it}P" }, filled = false) { value -> action { repo.store.set("playback", repo.store.json("playback").put("homeQuality", value.toInt())) } } }
                    }
                    SettingRow("猜你喜欢", icon = "auto_awesome_rounded", onClick = { nav(Route("recommendationPreferences")) })
                }
            }
            "playbackSettings" -> {
                val p = repo.store.json("playback")
                fun save(name: String, value: Any) = action { repo.store.set("playback", repo.store.json("playback").put(name, value)) }
                SettingsSection("解码与内存") {
                    SwitchRow("硬件解码", p.optBoolean("hardwareDecoding", true), icon = "memory_rounded") { save("hardwareDecoding", it) }
                    Row(Modifier.padding(horizontal = 16.dp, vertical = 14.dp)) {
                        Box(Modifier.width(40.dp).padding(top = 2.dp)) { Glyph("developer_board_outlined") }
                        Spacer(Modifier.width(16.dp))
                        Column(Modifier.weight(1f)) {
                            Text("硬件解码器", style = MaterialTheme.typography.titleMedium); Spacer(Modifier.height(8.dp))
                            SettingsDropdown(p.text("hardwareDecoder", "automatic"), listOf("automatic" to "自动（安全）", "copy" to "自动（复制）", "mediaCodec" to "MediaCodec", "mediaCodecCopy" to "MediaCodec（复制）"), enabled = p.optBoolean("hardwareDecoding", true), filled = false) { save("hardwareDecoder", it) }
                        }
                    }
                    SwitchRow("低内存模式", p.optBoolean("lowMemory"), icon = "savings_outlined") { save("lowMemory", it) }
                }
            }
            "personalization" -> PersonalizationSettings()
            "downloadSettings" -> {
                SettingsSection("下载任务") {
                    SettingRow("下载合集", icon = "download_rounded", onClick = { nav(Route("downloads")) })
                    SettingRow("下载偏好", repo.store.json("downloadPreferences").optInt("quality").let { if (it == 0) "自动 · 优先高清" else "${it}P" }, icon = "download_outlined", onClick = { nav(Route("downloadPreferences")) })
                    SettingRow("下载目录与空间", icon = "folder_outlined", onClick = { nav(Route("storage")) })
                }
                if (repo.store.admin) DownloadSavingSettings()
                if (repo.store.admin) SettingsSection("完成后处理") {
                    SwitchRow("下载完成后自动导出 Emby", repo.store.bool("autoExport", global = true)) { action { repo.store.set("autoExport", it, true); if (it) DownloadService.start(repo.context) } }
                    SwitchRow("同时导出海报文件", repo.store.bool("exportPosters", global = true)) { action { repo.store.set("exportPosters", it, true) } }
                }
            }
            "downloadPreferences" -> {
                val p = repo.store.json("downloadPreferences")
                Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.settingsCardColor()) { Column {
                    SettingRow("默认画质")
                    Column(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp)) {
                        SettingsDropdown(p.optInt("quality").toString(), listOf("0" to "自动 · 优先高清", "1080" to "1080P", "720" to "720P", "480" to "480P"), enabled = repo.store.canDownload, label = "下载画质", formField = true) { action { repo.store.set("downloadPreferences", p.copy().put("quality", it.toInt())) } }
                    }
                    SwitchRow("默认包含 VIP 集", p.optBoolean("includeVip"), enabled = repo.store.canDownload) { action { repo.store.set("downloadPreferences", p.copy().put("includeVip", it)) } }
                } }
                Text("偏好保存在当前用户中，应用于下载选集、批量下载和更新本剧。", Modifier.padding(16.dp))
            }
        }
    } }
}
val qualities = listOf("0" to "自动", "360" to "360P", "480" to "480P", "720" to "720P", "1080" to "1080P", "1440" to "2K", "2160" to "4K")
@Composable
fun DownloadSavingSettings() {
    val repo = LocalRepository.current; val action = rememberAction()
    var settings by remember { mutableStateOf<JSONObject?>(null) }; var busy by remember { mutableStateOf(false) }; var failure by remember { mutableStateOf<String?>(null) }; var retry by remember { mutableIntStateOf(0) }
    LaunchedEffect(retry) { busy = true; try { settings = NativeBridge.call(obj("action" to "resourceSettings")); failure = null } catch (cancel: CancellationException) { throw cancel } catch (error: Exception) { failure = error.message } finally { busy = false } }
    SettingsSection("保存方式") {
        if (settings != null) SwitchRow("按站源分类保存", settings!!.optBoolean("downloadBySource"), enabled = !busy) { value -> action { busy = true; try { repo.store.requireAdmin(); settings = NativeBridge.call(obj("action" to "saveResourceSettings", "settings" to settings!!.copy().put("downloadBySource", value))); failure = null } catch (error: Exception) { failure = error.message } finally { busy = false } } }
        else if (busy) SettingRow("正在读取下载保存设置") else SettingRow("无法读取下载保存设置", failure.orEmpty(), trailing = { IconAction("refresh_rounded", "重试") { retry++ } })
        if (settings != null && failure != null) Text(failure!!, Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.error)
    }
}
@Composable
fun SubscriptionsScreen(back: () -> Unit) {
    val repo = LocalRepository.current; val action = rememberAction(); val context = LocalContext.current
    val message = LocalMessage.current
    val installed by repo.subscriptions.installed.collectAsState(); val problems by repo.subscriptions.problems.collectAsState()
    var input by remember { mutableStateOf(Subscriptions.official) }
    var adding by remember { mutableStateOf(installed.isEmpty()) }
    var preview by remember { mutableStateOf<SubscriptionPreview?>(null) }
    var selected by remember { mutableStateOf(setOf<String>()) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf("") }
    var remove by remember { mutableStateOf<SourcePackage?>(null) }
    var update by remember { mutableStateOf<Pair<SubscriptionPreview, JSONObject>?>(null) }
    fun run(work: suspend () -> Unit) {
        if (busy) return
        busy = true
        error = ""
        action {
            try { work() }
            catch (cancel: kotlinx.coroutines.CancellationException) { throw cancel }
            catch (failure: Exception) { error = failure.message ?: "操作失败，原站源与用户配置已保留" }
            finally { busy = false }
        }
    }
    fun load() = run {
        preview = null
        selected = emptySet()
        preview = repo.subscriptions.preview(input)
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> if (uri != null) action {
        if (!busy) { busy = true; try {
            val bytes = withContext(Dispatchers.IO) { context.contentResolver.openInputStream(uri)!!.use { it.readLimited(4 * 1024 * 1024) } }
            repo.subscriptions.importLocal(bytes)
        } finally { busy = false } }
    } }
    Page("订阅与更新", back) { padding -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.TopCenter) { Column(Modifier.widthIn(max = 800.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp)) {
        Text("已安装 ${installed.size} 个订阅", style = MaterialTheme.typography.titleLarge)
        Spacer(Modifier.height(8.dp)); Text("订阅用于安装和更新站源程序；内容列表与站源开关在“启用与维护”中管理。")
        Spacer(Modifier.height(16.dp)); FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(hapticClick { action { busy = true; try { val count = repo.subscriptions.updateAll(); message(if (repo.subscriptions.problems.value.isNotEmpty()) "已更新 $count 个订阅，部分订阅失败，详情见下方" else if (count == 0) "在线订阅已是最新版本，本地导入不参与检查" else "已更新 $count 个订阅，本地导入不参与检查") } finally { busy = false } } }, enabled = !busy && installed.any { it.origin.startsWith("https://") }, contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) { Glyph("sync_rounded", size = 18); Spacer(Modifier.width(8.dp)); Text("检查并更新全部") }
            if (installed.isNotEmpty()) LegacyOutlinedButton({ adding = !adding }, enabled = !busy, contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) { Glyph(if (adding) "close" else "add", size = 18); Spacer(Modifier.width(8.dp)); Text(if (adding) "收起添加" else "添加订阅") }
        }
        if (busy || remove != null || update != null) { Spacer(Modifier.height(16.dp)); LinearProgressIndicator(Modifier.fillMaxWidth()); Spacer(Modifier.height(8.dp)); Text("正在处理订阅，请稍候…") }
        if (error.isNotEmpty()) Text(error, Modifier.padding(vertical = 12.dp), color = MaterialTheme.colorScheme.error)
        Spacer(Modifier.height(16.dp))
        if (adding || installed.isEmpty()) LegacyCard(Modifier.padding(4.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.settingsCardColor())) {
            Column(Modifier.fillMaxWidth().padding(16.dp)) {
                Text("添加订阅", style = MaterialTheme.typography.titleMedium); Spacer(Modifier.height(12.dp))
                TextField(input, { input = it; preview = null }, Modifier.fillMaxWidth(), enabled = !busy, singleLine = true, label = { Text("GitHub 仓库、订阅或单个站源链接") }, shape = androidx.compose.ui.graphics.RectangleShape, keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Uri, imeAction = androidx.compose.ui.text.input.ImeAction.Done), keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { load() }), textStyle = MaterialTheme.typography.bodyLarge, colors = TextFieldDefaults.colors(focusedContainerColor = MaterialTheme.colorScheme.surfaceContainer, unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainer, focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent, unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent))
                Spacer(Modifier.height(12.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(hapticClick(::load), enabled = !busy, contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) { Glyph("cloud_download_outlined", size = 18); Spacer(Modifier.width(8.dp)); Text("获取站源列表") }
                    LegacyOutlinedButton({ picker.launch(arrayOf("application/json", "text/plain", "application/octet-stream")) }, enabled = !busy, contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) { Glyph("file_open_outlined", size = 18); Spacer(Modifier.width(8.dp)); Text("导入本地站源") }
                }
                Spacer(Modifier.height(12.dp)); Text("导入后在设备本地运行，更新站源无需重新安装应用。请选择你信任的订阅仓库。Cookie 只保存在本机，不会上传到订阅仓库。导入保留已有开关设置，新站源可在站源管理中开启。")
            }
        }
        if (adding || installed.isEmpty()) preview?.let { result ->
            Text(result.name, Modifier.padding(vertical = 12.dp), style = MaterialTheme.typography.titleMedium)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(hapticClick { selected = result.entries.map { it.text("id") }.toSet() }, enabled = !busy) { Text("全选") }
                TextButton(hapticClick { selected = emptySet() }, enabled = !busy) { Text("清空选择") }
                Button(hapticClick {
                    run {
                        val epoch = repo.store.epoch
                        var count = 0
                        val failures = mutableListOf<String>()
                        for (entry in result.entries.filter { it.text("id") in selected }) {
                            check(repo.store.epoch == epoch && repo.store.admin) { "用户已切换" }
                            try {
                                repo.subscriptions.install(result, entry)
                                selected = selected - entry.text("id")
                                count++
                            } catch (cancel: kotlinx.coroutines.CancellationException) { throw cancel }
                            catch (failure: Exception) {
                                failures.add("${entry.text("name")}：${failure.message ?: "站源解析或安装失败"}")
                            }
                        }
                        if (failures.isNotEmpty()) error = "以下站源未导入，其余已保留：${failures.joinToString("、")}"
                        else {
                            selected = emptySet()
                            preview = null
                            adding = false
                            message("已添加 $count 个订阅，可在“启用与维护”中开启站源")
                        }
                    }
                }, enabled = selected.isNotEmpty() && !busy, contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) {
                    Glyph("download_done_outlined", size = 18)
                    Spacer(Modifier.width(8.dp))
                    Text("导入并订阅 ${selected.size} 个站源")
                }
            }
            result.entries.forEach { entry ->
                val id = entry.text("id")
                val children = entry.array("children").objects()
                fun toggle() { selected = if (id in selected) selected - id else selected + id }
                LegacyCard(Modifier.fillMaxWidth().padding(4.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.settingsCardColor())) {
                    SettingRow("${entry.text("name")} · ${entry.text("version")}",
                        if (children.isEmpty()) "" else "包含：${children.joinToString("、") { it.text("name") }}",
                        enabled = !busy, onClick = ::toggle, trailing = { Checkbox(id in selected, hapticToggle { toggle() }, enabled = !busy) })
                }
            }
            Spacer(Modifier.height(24.dp))
        }
        if (installed.isEmpty()) Text("尚未安装订阅。获取列表后选择站源，再点“导入并订阅”。", Modifier.padding(vertical = 16.dp))
            installed.forEach { item ->
                LegacyCard(Modifier.fillMaxWidth().padding(bottom = 12.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.settingsCardColor())) { Column(Modifier.padding(16.dp)) {
                    var menu by remember(item.id) { mutableStateOf(false) }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("${item.name} · ${item.version}", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                        Box { IconAction("more_vert_rounded", "${item.name}更多操作", !busy) { menu = true }
                            DropdownMenu(menu, { menu = false }) {
                                if (!item.origin.startsWith("local:")) DropdownMenuItem(text = { Text("复制订阅链接") }, onClick = hapticClick { menu = false; context.getSystemService(android.content.ClipboardManager::class.java).setPrimaryClip(android.content.ClipData.newPlainText("订阅链接", repo.subscriptions.independentLink(item.id))) })
                                val previous = repo.subscriptions.previousVersion(item.id)
                                if (previous.isNotEmpty()) DropdownMenuItem(text = { Text("回退到 $previous") }, onClick = hapticClick { menu = false; action { busy = true; try { repo.subscriptions.rollback(item.id) } finally { busy = false } } })
                                DropdownMenuItem(text = { Text("移除订阅") }, onClick = hapticClick { menu = false; remove = item })
                            }
                        }
                    }
                    if (item.document.has("children") && item.sources.isNotEmpty()) Text("包含：${item.sources.joinToString("、") { it.name }}")
                    Spacer(Modifier.height(4.dp)); Text(if (item.origin.startsWith("local:")) "本地导入 · 需重新导入文件更新" else "在线订阅 · ${java.net.URI(item.origin).host}")
                    if (!item.origin.startsWith("local:")) { Spacer(Modifier.height(8.dp)); TextButton(hapticClick { action { busy = true; try { update = repo.subscriptions.checkUpdates(item.id).firstOrNull(); if (update == null && repo.subscriptions.problems.value.isEmpty()) message("此订阅已是最新版本") } finally { busy = false } } }, enabled = !busy) { Glyph("update_rounded", size = 18); Spacer(Modifier.width(8.dp)); Text("检查并更新此订阅") } }
                } }
            }
        problems.forEach { Text(it, Modifier.padding(8.dp), color = MaterialTheme.colorScheme.error) }
        Spacer(Modifier.height(24.dp))
    } } }
    update?.let { (p, entry) -> LegacyAlertDialog(onDismissRequest = { update = null }, title = { Text("更新 ${entry.text("name")}") }, text = { Text("版本：${installed.firstOrNull { it.id == entry.text("id") }?.version} → ${entry.text("version")}\n${entry.text("changelog")}\n\n站源脚本由此订阅仓库提供。") }, confirmButton = { Button(hapticClick { update = null; action { busy = true; try { repo.subscriptions.install(p, entry) } finally { busy = false } } }) { Text("更新站源") } }, dismissButton = { TextButton(hapticClick { update = null }) { Text("取消") } }) }
    remove?.let { item ->
        LegacyAlertDialog(
            onDismissRequest = { remove = null }, title = { Text("移除站源") },
            text = { Text("移除订阅与站源程序。观看记录、收藏和本地账号配置保留，重新导入相同站源后仍可使用。") },
            dismissButton = { TextButton(hapticClick { remove = null }) { Text("取消") } },
            confirmButton = { TextButton(hapticClick { remove = null; run { repo.subscriptions.remove(item.id) } }) { Text("移除") } },
        )
    }
}
@Composable
fun SourcesScreen(back: () -> Unit) {
    val repo = LocalRepository.current; val nav = LocalNavigate.current; val action = rememberAction()
    val installed by repo.subscriptions.installed.collectAsState()
    val statuses by repo.maintenance.states.collectAsState(); val storageErrors by repo.storageErrors.collectAsState()
    var expanded by remember { mutableStateOf(false) }
    var pendingEnable by remember { mutableStateOf<Pair<Set<String>, String?>?>(null) }
    val active = LocalScreenActive.current
    LaunchedEffect(active) { if (active) pendingEnable?.let { (ids, family) -> pendingEnable = null; if (repo.secrets.read("cookie.douyin.${repo.store.active}").isNotEmpty()) repo.store.enableSources(ids, true, family) } }
    val authorized = repo.subscriptions.sources
    val managementGroups = authorized.groupBy { source ->
        if (source.group in setOf("douyin", "bilibili")) "${source.group}${if (source.id.endsWith("-test")) "-test" else ""}-family"
        else source.catalogGroup
    }

    fun enable(sources: List<SourcePackage>, visible: Boolean, family: String? = null) = action {
        if (visible && sources.any { it.group == "douyin" } && repo.secrets.read("cookie.douyin.${repo.store.active}").isEmpty()) { pendingEnable = sources.map { it.id }.toSet() to family; nav(Route("sourceSettings", source = sources.first().id)) }
        else repo.store.enableSources(sources.map { it.id }.toSet(), visible, family)
    }
    LaunchedEffect(installed, repo.store.epoch) { repo.available().forEach { repo.maintenance.refresh(it.id) } }
    fun familyName(id: String, members: List<SourcePackage>) = when {
        id.startsWith("douyin-") -> "抖音" + if ("test" in id) "（测试版）" else ""
        id.startsWith("bilibili-") -> "Bilibili" + if ("test" in id) "（测试版）" else ""
        else -> members.first().catalogName
    }
    fun grouped(id: String, members: List<SourcePackage>) = id == "huangguo" || members.first().group in setOf("douyin", "bilibili")
    val enabledSources = repo.available()
    val groups = managementGroups.entries.sortedByDescending { (_, members) -> members.count { repo.store.allowed(it.id) } }
    Page("启用与维护", back, actions = {
        IconAction("refresh_rounded", "刷新全部内容目录", enabledSources.isNotEmpty()) { enabledSources.forEach { repo.maintenance.start(it.id, "update") } }
        IconAction("wifi_rounded", "检测全部站源连接与播放", enabledSources.isNotEmpty()) { enabledSources.forEach { repo.maintenance.start(it.id, "check") } }
    }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.TopCenter) {
            LazyColumn(Modifier.widthIn(max = 960.dp).fillMaxWidth(), contentPadding = PaddingValues(16.dp)) {
                item {
                    Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.settingsCardColor()) {
                        Text("在这里启用站源、刷新内容目录或检测连接与播放。刷新目录会查找新内容，不更新站源程序；程序更新请前往“订阅与更新”。", Modifier.padding(16.dp))
                    }
                    Spacer(Modifier.height(16.dp))
                    SourceSection("启用站源", "已启用 ${groups.count { (_, members) -> members.any { repo.store.allowed(it.id) } }}/${groups.size} 组 · 展开调整开关",
                        "visibility_outlined", expanded, { expanded = !expanded }) {
                        groups.forEach { (family, members) ->
                            val familyGroup = grouped(family, members)
                            val count = members.count { repo.store.allowed(it.id) }
                            val group = members.first().group
                            val label = familyName(family, members)
                            val subtitle = if (familyGroup) "已开启 $count/${members.size} · 子项在下方管理" else ""
                            SettingRow(label, subtitle, trailing = {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    if (group in setOf("douyin", "bilibili")) IconAction("manage_accounts_outlined", if (group == "douyin") "统一配置抖音 Cookie" else "统一配置 Bilibili Cookie") {
                                        nav(Route("sourceSettings", source = members.first().id))
                                    }
                                    Switch(count > 0, hapticToggle { enable(members, it, family.takeIf { familyGroup }) })
                                }
                            })
                            Spacer(Modifier.height(8.dp))
                        }
                    }
                    Spacer(Modifier.height(12.dp))
                }
                if (enabledSources.isEmpty()) item { Text("没有已开启的站源，请先导入订阅或开启已安装站源", Modifier.padding(24.dp)) }
                groups.forEach { (family, members) ->
                    val familyGroup = grouped(family, members)
                    if (familyGroup) item(key = family) {
                        var open by remember { mutableStateOf(false) }
                        val label = familyName(family, members)
                        val subtitle = when {
                            family == "huangguo" -> "${members.size} 个入口 · ${members.sumOf { statuses[it.id]?.optInt("count") ?: 0 }} 部"
                            "test" in family -> "独立测试来源 · 共用原版 Cookie"
                            family == "douyin-family" -> "短视频、直播、短剧、放映厅 · 共用一个 Cookie"
                            else -> "视频、直播 · 共用一个 Cookie"
                        }
                        SourceSection(label, subtitle, if (family == "huangguo") "hub_outlined" else "video_library_outlined", open, { open = !open }) {
                            members.forEach { source ->
                                key(source.id) { SourceMaintenanceCard(source, statuses[source.id], storageErrors[source.id], true) { enable(listOf(source), it) } }
                                Spacer(Modifier.height(16.dp))
                            }
                        }
                        Spacer(Modifier.height(16.dp))
                    } else items(members.filter { repo.store.allowed(it.id) }, key = { it.id }) { source ->
                        SourceMaintenanceCard(source, statuses[source.id], storageErrors[source.id], false) { enable(listOf(source), it) }
                        Spacer(Modifier.height(16.dp))
                    }
                }
            }
        }
    }
}

@Composable
private fun SourceSection(title: String, subtitle: String, icon: String, expanded: Boolean, toggle: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.settingsCardColor()) {
        Column {
            SettingRow(title, subtitle, icon, onClick = toggle, trailing = { Glyph(if (expanded) "expand_less_rounded" else "expand_more_rounded") })
            if (expanded) Column(Modifier.padding(8.dp), content = content)
        }
    }
}

private fun sourceTime(value: String): String = runCatching {
    java.time.Instant.parse(value).atZone(java.time.ZoneId.systemDefault())
        .format(java.time.format.DateTimeFormatter.ofPattern("M/d HH:mm", java.util.Locale.ROOT))
}.getOrDefault("尚无记录")

@Composable
private fun SourceMaintenanceCard(
    source: SourcePackage, status: JSONObject?, storageError: String?, family: Boolean, onVisibility: (Boolean) -> Unit,
) {
    val repo = LocalRepository.current
    val nav = LocalNavigate.current
    val context = LocalContext.current
    val message = LocalMessage.current
    val colors = MaterialTheme.colorScheme
    val state = status ?: JSONObject()
    val visible = repo.store.allowed(source.id)
    val name = if (source.id == "douyin") "抖音短视频" else source.name
    val shape = RoundedCornerShape(20.dp)
    if (!visible) {
        Surface(Modifier.fillMaxWidth(), shape = shape, color = colors.settingsCardColor()) {
            SettingRow(name, "已关闭", trailing = { Switch(false, hapticToggle(onVisibility)) })
        }
        return
    }
    val busy = state.optBoolean("running")
    val count = state.optInt("count")
    val page = state.optInt("page").coerceAtLeast(1)
    val totalPages = state.optInt("totalPages")
    val hasMore = state.optBoolean("hasMore", true)
    val retry = state.optInt("retrySeconds")
    val enabled = !busy && retry <= 0
    var menu by remember { mutableStateOf(false) }
    var healthExpanded by remember { mutableStateOf(false) }
    fun start(operation: String) {
        if (operation == "check" || operation == "checkCatalog") healthExpanded = true
        repo.maintenance.start(source.id, operation)
    }
    Surface(Modifier.fillMaxWidth(), shape = shape, color = colors.settingsCardColor()) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Glyph("dns_outlined", color = colors.onSurfaceVariant)
                Spacer(Modifier.width(12.dp))
                Text(name, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium.copy(fontWeight = appTextWeight(FontWeight.SemiBold)))
                Text("$count ${if (source.kind == "live") "个直播间" else "部"}", color = colors.onSurfaceVariant)
                if (family) Switch(true, hapticToggle(onVisibility), Modifier.padding(horizontal = 4.dp))
            }
            Spacer(Modifier.height(8.dp))
            Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp), color = colors.settingsCardColor(colors.settingsCardColor())) {
                Column(Modifier.padding(horizontal = 12.dp, vertical = 10.dp)) {
                    Text("目录刷新：${sourceTime(state.text("updatedAt"))}", color = colors.onSurfaceVariant)
                    if (count > 0 || page > 1 || totalPages > 0) {
                        Spacer(Modifier.height(4.dp))
                        val pages = when {
                            totalPages > 0 && page >= totalPages -> "共 $totalPages 页 · 已全部加载"
                            totalPages > 0 -> "已加载至第 $page/$totalPages 页 · ${if (hasMore) "可继续加载" else "暂无后续页"}"
                            hasMore -> "已加载至第 $page 页 · 总页数未知，可继续加载"
                            else -> "共 $page 页 · 已全部加载"
                        }
                        Text(pages, color = colors.onSurfaceVariant)
                    }
                }
            }
            Spacer(Modifier.height(12.dp))
            val buttonPadding = PaddingValues(start = 16.dp, end = 24.dp)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (source.id == "hanime") LegacyOutlinedButton({ nav(Route("sourceSettings", source = source.id)) }, enabled = enabled, contentPadding = buttonPadding) {
                    Glyph("manage_accounts_outlined", size = 18); Spacer(Modifier.width(8.dp)); Text("Cookie 设置")
                }
                FilledTonalButton(hapticClick { start("update") }, enabled = enabled, contentPadding = buttonPadding) {
                    Glyph("refresh_rounded", size = 18); Spacer(Modifier.width(8.dp)); Text("刷新目录")
                }
                LegacyOutlinedButton({ start("check") }, enabled = enabled, contentPadding = buttonPadding) {
                    Glyph("wifi_rounded", size = 18); Spacer(Modifier.width(8.dp)); Text("检测连接与播放")
                }
                if (busy) TextButton(hapticClick { healthExpanded = false; repo.maintenance.stop(source.id) }) { Text("停止") }
                if (source.id != "douyin") Box {
                    IconAction("more_vert_rounded", "${source.name}更多操作", enabled) { menu = true }
                    DropdownMenu(menu, { menu = false }) {
                        val operations = linkedMapOf("more" to "继续加载一页")
                        if (source.group != "douyin") {
                            operations["allPages"] = "加载后续所有页"
                            operations["metadata"] = "补齐资料"
                            if (source.id == "huangdou") operations["vipMetadata"] = "补齐 VIP 资料（${state.optInt("unknownVip")} 部）"
                        }
                        operations["checkCatalog"] = "仅检测目录"
                        operations.forEach { (operation, label) ->
                            val optionEnabled = when (operation) {
                                "more", "allPages" -> hasMore
                                "vipMetadata" -> state.optInt("unknownVip") > 0
                                else -> true
                            }
                            DropdownMenuItem(text = { Text(label) }, enabled = optionEnabled, onClick = hapticClick { menu = false; start(operation) })
                        }
                    }
                }
            }
            val total = state.optInt("total")
            if (busy) {
                Spacer(Modifier.height(12.dp))
                if (total > 0) LinearProgressIndicator(progress = { (state.optInt("completed") / total.toFloat()).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth().height(4.dp))
                else LinearProgressIndicator(Modifier.fillMaxWidth().height(4.dp))
                Spacer(Modifier.height(8.dp))
                Text(state.text("stage", "准备中") + if (total > 0) " · ${state.optInt("completed")}/$total" else "")
            } else if (state.text("stage").isNotEmpty()) {
                Spacer(Modifier.height(12.dp))
                Text(state.text("stage") + if (state.optInt("added") > 0) " · 新增 ${state.optInt("added")} 部" else "")
            }
            if (retry > 0) Text("请在 $retry 秒后重试", Modifier.padding(top = 8.dp), color = colors.error)
            val error = state.text("error")
            if (error.isNotEmpty()) SelectionContainer { Text(error, Modifier.padding(top = 8.dp), color = colors.error) }
            storageError?.let {
                Text(it, Modifier.padding(top = 8.dp), color = colors.error)
                TextButton(hapticClick { start("retrySave") }, enabled = !busy) { Glyph("save_outlined", size = 18); Spacer(Modifier.width(8.dp)); Text("重试保存") }
            }
            val health = state.optJSONObject("health")
            if (health == null) {
                Spacer(Modifier.height(12.dp))
                Text("尚未检测连接")
            } else {
                Spacer(Modifier.height(28.dp))
                val label = when (health.text("state")) {
                    "resolved" -> "目录与解析正常 · 实播未检测"
                    "catalogOnly" -> "目录正常 · 播放未检测"
                    else -> "检测未通过"
                }
                val date = sourceTime(health.text("checkedAt"))
                val sample = health.text("sample")
                val steps = health.array("steps").objects()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(hapticClick { healthExpanded = !healthExpanded }, Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 4.dp, vertical = 8.dp),
                        colors = ButtonDefaults.textButtonColors(contentColor = colors.onSurface)) {
                        Column(Modifier.weight(1f)) {
                            Text(label)
                            Text(date, style = MaterialTheme.typography.bodySmall)
                        }
                        Spacer(Modifier.width(8.dp))
                        Glyph(if (healthExpanded) "expand_less_rounded" else "expand_more_rounded")
                    }
                    IconAction("copy_rounded", "复制诊断信息") {
                        val report = buildString {
                            appendLine(name)
                            appendLine("缓存 $count 部，更新 ${sourceTime(state.text("updatedAt"))}")
                            appendLine("$label · $date")
                            if (sample.isNotEmpty()) appendLine("检测剧集：$sample")
                            steps.forEach { appendLine("${it.text("name")}：${it.text("message")}") }
                        }
                        context.getSystemService(android.content.ClipboardManager::class.java)
                            .setPrimaryClip(android.content.ClipData.newPlainText("诊断信息", report))
                        message("诊断信息已复制")
                    }
                }
                if (healthExpanded) {
                    if (sample.isNotEmpty()) Text("检测剧集：$sample")
                    steps.forEach { step ->
                        val ok = step.text("state") == "ok"
                        Row(Modifier.padding(top = 10.dp)) {
                            Glyph(if (ok) "check_circle_outline" else "error_outline", color = if (ok) colors.primary else colors.error, size = 20)
                            Spacer(Modifier.width(8.dp))
                            Text("${step.text("name")}：${step.text("message")}", Modifier.weight(1f))
                        }
                    }
                }
            }
        }
    }
}
