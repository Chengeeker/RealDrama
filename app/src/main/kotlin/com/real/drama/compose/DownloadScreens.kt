package com.real.drama.compose

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import org.json.JSONArray
import org.json.JSONObject

fun stateLabel(state: String) = mapOf("queued" to "等待下载", "downloading" to "下载中", "paused" to "已暂停", "failed" to "失败，可重试", "completed" to "已完成", "running" to "处理中", "cancelled" to "已取消")[state] ?: state
@Composable
fun LocalPlaybackScreen(item: JSONObject, back: () -> Unit) {
    val repo = LocalRepository.current
    val original = remember(item) { Drama(item.getJSONObject("drama")) }
    val episode = remember(item) { Episode(obj("id" to item.text("id"), "title" to original.title), item.array("episodes").optInt(0, 1).coerceAtLeast(1)) }
    val drama = original
    var error by remember { mutableStateOf<String?>(null) }
    var plan by remember { mutableStateOf<JSONObject?>(null) }
    LaunchedEffect(item) { try { val file = withContext(Dispatchers.IO) { repo.mediaLibrary.fileFor(item).also { require(it.isFile) { "本地媒体文件不存在" } } }; plan = obj("url" to file.path, "local" to true) } catch (e: Exception) { error = e.message } }
    Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black)) {
        if (plan != null) PlayerScreen(drama, back, suppliedDetail = Detail(drama, listOf(episode)), localOnly = true, localPlan = plan, mediaId = item.text("id"))
        else if (error != null) StatusPanel("无法播放", error!!, "返回", back) else Loading()
    }
}
