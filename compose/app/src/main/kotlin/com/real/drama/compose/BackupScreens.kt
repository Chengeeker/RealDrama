package com.real.drama.compose

import android.util.Base64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI

@Composable
fun BackupScreen(back: () -> Unit) {
    val repo = LocalRepository.current; val nav = LocalNavigate.current; val context = LocalContext.current; val action = rememberAction(); val message = LocalMessage.current
    var pending by remember { mutableStateOf<ByteArray?>(null) }
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri -> if (uri != null) action {
        val bytes = repo.store.exportBackup(); withContext(Dispatchers.IO) { context.contentResolver.openOutputStream(uri, "wt")!!.use { it.write(bytes) } }; message("配置备份已导出")
    } }
    val restore = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> if (uri != null) action {
        val bytes = withContext(Dispatchers.IO) { context.contentResolver.openInputStream(uri)!!.use { it.readLimited(8 * 1024 * 1024) } }
        withContext(Dispatchers.Default) { LocalStore.decodeBackup(bytes) }; pending = bytes
    } }
    Page("备份设置", back) { padding -> SettingsColumn(padding) {
        SettingsSection("配置备份") {
            SettingRow("WebDAV 备份", icon = "cloud_sync_outlined", onClick = { nav(Route("webdav")) })
            SettingRow("导出配置备份", icon = "backup_outlined", onClick = { export.launch("RealDrama-backup.json") }, trailing = {})
            SettingRow("恢复配置备份", icon = "restore", onClick = { restore.launch(arrayOf("application/json", "text/plain", "application/octet-stream")) }, trailing = {})
        }
    } }
    if (pending != null) ConfirmDialog("恢复备份？", "将替换本地用户、收藏、作者关注、观看记录和偏好。已下载视频与账号凭据保留。", { pending = null }) { action { repo.store.importBackup(pending!!); pending = null; message("配置已恢复") } }
}
class WebDavClient(private val address: String, private val username: String, private val password: String) {
    private val uri = URI(address.trim())
    init {
        require(uri.scheme == "https" && uri.host != null && uri.userInfo == null && uri.fragment == null && uri.query == null && uri.path.substringAfterLast('/').isNotEmpty()) { "请输入完整的 HTTPS 备份文件地址" }
        require(username.none { it == ':' || it == '\r' || it == '\n' } && password.none { it == '\r' || it == '\n' }) { "WebDAV 用户名不能包含冒号，凭据不能包含换行符" }
    }
    suspend fun request(method: String, bytes: ByteArray? = null): ByteArray = withContext(Dispatchers.IO) {
        val connection = uri.toURL().openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false; connection.connectTimeout = 10000; connection.readTimeout = 25000; connection.requestMethod = method
            if (username.isNotEmpty() || password.isNotEmpty()) connection.setRequestProperty("Authorization", "Basic " + Base64.encodeToString("$username:$password".toByteArray(), Base64.NO_WRAP))
            if (bytes != null) { require(bytes.size <= 8 * 1024 * 1024); connection.doOutput = true; connection.setRequestProperty("Content-Type", "application/json; charset=utf-8"); connection.setFixedLengthStreamingMode(bytes.size); connection.outputStream.use { it.write(bytes) } }
            check(if (method == "GET") connection.responseCode == 200 else connection.responseCode in setOf(200, 201, 204)) { "WebDAV 请求失败（HTTP ${connection.responseCode}）" }
            if (method == "GET") connection.inputStream.use { it.readLimited(8 * 1024 * 1024) } else ByteArray(0)
        } finally { connection.disconnect() }
    }
}
@Composable
fun WebDavScreen(back: () -> Unit) {
    val repo = LocalRepository.current; val scope = rememberCoroutineScope()
    val preferences = LocalContext.current.getSharedPreferences("compose.webdav", android.content.Context.MODE_PRIVATE)
    val legacy = LocalContext.current.getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE)
    var address by remember { mutableStateOf(preferences.getString("address", legacy.getString("flutter.webdavBackup.address", "")).orEmpty()) }; var user by remember { mutableStateOf(preferences.getString("username", legacy.getString("flutter.webdavBackup.username", "")).orEmpty()) }
    var password by remember { mutableStateOf("") }; var busy by remember { mutableStateOf(false) }; var restore by remember { mutableStateOf<ByteArray?>(null) }
    var upload by remember { mutableStateOf(false) }; var showPassword by remember { mutableStateOf(false) }; var status by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { try { password = repo.secrets.read("webdav.password") } catch (cancel: CancellationException) { throw cancel } catch (_: Exception) { status = "无法读取设备中保存的 WebDAV 设置" } }
    fun run(operation: suspend (WebDavClient) -> String?) {
        if (busy) return
        busy = true; status = null
        scope.launch {
            try {
                repo.store.requireAdmin()
                val client = WebDavClient(address.trim(), user.trim(), password)
                withContext(Dispatchers.IO) { check(preferences.edit().putString("address", address.trim()).putString("username", user.trim()).commit()) { "无法保存 WebDAV 设置" } }
                repo.secrets.write("webdav.password", password)
                status = operation(client)
            } catch (cancel: CancellationException) { throw cancel } catch (failure: Exception) { status = failure.message ?: "WebDAV 操作失败" } finally { busy = false }
        }
    }
    Page("WebDAV 备份", back) { padding -> SettingsColumn(padding) {
        val fieldColors = TextFieldDefaults.colors(unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainer, focusedContainerColor = MaterialTheme.colorScheme.surfaceContainer, disabledContainerColor = MaterialTheme.colorScheme.surfaceContainer, focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent, unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent, disabledIndicatorColor = androidx.compose.ui.graphics.Color.Transparent)
        Surface(Modifier.padding(4.dp), color = MaterialTheme.colorScheme.settingsCardColor(), shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp)) { Column(Modifier.fillMaxWidth().padding(16.dp)) {
            Text("服务器配置", style = MaterialTheme.typography.titleMedium.copy(fontWeight = appTextWeight(androidx.compose.ui.text.font.FontWeight.Bold)))
            Spacer(Modifier.height(16.dp))
            TextField(address, { address = it }, Modifier.fillMaxWidth(), enabled = !busy, singleLine = true, label = { Text("HTTPS 文件地址") }, placeholder = { Text("https://dav.example.com/RealDrama.json") }, leadingIcon = { Glyph("add_link") }, textStyle = MaterialTheme.typography.bodyLarge, colors = fieldColors, shape = androidx.compose.ui.graphics.RectangleShape)
            Spacer(Modifier.height(14.dp))
            TextField(user, { user = it }, Modifier.fillMaxWidth(), enabled = !busy, singleLine = true, label = { Text("账号（可选）") }, leadingIcon = { Glyph("person_outline") }, textStyle = MaterialTheme.typography.bodyLarge, colors = fieldColors, shape = androidx.compose.ui.graphics.RectangleShape)
            Spacer(Modifier.height(14.dp))
            TextField(password, { password = it }, Modifier.fillMaxWidth(), enabled = !busy, singleLine = true, label = { Text("密码（可选）") }, leadingIcon = { Glyph("lock_outline") }, trailingIcon = { IconAction(if (showPassword) "visibility_off_outlined" else "visibility_outlined", if (showPassword) "隐藏密码" else "显示密码") { showPassword = !showPassword } }, visualTransformation = if (showPassword) androidx.compose.ui.text.input.VisualTransformation.None else PasswordVisualTransformation(), textStyle = MaterialTheme.typography.bodyLarge, colors = fieldColors, shape = androidx.compose.ui.graphics.RectangleShape)
            Spacer(Modifier.height(14.dp))
            LegacyOutlinedButton({ run { "WebDAV 设置已保存" } }, Modifier.fillMaxWidth(), enabled = !busy) { Glyph("save_outlined", size = 18); Spacer(Modifier.width(8.dp)); Text("保存设置") }
        } }
        Spacer(Modifier.height(16.dp))
        Surface(Modifier.padding(4.dp), color = MaterialTheme.colorScheme.settingsCardColor(), shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp)) { Column(Modifier.fillMaxWidth().padding(16.dp)) {
            Text("云端备份与恢复", style = MaterialTheme.typography.titleMedium.copy(fontWeight = appTextWeight(androidx.compose.ui.text.font.FontWeight.Bold)))
            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(hapticClick { upload = true }, Modifier.weight(1f), enabled = !busy, contentPadding = PaddingValues(horizontal = 8.dp)) {
                    Glyph("cloud_upload_outlined", size = 18); Spacer(Modifier.width(8.dp)); Text("上传备份")
                }
                FilledTonalButton(hapticClick { run { client -> val bytes = client.request("GET"); LocalStore.decodeBackup(bytes); restore = bytes; null } }, Modifier.weight(1f), enabled = !busy, contentPadding = PaddingValues(horizontal = 8.dp)) {
                    Glyph("cloud_download_outlined", size = 18); Spacer(Modifier.width(8.dp)); Text("恢复备份")
                }
            }
        } }
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 16.dp))
        status?.let { Spacer(Modifier.height(16.dp)); Surface(Modifier.padding(4.dp), color = MaterialTheme.colorScheme.settingsCardColor(), shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp)) { androidx.compose.foundation.text.selection.SelectionContainer { Text(it, Modifier.fillMaxWidth().padding(16.dp)) } } }
    } }
    if (upload) ConfirmDialog("上传备份？", "将覆盖云端旧备份。不含密码和已下载视频。", { upload = false }, confirmLabel = "上传") { upload = false; run { it.request("PUT", repo.store.exportBackup()); "配置备份已上传" } }
    if (restore != null) ConfirmDialog("恢复备份？", "将替换当前资料和设置，并保留本地回退副本。", { restore = null }) { val bytes = restore!!; restore = null; run { repo.store.importBackup(bytes); "配置备份已恢复" } }
}
@Composable
fun StorageScreen(back: () -> Unit) {
    val repo = LocalRepository.current; val action = rememberAction(); val message = LocalMessage.current
    val context = LocalContext.current
    var storage by remember { mutableStateOf(JSONObject()) }; var target by remember { mutableStateOf("") }; var choose by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }; var error by remember { mutableStateOf<String?>(null) }
    suspend fun refresh() { try { storage = NativeBridge.call(obj("action" to "storage")); error = null } catch (e: Exception) { error = e.message } }
    LaunchedEffect(Unit) { refresh() }
    androidx.activity.compose.BackHandler(busy) { }
    Page("下载目录与空间", { if (!busy) back() }) { padding -> SettingsColumn(padding) {
        Surface(color = MaterialTheme.colorScheme.settingsCardColor(), shape = androidx.compose.foundation.shape.RoundedCornerShape(24.dp)) { Column(Modifier.fillMaxWidth().padding(16.dp)) {
            Text("已使用 ${formatBytes(storage.optLong("bytes"))}", style = MaterialTheme.typography.titleMedium.copy(fontWeight = appTextWeight(androidx.compose.ui.text.font.FontWeight.SemiBold)))
            Spacer(Modifier.height(4.dp)); Text("剩余 ${formatBytes(storage.optLong("free"))} · ${storage.optLong("files")} 个文件", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(32.dp)); Text("当前下载目录", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(8.dp)); androidx.compose.foundation.text.selection.SelectionContainer { Text(storage.text("directory")) }
            TextButton(hapticClick { context.getSystemService(android.content.ClipboardManager::class.java).setPrimaryClip(android.content.ClipData.newPlainText("下载目录", storage.text("directory"))) }, contentPadding = PaddingValues(start = 12.dp, end = 16.dp)) { Glyph("copy", size = 18); Spacer(Modifier.width(8.dp)); Text("复制路径") }
            Text("在下载页删除不需要的分集，在本地媒体页删除合并成品或 Emby 导出，可释放空间。", color = MaterialTheme.colorScheme.onSurfaceVariant)
        } }
        if (busy) { LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical = 20.dp)); Text("正在迁移，请保持应用运行…") }
        error?.let { Text(it, Modifier.padding(vertical = 16.dp), color = MaterialTheme.colorScheme.error) }
        if (repo.store.admin) Button(hapticClick { choose = true }, Modifier.fillMaxWidth(), enabled = !busy, contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) { Glyph("drive_file_move_outline", size = 18); Spacer(Modifier.width(8.dp)); Text("更改并迁移目录") }
        TextButton(hapticClick { action { refresh() } }, Modifier.fillMaxWidth(), enabled = !busy) { Text("刷新用量") }
    } }
    if (choose) LegacyAlertDialog(onDismissRequest = { choose = false }, title = { Text("选择下载位置") }, text = { Column {
        val directories = listOf(repo.store.directory to "应用内部存储") + context.getExternalFilesDirs(null).filterNotNull().mapIndexed { i, file -> java.io.File(file, "compose-data") to if (i == 0) "设备共享存储（应用目录）" else "SD 卡 ${i + 1}（应用目录）" }
        directories.forEach { (file, label) -> TextButton(hapticClick { target = file.path; choose = false }) { Text(label) } }
    } }, confirmButton = { TextButton(hapticClick { choose = false }) { Text("取消") } })
    if (target.isNotEmpty()) ConfirmDialog("迁移已下载内容？", "将视频、合并成品及导出内容迁移到：\n$target\n\n下载会先暂停，复制成功后清理旧目录。请保证目标有足够空间，并在完成后继续下载。", { target = "" }) { action {
        repo.store.requireAdmin(); busy = true
        try { repo.mediaLibrary.pause(); NativeBridge.call(obj("action" to "moveDownloads", "directory" to target)); repo.mediaLibrary.open(); refresh(); message("迁移完成") } finally { busy = false; target = "" }
    } }
}
