package com.real.drama.compose

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

fun canonical(value: Any?): String = when (value) {
    null, JSONObject.NULL -> "null"
    is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(",", "{", "}") { canonical(it) + ":" + canonical(value.get(it)) }
    is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
    is String -> buildString { append('"'); value.forEach { c -> when (c) { '"' -> append("\\\""); '\\' -> append("\\\\"); '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t"); '\b' -> append("\\b"); '\u000c' -> append("\\f"); else -> if (c.code < 32) append("\\u%04x".format(c.code)) else append(c) } }; append('"') }
    is Boolean, is Int, is Long -> value.toString()
    is Number -> { require(value.toDouble().isFinite()); value.toString() }
    else -> error("不支持的同步字段")
}
fun lanHash(value: Any?) = sha256(canonical(value).toByteArray())
fun integral(value: Any?) = value is Int || value is Long
fun vectorIncludes(a: JSONObject, b: JSONObject) = b.keys().asSequence().all { a.optLong(it) >= b.getLong(it) }
fun vectorJoin(a: JSONObject, b: JSONObject) = JSONObject(canonical(a)).apply {
    b.keys().forEach { put(it, maxOf(optLong(it), b.getLong(it))) }
    require(length() <= 64) { "同步设备数量超过限制" }
}
fun mergeCell(first: JSONArray, second: JSONArray): JSONArray {
    val result = mutableListOf<JSONObject>()
    for (incoming in first.objects() + second.objects()) {
        var current = incoming
        val prior = result.filter { vectorIncludes(it.getJSONObject("v"), current.getJSONObject("v")) }
        if (prior.isNotEmpty()) {
            require(prior.none { vectorIncludes(current.getJSONObject("v"), it.getJSONObject("v")) && canonical(it.opt("value")) != canonical(current.opt("value")) }) { "相同同步版本的内容不一致" }
            continue
        }
        result.removeAll { vectorIncludes(current.getJSONObject("v"), it.getJSONObject("v")) }
        val identical = result.filter { canonical(it.opt("value")) == canonical(current.opt("value")) }
        for (value in identical) { current = obj("v" to vectorJoin(current.getJSONObject("v"), value.getJSONObject("v")), "value" to current.opt("value")); result.remove(value) }
        result.removeAll { vectorIncludes(current.getJSONObject("v"), it.getJSONObject("v")) }; result.add(current)
    }
    require(result.size <= 32) { "同步冲突过多，请先处理冲突" }
    return JSONArray(result.sortedBy(::canonical))
}
fun validateLanDrama(row: JSONObject) {
    val source = row.text("source"); val id = row.text("id")
    require(source.matches(Regex("[a-z][a-z0-9-]{0,31}")) && id.length <= 512 && id.startsWith("$source:") && id.length > source.length + 1)
    require(row.text("sourceId").length <= 450 && (row.text("sourceId").isEmpty() || id == "$source:${row.text("sourceId")}"))
    listOf("description", "cover", "category", "heat", "views", "onlineDate", "releaseStatus").forEach { key -> require(row.opt(key) == null || row.opt(key) is String); require(row.text(key).length <= if (key == "description") 4000 else 2048) }
    require(row.text("title").length in 1..300 && row.text("description").length <= 4000 && integral(row.opt("episodes")) && row.optInt("episodes") in 0..1000000)
    require(row.opt("tags") is JSONArray && row.array("tags").length() <= 32 && row.array("tags").strings().size == row.array("tags").length() && row.array("tags").strings().all { it.length in 1..100 })
    if (row.text("cover").isNotEmpty()) { val uri = java.net.URI(row.text("cover")); require(uri.scheme in setOf("http", "https") && uri.userInfo == null && row.text("cover").length <= 2048) }
}
fun compactLanDrama(input: JSONObject): JSONObject = normalizedDrama(input).apply {
    put("title", text("title").take(300)); put("description", text("description").take(4000))
    put("tags", JSONArray(array("tags").strings().take(32).map { it.take(100) }))
    if (text("cover").length > 2048 || runCatching { java.net.URI(text("cover")).scheme !in setOf("http", "https") }.getOrDefault(true)) put("cover", "")
    validateLanDrama(this)
}
fun lanTimestamp(value: String): String {
    val time = Instant.parse(value); val micros = time.nano / 1000
    val fraction = if (micros % 1000 == 0) (micros / 1000).toString().padStart(3, '0') else micros.toString().padStart(6, '0')
    return java.time.format.DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss").withZone(java.time.ZoneOffset.UTC).format(time) + "." + fraction + "Z"
}
fun validateLanRecord(row: JSONObject) {
    require(canonical(row).toByteArray().size <= 512 * 1024)
    validateLanDrama(row.getJSONObject("drama"))
    for (field in listOf("member", "status", "progress")) {
        val cell = row.getJSONArray(field)
        require(cell.length() in 1..32 && cell.objects().size == cell.length())
        cell.objects().forEach { candidate ->
            val version = candidate.getJSONObject("v"); require(version.length() in 1..64)
            version.keys().forEach { require(it.matches(Regex("[a-f0-9]{32}")) && integral(version.opt(it)) && version.getLong(it) in 1 until 9007199254740000L) }
            val value = candidate.opt("value")
            when (field) {
                "member" -> require(value is Boolean)
                "status" -> { require(value is JSONObject); require(value.length() == 2 && value.text("status") in setOf("planned", "watching", "watched") && value.opt("manual") is Boolean && (!value.optBoolean("manual") || value.text("status") == "watched")) }
                else -> if (value != null && value != JSONObject.NULL) {
                    require(value is JSONObject && value.length() == 4 && integral(value.opt("episode")) && value.optInt("episode") in 1..1000000)
                    require(value.opt("position") is Number && value.opt("duration") is Number && value.optDouble("position") in 0.0..604800.0 && value.optDouble("duration") in 0.0..604800.0)
                    Instant.parse(value.getString("updatedAt"))
                }
            }
        }
        for (a in 0 until cell.length()) for (b in a + 1 until cell.length()) {
            val av = cell.getJSONObject(a); val bv = cell.getJSONObject(b)
            require(!vectorIncludes(av.getJSONObject("v"), bv.getJSONObject("v")) && !vectorIncludes(bv.getJSONObject("v"), av.getJSONObject("v")) && canonical(av.opt("value")) != canonical(bv.opt("value")))
        }
    }
    require(integral(row.opt("known")) && row.optInt("known") in 0..1000000 && (row.isNull("read") || integral(row.opt("read")) && row.optInt("read") in 0..row.optInt("known")))
}
fun mergeRecord(a: JSONObject, b: JSONObject): JSONObject {
    require(a.getJSONObject("drama").text("id") == b.getJSONObject("drama").text("id"))
    val da = a.getJSONObject("drama"); val db = b.getJSONObject("drama")
    val metadata = if (canonical(da) <= canonical(db)) mergeDrama(da, db) else mergeDrama(db, da)
    return obj("drama" to compactLanDrama(metadata), "member" to mergeCell(a.getJSONArray("member"), b.getJSONArray("member")), "status" to mergeCell(a.getJSONArray("status"), b.getJSONArray("status")),
        "progress" to mergeCell(a.getJSONArray("progress"), b.getJSONArray("progress")), "known" to maxOf(a.optInt("known"), b.optInt("known")),
        "read" to if (a.isNull("read") && b.isNull("read")) null else maxOf(a.optInt("read"), b.optInt("read")))
}
fun mergeDrama(old: JSONObject, fresh: JSONObject): JSONObject {
    if (old.text("id") != fresh.text("id")) return fresh
    val result = JSONObject(canonical(old))
    val generic = setOf("短剧", "真人剧", "漫剧", "AI剧", "AI 剧", "AI短剧", "AI 短剧", "AI漫剧", "AI 漫剧")
    fresh.keys().forEach { name ->
        val value = fresh.opt(name)
        when (name) {
            "title" -> if (value is String && value.isNotEmpty() && value != "短剧") result.put(name, value)
            "category" -> if (value is String && value.isNotEmpty() && !(value in generic && old.text(name).isNotEmpty() && old.text(name) !in generic)) result.put(name, value)
            "episodes" -> if (fresh.optInt(name) > 0) result.put(name, value)
            "releaseStatus" -> if (value is String && value.isNotEmpty() && value != "unknown") result.put(name, value)
            "tags" -> Unit
            else -> if (value != JSONObject.NULL && (value !is String || value.isNotEmpty())) result.put(name, value)
        }
    }
    result.put("tags", JSONArray((old.array("tags").strings() + fresh.array("tags").strings() + listOf(old.text("category"), fresh.text("category"))).map { it.trim() }.filter { it.isNotEmpty() }.distinct()))
    return result
}
class LanRecords(val document: JSONObject) {
    val replica = document.getString("replica")
    var counter = document.optLong("counter")
    val records = document.array("records").objects().associateBy { it.getJSONObject("drama").getString("id") }.toMutableMap()
    init {
        require(document.optInt("schema") == 1 && integral(document.opt("counter")) && replica.matches(Regex("[a-f0-9]{32}")) && records.size <= 25000 && counter in 0 until 9007199254740000L)
        require(records.size == document.getJSONArray("records").length())
        records.values.forEach(::validateLanRecord)
    }
    fun hash(sources: Set<String>): String = lanHash(JSONArray(records.values.filter { it.getJSONObject("drama").text("source") in sources }.sortedBy { it.getJSONObject("drama").text("id") }.map { JSONArray().put(it.getJSONObject("drama").text("id")).put(lanHash(it)) }))
    fun edit(cell: JSONArray?, value: Any?): JSONArray {
        var version = JSONObject()
        cell?.objects()?.forEach { version = vectorJoin(version, it.getJSONObject("v")) }
        counter = maxOf(counter, version.optLong(replica)) + 1
        require(counter in 1 until 9007199254740000L) { "同步计数已达上限" }
        return JSONArray().put(obj("v" to version.put(replica, counter), "value" to value))
    }
    fun reconcile(store: LocalStore) = reconcile(store.list("favorites"), store.list("history"), store.json("followStates"))
    fun clearProgress(ids: Set<String>) {
        ids.forEach { id -> records[id]?.let { row -> row.put("progress", edit(row.getJSONArray("progress"), null)) } }
    }
    fun reconcile(favoriteRows: JSONArray, historyRows: JSONArray, states: JSONObject) {
        val favorites = favoriteRows.objects().associateBy { it.text("id") }
        val history = historyRows.objects().associateBy { it.getJSONObject("drama").text("id") }
        for (id in records.keys + favorites.keys) {
            val old = records[id]
            val drama = compactLanDrama(favorites[id] ?: old?.getJSONObject("drama") ?: continue)
            val followed = favorites.containsKey(id)
            val state = states.optJSONObject(id) ?: JSONObject()
            val status = obj("status" to state.text("status", "planned"), "manual" to state.optBoolean("manuallyWatched"))
            val progress = history[id]?.let { obj("episode" to it.optInt("episode"), "position" to kotlin.math.floor(it.optDouble("position") * 1000 + .5) / 1000, "duration" to kotlin.math.floor(it.optDouble("duration") * 1000 + .5) / 1000, "updatedAt" to lanTimestamp(it.text("updatedAt"))) }
            if (old == null) records[id] = obj("drama" to drama, "member" to edit(null, true), "status" to edit(null, status), "progress" to edit(null, progress), "known" to drama.optInt("episodes"), "read" to state.opt("readEpisodes"))
            else {
                val row = JSONObject(canonical(old)).put("drama", drama).put("known", maxOf(old.optInt("known"), state.optInt("knownEpisodes"), drama.optInt("episodes"))).put("read", state.opt("readEpisodes") ?: old.opt("read"))
                val member = row.getJSONArray("member")
                if (member.length() == 1 && member.getJSONObject(0).optBoolean("value") != followed) row.put("member", edit(member, followed))
                if (followed) {
                    for ((field, value) in listOf("status" to status, "progress" to progress)) {
                        val cell = row.getJSONArray(field)
                        if (cell.length() == 1 && canonical(cell.getJSONObject(0).opt("value")) != canonical(value)) row.put(field, edit(cell, value))
                    }
                }
                records[id] = row
            }
        }
        require(records.size <= 25000)
    }
    fun json() = obj("schema" to 1, "replica" to replica, "counter" to counter, "records" to JSONArray(records.values.toList()))
    companion object { fun fresh() = LanRecords(obj("schema" to 1, "replica" to randomToken(), "counter" to 0, "records" to JSONArray())) }
}

fun LocalStore.lanDocument(): LanRecords = (if (text("lanRecords").isEmpty()) LanRecords.fresh() else LanRecords(json("lanRecords"))).also { it.reconcile(this) }
suspend fun LocalStore.ensureLanRecords() {
    if (text("lanRecords").isEmpty()) set("lanRecords", canonical(lanDocument().json()))
}
suspend fun LocalStore.applyLanRecords(operation: String, base: String, sources: Set<String>, incoming: List<JSONObject>, expectedEpoch: Long, current: () -> Boolean = { true }) {
    update { next ->
        check(!locked.value && epoch == expectedEpoch && current() && sources.isNotEmpty() && sources.all(::allowed)) { "当前用户或站源权限已变更，请重新连接" }
        val receipts = list("lanReceipts").objects()
        if (receipts.any { it.text("operation") == operation }) return@update
        val doc = lanDocument()
        check(doc.hash(sources) == base) { "记录刚刚发生变化，请重新预览" }
        require(incoming.size <= 25000 && incoming.map { it.getJSONObject("drama").text("id") }.distinct().size == incoming.size)
        val favorites = list("favorites").objects().associateBy { it.text("id") }.toMutableMap()
        val history = list("history").objects().associateBy { it.getJSONObject("drama").text("id") }.toMutableMap()
        val states = json("followStates")
        incoming.forEach { row ->
            validateLanRecord(row)
            val drama = row.getJSONObject("drama"); val id = drama.text("id")
            require(drama.text("source") in sources)
            doc.records[id] = row
            if (row.getJSONArray("member").objects().all { it.getBoolean("value") }) {
                favorites[id] = drama
                val status = row.getJSONArray("status").objects().sortedBy(::canonical).first().getJSONObject("value")
                val state = states.optJSONObject(id) ?: JSONObject()
                state.put("status", status.text("status")).put("manuallyWatched", status.optBoolean("manual")).put("knownEpisodes", row.optInt("known")).put("readEpisodes", row.opt("read"))
                states.put(id, state)
                val progress = row.getJSONArray("progress").objects().sortedBy(::canonical).first().optJSONObject("value")
                if (progress == null) history.remove(id) else history[id] = JSONObject(canonical(progress)).put("drama", drama)
            } else { favorites.remove(id); states.remove(id) }
        }
        require(favorites.size <= 20000 && doc.records.size <= 25000)
        next.put(key("favorites"), canonical(JSONArray(favorites.values.toList())))
            .put(key("followStates"), canonical(states))
            .put(key("history"), canonical(JSONArray(history.values.sortedByDescending { it.text("updatedAt") }.take(300))))
            .put(key("lanRecords"), canonical(doc.json()))
            .put(key("lanReceipts"), canonical(JSONArray((receipts + obj("operation" to operation, "hash" to doc.hash(sources), "savedAt" to Instant.now().toString())).takeLast(64))))
    }
}
