package com.real.drama.compose

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import org.json.JSONObject

@Composable
fun ResourceSettingsScreen(back: () -> Unit) {
    val repo = LocalRepository.current; val nav = LocalNavigate.current; val action = rememberAction(); val message = LocalMessage.current
    var settings by remember { mutableStateOf<JSONObject?>(null) }; var proxy by remember { mutableStateOf("") }; var mode by remember { mutableStateOf("auto") }; var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }; var showProxy by remember { mutableStateOf(false) }; var retry by remember { mutableIntStateOf(0) }
    LaunchedEffect(retry) { try { settings = NativeBridge.call(obj("action" to "resourceSettings")); proxy = settings!!.text("proxyUrl"); mode = settings!!.text("proxyMode", "auto"); error = null } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { error = e.message } }
    Page("网络与资源", back, actions = { TextButton(hapticClick { action { busy = true; try { repo.store.requireAdmin(); settings = NativeBridge.call(obj("action" to "saveResourceSettings", "settings" to settings!!.copy().put("proxyMode", mode).put("proxyUrl", proxy.trim()))); message("设置已保存，将用于后续请求和下载任务") } catch (e: Exception) { error = e.message } finally { busy = false } } }, enabled = !busy && settings != null && repo.store.admin) { Text("保存") } }) { padding ->
        if (!repo.store.admin) StatusPanel("需要管理员权限", "请返回后切换管理员。") else if (settings == null) { if (error == null) Loading() else StatusPanel("无法读取设置", error!!, onRetry = { retry++ }) }
        else SettingsColumn(padding) {
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            LegacyCard(Modifier.padding(4.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.settingsCardColor())) { SettingRow("网络诊断", icon = "network_check_rounded", onClick = { nav(Route("networkDiagnostics")) }) }
            Spacer(Modifier.height(20.dp)); val current = settings!!
            if (current.text("warning").isNotEmpty()) Text(current.text("warning"), Modifier.padding(bottom = 16.dp))
            Surface(Modifier.padding(4.dp), shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.settingsCardColor()) { Column(Modifier.padding(16.dp)) {
                SettingsDropdown(mode, listOf("auto" to "自动", "direct" to "直连", "manual" to "手动代理"), !busy, label = "连接方式") { mode = it }
                if (mode == "auto") Text(current.text("systemProxyStatus").ifEmpty { "使用系统静态代理；未配置时使用环境变量或直连。" }, Modifier.padding(vertical = 12.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
                if (mode == "manual") { Spacer(Modifier.height(12.dp)); OutlinedTextField(proxy, { proxy = it }, Modifier.fillMaxWidth(), enabled = !busy, visualTransformation = if (showProxy) VisualTransformation.None else PasswordVisualTransformation(), label = { Text("代理地址") }, placeholder = { Text("http://127.0.0.1:7890") }, supportingText = { Text("支持 HTTP、HTTPS、SOCKS5；仅保存在本机，不进入配置备份。") }, trailingIcon = { IconAction(if (showProxy) "visibility_off_outlined" else "visibility_outlined", "显示代理地址") { showProxy = !showProxy } }, textStyle = MaterialTheme.typography.bodyLarge, colors = legacyTextFieldColors(), shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp)) }
            } }
            Spacer(Modifier.height(16.dp))
            Surface(Modifier.padding(4.dp), shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.settingsCardColor()) { Column(Modifier.padding(16.dp)) {
                SettingsDropdown(current.optInt("catalogConcurrency", 3).toString(), (1..6).map { "$it" to "$it" }, !busy, label = "目录请求并发") { settings = current.copy().put("catalogConcurrency", it.toInt()) }
                Spacer(Modifier.height(16.dp)); Text("目录请求间隔 · ${current.optInt("catalogIntervalMs", 250)} 毫秒", style = MaterialTheme.typography.bodyMedium)
                SettingsSlider(current.optInt("catalogIntervalMs", 250).toFloat(), { settings = current.copy().put("catalogIntervalMs", it.toInt()) }, enabled = !busy, valueRange = 0f..5000f, steps = 99)
                Spacer(Modifier.height(8.dp))
                SettingsDropdown(current.optInt("downloadConcurrency", 2).toString(), (1..6).map { "$it" to "$it" }, !busy, label = "同时下载数量") { settings = current.copy().put("downloadConcurrency", it.toInt()) }
            } }
            if (error != null) Text(error!!, Modifier.padding(vertical = 12.dp), color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
fun NetworkDiagnosticsScreen(back: () -> Unit) {
    val repo = LocalRepository.current; val sources = repo.available(); val states by repo.maintenance.states.collectAsState()
    var source by remember { mutableStateOf(sources.firstOrNull()?.id.orEmpty()) }
    val status = states[source] ?: JSONObject(); val busy = status.optBoolean("running")
    Page("网络诊断", back) { padding ->
        if (!repo.store.admin) StatusPanel("需要管理员权限", "请返回后切换管理员。") else if (sources.isEmpty()) StatusPanel("没有可诊断的站源", "请先在站源管理中显示至少一个站源。") else SettingsColumn(padding) {
            Card { Text("诊断会请求站源目录、分集和播放地址，并检查媒体连接。媒体检查最多读取一个片段开头的 1 KB，不会下载或保存完整视频。", Modifier.padding(16.dp)) }
            Spacer(Modifier.height(16.dp)); Text("诊断站源", style = MaterialTheme.typography.bodySmall)
            SettingsDropdown(source, sources.map { it.id to it.name }, !busy) { source = it }
            Spacer(Modifier.height(12.dp))
            if (busy) { LinearProgressIndicator(Modifier.fillMaxWidth()); Text("正在检查：${status.text("stage")}"); TextButton(hapticClick { repo.maintenance.stop(source) }) { Glyph("stop_rounded"); Text("停止诊断") } }
            else Button(hapticClick { repo.maintenance.start(source, "check") }) { Glyph("network_check_rounded"); Text("开始诊断") }
            if (status.text("error").isNotEmpty()) Text(status.text("error"), Modifier.padding(top = 12.dp), color = MaterialTheme.colorScheme.error)
            status.optJSONObject("health")?.let { health ->
                Spacer(Modifier.height(20.dp)); Text("${if (health.text("state") == "resolved") "目录与解析正常 · 实播未检测" else "目录正常 · 播放未检测"}${health.text("sample").let { if (it.isEmpty()) "" else " · $it" }}", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(8.dp)); health.array("steps").objects().forEach { step -> LegacyCard(Modifier.padding(bottom = 8.dp)) { SettingRow(step.text("name"), listOf(step.text("message"), step.text("host").takeIf { it.isNotEmpty() }?.let { it + if (step.optInt("httpStatus") > 0) " · HTTP ${step.optInt("httpStatus")}" else "" }, "${step.optInt("elapsedMs")} ms").filterNotNull().joinToString("\n"), if (step.text("state") == "ok") "check_circle_outline_rounded" else "error_outline_rounded") } }
            }
        }
    }
}
