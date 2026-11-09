package com.real.drama.compose

import org.json.JSONArray
import org.json.JSONObject

data class SeriesInfo(val base: String, val key: String, val season: Int, val unit: String)
data class SeriesEntry(val drama: Drama, val season: Int, val unit: String)
private val seasonSuffix = Regex("第\\s*([0-9零〇一二两兩三四五六七八九十百]+)\\s*([季部])[\\s\u3000，。！？、：；·「」『』（）【】《》“”‘’.,!?:;\\-_/()\\[\\]{}]*$")
fun seriesInfo(drama: Drama, unit: String? = null): SeriesInfo? {
    if (drama.source != "hongguo") return null
    val title = drama.title.trim(); val match = seasonSuffix.find(title)
    if (match == null) return if (unit == null || title.isEmpty()) null else SeriesInfo(title, normalizedSearchText(title), 1, unit)
    val base = title.substring(0, match.range.first).trim(); if (base.isEmpty()) return null
    val text = match.groupValues[1]
    val digits = mapOf('零' to 0, '〇' to 0, '一' to 1, '二' to 2, '两' to 2, '兩' to 2, '三' to 3, '四' to 4, '五' to 5, '六' to 6, '七' to 7, '八' to 8, '九' to 9)
    var digit = 0; var total = 0; var previous = 1000
    val number = text.toIntOrNull() ?: run {
        for (char in text) {
            if (char in digits) { digit = digit * 10 + digits.getValue(char); if (digit > 200) return null }
            else {
                val multiplier = if (char == '百') 100 else 10
                if (multiplier >= previous || digit > 9) return null
                total += (if (digit == 0) 1 else digit) * multiplier; digit = 0; previous = multiplier
            }
        }
        total + digit
    }
    if (number !in 1..200) return null
    return SeriesInfo(base, normalizedSearchText(base), number, match.groupValues[2])
}
fun seriesEntries(anchor: Drama, candidates: List<Drama>): List<SeriesEntry> {
    if (anchor.source != "hongguo") return emptyList()
    val explicit = seriesInfo(anchor)
    val info = explicit ?: candidates.mapNotNull { seriesInfo(it) }.filter { it.key == normalizedSearchText(anchor.title) }.groupBy { it.unit }
        .entries.sortedWith(compareByDescending<Map.Entry<String, List<SeriesInfo>>> { it.value.size }.thenByDescending { it.value.maxOf { row -> row.season } }).firstOrNull()?.let { seriesInfo(anchor, it.key) } ?: return emptyList()
    return (listOf(anchor) + candidates).distinctBy { it.id }.mapNotNull { drama -> seriesInfo(drama, info.unit)?.takeIf { it.key == info.key && it.unit == info.unit }?.let { SeriesEntry(drama, it.season, it.unit) } }
        .sortedWith(compareBy<SeriesEntry> { it.season }.thenComparator { a, b -> naturalTitleCompare(a.drama.title, b.drama.title) }).takeIf { it.size > 1 }.orEmpty()
}
fun observeSeries(anchor: Drama, state: JSONObject, candidates: List<Drama>, favoriteIds: Set<String>): JSONObject {
    val entries = seriesEntries(anchor, candidates); val season = entries.firstOrNull { it.drama.id == anchor.id }?.season ?: return state
    val notices = state.optJSONObject("seriesSeasons")?.copy() ?: JSONObject()
    notices.keys().asSequence().filter { it == anchor.id || it in favoriteIds }.toList().forEach(notices::remove)
    entries.filter { it.season > season && it.drama.id !in favoriteIds && it.drama.id != anchor.id }.take(200).forEach { entry -> notices.put(entry.drama.id, obj("id" to entry.drama.id, "title" to entry.drama.title, "season" to entry.season, "unit" to entry.unit, "read" to (notices.optJSONObject(entry.drama.id)?.optBoolean("read") ?: false))) }
    return state.copy().put("seriesSeasons", notices)
}
fun followUpdateLabel(state: JSONObject?): String {
    if (state == null) return ""
    val episodes = if (state.isNull("readEpisodes")) 0 else (state.optInt("knownEpisodes") - state.optInt("readEpisodes")).coerceAtLeast(0)
    val seasons = state.optJSONObject("seriesSeasons")?.let { values -> values.keys().asSequence().count { values.optJSONObject(it)?.optBoolean("read") == false } } ?: 0
    return listOfNotNull(if (episodes > 0) "$episodes 集更新" else null, if (seasons > 0) "新季 $seasons 部" else null).joinToString(" · ")
}
fun mergeDramaMetadata(original: Drama, incoming: Drama): Drama {
    require(original.id == incoming.id && original.source == incoming.source)
    val result = original.json.copy()
    incoming.json.keys().forEach { key -> val value = incoming.json.opt(key); if (value is String && value.isNotBlank() || value is JSONArray && value.length() > 0 || value is Boolean) result.put(key, value) }
    result.put("episodes", incoming.json.optInt("episodes").takeIf { it > 0 } ?: original.json.optInt("episodes"))
    if (incoming.title == "短剧") result.put("title", original.title)
    val generic = setOf("短剧", "真人剧", "漫剧", "AI剧", "AI 剧", "AI短剧", "AI 短剧", "AI漫剧", "AI 漫剧")
    if (incoming.json.text("category") in generic && original.json.text("category").isNotBlank() && original.json.text("category") !in generic) result.put("category", original.json.text("category"))
    if (incoming.json.text("releaseStatus") == "unknown") result.put("releaseStatus", original.json.text("releaseStatus"))
    result.put("tags", JSONArray((original.json.array("tags").strings() + incoming.json.array("tags").strings() + original.json.text("category") + incoming.json.text("category")).map { it.trim() }.filter { it.isNotEmpty() }.distinct()))
    return Drama(result)
}
suspend fun LocalStore.refreshDramas(updates: List<Drama>, expectedEpoch: Long = epoch) {
    update { next ->
        if (epoch != expectedEpoch) return@update
        val changed = updates.filter { allowed(it.source) }.associateBy { it.id }
        val favorites = list("favorites").objects().map(::Drama).map { old -> changed[old.id]?.let { mergeDramaMetadata(old, it) } ?: old }
        val history = list("history").objects().map { row -> val old = Drama(row.getJSONObject("drama")); changed[old.id]?.let { row.copy().put("drama", mergeDramaMetadata(old, it).json) } ?: row }
        val candidates = (list("seriesCandidates").objects().map(::Drama) + changed.values + favorites + history.map { Drama(it.getJSONObject("drama")) }).filter { it.source == "hongguo" }.associateBy { it.id }.values.sortedBy { it.id }.take(2000)
        val states = json("followStates"); val ids = favorites.map { it.id }.toSet()
        favorites.forEach { drama -> states.put(drama.id, observeSeries(drama, observedFollow(states.optJSONObject(drama.id), drama), candidates, ids)) }
        next.put(key("favorites"), JSONArray(favorites.map { it.json }).toString()).put(key("history"), JSONArray(history).toString()).put(key("followStates"), states.toString()).put(key("seriesCandidates"), JSONArray(candidates.map { it.json }).toString())
    }
}
suspend fun LocalStore.markUpdatesRead(drama: Drama, season: String? = null) {
    val expected = epoch
    update { next ->
        check(epoch == expected && allowed(drama.source))
        val states = json("followStates"); val value = states.optJSONObject(drama.id) ?: return@update
        if (season == null) value.put("readEpisodes", value.optInt("knownEpisodes").takeIf { it > 0 })
        value.optJSONObject("seriesSeasons")?.let { notices -> notices.keys().forEach { id -> if (season == null || id == season) notices.getJSONObject(id).put("read", true) } }
        next.put(key("followStates"), states.toString())
    }
}
fun resumeEpisodeIndex(episodes: List<Episode>, watch: JSONObject?): Int {
    if (episodes.isEmpty() || watch == null) return 0
    val number = watch.optInt("episode"); val current = episodes.indexOfFirst { it.number == number }
    val finished = watch.optDouble("duration") > 1 && watch.optDouble("position") >= watch.optDouble("duration") - 1
    if (current >= 0 && !finished) return current
    return episodes.indexOfFirst { it.number > number }.takeIf { it >= 0 } ?: current.takeIf { it >= 0 } ?: episodes.lastIndex
}
