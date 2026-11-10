package com.real.drama.compose

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

fun obj(vararg entries: Pair<String, Any?>) = JSONObject().apply { entries.forEach { (key, value) -> put(key, value ?: JSONObject.NULL) } }
fun JSONObject.copy() = JSONObject(canonical(this))
fun JSONObject.text(key: String, default: String = "") = if (isNull(key)) default else optString(key, default)
fun JSONObject.array(key: String) = optJSONArray(key) ?: JSONArray()
fun JSONArray.objects() = (0 until length()).mapNotNull { optJSONObject(it) }
fun JSONArray.strings() = (0 until length()).mapNotNull { opt(it) as? String }
fun JSONObject.merge(other: JSONObject) = copy().apply { other.keys().forEach { put(it, other.get(it)) } }
fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
fun normalizedDrama(input: JSONObject): JSONObject = obj("metadataSchema" to 1, "id" to input.text("id"), "source" to input.text("source", "hongguo"),
    "title" to input.text("title", "短剧"), "episodes" to input.optInt("episodes"), "tags" to JSONArray(input.array("tags").strings()),
    "vip" to input.opt("vip").takeIf { it is Boolean && (it == true || input.text("source") != "huangdou" || input.optInt("metadataSchema") >= 1) }).apply {
    listOf("sourceId", "description", "cover", "category", "heat", "views", "onlineDate", "releaseStatus", "creatorSecUid", "creatorName", "creatorAvatar", "creatorId").forEach { put(it, input.text(it)) }
}
data class Drama(private val input: JSONObject) {
    val json = normalizedDrama(input)
    val id get() = json.text("id")
    val source get() = json.text("source")
    val title get() = json.text("title", "未命名")
    val cover get() = json.text("cover")
    val description get() = json.text("description")
    val creator get() = json.text("creatorName")
    val creatorId get() = json.text("creatorSecUid").ifEmpty { json.text("creatorId") }
    override fun equals(other: Any?) = other is Drama && id == other.id
    override fun hashCode() = id.hashCode()
}
data class Episode(val json: JSONObject, val number: Int) {
    val id get() = json.text("id")
    val title get() = json.text("title").ifBlank { "第 $number 集" }
}
data class Detail(val drama: Drama, val episodes: List<Episode>, val warning: String = "") {
    companion object {
        fun parse(value: JSONObject, fallback: Drama): Detail {
            val chapters = value.array("chapters").objects()
            return Detail(value.optJSONObject("drama")?.let(::Drama) ?: fallback,
                chapters.mapIndexed { index, chapter -> Episode(chapter, chapter.optInt("currentEpisode", index + 1)) }, value.text("warning"))
        }
    }
}
data class Catalog(val items: List<Drama>, val more: Boolean, val page: Int, val warning: String = "") {
    companion object { fun parse(value: JSONObject) = Catalog(value.array("items").objects().map(::Drama), value.optBoolean("hasMore"), value.optInt("page", 1), value.text("warning")) }
}
data class SourcePackage(val document: JSONObject, val origin: String, val digest: String, val bytes: ByteArray) {
    val id get() = document.getString("id")
    val name get() = document.getString("name")
    val version get() = document.getString("version")
    val program get() = document.getString("program")
    val kind get() = document.text("kind", "drama")
    val group get() = document.text("credentialGroup", id)
    val catalogGroup get() = document.text("family").takeIf { it.isNotEmpty() && it != "douyin" } ?: when (id) { "huangguo-video", "huangguoai", "cloudfront" -> "huangguo"; else -> id }
    val catalogName get() = if (catalogGroup == "huangguo") "黄果" else name
    val domains get() = document.array("domains").strings()
    val credentials get() = document.array("credentialDomains").strings()
    val capabilities get() = document.array("capabilities").strings().toSet()
    internal val feedSeek get() = kind != "live" && (kind == "video" || "feedSeek" in capabilities)
    internal val danmakuWindowMs get() = document.optInt("danmakuWindowMs").takeIf { it in 1_000..600_000 }
        ?: if (group == "bilibili") 360_000 else 32_000
    val sources: List<SourcePackage> get() = if (!document.has("children")) listOf(this) else
        document.array("children").objects().map { child ->
            SourcePackage(document.merge(child).apply { remove("children"); put("api", 1) }, origin, digest, bytes)
        }
    companion object {
        fun parse(bytes: ByteArray, origin: String, expectedHash: String? = null, expectedId: String? = null): SourcePackage {
            require(bytes.size <= 4 * 1024 * 1024) { "站源包超过 4 MiB" }
            val digest = sha256(bytes)
            require(expectedHash == null || digest == expectedHash) { "站源摘要不匹配，原版本已保留" }
            val d = JSONObject(bytes.toString(Charsets.UTF_8))
            require(d.optInt("schema") == 1 && (d.optInt("api") == 1 || d.optInt("api") == 2 && d.has("children")) && d.text("engine") == "javascript-generator-v1") { "站源协议不兼容" }
            listOf("id", "name", "version", "program").forEach { require(d.opt(it) is String && d.getString(it).isNotEmpty()) { "站源缺少 $it" } }
            require(d.getString("id").matches(Regex("^[a-z][a-z0-9-]{0,63}$")) && (expectedId == null || expectedId == d.getString("id"))) { "站源标识无效" }
            require(d.getString("version").matches(Regex("^\\d+\\.\\d+\\.\\d+$"))) { "版本无效" }
            listOf("domains", "capabilities").forEach { key -> require(d.opt(key) is JSONArray && d.array(key).strings().size == d.array(key).length()) { "站源声明无效" } }
            val result = SourcePackage(d, origin, digest, bytes)
            require(result.domains.size in 1..30 && result.domains.all { it.matches(Regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$")) && '.' in it && ".." !in it }) { "站源域名无效" }
            listOf("credentialDomains", "browserCredentialDomains").forEach { key -> require(!d.has(key) || d.opt(key) is JSONArray && d.array(key).strings().size == d.array(key).length()) }
            require(result.credentials.all { it in result.domains }) { "凭据域名超出声明" }
            val browserDomains = d.array("browserCredentialDomains").strings()
            require(browserDomains.all { it in result.credentials } && browserDomains.distinct().size == browserDomains.size && (browserDomains.isEmpty() || d.optBoolean("browser")))
            require(!d.optBoolean("browser") || result.credentials.isEmpty() || browserDomains.isNotEmpty()) { "账号站源不能使用共享浏览器会话" }
            val protected = when (result.group) {
                "douyin" -> setOf("www.douyin.com", "www-hj.douyin.com", "live.douyin.com")
                "bilibili" -> if (result.id in setOf("bilibili-live", "bilibili-live-test")) setOf("api.live.bilibili.com") else setOf("api.bilibili.com", "api.live.bilibili.com")
                else -> null
            }
            if (protected != null) {
                val ids = if (result.group == "douyin") listOf("douyin", "douyin-live", "douyin-series", "douyin-theater") else listOf("bilibili", "bilibili-live")
                require(result.id in ids + ids.map { "$it-test" } && result.credentials.all { it in protected }) { "订阅无权读取此账号组" }
            }
            require(result.program.length <= 1500000) { "站源脚本过大" }
            if (d.has("children")) {
                val children = d.array("children")
                require(children.length() in 1..20 && children.objects().size == children.length())
                require(children.objects().map { it.getString("id") }.distinct().size == children.length()) { "组合站源包含重复子项" }
                children.objects().forEach { child ->
                    require(!child.has("children"))
                    val merged = d.merge(child).apply { remove("children"); put("api", 1) }
                    val parsed = parse(merged.toString().toByteArray(), origin)
                    require(parsed.domains.all { it in result.domains }) { "子项域名超出组合权限" }
                }
            }
            return result
        }
    }
}
