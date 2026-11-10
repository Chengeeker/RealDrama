package com.real.drama.compose

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecoveryScreen() {
    val repo = LocalRepository.current
    val context = LocalContext.current
    val action = rememberAction()
    var busy by remember { mutableStateOf(false) }
    var backup by remember { mutableStateOf<ByteArray?>(null) }
    var password by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    fun run(work: suspend () -> Unit) {
        if (busy) return
        busy = true
        error = null
        action {
            try { work() }
            catch (cancel: CancellationException) { throw cancel }
            catch (failure: Exception) { error = failure.message ?: "恢复操作失败，请重试" }
            finally { busy = false }
        }
    }
    val import = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> if (uri != null) run {
        val bytes = withContext(Dispatchers.IO) { context.contentResolver.openInputStream(uri)!!.use { it.readLimited(8 * 1024 * 1024) } }
        LocalStore.decodeBackup(bytes)
        backup = bytes
    } }
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri -> if (uri != null) run {
        val bytes = repo.store.rawConfiguration()
        withContext(Dispatchers.IO) { context.contentResolver.openOutputStream(uri, "wt")!!.use { it.write(bytes) } }
    } }
    Scaffold(topBar = { TopAppBar(title = { Text("解锁RealDrama") }, expandedHeight = 56.dp) }) { padding ->
        SettingsColumn(padding, top = 20, bottom = 20, horizontal = 20) {
            Text("需要恢复本地配置", style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.height(12.dp))
            Text(repo.store.readError.orEmpty())
            Spacer(Modifier.height(12.dp))
            Button(hapticClick { import.launch(arrayOf("application/json", "text/plain")) }, Modifier.fillMaxWidth(),
                enabled = !busy, contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) {
                Glyph("restore_rounded", size = 18)
                Spacer(Modifier.width(8.dp))
                Text("从备份恢复")
            }
            LegacyOutlinedButton({ export.launch("RealDrama-recovery.json") }, Modifier.fillMaxWidth(), enabled = !busy) { Text("导出原始配置") }
            TextButton(hapticClick { run { repo.open() } }, Modifier.fillMaxWidth(), enabled = !busy) { Text("重新读取配置") }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth().padding(16.dp))
            error?.let { Text(it, Modifier.padding(vertical = 12.dp), color = MaterialTheme.colorScheme.error) }
        }
    }
    val bytes = backup
    if (bytes != null && !password) ConfirmDialog(
        "从备份恢复用户与记录？", "将使用这份备份替换损坏的用户配置、收藏、观看记录和偏好。建议先导出原始配置；已下载视频保留。",
        { backup = null }, confirmLabel = "继续恢复",
    ) { password = true }
    if (bytes != null && password) LoginPasswordDialog("管理员（原配置或备份中的密码）", { backup = null; password = false }) { entered ->
        backup = null
        password = false
        run { repo.store.recoverBackup(bytes, entered); repo.open() }
    }
}
