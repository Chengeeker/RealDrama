package com.real.drama.compose

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import org.json.JSONObject

@Composable
fun LoginScreen() = ProfilesScreen({}, true)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfilesScreen(back: () -> Unit, locked: Boolean = false) {
    val repo = LocalRepository.current; val action = rememberAction()
    var editing by remember { mutableStateOf<JSONObject?>(null) }; var login by remember { mutableStateOf<JSONObject?>(null) }; var pin by remember { mutableStateOf("") }; var busy by remember { mutableStateOf(false) }; var error by remember { mutableStateOf<String?>(null) }
    if (editing != null) { ProfileEditor(editing!!) { editing = null }; return }
    fun unlock(profile: JSONObject) = action { busy = true; error = null; try { check(repo.store.unlock(profile.text("id"), pin)) { "密码不正确" }; login = null } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { error = e.message; login = null } finally { busy = false } }
    Scaffold(topBar = { TopAppBar(title = { Text(if (locked) "解锁RealDrama" else "用户管理", Modifier.padding(start = if (locked) 0.dp else 16.dp)) }, expandedHeight = 56.dp, navigationIcon = { if (!locked) IconAction("arrow_back_rounded", "返回", action = back) }) }) { padding -> SettingsColumn(padding, top = 20, bottom = 20, horizontal = 20) {
        Text(if (locked) "选择用户并输入密码" else "当前用户：${repo.store.profile.text("name")}", style = MaterialTheme.typography.titleLarge)
        Spacer(Modifier.height(8.dp)); Text("各用户的收藏、作者关注和观看记录独立保存；作者关注仅保存在本机。下载文件由本机共享。")
        if (!locked && repo.store.admin) { Spacer(Modifier.height(12.dp)); SwitchRow("启动时需要登录", repo.store.forceLogin, if (repo.store.forceLogin) "每次打开应用先解锁当前受保护用户" else "保留密码，仅切换用户或手动锁定时验证", !busy, horizontal = 0) { action { repo.store.set("forceLogin", it, true) } } }
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth().padding(16.dp))
        if (error != null) Text(error!!, Modifier.padding(vertical = 12.dp), color = MaterialTheme.colorScheme.error)
        Spacer(Modifier.height(16.dp))
        repo.store.profiles.forEach { profile -> LegacyCard(Modifier.padding(4.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
            SettingRow(profile.text("name"), if (profile.optBoolean("admin")) "管理员 · 全部权限" else "当前版本全部站源 · ${if (profile.optBoolean("download", true)) "可下载" else "仅在线观看"}", if (profile.optBoolean("admin")) "admin_panel_settings_outlined" else "person_outline", enabled = !busy, onClick = { pin = ""; if (profile.text("pinHash").isEmpty()) unlock(profile) else login = profile }, trailing = {
                if (!locked && repo.store.admin) IconAction("edit_outlined", "编辑用户", !busy) { editing = profile } else Glyph(if (profile.text("pinHash").isNotEmpty()) "lock_outline" else "chevron_right")
            })
        } }
        if (!locked && repo.store.admin) { Spacer(Modifier.height(16.dp)); Button(hapticClick { editing = JSONObject() }, Modifier.fillMaxWidth(), enabled = !busy, contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) { Glyph("person_add_outlined", size = 18); Spacer(Modifier.width(8.dp)); Text("添加用户") } }
        if (!locked && repo.store.profile.text("pinHash").isNotEmpty()) TextButton(hapticClick { repo.store.lock() }) { Glyph("lock_outline"); Text("锁定当前用户") }
    } }
    login?.let { profile ->
        LoginPasswordDialog(profile.text("name"), { login = null }) { entered ->
            login = null
            pin = entered
            unlock(profile)
        }
    }
}

@Composable
fun LoginPasswordDialog(name: String, dismiss: () -> Unit, onPassword: (String) -> Unit) {
    var password by remember { mutableStateOf("") }
    val focus = remember { androidx.compose.ui.focus.FocusRequester() }
    LegacyAlertDialog(
        onDismissRequest = dismiss, title = { Text("登录 $name") },
        text = {
            val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
            LaunchedEffect(Unit) { focus.requestFocus(); keyboard?.show() }
            TextField(
                password, { password = it }, Modifier.fillMaxWidth().focusRequester(focus),
                label = { Text("密码") }, visualTransformation = PasswordVisualTransformation(), singleLine = true,
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                    keyboardType = androidx.compose.ui.text.input.KeyboardType.Password,
                    imeAction = androidx.compose.ui.text.input.ImeAction.Done,
                ),
                keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { onPassword(password) }),
                textStyle = MaterialTheme.typography.bodyLarge,
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = MaterialTheme.colorScheme.surfaceContainer,
                    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainer,
                    focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
                    unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
                ),
                shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp),
            )
        },
        confirmButton = { Button(hapticClick { onPassword(password) }) { Text("登录") } },
        dismissButton = { TextButton(hapticClick(dismiss)) { Text("取消") } },
    )
}

@Composable
private fun ProfileEditor(profile: JSONObject, back: () -> Unit) {
    val repo = LocalRepository.current
    val action = rememberAction()
    val adding = profile.text("id").isEmpty()
    val admin = profile.optBoolean("admin")
    var name by remember { mutableStateOf(profile.text("name")) }
    var pin by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    var clear by remember { mutableStateOf(false) }
    var download by remember { mutableStateOf(profile.optBoolean("download", true)) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var removal by remember { mutableStateOf(false) }
    BackHandler { if (!busy) back() }
    Page(if (adding) "添加用户" else "编辑用户", { if (!busy) back() }) { padding ->
      SettingsColumn(padding, top = 20, bottom = 20, maxWidth = 640, horizontal = 20) {
        val shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp)
        val password = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Password)
        val colors = TextFieldDefaults.colors(
            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainer,
            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainer,
            focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
            unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
        )
        TextField(name, { name = it.take(40) }, Modifier.fillMaxWidth(), singleLine = true,
            label = { Text("用户名") }, supportingText = {
                Text("${name.length}/40", Modifier.fillMaxWidth(), textAlign = androidx.compose.ui.text.style.TextAlign.End)
            }, textStyle = MaterialTheme.typography.bodyLarge, colors = colors, shape = shape)
        Spacer(Modifier.height(12.dp))
        TextField(pin, { pin = it }, Modifier.fillMaxWidth(), singleLine = true,
            label = { Text("设置密码（至少 6 位）") }, supportingText = { Text("留空保留原密码") },
            visualTransformation = PasswordVisualTransformation(), keyboardOptions = password,
            textStyle = MaterialTheme.typography.bodyLarge, colors = colors, shape = shape)
        Spacer(Modifier.height(12.dp))
        TextField(confirm, { confirm = it }, Modifier.fillMaxWidth(), singleLine = true,
            label = { Text("再次输入密码") }, visualTransformation = PasswordVisualTransformation(), keyboardOptions = password,
            textStyle = MaterialTheme.typography.bodyLarge, colors = colors, shape = shape)
        if (profile.text("pinHash").isNotEmpty() && !admin) {
            SettingRow("取消此用户密码", horizontal = 0, onClick = { clear = !clear }, trailing = { Checkbox(clear, hapticToggle { clear = it }) })
        }
        Spacer(Modifier.height(20.dp))
        if (!admin) {
            Text("首次使用默认只显示红果；其他站源可在站源管理中开启。各用户的显示设置互相独立。")
            SwitchRow("允许下载和本地媒体", download, if (download) "可下载、合并和导出" else "仅在线观看，隐藏下载入口", horizontal = 0) { download = it }
        } else Text("管理员可以访问全部站源和功能。创建其他用户前需要先设置管理员密码。")
        if (error != null) Text(error!!, Modifier.padding(vertical = 12.dp), color = MaterialTheme.colorScheme.error)
        Spacer(Modifier.height(24.dp)); Button(hapticClick { action { busy = true; error = null; try { check(pin == confirm) { "两次输入的密码不一致" }; repo.store.saveProfile(profile.text("id").takeIf { it.isNotEmpty() }, name, if (clear) "" else pin.takeIf { it.isNotEmpty() }, if (adding) repo.subscriptions.sources.map { it.id } else profile.array("sources").strings(), download); back() } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { error = e.message } finally { busy = false } } }, Modifier.fillMaxWidth(), enabled = !busy) { Text(if (busy) "正在保存…" else "保存") }
        if (!adding && !admin) TextButton(hapticClick { removal = true }, Modifier.fillMaxWidth(), enabled = !busy) { Text("删除用户") }
    } }
    if (removal) ConfirmDialog("删除此用户？", "会同时删除该用户的收藏和观看记录。下载文件会保留。", { removal = false }, confirmLabel = "删除") {
        removal = false
        action {
            busy = true
            error = null
            try { repo.store.removeProfile(profile.text("id")); back() }
            catch (cancel: CancellationException) { throw cancel }
            catch (failure: Exception) { error = failure.message }
            finally { busy = false }
        }
    }
}
