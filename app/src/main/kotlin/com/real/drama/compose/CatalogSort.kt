package com.real.drama.compose

import org.json.JSONObject

val catalogSortLabels = linkedMapOf("source" to "默认顺序", "name" to "名称", "season" to "自然季号", "date" to "上线日期", "heat" to "热度", "views" to "播放量")
val catalogReleaseLabels = linkedMapOf("" to "全部", "ongoing" to "连载中", "finished" to "已完结", "unknown" to "状态未知")
fun normalizedSearchText(text: String): String = text.map { if (it.code in 0xff01..0xff5e) (it.code - 0xfee0).toChar() else it }.joinToString("").lowercase(java.util.Locale.ROOT)
    .replace(Regex("[\\s\u3000，。！？、：；·「」『』（）【】《》“”‘’.,!?:;\\-_/()\\[\\]{}]+"), "")
fun matchesDramaQuery(drama: Drama, query: String): Boolean {
    if (query.isBlank()) return true
    val fields = normalizedSearchText("${drama.title} ${drama.description} ${drama.json.array("tags").strings().joinToString(" ")}")
    return query.trim().split(Regex("\\s+")).map(::normalizedSearchText).filter(String::isNotEmpty).all(fields::contains)
}
fun catalogMetric(text: String): Double? {
    val match = Regex("^(\\d+(?:\\.\\d+)?)([亿万千wkmb]?)(?:\\+)?(?:次播放|次观看|人看过|热度|播放|观看|次)?\\+?$").matchEntire(text.lowercase(java.util.Locale.ROOT).replace(Regex("[,，\\s]"), "")) ?: return null
    val number = match.groupValues[1].toDoubleOrNull()?.takeIf(Double::isFinite) ?: return null
    return (number * when (match.groupValues[2]) { "亿" -> 1e8; "万", "w" -> 1e4; "千", "k" -> 1e3; "m" -> 1e6; "b" -> 1e9; else -> 1.0 }).takeIf(Double::isFinite)
}
private fun seasonNumber(text: String): Int {
    text.toIntOrNull()?.let { return it }
    val digits = mapOf('零' to 0, '〇' to 0, '一' to 1, '二' to 2, '两' to 2, '兩' to 2, '三' to 3, '四' to 4, '五' to 5, '六' to 6, '七' to 7, '八' to 8, '九' to 9)
    var number = 0; var digit = 0
    text.forEach { character -> if (character in digits) digit = digit * 10 + digits.getValue(character) else { number += (if (digit == 0) 1 else digit) * (if (character == '百') 100 else 10); digit = 0 } }
    return number + digit
}
private fun naturalTokens(text: String): List<String> = Regex("\\d+|\\D+").findAll(Regex("第([0-9零〇一二两兩三四五六七八九十百]+)([季部])").replace(normalizedSearchText(text)) { "第${seasonNumber(it.groupValues[1])}${it.groupValues[2]}" }).map { it.value }.toList()
fun naturalTitleCompare(left: String, right: String): Int {
    val a = naturalTokens(left); val b = naturalTokens(right)
    for (index in 0 until minOf(a.size, b.size)) {
        val an = a[index].toBigIntegerOrNull(); val bn = b[index].toBigIntegerOrNull()
        val comparison = if (an != null && bn != null) an.compareTo(bn) else a[index].compareTo(b[index])
        if (comparison != 0) return comparison
    }
    return a.size.compareTo(b.size)
}
fun sortCatalog(rows: List<Drama>, view: JSONObject): List<Drama> {
    val items = rows.filter { drama ->
        val release = drama.json.text("releaseStatus").let { if (it == "completed") "finished" else it }
        when (view.text("release")) { "" -> true; "unknown" -> release.isEmpty() || release == "unknown"; else -> release == view.text("release") }
    }
    val sort = view.text("sort", "source")
    if (sort !in catalogSortLabels || sort == "source") return items
    val names = items.associate { it.id to normalizedSearchText(it.title) }
    val metrics = items.associate { drama -> drama.id to if (sort == "date") runCatching { java.time.Instant.parse(drama.json.text("onlineDate")).toEpochMilli().toDouble() }.getOrNull()
        ?: runCatching { java.time.LocalDate.parse(drama.json.text("onlineDate")).toEpochDay().toDouble() * 86400000 }.getOrNull() else catalogMetric(drama.json.text(sort)) }
    return items.sortedWith { a, b -> when (sort) {
        "name" -> names.getValue(a.id).compareTo(names.getValue(b.id))
        "season" -> naturalTitleCompare(a.title, b.title)
        else -> { val left = metrics[a.id]; val right = metrics[b.id]; if (left == null) { if (right == null) 0 else 1 } else if (right == null) -1 else right.compareTo(left) }
    } }
}
