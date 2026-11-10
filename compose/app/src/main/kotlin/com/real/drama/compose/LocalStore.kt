package com.real.drama.compose

import android.content.Context
import android.util.AtomicFile
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeParseException
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

fun atomicWrite(file: File, bytes: ByteArray) {
    file.parentFile?.mkdirs()
    val atomic = AtomicFile(file)
    val output = atomic.startWrite()
    try { output.write(bytes); atomic.finishWrite(output) }
    catch (error: Throwable) { atomic.failWrite(output); throw error }
}
fun randomToken() = ByteArray(16).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
fun pinHash(pin: String, salt: String): String = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
    .generateSecret(PBEKeySpec(pin.toCharArray(), salt.toByteArray(), 120000, 256)).encoded.joinToString("") { "%02x".format(it) }

class LocalStore(private val context: Context) {
    val directory = File(context.filesDir, "compose-data")
    private val file = File(directory, "snapshot.json")
    private val lock = Mutex()
    private val snapshotState = mutableStateOf(JSONObject())
    private val lockedState = MutableStateFlow(true)
    private data class WatchIndex(
        val history: String,
        val hiddenSources: String,
        val rows: List<JSONObject>,
        val byId: Map<String, JSONObject>,
    )
    @Volatile private var watchIndex: WatchIndex? = null
    val locked = lockedState.asStateFlow()
    var epoch by mutableLongStateOf(0L); private set
    var readError: String? = null; private set
    private var failures = 0
    private var retryAt = 0L
    val values get() = snapshotState.value
    val active get() = values.text("activeProfile", "default")
    val profiles get() = JSONArray(values.text("profiles", "[]")).objects()
    val profile get() = profiles.firstOrNull { it.text("id") == active } ?: JSONObject()
    val admin get() = !locked.value && profile.optBoolean("admin")
    val forceLogin get() = values.optBoolean("forceLogin", profiles.firstOrNull { it.optBoolean("admin") }?.text("pinHash")?.isNotEmpty() == true)
    val canDownload get() = !locked.value && (admin || profile.optBoolean("download", true))
    fun key(name: String, id: String = active) = if (id == "default") name else "profile.$id.$name"
    fun text(name: String, default: String = "", global: Boolean = false) = values.text(if (global) name else key(name), default)
    fun bool(name: String, default: Boolean = false, global: Boolean = false) = values.optBoolean(if (global) name else key(name), default)
    fun json(name: String, global: Boolean = false) = JSONObject(text(name, "{}", global))
    fun list(name: String) = JSONArray(text(name, "[]"))
    fun allowed(source: String): Boolean = !locked.value && source !in list("hiddenSources").strings()
    fun requireAdmin() { check(admin) { "需要管理员解锁后操作" } }

    suspend fun open() = withContext(Dispatchers.IO) {
        readError = null
        try {
            directory.mkdirs()
            val snapshot = if (file.exists()) {
                require(file.length() <= 16 * 1024 * 1024) { "本地资料过大" }
                JSONObject(file.readText()).also { require(it.optInt("version") == 1) }.getJSONObject("values")
            } else {
                val preferences = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                val raw = preferences.getString("flutter.localSnapshot.v1", null)
                val old = if (raw != null) JSONObject(raw).also { require(it.optInt("version") == 1) }.getJSONObject("values") else JSONObject().apply {
                    preferences.all.forEach { (name, value) ->
                        val stripped = name.removePrefix("flutter.")
                        if (stripped in globalKeys || stripped in libraryKeys || stripped.matches(Regex("profile\\.[a-zA-Z0-9_-]{1,64}\\..+"))) put(stripped, value)
                    }
                }
                if (!old.has("profiles")) {
                    require(!old.has("activeProfile") && old.keys().asSequence().none { it.startsWith("profile.") }) { "原用户资料缺失" }
                    old.put("profiles", JSONArray().put(obj("id" to "default", "name" to "管理员", "admin" to true, "download" to true, "sources" to JSONArray(), "salt" to "", "pinHash" to "")).toString())
                }
                normalizeLegacyWatchTimes(old)
                validate(old)
                if (raw != null) atomicWrite(File(directory, "flutter-snapshot.original.json"), raw.toByteArray())
                persist(old)
                old
            }
            validate(snapshot)
            snapshotState.value = snapshot
            lockedState.value = forceLogin && profile.text("pinHash").isNotBlank()
        } catch (error: Exception) {
            readError = "本地资料无法读取，原文件已保留：${error.message}"
            lockedState.value = true
        }
    }
    private fun persist(next: JSONObject) = atomicWrite(file, obj("version" to 1, "values" to next).toString().toByteArray())
    suspend fun update(change: (JSONObject) -> Unit) = lock.withLock {
        withContext(Dispatchers.IO) {
            check(readError == null) { "请先恢复损坏的本地资料" }
            val next = values.copy()
            change(next)
            if (canonical(next) == canonical(values)) return@withContext
            validate(next)
            persist(next)
            snapshotState.value = next
        }
    }
    suspend fun set(name: String, value: Any?, global: Boolean = false) {
        val expectedEpoch = epoch
        check(!locked.value)
        val protected = global && name !in setOf("displayMode", "themeMode", "dynamicColor", "themeSeed", "fontWeightAdjustment", "navigationStyle", "hapticFeedback", "startupDestination")
        if (protected) requireAdmin()
        val target = if (global) name else key(name)
        update { check(epoch == expectedEpoch && !locked.value && (!protected || admin)) { "当前用户已变更" }; it.put(target, if (value is JSONObject || value is JSONArray) value.toString() else value) }
    }
    suspend fun unlock(id: String, pin: String): Boolean = withContext(Dispatchers.Default) {
        check(System.currentTimeMillis() >= retryAt) { "尝试次数过多，请稍后再试" }
        val target = profiles.firstOrNull { it.text("id") == id } ?: return@withContext false
        val correct = target.text("pinHash").isEmpty() || MessageDigest.isEqual(pinHash(pin, target.text("salt")).toByteArray(), target.text("pinHash").toByteArray())
        if (!correct) { failures++; if (failures >= 3) retryAt = System.currentTimeMillis() + minOf(failures * 2, 30) * 1000; return@withContext false }
        update { it.put("activeProfile", id) }
        failures = 0; epoch++; lockedState.value = false; true
    }
    fun lock() { if (profile.text("pinHash").isNotEmpty()) { lockedState.value = true; epoch++ } }
    suspend fun saveProfile(id: String?, name: String, pin: String?, sources: List<String>, download: Boolean) {
        requireAdmin()
        require(name.trim().length in 1..40)
        val actual = id ?: randomToken()
        val old = profiles.firstOrNull { it.text("id") == actual }
        require(pin.isNullOrEmpty() || pin.length in 6..128) { "密码需要 6 至 128 个字符" }
        require(actual == "default" || profiles.first { it.optBoolean("admin") }.text("pinHash").isNotEmpty()) { "请先为管理员设置密码，再创建或修改其他用户" }
        require(pin != "" || actual != "default" || profiles.size == 1) { "存在其他用户时不能取消管理员密码" }
        val salt = if (pin == null) old?.text("salt").orEmpty() else if (pin.isEmpty()) "" else randomToken()
        val hash = if (pin == null) old?.text("pinHash").orEmpty() else if (pin.isEmpty()) "" else withContext(Dispatchers.Default) { pinHash(pin, salt) }
        val next = obj("id" to actual, "name" to name.trim(), "admin" to (actual == "default"), "sources" to JSONArray(sources), "download" to download, "salt" to salt, "pinHash" to hash)
        update { requireAdmin(); it.put("profiles", JSONArray((profiles.filter { p -> p.text("id") != actual } + next).sortedWith(compareByDescending<JSONObject> { p -> p.optBoolean("admin") }.thenBy { p -> p.text("name") })).toString()) }
    }
    suspend fun removeProfile(id: String) {
        requireAdmin(); require(id != "default")
        update { next ->
            next.put("profiles", JSONArray(profiles.filter { it.text("id") != id }).toString())
            next.keys().asSequence().filter { it.startsWith("profile.$id.") }.toList().forEach(next::remove)
        }
    }
    fun favorites() = list("favorites").objects().map(::Drama).filter { allowed(it.source) }
    fun history(): List<JSONObject> = if (locked.value) emptyList() else currentWatchIndex().rows
    fun watch(drama: Drama): JSONObject? = if (locked.value) null else currentWatchIndex().byId[drama.id]

    private fun currentWatchIndex(): WatchIndex {
        val snapshot = values
        val profileId = snapshot.text("activeProfile", "default")
        val history = snapshot.text(key("history", profileId), "[]")
        val hiddenSources = snapshot.text(key("hiddenSources", profileId), "[]")
        watchIndex?.let { if (it.history == history && it.hiddenSources == hiddenSources) return it }
        val hidden = JSONArray(hiddenSources).strings().toHashSet()
        val byId = linkedMapOf<String, JSONObject>()
        val rows = JSONArray(history).objects().filter { row ->
            val drama = row.getJSONObject("drama")
            if (drama.text("source") in hidden) false
            else {
                byId.putIfAbsent(drama.text("id"), row)
                true
            }
        }
        return WatchIndex(history, hiddenSources, rows, byId).also { watchIndex = it }
    }
    suspend fun favorite(drama: Drama) {
        val expectedEpoch = epoch
        check(allowed(drama.source))
        update { next ->
            check(epoch == expectedEpoch && allowed(drama.source))
            val rows = list("favorites").objects(); val exists = rows.any { it.text("id") == drama.id }
            require(exists || rows.size < 20000)
            val states = json("followStates")
            if (exists) states.remove(drama.id) else {
                val watch = watch(drama)
                states.put(drama.id, observedFollow(null, drama, watch?.optInt("episode") ?: 0, watch?.optDouble("position") ?: 0.0, watch?.optDouble("duration") ?: 0.0))
            }
            next.put(key("favorites"), JSONArray(if (exists) rows.filter { it.text("id") != drama.id } else rows + drama.json).toString()).put(key("followStates"), states.toString())
        }
    }
    suspend fun progress(drama: Drama, episode: Int, position: Double, duration: Double, expectedEpoch: Long) {
        if (epoch != expectedEpoch || !allowed(drama.source) || !position.isFinite() || !duration.isFinite()) return
        val row = obj("drama" to drama.json, "episode" to episode, "position" to position.coerceAtLeast(0.0), "duration" to duration.coerceAtLeast(0.0), "updatedAt" to Instant.now().toString())
        val target = key("history")
        update { next ->
            if (epoch != expectedEpoch) return@update
            val rows = JSONArray(next.text(target, "[]")).objects().filter { it.getJSONObject("drama").text("id") != drama.id }
            next.put(target, JSONArray((listOf(row) + rows).take(300)).toString())
            val states = json("followStates")
            if (states.has(drama.id)) { states.put(drama.id, observedFollow(states.getJSONObject(drama.id), drama, episode, position, duration)); next.put(key("followStates"), states.toString()) }
        }
    }
    suspend fun followCreator(drama: Drama) {
        check(allowed(drama.source)); require(drama.creatorId.isNotEmpty())
        val rows = list("followedCreators").objects()
        val id = "${drama.source}:${android.net.Uri.encode(drama.creatorId)}"
        val matches: (JSONObject) -> Boolean = { it.text("id") == id || it.text("source") == drama.source && it.text("creatorSecUid").ifEmpty { it.text("creatorId") } == drama.creatorId }
        val exists = rows.any(matches)
        set("followedCreators", JSONArray(if (exists) rows.filterNot(matches)
        else rows + obj("id" to id, "source" to drama.source, "creatorId" to drama.json.text("creatorId"), "creatorSecUid" to drama.json.text("creatorSecUid"), "name" to drama.creator, "avatar" to drama.json.text("creatorAvatar"), "anchor" to drama.json, "followedAt" to Instant.now().toString())))
    }
    suspend fun mediaProgress(id: String, drama: Drama, episode: Int, position: Double, duration: Double, expectedEpoch: Long) {
        if (epoch != expectedEpoch || !canDownload || !allowed(drama.source) || !position.isFinite() || !duration.isFinite()) return
        update { next ->
            if (epoch != expectedEpoch || !canDownload) return@update
            val rows = json("mediaHistory"); rows.remove(id)
            rows.put(id, obj("drama" to drama.json, "episode" to episode, "position" to position.coerceAtLeast(0.0), "duration" to duration.coerceAtLeast(0.0), "updatedAt" to Instant.now().toString()))
            while (rows.length() > 300) rows.remove(rows.keys().next())
            next.put(key("mediaHistory"), rows.toString())
        }
    }
    suspend fun enableSource(id: String, enabled: Boolean) = enableSources(setOf(id), enabled)
    suspend fun enableSources(ids: Set<String>, enabled: Boolean, family: String? = null) {
        val expected = epoch
        update { next ->
            check(!locked.value && epoch == expected) { "当前用户不能调整此站源" }
            val hidden = JSONArray(next.text(key("hiddenSources"), "[]")).strings().toMutableSet()
            val selections = JSONObject(next.text(key("sourceFamilySelections"), "{}"))
            val saved = family?.let { selections.array(it).strings().toSet().intersect(ids) }.orEmpty()
            if (!enabled && family != null) ids.filterNot { it in hidden }.takeIf { it.isNotEmpty() }?.let { selections.put(family, JSONArray(it)) }
            ids.forEach { if (enabled && (saved.isEmpty() || it in saved)) hidden.remove(it) else hidden.add(it) }
            next.put(key("hiddenSources"), JSONArray(hidden.sorted()).toString())
            if (family != null) next.put(key("sourceFamilySelections"), selections.toString())
            if (next.text(key("source")) in hidden) { next.put(key("source"), ""); next.put(key("catalogView"), JSONObject(next.text(key("catalogView"), "{}")).put("allSources", false).toString()) }
        }
        epoch++
    }
    suspend fun exposureHistory(): List<Drama> = withContext(Dispatchers.IO) {
        if (locked.value) return@withContext emptyList()
        val owner = active
        runCatching {
            val saved = File(directory, "feed-exposure-$owner.json")
            val raw = if (saved.exists()) { require(saved.length() <= 512 * 1024); saved.readText() } else context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getString("flutter.feedExposureHistory.$owner", "[]")!!
            JSONArray(raw).objects().map(::Drama).filter { it.id.isNotEmpty() }.takeLast(30)
        }.getOrDefault(emptyList())
    }
    suspend fun saveExposures(rows: List<Drama>, expectedEpoch: Long = epoch) = lock.withLock { withContext(Dispatchers.IO) {
        check(epoch == expectedEpoch && !locked.value)
        val owner = active
        val data = JSONArray(rows.takeLast(30).map { drama -> obj("id" to drama.id, "source" to drama.source, "title" to drama.title, "category" to drama.json.text("category"), "tags" to JSONArray(drama.json.array("tags").strings().take(24))) }).toString().toByteArray()
        atomicWrite(File(directory, "feed-exposure-$owner.json"), data)
    } }
    suspend fun reconcileSources(ids: Set<String>) = update { next ->
        for (profile in profiles) {
            val id = profile.text("id"); val hiddenKey = key("hiddenSources", id); val knownKey = key("knownSources", id)
            val known = JSONArray(next.text(knownKey, "[]")).strings().toSet()
            val preferred = next.text(key("source", id))
            val defaults = ids.filterNot { it == "hongguo" || it == preferred }.toSet()
            val hidden = if (next.has(hiddenKey)) JSONArray(next.getString(hiddenKey)).strings().toMutableSet() else defaults.toMutableSet()
            hidden.addAll((ids - known).filter { it != "hongguo" && it != preferred })
            next.put(hiddenKey, JSONArray(hidden.toList()).toString()).put(knownKey, JSONArray((known + ids).sorted()).toString())
        }
    }
    fun exportBackup(): ByteArray {
        requireAdmin()
        val backup = obj("schema" to 1, "app" to "zhenguojian", "profiles" to JSONArray(profiles))
        globalKeys.filterNot { it in setOf("profiles", "activeProfile", "sourceGateSalt", "sourceGateHash") }.forEach { name ->
            if (values.has(name)) backup.put(name, values.get(name))
        }
        values.text("fontWeightAdjustment").toIntOrNull()?.let { backup.put("fontWeightAdjustment", it) }
        val libraries = JSONObject()
        for (p in profiles) {
            val library = JSONObject()
            for (name in libraryKeys - setOf("lanSettings", "lanReceipts", "lanRecords")) {
                val value = values.opt(key(name, p.text("id"))) ?: continue
                library.put(name, if (value is String && (value.startsWith('[') || value.startsWith('{'))) org.json.JSONTokener(value).nextValue() else value)
            }
            listOf("history", "favorites", "followedCreators").forEach { if (!library.has(it)) library.put(it, JSONArray()) }
            if (!library.has("hideVip")) library.put("hideVip", true)
            if (!library.has("source")) library.put("source", "")
            val recordValue = values.text(key("lanRecords", p.text("id")))
            val document = if (recordValue.isEmpty()) LanRecords.fresh() else LanRecords(JSONObject(recordValue))
            document.reconcile(library.getJSONArray("favorites"), library.getJSONArray("history"), library.optJSONObject("followStates") ?: JSONObject())
            library.put("followSync", JSONArray(document.records.values.toList()))
            libraries.put(p.text("id"), library)
        }
        backup.put("libraries", libraries)
        val bytes = canonical(backup).toByteArray()
        require(bytes.size <= 8 * 1024 * 1024) { "备份超过 8 MiB 保存上限，请先整理记录；尚未写出备份文件" }
        return bytes
    }
    suspend fun importBackup(bytes: ByteArray) {
        requireAdmin()
        val next = decodeBackup(bytes)
        atomicWrite(File(directory, "before-restore.json"), obj("version" to 1, "values" to values).toString().toByteArray())
        update { current -> current.keys().asSequence().toList().forEach(current::remove); next.keys().forEach { current.put(it, next.get(it)) } }
        epoch++; lockedState.value = profile.text("pinHash").isNotEmpty()
    }
    suspend fun clearHistory(id: String? = null) {
        val expected = epoch; val historyKey = key("history"); val recordsKey = key("lanRecords")
        update { next ->
            check(epoch == expected && !locked.value)
            val history = JSONArray(next.text(historyKey, "[]"))
            val document = if (next.has(recordsKey)) LanRecords(JSONObject(next.getString(recordsKey))) else LanRecords.fresh()
            document.reconcile(JSONArray(next.text(key("favorites"), "[]")), history, JSONObject(next.text(key("followStates"), "{}")))
            document.clearProgress(if (id == null) document.records.keys else setOf(id))
            next.put(historyKey, JSONArray(history.objects().filterNot { id == null || it.getJSONObject("drama").text("id") == id }).toString())
            next.put(recordsKey, canonical(document.json()))
        }
    }
    suspend fun rawConfiguration(): ByteArray = withContext(Dispatchers.IO) {
        if (file.exists()) { require(file.length() <= 32 * 1024 * 1024); file.readBytes() }
        else context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getString("flutter.localSnapshot.v1", "{}")!!.toByteArray()
    }
    suspend fun recoverBackup(bytes: ByteArray, pin: String) = lock.withLock {
        check(readError != null) { "当前配置可以读取，请通过备份设置恢复" }
        val next = decodeBackup(bytes); val administrator = JSONArray(next.getString("profiles")).objects().single { it.optBoolean("admin") }
        val hash = administrator.text("pinHash")
        check(hash.isEmpty() || withContext(Dispatchers.Default) { MessageDigest.isEqual(pinHash(pin, administrator.text("salt")).toByteArray(), hash.toByteArray()) }) { "备份中的管理员密码不正确" }
        withContext(Dispatchers.IO) {
            atomicWrite(File(directory, "before-recovery-${System.currentTimeMillis()}.json"), rawConfiguration())
            persist(next); snapshotState.value = next; readError = null; epoch++; lockedState.value = hash.isNotEmpty()
        }
    }
    companion object {
        val libraryKeys = setOf("history", "favorites", "followStates", "followedCreators", "seriesCandidates", "mediaHistory", "source", "hiddenSources", "knownSources", "sourceFamilySelections", "hideVip", "playback", "downloadPreferences", "catalogView", "recentSearches", "feedNotInterested", "unavailableFeedDramas", "homeFeedPreferences", "feedRecommendation", "lanRecords", "lanSettings", "lanReceipts")
        val globalKeys = setOf("profiles", "activeProfile", "displayMode", "themeMode", "dynamicColor", "themeSeed", "fontWeightAdjustment", "navigationStyle", "hapticFeedback", "startupDestination", "autoExport", "exportPosters", "sourceGateEnabled", "sourceGateOff", "sourceGateSalt", "sourceGateHash", "forceLogin")
        fun validate(values: JSONObject) {
            val booleanKeys = setOf("hideVip", "autoExport", "exportPosters", "sourceGateEnabled", "sourceGateOff", "forceLogin", "dynamicColor", "hapticFeedback")
            values.keys().forEach { key ->
                val name = key.substringAfterLast('.')
                require(key in globalKeys || key in libraryKeys || key.matches(Regex("profile\\.[a-zA-Z0-9_-]{1,64}\\..+")) && name in libraryKeys) { "本地配置字段无效" }
                require(if (name in booleanKeys) values.opt(key) is Boolean else values.opt(key) is String) { "本地配置字段类型无效：$name" }
                if (name in setOf("history", "favorites", "followedCreators", "seriesCandidates", "recentSearches", "hiddenSources", "knownSources", "feedNotInterested", "lanReceipts")) {
                    val rows = JSONArray(values.getString(key))
                    val maximum = when (name) { "history" -> 300; "favorites" -> 20000; "followedCreators" -> 5000; "seriesCandidates" -> 2000; "recentSearches" -> 20; "lanReceipts" -> 64; else -> 25000 }
                    require(rows.length() <= maximum) { "本地记录超过上限：$name" }
                    if (name in setOf("history", "favorites", "followedCreators", "seriesCandidates", "lanReceipts")) require(rows.objects().size == rows.length()) else require(rows.strings().size == rows.length())
                    if (name == "history") rows.objects().forEach { row -> validateWatch(row) }
                    if (name in setOf("favorites", "seriesCandidates")) rows.objects().forEach { require(it.text("id").isNotBlank() && it.text("source").isNotBlank() && it.text("title").isNotBlank()) }
                }
                if (name in setOf("followStates", "mediaHistory", "sourceFamilySelections", "playback", "downloadPreferences", "catalogView", "homeFeedPreferences", "feedRecommendation", "unavailableFeedDramas", "lanRecords", "lanSettings")) {
                    val data = JSONObject(values.getString(key))
                    if (name == "mediaHistory") { require(data.length() <= 300); data.keys().forEach { validateWatch(data.getJSONObject(it)) } }
                    if (name == "playback") require(data.optDouble("speed", 1.0) in listOf(.5, .75, 1.0, 1.25, 1.5, 2.0, 3.0) && data.optInt("quality") in 0..4320 && data.optInt("homeQuality") in 0..4320)
                    if (name == "followStates") data.keys().forEach { id ->
                        val state = data.getJSONObject(id); val known = state.optInt("knownEpisodes")
                        require(state.text("status") in followLabels && known in 0..1000000 && (state.isNull("readEpisodes") || state.optInt("readEpisodes") in 0..known) && (!state.optBoolean("manuallyWatched") || state.text("status") == "watched"))
                    }
                }
            }
            val profiles = JSONArray(values.getString("profiles")).objects()
            require(profiles.size == JSONArray(values.getString("profiles")).length())
            require(profiles.size in 1..20 && profiles.map { it.getString("id") }.distinct().size == profiles.size && profiles.count { it.optBoolean("admin") } == 1) { "用户配置无效" }
            profiles.forEach {
                require(it.text("id").matches(Regex("[a-zA-Z0-9_-]{1,64}")) && it.text("name").length in 1..40 && it.optBoolean("admin") == (it.text("id") == "default"))
                require(it.opt("admin") is Boolean && it.opt("sources") is JSONArray)
                require(it.array("sources").strings().size == it.array("sources").length() && (!it.has("download") || it.opt("download") is Boolean))
                val salt = it.text("salt"); val hash = it.text("pinHash")
                require(salt.isEmpty() && hash.isEmpty() || salt.matches(Regex("[a-f0-9]{32}")) && hash.matches(Regex("[a-f0-9]{64}"))) { "PIN 配置无效" }
            }
            require(profiles.size == 1 || profiles.first { it.optBoolean("admin") }.text("pinHash").isNotEmpty())
            require(values.text("activeProfile", "default") in profiles.map { it.text("id") })
            require(values.toString().toByteArray().size <= 16 * 1024 * 1024)
        }
        private fun validateWatch(row: JSONObject) {
            require(row.opt("drama") is JSONObject && row.getJSONObject("drama").text("id").isNotBlank() && integral(row.opt("episode")) && row.optInt("episode") in 1..1000000)
            require(row.opt("position") is Number && row.opt("duration") is Number && row.optDouble("position") in 0.0..604800.0 && row.optDouble("duration") in 0.0..604800.0)
            Instant.parse(row.getString("updatedAt"))
        }
        private fun normalizeLegacyWatchTimes(values: JSONObject) {
            val zone = ZoneId.systemDefault()
            fun convert(row: JSONObject): Boolean {
                val time = row.opt("updatedAt") as? String ?: return false
                if (time.endsWith('Z')) return false
                val local = try { LocalDateTime.parse(time) } catch (_: DateTimeParseException) { return false }
                row.put("updatedAt", local.atZone(zone).toInstant().toString())
                return true
            }
            for (key in values.keys()) {
                val raw = values.opt(key) as? String ?: continue
                when (key.substringAfterLast('.')) {
                    "history" -> {
                        val rows = JSONArray(raw)
                        var changed = false
                        for (row in rows.objects()) if (convert(row)) changed = true
                        if (changed) values.put(key, rows.toString())
                    }
                    "mediaHistory" -> {
                        val rows = JSONObject(raw)
                        var changed = false
                        for (id in rows.keys()) if (convert(rows.getJSONObject(id))) changed = true
                        if (changed) values.put(key, rows.toString())
                    }
                }
            }
        }
        fun decodeBackup(bytes: ByteArray): JSONObject {
            require(bytes.size <= 8 * 1024 * 1024) { "备份超过 8 MiB" }
            val data = JSONObject(bytes.toString(Charsets.UTF_8))
            require(data.optInt("schema") == 1 && data.text("app") == "zhenguojian") { "备份格式不兼容" }
            val next = obj("profiles" to data.getJSONArray("profiles").toString(), "activeProfile" to "default")
            globalKeys.filterNot { it in setOf("profiles", "activeProfile", "sourceGateSalt", "sourceGateHash") }.forEach { if (data.has(it)) next.put(it, data.get(it)) }
            if (data.has("fontWeightAdjustment")) {
                val weight = data.optInt("fontWeightAdjustment")
                require(integral(data.opt("fontWeightAdjustment")) && weight in -300..300 && weight % 100 == 0)
                next.put("fontWeightAdjustment", weight.toString())
            }
            data.getJSONArray("profiles").objects().forEach { p ->
                val id = p.getString("id")
                val library = data.getJSONObject("libraries").getJSONObject(id)
                require(library.array("history").length() <= 300 && library.array("favorites").length() <= 20000 && library.array("followedCreators").length() <= 5000)
                (libraryKeys - setOf("lanSettings", "lanRecords", "lanReceipts")).forEach { name ->
                    if (library.has(name)) { val value = library.get(name); next.put(if (id == "default") name else "profile.$id.$name", if (value is JSONArray || value is JSONObject) value.toString() else value) }
                }
                if (library.has("followSync")) {
                    val doc = LanRecords(obj("schema" to 1, "replica" to randomToken(), "counter" to 0, "records" to library.getJSONArray("followSync")))
                    val favorites = library.getJSONArray("favorites").objects().map { it.text("id") }.toSet()
                    require(doc.records.values.filter { row -> row.getJSONArray("member").objects().all { it.getBoolean("value") } }.map { it.getJSONObject("drama").text("id") }.toSet() == favorites) { "备份同步记录与追剧列表不一致" }
                    next.put(if (id == "default") "lanRecords" else "profile.$id.lanRecords", canonical(doc.json()))
                }
            }
            normalizeLegacyWatchTimes(next)
            validate(next)
            return next
        }
    }
}
