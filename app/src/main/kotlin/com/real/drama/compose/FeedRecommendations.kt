package com.real.drama.compose

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.temporal.ChronoUnit
import kotlin.math.*
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableIntStateOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class FeedSignal(val drama: Drama, val value: Double, val isLike: Boolean = false)

fun leavingFeedValue(elapsed: Long, watch: JSONObject?, started: Long): Double {
    var value = if (elapsed < 3) -1.2 else if (elapsed >= 30) .3 else .05
    val updated = runCatching { Instant.parse(watch?.text("updatedAt")).toEpochMilli() }.getOrDefault(0L)
    if (watch != null && watch.optDouble("duration", 0.0) > 0 && updated > started) {
        val ratio = (watch.optDouble("position", 0.0) / watch.optDouble("duration")).coerceIn(0.0, 1.0)
        value = when { ratio < .05 -> -1.2; ratio < .2 -> -.7; ratio < .5 -> -.2; ratio < .8 -> .45; else -> .85 }
        if (ratio >= .98) value += .45
        if (watch.optInt("episode") >= 3) value += .6
        if (watch.optInt("episode") >= 5) value += .9
    }
    return value
}

class FeedRecommendations(val groups: List<JSONObject>) {
    var revision by mutableIntStateOf(0); private set
    private val topics = groups.flatMap { group -> group.getJSONArray("topics").objects().map { group.text("id") to it } }
    val session = mutableListOf<FeedSignal>()
    val likes = mutableSetOf<String>()
    val recent = mutableListOf<Drama>()
    val exposures = mutableMapOf<String, Int>()
    private val featureCache = java.util.IdentityHashMap<Drama, Set<String>>()
    fun reset() { session.clear(); likes.clear(); recent.clear(); exposures.clear(); featureCache.clear() }
    fun expose(drama: Drama) { recent.removeAll { it.id == drama.id }; recent.add(drama); while (recent.size > 30) recent.removeAt(0); exposures[drama.id] = (exposures[drama.id] ?: 0) + 1 }
    fun like(drama: Drama) {
        revision++
        session.removeAll { it.isLike && it.drama.id == drama.id && it.drama.source == drama.source }
        if (!likes.remove(drama.id)) { likes.add(drama.id); session.add(FeedSignal(drama, 1.0, true)) }
        while (session.size > 60) session.removeAt(0)
    }
    fun signal(drama: Drama, value: Double) { session.add(FeedSignal(drama, value)); while (session.size > 60) session.removeAt(0); revision++ }
    fun forget(drama: Drama) { likes.remove(drama.id); session.removeAll { it.drama.id == drama.id && it.drama.source == drama.source }; recent.removeAll { it.id == drama.id && it.source == drama.source }; exposures.remove(drama.id) }
    fun notInterested(drama: Drama) { likes.remove(drama.id); session.removeAll { it.drama.id == drama.id && it.drama.source == drama.source }; signal(drama, -1.5) }
    private fun shortSignals() = session.map { it.drama to it.value }
    fun features(drama: Drama): Set<String> = featureCache[drama] ?: run {
        val labels = (drama.json.array("tags").strings() + drama.json.text("category")).map { it.trim() }.filter { it.isNotEmpty() && it != "短剧" }.toMutableSet()
        val text = drama.title.take(128) + " " + drama.description.take(192)
        listOf("重生", "逆袭", "复仇", "穿越", "系统", "闪婚", "豪门", "先婚后爱", "甜宠", "虐恋", "悬疑", "治愈", "搞笑", "仙侠", "宫斗", "年代", "商战", "赘婿", "职场", "家庭", "校园", "成长", "都市", "古装", "奇幻", "漫剧", "AI剧", "AI短剧", "AI漫剧", "真人剧", "东方仙侠", "乡村", "传统玄幻", "冒险").filterTo(labels) { text.contains(it) }
        if (featureCache.size >= 4096) featureCache.remove(featureCache.keys.first())
        featureCache[drama] = labels; labels
    }
    private fun normalize(value: String) = value.lowercase().replace(Regex("[\\s·•_—-]+"), "").replace("ai短剧", "ai剧").replace("ai漫剧", "漫剧")
    fun matches(drama: Drama, categories: List<String>): Boolean {
        val labels = features(drama).map(::normalize).toSet(); val text = normalize(drama.title + drama.description)
        return categories.map(::normalize).filter { it.isNotEmpty() }.any { it in labels || text.contains(it) }
    }
    fun topicMatches(value: String): List<Pair<String, JSONObject>> {
        val normalized = normalize(value)
        if (normalized.isEmpty()) return emptyList()
        return topics.filter { (_, topic) -> topic.getJSONArray("aliases").strings().map(::normalize).any { normalized.contains(it) } }.ifEmpty { listOf(topics.last()) }
    }
    fun watchValue(entry: JSONObject): Double {
        val duration = entry.optDouble("duration", 0.0); val position = entry.optDouble("position", 0.0)
        if (duration <= 0 || position <= 0) return 0.0
        val ratio = (position / duration).coerceIn(0.0, 1.0)
        var value = when { ratio < .05 -> -1.2; ratio < .2 -> -.7; ratio < .5 -> -.2; ratio < .8 -> .45; else -> .85 }
        if (ratio >= .98) value += .45
        if (entry.optInt("episode") >= 3) value += .6
        if (entry.optInt("episode") >= 5) value += .9
        val age = runCatching { ChronoUnit.DAYS.between(Instant.parse(entry.text("updatedAt")), Instant.now()) }.getOrDefault(0)
        value *= when { age <= 30 -> 1.0; age <= 180 -> .7; else -> .4 }
        return value.coerceIn(-2.0, 3.0)
    }
    private fun weights(signals: List<Pair<Drama, Double>>): Map<String, Double> {
        val samples = mutableMapOf<String, MutableList<Double>>()
        signals.forEach { (drama, value) -> features(drama).forEach { samples.getOrPut(it) { mutableListOf() }.add(value) } }
        return samples.mapValues { (_, values) -> (values.sum() / sqrt(values.size.toDouble())).coerceIn(-3.0, 3.0) }
    }
    private fun history(store: LocalStore) = store.history().map { Drama(it.getJSONObject("drama")) to watchValue(it) } + store.favorites().map { it to 1.2 }
    fun interest(store: LocalStore): Map<String, Triple<Double, Double, Double>> {
        val long = weights(history(store).filter { it.first.source == "hongguo" }); val short = weights(shortSignals().filter { it.first.source == "hongguo" })
        val samples = mutableMapOf<String, MutableMap<String, Pair<Double, Double>>>()
        for (feature in long.keys + short.keys) for ((group, topic) in topicMatches(feature)) {
            for (key in listOf("group:$group", "topic:${topic.text("id")}")) samples.getOrPut(key) { mutableMapOf() }[feature] = (long[feature] ?: 0.0) to (short[feature] ?: 0.0)
        }
        return samples.mapValues { (_, values) -> val a = values.values.map { it.first }.average(); val b = values.values.map { it.second }.average(); Triple(a, b, a * .6 + b * .4) }
    }
    fun groupedWeights(raw: JSONObject): Map<String, Int> {
        val result = mutableMapOf<String, Int>(); val samples = mutableMapOf<String, MutableList<Int>>()
        raw.keys().forEach { key -> if (key.startsWith("topic:") || key.startsWith("group:")) result[key] = raw.getInt(key) else topicMatches(key).forEach { (_, topic) -> samples.getOrPut("topic:${topic.text("id")}") { mutableListOf() }.add(raw.getInt(key)) } }
        samples.forEach { (key, values) -> result.putIfAbsent(key, values.average().roundToInt()) }
        return result
    }
    private fun manual(feature: String, weights: Map<String, Int>): Double? {
        val overrides = mutableListOf<Int>(); val inherited = mutableListOf<Int>()
        for ((group, topic) in topicMatches(feature)) { val value = weights["topic:${topic.text("id")}"]; if (value != null) overrides.add(value) else weights["group:$group"]?.let(inherited::add) }
        val values = overrides.ifEmpty { inherited }
        return if (values.isNotEmpty()) values.average() * .03 else weights[feature]?.coerceIn(-100, 100)?.times(.03)
    }
    private fun match(features: Set<String>, weights: Map<String, Double>, manual: Map<String, Int>): Double {
        if (features.isEmpty() || weights.isEmpty() && features.none { manual(it, manual) != null }) return .35
        return ((features.map { manual(it, manual) ?: weights[it] ?: 0.0 }.average() + 3) / 6).coerceIn(0.0, 1.0)
    }
    private fun count(text: String): Double? {
        val found = Regex("([0-9]+(?:\\.[0-9]+)?)\\s*([万亿kKwW]?)").find(text) ?: return null
        return found.groupValues[1].toDouble() * when (found.groupValues[2].lowercase()) { "万", "w" -> 10000.0; "亿" -> 100000000.0; "k" -> 1000.0; else -> 1.0 }
    }
    suspend fun rank(candidates: List<Drama>, store: LocalStore, seed: Int, excludeRecent: Boolean = false, excludedCategories: List<String> = emptyList()): List<Drama> {
        val signals = session.toList()
        val recentItems = recent.toList()
        val seen = exposures.toMap()
        return withContext(Dispatchers.Default) {
            FeedRecommendations(groups).apply {
                session.addAll(signals)
                recent.addAll(recentItems)
                exposures.putAll(seen)
            }.rankCandidates(candidates, store, seed, excludeRecent, excludedCategories)
        }
    }

    private fun rankCandidates(candidates: List<Drama>, store: LocalStore, seed: Int, excludeRecent: Boolean, excludedCategories: List<String>): List<Drama> {
        val preferences = store.json("feedRecommendation")
        val disliked = store.list("feedNotInterested").strings().toSet()
        val unavailable = store.json("unavailableFeedDramas").let { data -> data.keys().asSequence().filter { data.optLong(it) > System.currentTimeMillis() }.toSet() }
        val recentIds = if (excludeRecent) recent.map { it.id }.toSet() else emptySet()
        val recentTitles = if (excludeRecent) recent.map { normalizedSearchText(it.title) }.filter { it.isNotEmpty() }.toSet() else emptySet()
        val unique = candidates.filterNot {
            it.id in unavailable || "${it.source}:${it.id}" in unavailable || it.id in recentIds ||
                it.source == "hongguo" && (it.id in disliked || "${it.source}:${it.id}" in disliked) ||
                recentTitles.isNotEmpty() && normalizedSearchText(it.title) in recentTitles ||
                excludedCategories.isNotEmpty() && matches(it, excludedCategories)
        }.distinctBy { it.id }
        if (preferences.optBoolean("randomMode")) return unique.shuffled(kotlin.random.Random(seed))
        val long = weights(history(store)); val short = weights(shortSignals())
        val overrides = groupedWeights(preferences.optJSONObject("manualWeights") ?: JSONObject())
        val seen = recent.flatMap(::features).groupingBy { it }.eachCount()
        val scored = unique.map { drama ->
            val features = features(drama); val manual = if (drama.source == "hongguo") overrides else emptyMap()
            val heat = (count(drama.json.text("heat")) ?: count(drama.json.text("views")))?.let { (ln(1 + it) / ln(100000001.0)).coerceIn(0.0, 1.0) } ?: .35
            val freshness = runCatching { (1 - ChronoUnit.DAYS.between(LocalDate.parse(drama.json.text("onlineDate").take(10)), LocalDate.now()) / 365.0).coerceIn(0.0, 1.0) }.getOrDefault(.35)
            val novelty = ((if (features.isEmpty()) .35 else features.map { 1.0 / (1 + (seen[it] ?: 0)) }.average()) + 1.0 / (1 + (exposures[drama.id] ?: 0))) / 2
            var noise = 0x811c9dc5L; "$seed:${drama.source}:${drama.id}".forEach { noise = ((noise xor it.code.toLong()) * 0x01000193L) and 0x7fffffff }
            val penalty = if (recent.any { it.id == drama.id }) 1.25 else (recent.count { it.source == drama.source && it.title == drama.title || features(it).intersect(features).size >= 2 } * .045).coerceAtMost(.2)
            drama to (.38 * match(features, long, manual) + .27 * match(features, short, manual) + .1 * heat + .1 * freshness + .1 * novelty + .05 * noise / 0x7fffffff - penalty)
        }.sortedWith(compareByDescending<Pair<Drama, Double>> { it.second }.thenBy { "${it.first.source}:${it.first.id}" })
        val ranked = mutableListOf<Drama>()
        for (window in scored.chunked(24)) {
            val remaining = window.toMutableList()
            while (remaining.isNotEmpty()) {
                val selected = remaining.maxBy { (drama, score) ->
                    score - (ranked.takeLast(5).maxOfOrNull { prior -> val overlap = features(drama).intersect(features(prior)).size; when { drama.source == prior.source && drama.title == prior.title -> 1.0; overlap >= 2 -> .16; overlap == 1 && drama.source == prior.source -> .08; else -> 0.0 } } ?: 0.0)
                }
                ranked.add(selected.first); remaining.remove(selected)
            }
        }
        return ranked
    }
}
