package com.real.drama.compose

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.json.JSONArray

@Composable
fun DramaActionsDialog(drama: Drama, history: Boolean = false, onSelect: (() -> Unit)? = null, dismiss: () -> Unit) {
    val repo = LocalRepository.current; val nav = LocalNavigate.current; val action = rememberAction()
    val state = repo.store.json("followStates").optJSONObject(drama.id)
    val series = (repo.source(drama.source)?.kind ?: "drama") == "drama"
    val saved = repo.store.favorites().any { it.id == drama.id }
    @Composable fun option(title: String, icon: String, selected: Boolean = false, onClick: () -> Unit) {
        Row(Modifier.fillMaxWidth().heightIn(min = 38.dp).hapticClickable(onClick = onClick).padding(horizontal = 24.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Glyph(icon, size = 22); Spacer(Modifier.width(14.dp)); Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            if (selected) Glyph("check_rounded", size = 20)
        }
    }
    Dialog(onDismissRequest = dismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        FlutterDialogDim()
    Surface(Modifier.padding(horizontal = 40.dp, vertical = 24.dp).widthIn(min = 280.dp, max = 560.dp).width(IntrinsicSize.Min), shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh) { Column {
        Text(drama.title, Modifier.padding(start = 24.dp, top = 24.dp, end = 24.dp), style = MaterialTheme.typography.headlineSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(top = 12.dp, bottom = 16.dp)) {
        if (repo.store.watch(drama) != null) option("继续观看", "play_arrow_rounded") { dismiss(); nav(Route("playback", drama)) }
        option(if (series) { if (saved) "取消追剧" else "加入追剧" } else { if (saved) "取消收藏" else "加入收藏" }, "bookmark_outline") { action { repo.store.favorite(drama); dismiss() } }
        if (series) followLabels.forEach { (id, label) -> option("标记$label", when (id) { "planned" -> "bookmark_add_outlined"; "watching" -> "play_circle_outline"; else -> "check_circle_outline" }, state?.text("status") == id) { action { repo.store.followStatus(drama, id); dismiss() } } }
        val updates = followUpdateLabel(state)
        if (series && updates.isNotEmpty()) option("标记 ${updates}已读", "mark_email_read_outlined") { action { repo.store.markUpdatesRead(drama); dismiss() } }
        if (repo.store.canDownload && repo.source(drama.source)?.capabilities?.contains("download") == true) {
            option(if (series) "下载选集" else "下载内容", "download_outlined") { dismiss(); nav(Route("detail", drama, payload = obj("download" to true))) }
            if (onSelect != null) option("多选下载", "checklist_rounded") { dismiss(); onSelect() }
        }
        if (history && repo.store.watch(drama) != null) option("删除这条观看记录", "history_toggle_off") { action { repo.store.clearHistory(drama.id); dismiss() } }
        if (series) Text("手动标记已看会保留真实播放进度。", Modifier.padding(start = 24.dp, top = 10.dp, end = 24.dp, bottom = 8.dp), style = MaterialTheme.typography.bodySmall)
    } } } }
}
