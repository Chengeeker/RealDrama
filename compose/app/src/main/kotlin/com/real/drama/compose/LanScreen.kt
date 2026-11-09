package com.real.drama.compose

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.foundation.shape.RoundedCornerShape
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject

@Composable
fun LanScreen(back: () -> Unit) {
    val repo = LocalRepository.current; val link = repo.lan; val action = rememberAction()
    val context = LocalContext.current; val navigate = LocalNavigate.current
    val revision by link.revision.collectAsState(); val values = repo.store.values
    var devices by remember { mutableStateOf(false) }; var rename by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf(link.name) }
    var manual by remember { mutableStateOf(false) }; var help by remember { mutableStateOf(false) }
    var connectionMenu by remember { mutableStateOf(false) }; var busy by remember { mutableStateOf(false) }
    fun perform(work: suspend () -> Unit) = action { if (!busy) { busy = true; try { work() } finally { busy = false } } }
    val document = remember(revision, values) { repo.store.lanDocument() }
    val count = document.records.values.filter { repo.store.allowed(it.getJSONObject("drama").text("source")) }.sumOf { row -> listOf("member", "status", "progress").count { row.getJSONArray(it).length() > 1 } }
    Page("收藏与进度同步", back) { padding -> SettingsColumn(padding, top = 12, bottom = 32) {
        val cardColors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)
        LegacyCard(Modifier.padding(4.dp), colors = cardColors) { Column {
            SwitchRow("设备互联", link.enabled, "同一局域网直连，接收端无需点击确认", enabled = !busy && !repo.store.locked.value) { perform { link.setting("enabled", it) } }
            SettingRow(link.name, "本机用户 · ${repo.store.profile.text("name")}", "smartphone_rounded", trailing = { IconAction("edit_outlined", "修改设备名称", !busy) { name = link.name; rename = true } })
        } }
        Spacer(Modifier.height(12.dp))
        LegacyCard(Modifier.padding(4.dp), colors = cardColors) { Column {
            SettingRow(link.connection?.peer?.text("name") ?: link.message, link.connection?.let { "对方用户 · ${it.user}" } ?: "仅发现一台设备时自动连接，多台时由发起端选择", "devices_rounded", trailing = {
                if (link.connection != null) Box {
                    IconAction("more_vert_rounded", "设备操作", !busy) { connectionMenu = true }
                    DropdownMenu(connectionMenu, { connectionMenu = false }) {
                        DropdownMenuItem(text = { Text("断开连接") }, onClick = hapticClick { connectionMenu = false; perform { link.disconnect() } })
                        DropdownMenuItem(text = { Text("忘记配对") }, onClick = hapticClick { connectionMenu = false; perform { link.disconnect(true) } })
                    }
                }
            })
            LegacyOutlinedButton({ devices = true }, Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 16.dp), enabled = !busy && !repo.store.locked.value) { Glyph("devices_other_rounded", size = 18); Spacer(Modifier.width(8.dp)); Text(if (link.connection == null) "选择设备" else "切换设备") }
        } }
        Spacer(Modifier.height(12.dp))
        LegacyCard(Modifier.padding(4.dp), colors = cardColors) { Column {
            SwitchRow("自动同步", link.automatic, "同步作品收藏、观看状态和续播进度；作者关注仅保存在本机", enabled = !busy && !link.syncing && !repo.store.locked.value) { perform { link.setting("autoSync", it) } }
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                if (link.syncing) LinearProgressIndicator(Modifier.fillMaxWidth())
                Spacer(Modifier.height(8.dp)); Text(link.syncMessage)
                link.lastSync?.let { Text("最近同步 · ${android.text.format.DateFormat.format("HH:mm", it)}", style = MaterialTheme.typography.bodySmall) }
            }
            Button(hapticClick { if (link.syncing) action { link.cancelSync() } else perform { link.synchronize() } }, Modifier.fillMaxWidth().padding(16.dp), enabled = link.syncing || link.connection != null && !busy) { Glyph(if (link.syncing) "close_rounded" else "sync_rounded", size = 18); Spacer(Modifier.width(8.dp)); Text(if (link.syncing) "取消本次同步" else "立即同步") }
        } }
        if (count > 0) LegacyCard(Modifier.padding(4.dp), colors = cardColors) { SettingRow("$count 项记录待处理", "两端同时修改的内容已保留，选择要继续使用的记录", "compare_arrows_rounded", onClick = { navigate(Route("lanConflicts")) }) }
        SettingRow("手动同步", "双向合并、覆盖对方或覆盖本机", "sync_alt_rounded", enabled = link.connection != null && !busy && !link.syncing, onClick = { link.manual = true; manual = true })
        link.error?.let { Text(it, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error) }
        link.local?.let { local ->
            SettingRow("本机地址与连接帮助", icon = "info_outline_rounded", onClick = { help = !help },
                trailing = { Glyph(if (help) "expand_less_rounded" else "expand_more_rounded") })
            if (help) Column(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 16.dp)) {
                Text("两台设备都需开启设备互联并保持前台。发现失败时，可在另一端输入下列地址；Windows 需允许本应用通过专用网络防火墙。")
                val addresses = local.array("addresses").strings()
                if (addresses.isEmpty()) Text("尚未取得局域网地址，请检查 Wi-Fi 或网线连接。")
                addresses.forEach { address ->
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.weight(1f)) { SelectionContainer { Text(address) } }
                        IconAction("copy_rounded", "复制地址") {
                            context.getSystemService(android.content.ClipboardManager::class.java)
                                .setPrimaryClip(android.content.ClipData.newPlainText("本机地址", address))
                        }
                    }
                }
            }
        }
    } }
    if (rename) LegacyAlertDialog(onDismissRequest = { rename = false }, title = { Text("设备名称") }, text = { OutlinedTextField(name, { if (it.length <= 60) name = it }, label = { Text("在其他设备上显示的名称") }, textStyle = MaterialTheme.typography.bodyLarge, colors = legacyTextFieldColors(), shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp)) }, dismissButton = { TextButton(hapticClick { rename = false }) { Text("取消") } }, confirmButton = { Button(hapticClick { action { require(name.trim().isNotEmpty()); link.setting("name", name.trim()); rename = false } }) { Text("保存") } })
    if (devices) LanDevicesDialog({ devices = false }, { devices = false })
    if (manual) LanManualPanel { manual = false; link.manual = false }
    DisposableEffect(link) { onDispose { link.manual = false } }
}

@Composable
fun LanConflictsScreen(back: () -> Unit) {
    val repo = LocalRepository.current
    val values = repo.store.values
    val rows = remember(values) {
        repo.store.lanDocument().records.values.filter { row ->
            repo.store.allowed(row.getJSONObject("drama").text("source")) &&
                listOf("member", "status", "progress").any { row.array(it).length() > 1 }
        }
    }
    val action = rememberAction()
    Page("处理记录冲突", back) { padding ->
        Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.TopCenter) {
            if (rows.isEmpty()) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("没有待处理的冲突") }
            else LazyColumn(Modifier.widthIn(max = 720.dp).fillMaxWidth(), contentPadding = PaddingValues(16.dp)) {
                items(rows, key = { it.getJSONObject("drama").text("id") }) { row ->
                    val drama = Drama(row.getJSONObject("drama"))
                    val series = repo.source(drama.source)?.kind == "drama"
                    LegacyCard(Modifier.fillMaxWidth().padding(4.dp)) {
                        Column(Modifier.padding(16.dp)) {
                            Text(drama.title, style = MaterialTheme.typography.titleMedium)
                            listOf("member" to "作品收藏", "status" to "观看状态", "progress" to "续播进度").forEach { (field, title) ->
                                val candidates = row.array(field).objects()
                                if (candidates.size < 2 || field == "status" && !series) return@forEach
                                Text(title, Modifier.padding(top = 16.dp, bottom = 4.dp))
                                candidates.forEach { choice ->
                                    val value = choice.opt("value")
                                    val label = when {
                                        field == "member" -> if (value == true) "保留收藏" else "取消收藏"
                                        value !is JSONObject -> "清空续播进度"
                                        field == "status" -> when (value.text("status")) {
                                            "planned" -> "想看"
                                            "watching" -> "在看"
                                            else -> if (value.optBoolean("manual")) "已看 · 手动标记" else "已看"
                                        }
                                        series -> "第 ${value.optInt("episode")} 集 · ${formatPosition(value.optDouble("position"))}"
                                        else -> "${if (repo.source(drama.source)?.kind == "live") "直播" else ""}播放至 ${formatPosition(value.optDouble("position"))}"
                                    }
                                    SettingRow(label, "使用这条记录", "radio_button_unchecked_rounded",
                                        onClick = { action {
                                            val current = repo.store.lanDocument()
                                            check(current.records[drama.id]?.let(::lanHash) == lanHash(row)) { "记录已更新，请重新选择" }
                                            val source = setOf(drama.source)
                                            val updated = JSONObject(canonical(row)).put(field, current.edit(row.getJSONArray(field), value))
                                            repo.store.applyLanRecords(randomToken(), current.hash(source), source, listOf(updated), repo.store.epoch)
                                        } }, trailing = {})
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LanPanel(onDismiss: () -> Unit, dismissible: Boolean = true, backEnabled: Boolean = true, content: @Composable () -> Unit) {
    val screen = LocalConfiguration.current
    val height = minOf(740.dp, screen.screenHeightDp.dp * .88f)
    if (screen.screenWidthDp >= 800) {
        Dialog(onDismiss, DialogProperties(dismissOnBackPress = backEnabled, dismissOnClickOutside = dismissible, usePlatformDefaultWidth = false)) {
            FlutterDialogDim()
            Surface(
                Modifier.padding(horizontal = 40.dp, vertical = 24.dp).width(620.dp).height(height),
                shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh,
            ) { content() }
        }
    } else {
        ModalBottomSheet(
            onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            sheetMaxWidth = 720.dp, sheetGesturesEnabled = dismissible, containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
            scrimColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = .54f),
            properties = ModalBottomSheetProperties(shouldDismissOnBackPress = backEnabled, shouldDismissOnClickOutside = dismissible),
        ) { Box(Modifier.fillMaxWidth().height(height)) { content() } }
    }
}

@Composable
private fun LanManualPanel(onDismiss: () -> Unit) {
    val repo = LocalRepository.current
    val link = repo.lan
    val revision by link.revision.collectAsState()
    val connection = remember(revision) { link.connection } ?: run { LaunchedEffect(Unit) { onDismiss() }; return }
    val name = connection.peer.text("name").ifEmpty { "对方" }
    val scope = rememberCoroutineScope()
    val modes = listOf("merge" to "双向合并", "push" to "覆盖对方", "pull" to "覆盖本机")
    var mode by remember(connection) { mutableStateOf("merge") }
    var preview by remember(connection) { mutableStateOf<LanPreview?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var task by remember { mutableStateOf<Job?>(null) }
    var cancelling by remember { mutableStateOf(false) }
    val busy = task != null || cancelling
    LanPanel(onDismiss = onDismiss, dismissible = false, backEnabled = !busy) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.padding(start = 20.dp, top = 12.dp, end = 12.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("手动同步", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                IconAction("close_rounded", "关闭", enabled = !busy, action = onDismiss)
            }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp)) {
                modes.forEach { (key, label) ->
                    val selected = mode == key
                    val subtitle = when (key) {
                        "merge" -> "本机 ↔ $name · 合并双方记录"
                        "push" -> "本机 → $name · 以本机记录替换对方"
                        else -> "$name → 本机 · 以对方记录替换本机"
                    }
                    LegacyCard(Modifier.fillMaxWidth().padding(4.dp),
                        colors = CardDefaults.cardColors(containerColor = if (selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceContainerLow)) {
                        SettingRow(label, subtitle, if (selected) "radio_button_checked_rounded" else "radio_button_unchecked_rounded",
                            enabled = !busy, onClick = { mode = key; preview = null; error = null }, trailing = {})
                    }
                }
                if (busy) LinearProgressIndicator(Modifier.fillMaxWidth().padding(16.dp))
                preview?.let { result ->
                    LegacyCard(Modifier.fillMaxWidth().padding(4.dp)) {
                        Column(Modifier.padding(16.dp)) {
                            Text("同步预览", style = MaterialTheme.typography.titleMedium)
                            Spacer(Modifier.height(12.dp))
                            Text("本机 · ${repo.store.profile.text("name")}")
                            Text(result.localCount.label)
                            Spacer(Modifier.height(12.dp))
                            Text("$name · ${connection.user}")
                            Text(result.remoteCount.label)
                            if (result.skipped > 0) Text("双方范围外的 ${result.skipped} 条记录会保留", Modifier.padding(top = 12.dp))
                            if (mode != "merge") Text(
                                if (mode == "push") "将覆盖 $name 的当前用户记录；移除 ${result.remoteCount.removed} 项收藏。"
                                else "将覆盖本机当前用户记录；移除 ${result.localCount.removed} 项收藏。",
                                Modifier.padding(top = 16.dp),
                            )
                        }
                    }
                }
                error?.let { Text(it, Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error) }
            }
            if (busy) LegacyOutlinedButton(
                {
                    cancelling = true
                    scope.launch {
                        try { task?.cancelAndJoin(); preview = null }
                        finally { cancelling = false }
                    }
                },
                Modifier.fillMaxWidth().padding(16.dp), enabled = !cancelling,
            ) { Glyph("close_rounded", size = 18); Spacer(Modifier.width(8.dp)); Text(if (cancelling) "正在取消" else "取消本次同步") }
            else Button(hapticClick {
                val job = scope.launch(start = kotlinx.coroutines.CoroutineStart.LAZY) {
                    try {
                        error = null
                        val result = preview
                        if (result == null) preview = link.preview(mode)
                        else { link.apply(result); onDismiss() }
                    } catch (cancel: CancellationException) { throw cancel }
                    catch (failure: Exception) { error = failure.message ?: "同步未完成"; preview = null }
                    finally { task = null }
                }
                task = job
                job.start()
            }, Modifier.fillMaxWidth().padding(16.dp)) {
                Text(if (preview == null) "查看预览" else if (mode == "merge") "开始同步" else modes.first { it.first == mode }.second)
            }
        }
    }
}

@Composable
fun LanDevicesDialog(onDismiss: () -> Unit, onConnected: () -> Unit) {
    val link = LocalRepository.current.lan
    val revision by link.revision.collectAsState()
    var address by remember { mutableStateOf("") }
    var manual by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val changing = remember { link.connection != null }
    val remembered = link.settings.optJSONObject("preferred")
    val peers = remember(revision, remembered) {
        (link.peers.values + listOfNotNull(remembered)).distinctBy { it.text("deviceId") }
    }
    fun perform(work: suspend () -> Unit) {
        if (busy) return
        busy = true
        error = null
        scope.launch {
            try { work() }
            catch (cancel: CancellationException) { throw cancel }
            catch (failure: Exception) { error = failure.message ?: "连接失败，请重试" }
            finally { busy = false }
        }
    }
    fun connect(peer: JSONObject? = null) = perform {
        val target = peer ?: link.probe(address.trim())
        if (link.connection?.peer?.text("deviceId") != target.text("deviceId")) {
            if (link.connection != null) link.disconnect()
            link.connect(target)
        }
        onConnected()
    }
    LaunchedEffect(Unit) {
        try { if (!link.enabled) link.setting("enabled", true); link.rescan() }
        catch (cancel: CancellationException) { throw cancel }
        catch (failure: Exception) { error = failure.message ?: "设备互联暂不可用" }
    }
    LaunchedEffect(revision) {
        if (!changing && link.connection != null && !busy) onConnected()
    }
    LanPanel(onDismiss) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.padding(start = 20.dp, top = 8.dp, end = 12.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(if (changing) "切换设备" else "连接设备", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                IconAction("refresh_rounded", "重新搜索", !busy) { link.rescan() }
                IconAction("close_rounded", "关闭", action = onDismiss)
            }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
                Text("只发现一台设备时自动连接；多台时选择接收设备，对方无需确认。", Modifier.padding(vertical = 8.dp))
                if (peers.isEmpty()) Column(Modifier.fillMaxWidth().padding(vertical = 28.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Glyph("wifi_find_rounded", size = 48)
                    Spacer(Modifier.height(12.dp))
                    Text(if (link.local != null) "正在发现同一网络中的设备" else "正在开启设备互联")
                    Spacer(Modifier.height(8.dp))
                    Text("请让另一台设备也开启设备互联并保持应用在前台。", textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                }
                peers.forEach { peer ->
                    val id = peer.text("deviceId")
                    var menu by remember(id) { mutableStateOf(false) }
                    val status = if (link.connection?.peer?.text("deviceId") == id) "已连接" else if (id in link.peers) "可连接" else "上次连接的设备"
                    val icon = when (peer.text("kind")) { "tv" -> "tv_rounded"; "computer" -> "computer_rounded"; else -> "smartphone_rounded" }
                    LegacyCard(Modifier.fillMaxWidth().padding(4.dp)) {
                        SettingRow(peer.text("name"), status, icon, enabled = !busy, onClick = { connect(peer) }, trailing = {
                            Box {
                                IconAction("more_vert_rounded", "设备操作", !busy) { menu = true }
                                DropdownMenu(menu, { menu = false }) {
                                    DropdownMenuItem(text = { Text("忘记配对") }, onClick = hapticClick { menu = false; perform { link.forget(peer) } })
                                }
                            }
                        })
                    }
                }
                (error ?: link.error)?.let { Text(it, Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error) }
                TextButton(hapticClick { manual = !manual }, Modifier.align(Alignment.CenterHorizontally)) {
                    Glyph("keyboard_rounded", size = 18)
                    Spacer(Modifier.width(8.dp))
                    Text("输入地址连接")
                }
                if (manual) {
                    OutlinedTextField(
                        address, { address = it.take(160) }, label = { Text("对方显示的本机地址") },
                        placeholder = { Text("192.168.1.8:53120") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(autoCorrectEnabled = false, imeAction = androidx.compose.ui.text.input.ImeAction.Done),
                        keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { connect() }),
                        textStyle = MaterialTheme.typography.bodyLarge, colors = legacyTextFieldColors(), shape = RoundedCornerShape(16.dp),
                    )
                    Spacer(Modifier.height(12.dp))
                    Button(hapticClick { connect() }, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text("连接") }
                }
                Spacer(Modifier.height(24.dp))
            }
        }
    }
}
