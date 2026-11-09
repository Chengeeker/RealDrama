package com.real.drama.compose

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.json.JSONObject
import kotlin.math.roundToInt

@Composable
fun RecommendationScreen(back: () -> Unit) {
    val repo = LocalRepository.current; val action = rememberAction()
    val engine = repo.recommendations; val interests = remember { engine.interest(repo.store) }
    val preferences = repo.store.json("feedRecommendation"); val weights = engine.groupedWeights(preferences.optJSONObject("manualWeights") ?: JSONObject())
    var query by remember { mutableStateOf("") }; var clearing by remember { mutableStateOf(false) }
    val groups = engine.groups.map { group -> group to group.getJSONArray("topics").objects().filter { query.isEmpty() || group.text("label").contains(query, true) || it.text("label").contains(query, true) } }.filter { it.second.isNotEmpty() }
    fun save(key: String, value: Int?) = action {
        val next = weights.toMutableMap()
        if (value == null) next.remove(key) else next[key] = value
        if (key.startsWith("group:")) engine.groups.firstOrNull { "group:${it.text("id")}" == key }?.getJSONArray("topics")?.objects()?.forEach { next.remove("topic:${it.text("id")}") }
        repo.store.set("feedRecommendation", obj("randomMode" to false, "manualWeights" to JSONObject(next as Map<*, *>)))
    }
    fun signed(value: Int) = "${if (value > 0) "+" else ""}$value%"
    fun percent(value: Double) = (value / 3 * 100).roundToInt().coerceIn(-100, 100)
    @Composable fun weight(key: String, parent: String? = null, topic: String? = null) {
        val interest = interests[key] ?: Triple(0.0, 0.0, 0.0)
        val detected = percent(interest.third)
        val current = weights[key] ?: weights[parent] ?: detected
        var dragging by remember(key, current) { mutableStateOf<Float?>(null) }
        val followsGroup = key !in weights && parent in weights
        val description = "识别 ${signed(detected)} · 长期 ${signed(percent(interest.first))} · 本次 ${signed(percent(interest.second))}" +
            if (followsGroup) " · 跟随大类" else ""
        if (topic == null) Text(description, style = MaterialTheme.typography.labelSmall)
        else Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(topic, style = MaterialTheme.typography.titleSmall.copy(fontWeight = appTextWeight(FontWeight.SemiBold)))
                Spacer(Modifier.height(3.dp))
                Text(description, style = MaterialTheme.typography.labelSmall)
            }
            val shown = dragging?.roundToInt() ?: current
            Text(signed(shown), style = MaterialTheme.typography.titleSmall.copy(fontWeight = appTextWeight(FontWeight.Bold)),
                color = if (shown < 0) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
            if (key in weights) IconAction("subdirectory_arrow_left_rounded", "跟随大类权重") { save(key, null) }
        }
        SettingsSlider(dragging ?: current.toFloat(), { dragging = it }, valueRange = -100f..100f, steps = 39, onValueChangeFinished = {
            dragging?.let { save(key, it.roundToInt()); dragging = null }
        })
    }
    Page("猜你喜欢", back) { padding -> Column(Modifier.fillMaxSize().padding(padding).padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 16.dp)) {
        Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surfaceContainer) { Column(Modifier.padding(start = 16.dp, top = 14.dp, end = 12.dp, bottom = 14.dp)) {
            Text(if (preferences.optBoolean("randomMode")) "当前：全随机" else "当前：按兴趣排序", style = MaterialTheme.typography.titleMedium.copy(fontWeight = appTextWeight(FontWeight.Bold)))
            Spacer(Modifier.height(4.dp))
            Text("仅用于红果源。客户端根据分类、标签、标题和简介，将剧目归并为 5 个大类和 25 个二级题材；缺少标签时识别可能不完整。调整影响后续候选，热度与播放量合计占 10%，百分比不是播放概率。全随机作用于整个首页信息流；首页去重记录独立于最近观看。", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(8.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                LegacyOutlinedButton({ action { repo.store.set("feedRecommendation", obj("randomMode" to true, "manualWeights" to JSONObject())) } }, contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) { Glyph("shuffle_rounded", size = 18); Spacer(Modifier.width(8.dp)); Text("重置为全随机") }
                LegacyOutlinedButton({ clearing = true }, contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) { Glyph("history_toggle_off_rounded", size = 18); Spacer(Modifier.width(8.dp)); Text("清除首页去重记录") }
            }
        } }
        Spacer(Modifier.height(12.dp))
        TextField(query, { query = it }, Modifier.fillMaxWidth(), placeholder = { Text("搜索大类或二级题材") }, leadingIcon = { Glyph("search_rounded") }, trailingIcon = { if (query.isNotEmpty()) IconAction("close_rounded", "清除搜索") { query = "" } }, shape = RoundedCornerShape(16.dp), colors = TextFieldDefaults.colors(focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent, unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent, unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow))
        Text(if (query.isEmpty()) "题材权重 · 5 个大类" else "匹配 ${groups.size} 个大类 · ${groups.sumOf { it.second.size }} 个二级题材", Modifier.padding(start = 16.dp, top = 8.dp, bottom = 8.dp), style = MaterialTheme.typography.labelLarge)
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            items(groups, key = { it.first.text("id") }) { (group, topics) ->
                var expanded by remember(query, group) { mutableStateOf(query.isNotEmpty()) }
                val key = "group:${group.text("id")}"; val current = weights[key] ?: percent(interests[key]?.third ?: 0.0)
                Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surfaceContainer) { Column {
                    Row(Modifier.padding(start = 16.dp, top = 14.dp, end = 16.dp)) {
                        Text(group.text("label"), Modifier.weight(1f), style = MaterialTheme.typography.titleMedium.copy(fontWeight = appTextWeight(FontWeight.SemiBold)))
                        Text("${topics.size} 个二级题材", style = MaterialTheme.typography.labelMedium); Spacer(Modifier.width(10.dp)); Text(signed(current), style = MaterialTheme.typography.titleSmall.copy(fontWeight = appTextWeight(FontWeight.Bold)), color = if (current < 0) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
                    }
                    Column(Modifier.padding(start = 12.dp, end = 12.dp, bottom = 2.dp)) { weight(key) }
                    SettingRow("展开二级题材", onClick = { expanded = !expanded }, trailing = { Glyph(if (expanded) "expand_less_rounded" else "expand_more_rounded") })
                    if (expanded) topics.forEach { topic -> Surface(Modifier.padding(start = 8.dp, top = 8.dp, end = 8.dp, bottom = 2.dp), shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainerLow) {
                        Column(Modifier.padding(start = 12.dp, top = 12.dp, end = 12.dp, bottom = 8.dp)) { weight("topic:${topic.text("id")}", key, topic.text("label")) }
                    } }
                } }
            }
        }
    } }
    if (clearing) ConfirmDialog("清除首页去重记录？", "这会清除最近 30 部首页已刷短剧的去重记录，让它们之后可以重新进入推荐。最近观看、播放进度和收藏不会被清除。", { clearing = false }) { action { repo.store.saveExposures(emptyList()); engine.recent.clear(); engine.exposures.clear(); clearing = false } }
}
