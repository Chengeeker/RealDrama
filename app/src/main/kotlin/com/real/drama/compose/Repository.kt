package com.real.drama.compose

import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicLong

class DramaApplication : Application() {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    lateinit var repository: Repository; private set
    override fun onCreate() { super.onCreate(); repository = Repository(this) }
}
class Repository(val context: Context) {
    val store = LocalStore(context)
    val danmaku = MutableStateFlow(false)
    val diagnostics = Diagnostics(store.directory)
    val subscriptions = Subscriptions(File(store.directory, "source-subscriptions"), File(context.filesDir, "source-subscriptions"), store)
    val secrets = Secrets(context)
    val runtime = SourceRuntime(context, subscriptions, store, secrets)
    val mediaLibrary = MediaLibrary(this)
    val lan = LanController(this)
    val maintenance = SourceMaintenance(this)
    val recommendations by lazy { FeedRecommendations(JSONArray(context.assets.open("feed_topics.json").bufferedReader().use { it.readText() }).objects()) }
    val ready = MutableStateFlow(false)
    val startupError = MutableStateFlow<String?>(null)
    private val initialize = Mutex()
    private val sequence = AtomicLong(System.currentTimeMillis() * 1000)
    private val catalogs = LinkedHashMap<String, Catalog>()
    val storageErrors = MutableStateFlow<Map<String, String>>(emptyMap())
    private val details = LinkedHashMap<String, Detail>()
    private val resolving = Mutex()
    private val resolveScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private data class Pending(val task: Deferred<JSONObject>, var readers: Int)
    private val pending = mutableMapOf<String, Pending>()
    private suspend fun resolvedData(drama: Drama, episode: Episode, quality: Int): JSONObject {
        val key = "${store.epoch}:${source(drama.source)?.digest}:${drama.id}:${episode.id}:$quality"
        val entry = resolving.withLock {
            pending.getOrPut(key) { Pending(resolveScope.async { runtime.execute(drama.source, "resolve", obj("drama" to drama.json, "chapter" to episode.json, "index" to episode.number, "quality" to quality)) }, 0) }.also { it.readers++ }
        }
        try { return entry.task.await().copy() }
        finally { withContext(NonCancellable) { resolving.withLock { entry.readers--; if (entry.readers == 0) { entry.task.cancel(); if (pending[key] === entry) pending.remove(key) } } } }
    }
    suspend fun open() = initialize.withLock {
        if (ready.value) return@withLock
        try {
            store.open()
            check(store.readError == null) { store.readError.orEmpty() }
            subscriptions.open()
            store.reconcileSources(subscriptions.sources.map { it.id }.toSet())
            migrateLegacyFiles(context, store.directory)
            withContext(Dispatchers.IO) {
                val settings = File(context.filesDir, "resource-settings.json")
                val destination = File(store.directory, settings.name)
                if (settings.exists() && !destination.exists() && settings.length() < 64 * 1024) atomicWrite(destination, settings.readBytes())
            }
            val core = NativeBridge.call(obj("action" to "initialize", "directory" to store.directory.absolutePath))
            check(core.optInt("sourceRuntime") == 1) { "应用与原生核心版本不一致" }
            updateProxy()
            mediaLibrary.open()
            ready.value = true; startupError.value = null
        } catch (cancel: CancellationException) { throw cancel }
        catch (error: Exception) { startupError.value = error.message ?: "初始化失败" }
    }
    suspend fun updateProxy() {
        val proxy = context.getSystemService(ConnectivityManager::class.java)?.defaultProxy
        NativeBridge.call(obj("action" to "updateSystemProxy", "systemProxy" to if (proxy == null) JSONObject() else obj("http" to "http://${proxy.host}:${proxy.port}", "https" to "http://${proxy.host}:${proxy.port}", "bypass" to JSONArray(proxy.exclusionList.toList()), "pac" to (proxy.pacFileUrl != android.net.Uri.EMPTY))))
    }
    fun source(id: String) = subscriptions.source(id)
    fun available() = subscriptions.sources.filter { store.allowed(it.id) }
    suspend fun categories(source: String) = if (this.source(source)?.capabilities?.contains("categories") == true) runtime.execute(source, "categories").array("items").objects() else emptyList()
    suspend fun catalog(source: String, page: Int = 1, category: String = "", query: String = "", force: Boolean = false): Catalog {
        check(store.allowed(source))
        val epoch = store.epoch
        val key = "${store.active}:$source:$category:$query:${subscriptions.source(source)?.digest}"
        val value = runtime.execute(source, if (query.isEmpty()) "catalog" else "search", obj("page" to page, "category" to category, "query" to query, "force" to force))
        if (!value.has("page")) value.put("page", page)
        val parsed = Catalog.parse(value)
        check(epoch == store.epoch && store.allowed(source)) { "用户或站源权限已变更" }
        store.refreshDramas(parsed.items, epoch)
        if (query.isEmpty()) {
            val previous = if (page > 1 && !force) cached(source, category)?.items.orEmpty() else emptyList()
            val merged = (previous + parsed.items).associateBy { it.id }.values.toList().takeLast(5000)
            catalogs[key] = parsed.copy(items = merged)
            while (catalogs.size > 24) catalogs.remove(catalogs.keys.first())
            try { saveCatalog(source, category, catalogs.getValue(key)) }
            catch (cancel: CancellationException) { throw cancel } catch (_: Exception) { storageErrors.value = storageErrors.value + (source to "目录未能保存，本次内容仍可浏览，请检查应用存储") }
        }
        return parsed
    }
    suspend fun cached(source: String, category: String = ""): Catalog? {
        check(store.allowed(source))
        val key = "${store.active}:$source:$category::${subscriptions.source(source)?.digest}"
        catalogs[key]?.let { return it }
        val result = withContext(Dispatchers.IO) {
            val file = File(store.directory, "catalogs/${sha256(key.toByteArray())}.json")
            val legacy = File(context.filesDir, "source-subscriptions/catalog-${sha256("${store.active}:$source:$category".toByteArray())}.json")
            val input = if (file.exists()) file else legacy
            if (!input.exists() || input.length() > 16 * 1024 * 1024) null else runCatching { Catalog.parse(JSONObject(input.readText())).let { it.copy(items = it.items.filter { row -> row.source == source }.takeLast(5000)) } }.getOrNull()
        }
        if (result != null) catalogs[key] = result
        return result
    }
    suspend fun saveCatalog(source: String, category: String, value: Catalog) {
        val key = "${store.active}:$source:$category::${subscriptions.source(source)?.digest}"
        catalogs[key] = value
        withContext(Dispatchers.IO) {
            val data = obj("page" to value.page, "hasMore" to value.more, "warning" to value.warning, "updatedAt" to java.time.Instant.now().toString(), "items" to JSONArray(value.items.map { it.json })).toString().toByteArray()
            require(data.size <= 16 * 1024 * 1024)
            atomicWrite(File(store.directory, "catalogs/${sha256(key.toByteArray())}.json"), data)
        }
        storageErrors.value = storageErrors.value - source
    }
    suspend fun detail(drama: Drama, refresh: Boolean = false): Detail {
        check(store.allowed(drama.source))
        val epoch = store.epoch
        val key = "$epoch:${store.active}:${source(drama.source)?.digest}:${drama.id}"
        if (!refresh) details[key]?.let { return it }
        val parsed = Detail.parse(runtime.execute(drama.source, "detail", obj("drama" to drama.json)), drama)
        val result = parsed.copy(drama = mergeDramaMetadata(drama, parsed.drama))
        check(epoch == store.epoch && store.allowed(drama.source))
        require(result.drama.id == drama.id && result.drama.source == drama.source) { "返回的剧集信息不匹配" }
        store.refreshDramas(listOf(result.drama), epoch)
        details[key] = result
        while (details.size > 48) details.remove(details.keys.first())
        return result
    }
    suspend fun resolve(drama: Drama, episode: Episode, quality: Int = 0, online: Boolean = false): JSONObject {
        val epoch = store.epoch
        check(store.allowed(drama.source))
        if (!online) {
            val local = NativeBridge.call(obj("action" to "localPlayback", "drama" to drama.json, "index" to episode.number))
            if (local.text("url").isNotBlank()) return local
        }
        val data = resolvedData(drama, episode, quality)
        check(epoch == store.epoch && store.allowed(drama.source))
        var plan: JSONObject? = null
        try {
            withContext(NonCancellable) { plan = NativeBridge.call(obj("action" to "subscriptionPlan", "subscription" to data.copy().put("source", drama.source))) }
            currentCoroutineContext().ensureActive()
            check(epoch == store.epoch && store.allowed(drama.source)) { "播放请求已取消" }
            return requireNotNull(plan)
        } catch (error: Throwable) { release(plan); throw error }
    }
    suspend fun release(plan: JSONObject?) { val session = plan?.text("session").orEmpty(); if (session.isNotEmpty()) withContext(NonCancellable) { NativeBridge.call(obj("action" to "release", "session" to session)) } }
    suspend fun warmPlayback(plan: JSONObject, quality: Int): JSONObject = coroutineScope {
        if (plan.optBoolean("local")) return@coroutineScope plan
        val request = obj("session" to "compose-prefetch:${sequence.incrementAndGet()}", "sequence" to 1)
        val task = async { NativeBridge.call(request.copy().put("action", "subscriptionPrefetch").put("quality", quality).put("subscription", plan)) }
        try { task.await() }
        finally {
            if (!isActive) withContext(NonCancellable) {
                runCatching { NativeBridge.call(request.put("action", "cancelRead")) }
            }
        }
    }
    suspend fun fallback(plan: JSONObject) = NativeBridge.call(obj("action" to "fallback", "session" to plan.text("session"), "sequence" to sequence.incrementAndGet()))
    suspend fun downloads(): List<JSONObject> = NativeBridge.call(obj("action" to "downloads")).array("jobs").objects().filter { store.allowed(it.getJSONObject("drama").text("source")) }
    suspend fun enqueue(detail: Detail, episodes: List<Episode>, quality: Int = 0, update: Boolean = false): Int {
        require(episodes.size in 1..500 && episodes.all { it.number > 0 } && episodes.map { it.number }.distinct().size == episodes.size)
        require(quality in setOf(0, 480, 720, 1080))
        check(store.canDownload && store.allowed(detail.drama.source)) { "当前用户不能下载" }
        check(source(detail.drama.source)?.capabilities?.contains("download") == true && source(detail.drama.source)?.group != "douyin") { "此站源不支持下载" }
        DownloadService.start(context)
        val result = NativeBridge.call(obj("action" to "enqueueDownloads", "force" to update, "drama" to detail.drama.json, "quality" to quality, "entries" to JSONArray(episodes.map { episode ->
            obj("index" to episode.number, "chapter" to obj("id" to episode.id, "title" to episode.title, "currentEpisode" to episode.number, "vip" to episode.json.opt("vip"), "source" to detail.drama.source, "subscriptionInput" to episode.json))
        })))
        return result.getInt("added").also { require(it in 0..episodes.size) { "未能确认添加数量，请重试" } }
    }
    suspend fun controlDownloadBatch(command: String, rows: List<JSONObject>): JSONObject {
        require(rows.size in 1..500 && command in setOf("pause", "resume", "archive", "restore", "remove"))
        check(store.canDownload && rows.all { store.allowed(it.getJSONObject("drama").text("source")) })
        val epoch = store.epoch; val current = downloads().associateBy { it.text("id") }
        require(rows.all { row -> current[row.text("id")]?.let { MediaLibrary.version(it) == MediaLibrary.version(row) } == true }) { "任务已变更，请刷新后重新操作" }
        check(epoch == store.epoch && store.canDownload)
        if (command == "resume") DownloadService.start(context)
        return NativeBridge.call(obj("action" to "controlDownloadBatch", "command" to command, "jobIds" to JSONArray(rows.map { it.text("id") }), "expectedVersions" to JSONObject().apply { rows.forEach { put(it.text("id"), MediaLibrary.version(it)) } }))
    }
    suspend fun controlDownload(command: String, job: JSONObject) {
        check(store.canDownload && store.allowed(job.getJSONObject("drama").text("source")))
        if (command in setOf("resume", "retry")) DownloadService.start(context)
        NativeBridge.call(obj("action" to "controlDownloads", "command" to command, "jobId" to job.getString("id")))
    }
    suspend fun cover(drama: Drama): String {
        check(store.allowed(drama.source))
        if (drama.cover.isEmpty()) return ""
        return NativeBridge.call(obj("action" to "subscriptionCover", "source" to drama.source, "drama" to drama.json)).text("path")
    }
}
