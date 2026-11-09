package com.real.drama.compose

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.json.JSONObject

val contentFormats = linkedMapOf("live" to "short_play", "manga" to "comic_series", "ai" to "ai_series")
fun taxonomyMatches(drama: Drama, category: String, recommendations: FeedRecommendations): Boolean {
    if (!category.startsWith("taxonomy")) return true
    val values = (drama.json.array("tags").strings() + drama.json.text("category")).filter { it.isNotBlank() }.flatMap(recommendations::topicMatches)
    return if (category.startsWith("taxonomy-group:")) values.any { it.first == category.removePrefix("taxonomy-group:") } else values.any { it.second.text("id") == category.removePrefix("taxonomy:") }
}
fun interleaveDramas(pages: List<List<Drama>>): List<Drama> {
    val result = linkedMapOf<String, Drama>()
    repeat(pages.maxOfOrNull { it.size } ?: 0) { index -> pages.forEach { page -> page.getOrNull(index)?.let { result.putIfAbsent(it.id, it) } } }
    return result.values.toList()
}
@Composable
fun CatalogCategoryBar(categories: List<JSONObject>, category: String, groups: List<JSONObject> = emptyList(), format: String = "all", choose: (String) -> Unit, chooseFormat: (String) -> Unit = {}, trailing: @Composable () -> Unit = {}) {
    val primary = groups.firstOrNull { group -> category == "taxonomy-group:${group.text("id")}" || group.array("topics").objects().any { category == "taxonomy:${it.text("id")}" } }
    val formatGroup = groups.firstOrNull { it.text("id") == "format" }
    val showFormats = category in setOf("", "app:recommendations") && formatGroup != null
    @Composable fun row(options: List<Pair<String, String>>, selected: String, select: (String) -> Unit, trailingRow: Boolean = false) {
        Row(Modifier.height(if (groups.isEmpty()) 52.dp else 50.dp), verticalAlignment = Alignment.CenterVertically) {
            LazyRow(Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                items(options) { (id, label) -> LegacyChip(selected == id, { select(id) }, label = { Text(label) }) }
            }
            if (trailingRow) trailing()
        }
    }
    if (groups.isEmpty()) row(listOf("" to "全部") + categories.map { it.text("id") to it.text("name") }, category, choose, true)
    else Column {
        row(listOf("" to "全部", "app:recommendations" to "推荐") + groups.filter { it.text("id") != "format" }.map { "taxonomy-group:${it.text("id")}" to it.text("label") }, primary?.let { "taxonomy-group:${it.text("id")}" } ?: category, choose, true)
        if (showFormats) row(listOf("all" to "全部内容形式") + formatGroup!!.array("topics").objects().map { it.text("id") to it.text("label") }, format, chooseFormat)
        else if (primary != null) row(listOf("taxonomy-group:${primary.text("id")}" to "全部${primary.text("label")}") + primary.array("topics").objects().map { "taxonomy:${it.text("id")}" to it.text("label") }, category, choose)
    }
}
