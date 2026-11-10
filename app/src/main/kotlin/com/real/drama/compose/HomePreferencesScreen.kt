package com.real.drama.compose

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import org.json.JSONObject

fun feedCategoryBatches(categories: Map<String, List<String>>): List<List<Pair<String, String>>> = (0 until (categories.values.maxOfOrNull { it.size } ?: 0)).map { index -> categories.mapNotNull { (source, values) -> values.getOrNull(index)?.let { source to it } } }

fun feedRequestCategories(source: String, config: JSONObject): List<String> = if (!config.optBoolean("enabled")) emptyList() else (config.optJSONObject("categories") ?: JSONObject()).keys().asSequence().filterNot { it.startsWith("tag:") }.sorted().toList()
fun feedCategorySelection(config: JSONObject, available: List<JSONObject>, selected: Set<String>): JSONObject {
    require(available.size <= 4096 && selected.size <= 4096)
    val categories = JSONObject(); val excluded = config.optJSONObject("excludedCategories")?.copy() ?: JSONObject()
    available.forEach { row -> val id = row.text("id"); val name = row.text("name"); if (id in selected) { categories.put(id, name); excluded.remove(id) } else excluded.put(id, name) }
    require(excluded.length() <= 4096)
    return config.copy().put("categories", categories).put("excludedCategories", excluded).put("categoriesConfigured", true)
}

@Composable
fun HomePreferencesScreen(back: () -> Unit) {
    val repo = LocalRepository.current; val nav = LocalNavigate.current; val installed by repo.subscriptions.installed.collectAsState()
    Page("首页偏好", back) { padding -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.TopCenter) {
        LazyColumn(Modifier.widthIn(max = 760.dp).fillMaxWidth(), contentPadding = PaddingValues(start = 16.dp, top = 12.dp, end = 16.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { Surface(shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.settingsCardColor()) { Text("站源默认关闭。首次开启站源时默认全选分类，你可以按需取消或用“反选”快速调整；剧目命中任一关闭分类时，即使同时命中已开启分类，也不会进入首页。红果细分类只在已开启的真人剧、漫剧或AI剧中生效。", Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant) } }
            if (repo.subscriptions.sources.isEmpty()) item { SettingRow("先导入站源订阅", icon = "add_link", onClick = { nav(Route("subscriptions")) }, trailing = {}) }
            items(repo.subscriptions.sources, key = { it.id }) { HomeSourcePreferences(it) }
        }
    } }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HomeSourcePreferences(source: SourcePackage) {
    val repo = LocalRepository.current; val action = rememberAction()
    val config = repo.store.json("homeFeedPreferences").optJSONObject(source.id) ?: JSONObject()
    val enabled = config.optBoolean("enabled"); val allowed = repo.store.allowed(source.id); val live = source.kind == "live"
    val selected = (config.optJSONObject("categories") ?: JSONObject()).keys().asSequence().toSet()
    var expanded by remember { mutableStateOf(false) }; var groupsExpanded by remember { mutableStateOf(setOf<String>()) }
    var categories by remember { mutableStateOf(emptyList<JSONObject>()) }; var loading by remember { mutableStateOf(false) }; var error by remember { mutableStateOf<String?>(null) }; var retry by remember { mutableIntStateOf(0) }
    var topicDialog by remember { mutableStateOf<Pair<String, List<JSONObject>>?>(null) }
    fun select(ids: Set<String>) = action { val current = repo.store.json("homeFeedPreferences"); val row = current.optJSONObject(source.id) ?: JSONObject(); repo.store.set("homeFeedPreferences", current.put(source.id, feedCategorySelection(row, categories, ids))) }
    LaunchedEffect(source.id, enabled, allowed, retry) {
        if (!enabled || !allowed || live) return@LaunchedEffect
        loading = true; error = null
        try {
            val base = repo.categories(source.id).filter { row -> row.text("id").isNotBlank() && (source.group in setOf("douyin", "bilibili") || row.text("id") !in setOf("all", "recommend", "category:all") && row.text("name") !in setOf("全部", "全部分类", "推荐")) }
            val extra = mutableListOf<JSONObject>(); val seen = base.map { normalizedSearchText(it.text("name")) }.toMutableSet()
            if (source.id == "hongguo") for (category in base) {
                val rows = repo.cached(source.id, category.text("id"))?.items.orEmpty() + try { repo.catalog(source.id, category = category.text("id"), force = retry > 0).items } catch (cancel: CancellationException) { throw cancel } catch (_: Exception) { emptyList() }
                rows.forEach { drama -> (drama.json.array("tags").strings() + drama.json.text("category")).filter { it.isNotBlank() && it !in setOf("全部", "全部分类", "推荐") }.forEach { name -> if (seen.add(normalizedSearchText(name))) extra.add(obj("id" to "tag:$name", "name" to name)) } }
            }
            categories = (base + extra).take(4096)
            val all = repo.store.json("homeFeedPreferences"); val current = all.optJSONObject(source.id) ?: JSONObject()
            if (!current.optBoolean("categoriesConfigured") && (current.optJSONObject("categories")?.length() ?: 0) == 0 && categories.isNotEmpty()) repo.store.set("homeFeedPreferences", all.put(source.id, feedCategorySelection(current, categories, categories.map { it.text("id") }.toSet())))
        } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { error = e.message } finally { loading = false }
    }
    @Composable fun selectionRow(label: String, rows: List<JSONObject>, modifier: Modifier = Modifier, expand: (() -> Unit)? = null, trailing: (@Composable () -> Unit)? = null) {
        val count = rows.count { it.text("id") in selected }; val all = count == rows.size
        val toggle = { select(if (all) selected - rows.map { it.text("id") }.toSet() else selected + rows.map { it.text("id") }) }
        Row(modifier.height(48.dp), verticalAlignment = Alignment.CenterVertically) {
            TriStateCheckbox(if (all) ToggleableState.On else if (count == 0) ToggleableState.Off else ToggleableState.Indeterminate, onClick = hapticClick { toggle() })
            Text(label, Modifier.weight(1f).hapticClickable { if (expand != null) expand() else toggle() }); Text("$count/${rows.size}", style = MaterialTheme.typography.labelSmall)
            if (trailing != null) trailing() else Spacer(Modifier.width(12.dp))
        }
    }
    val colors = MaterialTheme.colorScheme
    val cardColor = colors.settingsCardColor()
    Surface(shape = RoundedCornerShape(20.dp), color = cardColor) { Column {
        val subtitle = if (live) "直播内容不进入首页短剧信息流" else if (!allowed) "当前在站源管理中隐藏，首页不会请求此站源" else if (!enabled) "关闭时不会请求或推送此站源内容" else if (loading && categories.isEmpty()) "正在读取分类…" else if (categories.isNotEmpty()) "已选 ${categories.count { it.text("id") in selected }}/${categories.size} 个分类 · 点击左侧展开" else "分类暂不可用 · 点击左侧展开查看"
        SettingRow(source.name, subtitle, "dns_outlined", onClick = if (allowed && enabled && !live) ({ expanded = !expanded }) else null, trailing = {
            Row { if (!live) IconAction(if (expanded) "expand_less_rounded" else "expand_more_rounded", "展开分类", allowed && enabled) { expanded = !expanded }; Switch(enabled, hapticToggle { value -> action { val all = repo.store.json("homeFeedPreferences"); repo.store.set("homeFeedPreferences", all.put(source.id, (all.optJSONObject(source.id) ?: JSONObject()).put("enabled", value))); if (value) expanded = true } }, enabled = allowed && !live) }
        })
        if (enabled && expanded && !live) Column(Modifier.padding(start = 16.dp, top = 8.dp, end = 16.dp, bottom = 16.dp)) {
            if (loading) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (error != null) Row { Text("分类暂时无法加载：$error", Modifier.weight(1f)); IconAction("refresh_rounded", "重试") { retry++ } }
            if (categories.isEmpty()) Text(if (loading) "正在读取分类…" else "此站源没有可选择的短剧分类。") else {
                Row(verticalAlignment = Alignment.CenterVertically) { Text("${categories.count { it.text("id") in selected }}/${categories.size} 个分类", Modifier.weight(1f)); TextButton(hapticClick { select(categories.map { it.text("id") }.toSet()) }) { Text("全选") }; TextButton(hapticClick { select(categories.map { it.text("id") }.filterNot { it in selected }.toSet()) }) { Text("反选") } }
                if (selected.isEmpty()) Text("未选中分类：首页不会请求此站源。", style = MaterialTheme.typography.bodySmall)
                val categoryColor = colors.settingsCardColor(cardColor)
                Surface(shape = RoundedCornerShape(18.dp), color = categoryColor) {
                    LazyColumn(Modifier.height(if (source.id == "hongguo") 480.dp else minOf(480, categories.size * 48).dp), contentPadding = PaddingValues(8.dp)) {
                        if (source.id != "hongguo") items(categories) { row -> selectionRow(row.text("name"), listOf(row)) }
                        else repo.recommendations.groups.forEach { group ->
                            val matching = categories.filter { repo.recommendations.topicMatches(it.text("name")).first().first == group.text("id") }
                            if (matching.isNotEmpty()) item(key = group.text("id")) { Surface(Modifier.padding(bottom = 6.dp), shape = RoundedCornerShape(14.dp), color = colors.settingsCardColor(categoryColor)) { Column {
                                val id = group.text("id"); val toggle = { groupsExpanded = if (id in groupsExpanded) groupsExpanded - id else groupsExpanded + id }
                                selectionRow(group.text("label"), matching, expand = toggle, trailing = { IconAction(if (id in groupsExpanded) "expand_less_rounded" else "expand_more_rounded", "展开题材", action = toggle) })
                                if (id in groupsExpanded) group.array("topics").objects().forEach { topic -> val members = matching.filter { repo.recommendations.topicMatches(it.text("name")).first().second.text("id") == topic.text("id") }; if (members.isNotEmpty()) selectionRow(topic.text("label"), members, Modifier.padding(start = 20.dp), trailing = { IconAction("tune_rounded", "查看具体分类") { topicDialog = topic.text("label") to members } }) }
                            } } }
                        }
                    }
                }
            }
        }
    } }
    topicDialog?.let { (label, rows) -> ModalBottomSheet(scrimColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = .54f), onDismissRequest = { topicDialog = null }) { Column(Modifier.fillMaxHeight(.72f)) {
        SettingRow(label, "${rows.count { it.text("id") in selected }}/${rows.size} 个具体分类已开启", trailing = { val all = rows.all { it.text("id") in selected }; TextButton(hapticClick { select(if (all) selected - rows.map { it.text("id") }.toSet() else selected + rows.map { it.text("id") }) }) { Text(if (all) "全关" else "全开") } })
        LazyColumn { items(rows) { row -> Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(row.text("id") in selected, hapticToggle { on -> select(if (on) selected + row.text("id") else selected - row.text("id")) }); Text(row.text("name")) } } }
    } } }
}
