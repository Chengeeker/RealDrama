package com.real.drama.compose

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*
import org.json.JSONObject

fun normalizeCookie(value: String, group: String): String {
    require('\r' !in value && '\n' !in value) { "请只粘贴 Cookie 请求头这一行" }
    val cookie = value.replaceFirst(Regex("^\\s*cookie\\s*:\\s*", RegexOption.IGNORE_CASE), "").trim()
    require(cookie.length in 1..32768 && cookie.all { it.code in 32..126 }) { "请粘贴单行完整 Cookie，不能包含其他请求头" }
    val fields = linkedMapOf<String, String>()
    cookie.split(';').map(String::trim).filter { it.isNotEmpty() && !(group == "douyin" && it.lowercase() in setOf("douyin.com", ".douyin.com", "www.douyin.com")) }.forEach {
        val split = it.indexOf('='); require(split > 0) { "Cookie 字段格式无效，请复制请求头中的完整值" }
        val name = it.substring(0, split).trim()
        require(name.matches(Regex("[!#\$%&'*+.^_`|~0-9A-Za-z-]+")) && name !in fields) { "Cookie 字段名重复或格式无效" }
        fields[name] = it.substring(split + 1).trim()
    }
    require(group != "douyin" || listOf("sessionid", "sessionid_ss").any { fields[it]?.isNotEmpty() == true }) { "未找到登录会话，请复制登录网页后的完整 Cookie" }
    require(group != "bilibili" || fields["SESSDATA"]?.isNotEmpty() == true) { "未找到 SESSDATA，请复制已登录网页请求中的 Cookie" }
    return fields.map { (key, field) -> "$key=$field" }.joinToString("; ")
}

@Composable
fun AccountSettings(sourceId: String, back: () -> Unit) {
    val repo = LocalRepository.current; val source = repo.source(sourceId) ?: return; val context = LocalContext.current
    val scope = rememberCoroutineScope(); val epoch = remember { repo.store.epoch }; val profile = remember { repo.store.active }
    val key = "cookie.${source.group}.$profile"
    var cookie by remember { mutableStateOf("") }; var obscured by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(true) }; var message by remember { mutableStateOf("") }
    val content = remember(source.group) { JSONObject(context.assets.open("account_ui.json").bufferedReader().use { it.readText() }).optJSONObject(source.group) ?: JSONObject() }
    fun valid() = epoch == repo.store.epoch && profile == repo.store.active && !repo.store.locked.value
    LaunchedEffect(key) { try { cookie = repo.secrets.read(key); message = if (cookie.isNotEmpty()) "已保存 Cookie，可查看、复制或替换" else "尚未配置 Cookie" } catch (_: Exception) { message = "无法读取安全存储" } finally { busy = false } }
    fun run(operation: String) { if (!valid() || busy) return; scope.launch {
        busy = true; message = ""
        try {
            if (operation == "clear") {
                repo.secrets.write(key, ""); cookie = ""; repo.runtime.clearCredentials(source.group)
                if (source.group == "douyin") {
                    val hidden = repo.store.list("hiddenSources").strings().toSet() + repo.subscriptions.sources.filter { it.group == "douyin" }.map { it.id }
                    repo.store.set("hiddenSources", org.json.JSONArray(hidden.toList()))
                }
                message = if (source.group == "douyin") "已清除 Cookie 并关闭抖音站源" else "已清除本机保存的 Cookie"
            } else {
                if (cookie.isNotBlank() || operation == "save") { val normalized = normalizeCookie(cookie, source.group); check(valid()); repo.secrets.write(key, normalized); cookie = normalized; repo.runtime.clearCredentials(source.group) }
                check(valid())
                message = if (operation == "save") "Cookie 已保存在本机安全存储" else if (source.group == "bilibili") {
                    val result = repo.runtime.execute(sourceId, "account", configure = true)
                    if (result.optBoolean("isLogin")) "接口可用，Cookie 登录有效${result.text("name").takeIf { it.isNotBlank() }?.let { "：$it" }.orEmpty()}" else "接口可用，但当前未登录或 Cookie 已失效；公开内容仍可浏览，登录可解锁更多清晰度"
                } else {
                    require(cookie.isNotBlank()) { "请先输入 Cookie" }
                    val target = if (operation == "check-live") repo.subscriptions.sources.firstOrNull { it.group == source.group && it.kind == "live" } ?: error("请先导入直播站源") else source
                    val result = repo.runtime.execute(target.id, "catalog", obj("page" to 1, "force" to true), configure = true)
                    "已获取 ${result.array("items").length()} ${if (operation == "check-live") "个直播间" else "条内容"}；子项开关可在站源管理中设置。"
                }
            }
        } catch (cancel: CancellationException) { throw cancel } catch (error: Exception) { if (valid()) message = error.message ?: "操作失败，请检查网络或设备安全存储" } finally { busy = false }
    } }
    Page(content.text("title", source.name), back) { padding -> SettingsColumn(padding) {
        Surface(color = MaterialTheme.colorScheme.settingsCardColor(), shape = RoundedCornerShape(20.dp)) { Column(Modifier.padding(16.dp)) {
            Text(if (source.group == "bilibili") "可选 Cookie 登录" else "Cookie 登录", style = MaterialTheme.typography.titleMedium, fontWeight = appTextWeight(FontWeight.SemiBold))
            Spacer(Modifier.height(12.dp)); Text(content.text("instructions"), color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(16.dp))
            TextField(cookie, { cookie = it }, Modifier.fillMaxWidth(), enabled = !busy, singleLine = true, visualTransformation = if (obscured) PasswordVisualTransformation() else VisualTransformation.None,
                label = { Text("粘贴请求头 Cookie 的完整值") }, supportingText = { Text("字段名=字段值；多项用英文分号分隔。不要手动解码或修改字段值。") }, trailingIcon = { IconAction(if (obscured) "visibility_outlined" else "visibility_off_outlined", if (obscured) "显示 Cookie" else "隐藏 Cookie") { obscured = !obscured } })
            Spacer(Modifier.height(16.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(hapticClick { run("save") }, enabled = !busy) { Text("保存") }
                if (source.group in setOf("douyin", "bilibili")) LegacyOutlinedButton({ run("check") }, enabled = !busy) { Text(if (source.group == "douyin") "检测短视频" else "检测登录与接口") }
                if (source.group == "douyin") LegacyOutlinedButton({ run("check-live") }, enabled = !busy) { Text("检测直播") }
                if (source.group == "hanime") LegacyOutlinedButton({
                    busy = true
                    HanimeCloudflareVerifier(context as Activity).open({ value -> scope.launch { try { if (value != null && valid()) { val normalized = normalizeCookie(value, source.group); repo.secrets.write(key, normalized); cookie = normalized; repo.runtime.clearCredentials(source.group); message = "已同步本机验证 Cookie，并保存在当前资料的安全存储" } } catch (e: Exception) { message = e.message.orEmpty() } finally { busy = false } } }, { error -> busy = false; message = error })
                }, enabled = !busy) { Text("应用内验证并同步 Cookie") }
                LegacyOutlinedButton({ context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Cookie", cookie)); message = "已复制 Cookie" }, enabled = !busy && cookie.isNotEmpty()) { Text("复制 Cookie") }
                TextButton(hapticClick { run("clear") }, enabled = !busy) { Text(if (source.group == "douyin") "清除登录" else "清除 Cookie") }
            }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 16.dp))
            if (message.isNotEmpty()) Text(message, Modifier.padding(top = 16.dp))
        } }
    } }
}
