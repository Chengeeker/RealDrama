package com.real.drama.compose

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URI

data class SubscriptionPreview(
    val origin: String, val entries: List<JSONObject>, val direct: SourcePackage? = null,
    val name: String = direct?.name ?: "站源订阅",
)
class Subscriptions(val root: File, private val legacyRoot: File, private val store: LocalStore) {
    val installed = MutableStateFlow<List<SourcePackage>>(emptyList())
    val problems = MutableStateFlow<List<String>>(emptyList())
    private var records = listOf<JSONObject>()
    private val mutex = Mutex()
    val sources get() = installed.value.flatMap { it.sources }
    fun source(id: String) = sources.firstOrNull { it.id == id }
    fun previousVersion(id: String) = records.firstOrNull { it.text("id") == id }?.text("previousVersion").orEmpty()
    fun independentLink(id: String) = records.firstOrNull { it.text("id") == id }?.text("url").orEmpty()
    private fun packageFile(id: String, digest: String): File {
        require(id.matches(Regex("[a-z][a-z0-9-]{0,63}")) && digest.matches(Regex("[a-f0-9]{64}")))
        return File(root, "$id-$digest.json")
    }
    suspend fun open() = withContext(Dispatchers.IO) {
        root.mkdirs()
        val registry = File(root, "registry.json")
        if (!registry.exists() && File(legacyRoot, "registry.json").exists()) {
            val legacy = File(legacyRoot, "registry.json")
            require(legacy.length() <= 512 * 1024)
            val rows = JSONArray(legacy.readText()).objects()
            val valid = rows.map { row ->
                val output = packageFile(row.getString("id"), row.getString("digest"))
                val old = File(legacyRoot, output.name)
                require(old.length() <= 4 * 1024 * 1024)
                val bytes = old.readBytes()
                SourcePackage.parse(bytes, row.getString("origin"), row.getString("digest"), row.getString("id"))
                atomicWrite(output, bytes)
                row.text("previousDigest").takeIf { it.isNotEmpty() }?.let { previous ->
                    val previousOutput = packageFile(row.getString("id"), previous)
                    val previousFile = File(legacyRoot, previousOutput.name)
                    require(previousFile.length() <= 4 * 1024 * 1024)
                    val previousBytes = previousFile.readBytes()
                    SourcePackage.parse(previousBytes, row.getString("origin"), previous, row.getString("id"))
                    atomicWrite(previousOutput, previousBytes)
                }
                row
            }
            atomicWrite(registry, JSONArray(valid).toString().toByteArray())
        }
        if (!registry.exists()) return@withContext
        try { loadRegistry(registry) } catch (error: Exception) {
            val previous = File(root, "registry.previous.json")
            if (previous.exists()) { loadRegistry(previous); problems.value = listOf("已读取上次订阅注册表，请核对版本") }
            else problems.value = listOf("订阅注册表无法读取，原文件保留，请重新导入")
        }
    }
    private fun loadRegistry(file: File) {
        require(file.length() <= 512 * 1024)
        val rows = JSONArray(file.readText()).objects()
        require(rows.size <= 100 && rows.map { it.getString("id") }.distinct().size == rows.size)
        val packages = rows.map { row ->
            val file = packageFile(row.getString("id"), row.getString("digest"))
            require(file.length() <= 4 * 1024 * 1024)
            SourcePackage.parse(file.readBytes(), row.getString("origin"), row.getString("digest"), row.getString("id"))
        }
        val ids = packages.flatMap { it.sources }.map { it.id }
        require(ids.size <= 100 && ids.distinct().size == ids.size)
        records = rows; installed.value = packages
    }
    suspend fun preview(input: String): SubscriptionPreview = withContext(Dispatchers.IO) {
        var uri = URI(input.trim())
        validateUrl(uri)
        if (uri.host == "github.com") {
            val parts = uri.path.trim('/').split('/')
            require(parts.size >= 2 && uri.query == null)
            val owner = parts[0]; val repo = parts[1].removeSuffix(".git")
            uri = if (parts.size >= 5 && parts[2] == "blob") URI("https://raw.githubusercontent.com/$owner/$repo/${parts.drop(3).joinToString("/")}") else {
                require(parts.size == 2) { "请填写仓库根地址或文件链接" }
                val metadata = JSONObject(fetch(URI("https://api.github.com/repos/$owner/$repo")).toString(Charsets.UTF_8))
                URI("https://raw.githubusercontent.com/$owner/$repo/${metadata.getString("default_branch")}/subscription.json")
            }
        }
        val bytes = fetch(uri)
        val data = JSONObject(bytes.toString(Charsets.UTF_8))
        if (data.has("engine")) {
            val packageValue = SourcePackage.parse(bytes, uri.toString())
            return@withContext SubscriptionPreview(uri.toString(), listOf(data.copy().put("url", uri.toString()).put("sha256", packageValue.digest)), packageValue)
        }
        require(data.optInt("schema") == 1 && data.opt("sources") is JSONArray && data.array("sources").length() <= 100) { "仓库缺少兼容的 subscription.json" }
        val entries = data.array("sources").objects().map { row ->
            val address = uri.resolve(row.getString("url"))
            validateUrl(address)
            require(address.host == uri.host && row.text("sha256").matches(Regex("[a-f0-9]{64}")) && row.text("id").matches(Regex("[a-z][a-z0-9-]{0,63}"))) { "目录包含跨域链接或无效校验值" }
            row.copy().put("url", address.toString())
        }
        require(entries.map { it.text("id") }.distinct().size == entries.size)
        SubscriptionPreview(uri.toString(), entries, name = data.text("name", "站源订阅").take(200))
    }
    suspend fun install(preview: SubscriptionPreview, entry: JSONObject) = mutex.withLock {
        store.requireAdmin()
        val epoch = store.epoch
        withContext(Dispatchers.IO) {
            val id = entry.getString("id")
            val old = records.firstOrNull { it.text("id") == id }
            require(old == null || old.text("origin") == preview.origin) { "同名站源来自另一订阅，请先移除再导入" }
            require(old != null || records.size < 100)
            val bytes = preview.direct?.bytes ?: fetch(URI(entry.getString("url")))
            val packageValue = SourcePackage.parse(bytes, preview.origin, entry.getString("sha256"), id)
            require(packageValue.version == entry.text("version")) { "版本与目录不一致" }
            for (field in listOf("domains", "credentialDomains", "capabilities")) if (entry.has(field)) {
                require(entry.array(field).strings().toSet() == packageValue.document.array(field).strings().toSet()) { "权限与目录不一致" }
            }
            val collision = installed.value.filter { it.id != id }.flatMap { it.sources }.any { existing -> packageValue.sources.any { it.id == existing.id } }
            require(!collision) { "子源与已安装包重复，请先移除旧包" }
            require(installed.value.filter { it.id != id }.sumOf { it.sources.size } + packageValue.sources.size <= 100) { "站源总数超过上限" }
            require(epoch == store.epoch && store.admin) { "用户已切换" }
            atomicWrite(packageFile(id, packageValue.digest), bytes)
            val record = obj("id" to id, "digest" to packageValue.digest, "version" to packageValue.version, "origin" to preview.origin, "url" to entry.text("url", preview.origin), "installedAt" to java.time.Instant.now().toString())
            if (old != null && old.text("digest") != packageValue.digest) record.put("previousDigest", old.getString("digest")).put("previousVersion", old.text("version"))
            else if (old != null) { old.opt("previousDigest")?.let { record.put("previousDigest", it) }; old.opt("previousVersion")?.let { record.put("previousVersion", it) } }
            save(records.filter { it.text("id") != id } + record)
            installed.value = installed.value.filter { it.id != id } + packageValue
            store.reconcileSources(sources.map { it.id }.toSet())
        }
    }
    suspend fun importLocal(bytes: ByteArray) {
        val packageValue = withContext(Dispatchers.Default) { SourcePackage.parse(bytes, "local:${sha256(bytes).take(16)}") }
        val existing = records.firstOrNull { it.text("id") == packageValue.id }
        val origin = if (existing?.text("origin")?.startsWith("local:") == true) existing.text("origin") else "local:${packageValue.id}"
        val local = packageValue.copy(origin = origin)
        install(SubscriptionPreview(origin, emptyList(), local), local.document.copy().put("sha256", local.digest).put("url", origin))
    }
    private fun save(next: List<JSONObject>) {
        val registry = File(root, "registry.json")
        if (registry.exists()) atomicWrite(File(root, "registry.previous.json"), registry.readBytes())
        atomicWrite(registry, JSONArray(next).toString().toByteArray()); records = next
    }
    suspend fun remove(id: String) = mutex.withLock {
        store.requireAdmin()
        withContext(Dispatchers.IO) { save(records.filter { it.text("id") != id }); installed.value = installed.value.filter { it.id != id } }
    }
    suspend fun rollback(id: String) = mutex.withLock {
        store.requireAdmin()
        val epoch = store.epoch
        withContext(Dispatchers.IO) {
            val old = records.first { it.text("id") == id }
            val digest = old.text("previousDigest")
            require(digest.isNotEmpty()) { "没有可回退的版本" }
            val packageValue = SourcePackage.parse(packageFile(id, digest).readBytes(), old.getString("origin"), digest, id)
            val remaining = installed.value.filter { it.id != id }.flatMap { it.sources }
            require(remaining.size + packageValue.sources.size <= 100 && remaining.none { existing -> packageValue.sources.any { it.id == existing.id } }) { "回退版本的子源与已安装包冲突，当前版本已保留" }
            require(epoch == store.epoch && store.admin) { "用户已切换" }
            val next = old.copy().put("digest", digest).put("version", packageValue.version).put("previousDigest", old.getString("digest")).put("previousVersion", old.getString("version"))
            save(records.map { if (it.text("id") == id) next else it })
            installed.value = installed.value.map { if (it.id == id) packageValue else it }
            store.reconcileSources(sources.map { it.id }.toSet())
        }
    }
    suspend fun checkUpdates(id: String? = null): List<Pair<SubscriptionPreview, JSONObject>> {
        store.requireAdmin()
        val epoch = store.epoch
        val result = mutableListOf<Pair<SubscriptionPreview, JSONObject>>()
        val errors = mutableListOf<String>()
        for (origin in records.filter { id == null || it.text("id") == id }.map { it.text("origin") }.distinct().filter { it.startsWith("https://") }) {
            try {
                val preview = preview(origin)
                check(store.epoch == epoch && store.admin) { "用户已切换" }
                if (id != null) require(preview.entries.any { it.text("id") == id }) { "上游已移除此站源，本地版本仍保留" }
                preview.entries.forEach { entry ->
                    if ((id == null || entry.text("id") == id) && records.any { it.text("id") == entry.text("id") && it.text("origin") == origin && it.text("digest") != entry.text("sha256") }) result.add(preview to entry)
                }
            } catch (cancel: kotlinx.coroutines.CancellationException) { throw cancel } catch (error: Exception) { errors.add(error.message ?: "订阅检查失败") }
        }
        problems.value = errors
        return result
    }
    suspend fun updateAll(): Int {
        val epoch = store.epoch
        val updates = checkUpdates()
        val failures = problems.value.toMutableList()
        var count = 0
        for ((preview, entry) in updates) {
            check(store.epoch == epoch && store.admin) { "用户已切换" }
            try { install(preview, entry); count++ }
            catch (cancel: kotlinx.coroutines.CancellationException) { throw cancel }
            catch (error: Exception) { failures.add("${entry.text("name")}：${error.message ?: "更新失败，原版本保留"}") }
        }
        problems.value = failures
        return count
    }
    companion object {
        const val official = "https://github.com/Chengeeker/RealDrama-Subscription"
        fun validateUrl(uri: URI) { require(uri.scheme == "https" && !uri.host.isNullOrEmpty() && uri.userInfo == null && uri.port in listOf(-1, 443) && uri.fragment == null) { "仅支持无凭据的 HTTPS 地址" } }
        fun privateAddress(address: InetAddress): Boolean {
            val b = address.address.map { it.toInt() and 255 }
            return address.isAnyLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress || address.isSiteLocalAddress || address.isMulticastAddress ||
                b.size == 4 && (b[0] == 0 || b[0] >= 224 || b[0] == 100 && b[1] in 64..127) || b.size == 16 && b[0] and 254 == 252
        }
        fun fetch(uri: URI): ByteArray {
            validateUrl(uri)
            require(InetAddress.getAllByName(uri.host).none(::privateAddress)) { "订阅不支持本机或内网地址" }
            val connection = uri.toURL().openConnection() as HttpURLConnection
            try {
                connection.instanceFollowRedirects = false; connection.connectTimeout = 8000; connection.readTimeout = 12000
                connection.setRequestProperty("User-Agent", "RealDrama-Subscription/1")
                connection.setRequestProperty("Accept", "application/json")
                require(connection.responseCode == 200) { "订阅请求失败（HTTP ${connection.responseCode}）" }
                return connection.inputStream.use { it.readLimited(4 * 1024 * 1024) }
            } finally { connection.disconnect() }
        }
    }
}
