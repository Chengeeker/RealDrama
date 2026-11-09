package com.real.drama.compose

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject

data class LanConnection(val peer: JSONObject, val address: String, val token: String, val account: String, val user: String, val sources: Set<String>, var automatic: Boolean)
data class LanPreview(
    val connection: LanConnection, val epoch: Long, val sources: Set<String>, val base: String, val remoteBase: String,
    val result: Map<String, JSONObject>, val remoteChanges: List<JSONObject>, val localChanges: List<JSONObject>,
    val localCount: LanChangeCount, val remoteCount: LanChangeCount, val skipped: Int,
    val operation: String = randomToken(), val created: Long = System.currentTimeMillis(),
)

data class LanChangeCount(val added: Int, val updated: Int, val removed: Int, val conflicts: Int) {
    val label get() = "新增 $added · 更新 $updated · 移除 $removed · 冲突 $conflicts"
    companion object {
        fun between(previous: Map<String, JSONObject>, next: Map<String, JSONObject>): LanChangeCount {
            fun followed(row: JSONObject?) = row?.array("member")?.objects()?.all { it.optBoolean("value") } == true
            var added = 0; var updated = 0; var removed = 0; var conflicts = 0
            for ((id, row) in next) {
                val before = previous[id]
                val wasFollowed = followed(before)
                val isFollowed = followed(row)
                when {
                    isFollowed && !wasFollowed -> added++
                    !isFollowed && wasFollowed -> removed++
                    isFollowed && before != null && lanHash(before) != lanHash(row) -> updated++
                }
                conflicts += listOf("member", "status", "progress").count { row.array(it).length() > 1 }
            }
            return LanChangeCount(added, updated, removed, conflicts)
        }
    }
}
private data class IncomingSync(val operation: String, val base: String, val hash: String, val sources: Set<String>, val count: Int, val automatic: Boolean, val remote: LanConnection, val rows: LinkedHashMap<String, JSONObject> = linkedMapOf(), var bytes: Int = 0, val created: Long = System.currentTimeMillis())

class LanController(val repo: Repository) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val revision = MutableStateFlow(0L)
    val store get() = repo.store
    val settings get() = store.json("lanSettings")
    val enabled get() = !store.locked.value && settings.optBoolean("enabled")
    val automatic get() = settings.optBoolean("autoSync", true)
    val name get() = settings.text("name", "Android 手机")
    var local: JSONObject? = null; private set
    var connection: LanConnection? = null; private set
    val peers = linkedMapOf<String, JSONObject>()
    var message = "设备互联已关闭"; private set
    var syncMessage = "尚未同步"; private set
    var lastSync: Long? = null; private set
    var error: String? = null; private set
    var syncing = false; private set
    var manual = false
    private var generation = ""
    private var epoch = -1L
    private var foreground = false
    private var configuration = ""
    private var poll: Job? = null
    private var timer: Job? = null
    private var syncJob: Job? = null
    private val lifecycle = Mutex()
    private val writes = Mutex()
    private var incoming: IncomingSync? = null
    private val requests = mutableSetOf<String>()
    private val nsd = repo.context.getSystemService(NsdManager::class.java)
    private var discovery: NsdManager.DiscoveryListener? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var multicast: WifiManager.MulticastLock? = null
    private val resolving = Mutex()
    var playback: LanPlaybackHost? = null
    var receivePlayback: (suspend (LanPreparedPlayback) -> Unit)? = null
    internal var prepared: LanPreparedPlayback? = null
    internal val playReceipts = linkedMapOf<String, JSONObject>()
    fun notifyChange() { revision.value++ }
    suspend fun native(command: String, value: JSONObject = JSONObject()): JSONObject = NativeBridge.call(obj("action" to "lan", "command" to command, "lan" to value.put("generation", generation)))
    private fun config() = obj("name" to name, "kind" to if (repo.context.packageManager.hasSystemFeature("android.software.leanback")) "tv" else "phone", "account" to store.lanDocument().replica, "user" to store.profile.text("name"), "sources" to JSONArray(repo.available().map { it.id }), "autoSync" to automatic)
    private fun peerConfig() = config().apply {
        put("sourceOptions", getJSONArray("sources"))
        put("sources", JSONArray(repo.available().map { it.id }.filter { it in setOf("hongguo", "huangdou", "huangguo-video", "huangguoai", "cloudfront") }))
    }
    suspend fun setting(name: String, value: Any) { store.set("lanSettings", settings.put(name, value)); reconcile(foreground) }
    suspend fun reconcile(visible: Boolean) = lifecycle.withLock {
        foreground = visible
        val key = "${store.epoch}:$visible:$enabled:${if (!store.locked.value) canonical(config()) else ""}"
        if (key == configuration) return@withLock
        configuration = key
        stop()
        if (!visible || !enabled) return@withLock
        store.ensureLanRecords()
        epoch = store.epoch
        local = NativeBridge.call(obj("action" to "lan", "command" to "start", "lan" to obj("config" to config())))
        generation = local!!.getString("generation")
        message = "正在发现设备"; error = null
        val current = generation
        poll = scope.launch {
            while (isActive && generation == current) {
                try { native("poll").optJSONObject("event")?.let { event -> scope.launch { event(event, current) } } }
                catch (cancel: CancellationException) { throw cancel }
                catch (failure: Exception) { error = failure.message; notifyChange(); delay(1000) }
            }
        }
        advertise(); rescan()
        timer = scope.launch {
            while (isActive) {
                delay(5000)
                if (incoming?.let { System.currentTimeMillis() - it.created > 120000 } == true) incoming = null
                if (prepared?.let { it.state !in setOf("playing", "starting") && System.currentTimeMillis() - it.created > 120000 } == true) cancelIncomingPlayback()
                try {
                    val remote = connection
                    if (remote == null) {
                        val preferred = settings.optJSONObject("preferred")?.text("deviceId")
                        val peer = peers[preferred] ?: peers.values.singleOrNull()
                        if (peer != null) connect(peer)
                    } else {
                        val status = request("status", JSONObject()); remote.automatic = status.optBoolean("autoSync")
                        if (!manual && !syncing && incoming == null && automatic && remote.automatic && local!!.text("deviceId") < remote.peer.text("deviceId") && status.text("hash") != store.lanDocument().hash(shared(remote))) synchronize(true)
                    }
                } catch (cancel: CancellationException) { throw cancel } catch (failure: Exception) { error = failure.message; notifyChange() }
            }
        }
        notifyChange()
    }
    private suspend fun stop() {
        poll?.cancel(); timer?.cancel(); cancelSync()
        cancelIncomingPlayback()
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }; discovery = null
        registration?.let { runCatching { nsd.unregisterService(it) } }; registration = null
        multicast?.let { if (it.isHeld) it.release() }; multicast = null
        if (generation.isNotEmpty()) runCatching { native("stop") }
        generation = ""; local = null; connection = null; incoming = null; peers.clear(); message = "设备互联已关闭"; notifyChange()
    }
    private fun advertise() {
        val info = local ?: return
        val service = NsdServiceInfo().apply {
            serviceName = "Zgj-${info.text("deviceId").take(12)}"; serviceType = "_zgj-link._tcp."; port = info.getInt("port")
            mapOf("id" to info.text("deviceId"), "name" to name, "pin" to info.text("pin"), "kind" to info.text("kind"), "v" to "1", "caps" to "sync,play").forEach { (k, v) -> setAttribute(k, v) }
        }
        registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(service: NsdServiceInfo) {}
            override fun onRegistrationFailed(service: NsdServiceInfo, code: Int) { error = "自动发现暂不可用，可使用本机地址手动连接"; notifyChange() }
            override fun onServiceUnregistered(service: NsdServiceInfo) {}
            override fun onUnregistrationFailed(service: NsdServiceInfo, code: Int) {}
        }.also { nsd.registerService(service, NsdManager.PROTOCOL_DNS_SD, it) }
    }
    fun rescan() {
        if (generation.isEmpty()) return
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        if (multicast == null) multicast = (repo.context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).createMulticastLock("RealDrama discovery").apply { setReferenceCounted(false); acquire() }
        val current = generation
        discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onStartDiscoveryFailed(type: String, code: Int) { error = "自动发现暂不可用，可使用本机地址手动连接"; notifyChange() }
            override fun onStopDiscoveryFailed(type: String, code: Int) {}
            override fun onServiceLost(info: NsdServiceInfo) { peers.entries.removeAll { it.value.text("service") == info.serviceName }; notifyChange() }
            override fun onServiceFound(info: NsdServiceInfo) {
                scope.launch { resolving.withLock {
                    if (current != generation) return@withLock
                    val resolved = CompletableDeferred<NsdServiceInfo?>()
                    nsd.resolveService(info, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(service: NsdServiceInfo, code: Int) { resolved.complete(null) }
                        override fun onServiceResolved(service: NsdServiceInfo) { resolved.complete(service) }
                    })
                    val service = withTimeoutOrNull(10000) { resolved.await() } ?: return@withLock
                    val host = service.host?.hostAddress ?: return@withLock
                    val address = if (host.contains(':')) "[$host]:${service.port}" else "$host:${service.port}"
                    try {
                        val peer = probe(address)
                        if (current == generation && peer.text("deviceId") != local?.text("deviceId")) { peers[peer.text("deviceId")] = peer.put("service", info.serviceName); notifyChange() }
                    } catch (_: Exception) { }
                } }
            }
        }.also { nsd.discoverServices("_zgj-link._tcp.", NsdManager.PROTOCOL_DNS_SD, it) }
    }
    private fun checkPeer(peer: JSONObject) {
        require(peer.text("deviceId").matches(Regex("[a-f0-9]{32}")) && peer.text("pin").matches(Regex("[a-f0-9]{64}")) && peer.optInt("port") in 1..65535 && peer.optInt("protocol") == 1 && peer.text("kind") in setOf("phone", "computer", "tv")) { "设备信息或协议版本无效" }
        val remembered = settings.optJSONObject("pins")?.text(peer.text("deviceId")).orEmpty()
        check(remembered.isEmpty() || remembered == peer.text("pin")) { "设备证书已变化，请核对设备后忘记旧配对再连接" }
    }
    suspend fun probe(address: String): JSONObject {
        require(address.length in 3..160)
        return native("probe", obj("address" to address)).also { checkPeer(it); it.put("address", address) }
    }
    private fun parseConnection(peer: JSONObject, address: String, body: JSONObject): LanConnection {
        require(body.text("token").matches(Regex("[a-f0-9]{64}")) && body.text("account").matches(Regex("[a-f0-9]{32}")))
        val sources = (body.optJSONArray("sourceOptions") ?: body.getJSONArray("sources")).strings()
        require(sources.size <= 32 && sources.all { it.matches(Regex("[a-z][a-z0-9-]{0,31}")) })
        return LanConnection(peer, address, body.text("token"), body.text("account"), body.text("user").take(80), sources.toSet(), body.optBoolean("autoSync"))
    }
    private suspend fun remember(remote: LanConnection) {
        check(epoch == store.epoch && enabled)
        val updated = settings
        val pins = updated.optJSONObject("pins") ?: JSONObject()
        pins.put(remote.peer.text("deviceId"), remote.peer.text("pin")); require(pins.length() <= 64)
        store.set("lanSettings", updated.put("pins", pins).put("preferred", remote.peer).put("remoteAccount", remote.account))
    }
    suspend fun connect(peer: JSONObject) = writes.withLock {
        checkPeer(peer); check(local != null && epoch == store.epoch)
        check(connection == null || connection!!.peer.text("deviceId") == peer.text("deviceId")) { "请先断开当前设备" }
        val grant = native("allow", obj("deviceId" to peer.text("deviceId"), "pin" to peer.text("pin")))
        val addresses = (listOf(peer.text("address")) + peer.array("addresses").strings()).filter { it.isNotEmpty() }.distinct().take(16)
        var failure: Exception? = null
        for (address in addresses) try {
            val body = JSONObject(canonical(local!!)).merge(peerConfig()).put("returnToken", grant.text("token"))
            if (settings.optJSONObject("preferred")?.text("deviceId") == peer.text("deviceId")) body.put("expectedAccount", settings.text("remoteAccount"))
            val response = native("request", obj("deviceId" to peer.text("deviceId"), "pin" to peer.text("pin"), "address" to address, "path" to "pair", "requestId" to randomToken(), "payload" to body))
            val remote = parseConnection(peer, address, response)
            remember(remote); connection = remote; message = "已连接，等待同步"; error = null; notifyChange(); return@withLock
        } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { failure = e }
        throw failure ?: IllegalStateException("未找到可连接的设备地址")
    }
    suspend fun disconnect(forget: Boolean = false) {
        val remote = connection
        cancelSync(); cancelIncomingPlayback(); native("disconnect"); connection = null; incoming = null
        if (forget && remote != null) { val next = settings; next.optJSONObject("pins")?.remove(remote.peer.text("deviceId")); next.remove("preferred"); next.remove("remoteAccount"); store.set("lanSettings", next) }
        message = "已断开连接"; notifyChange()
    }
    suspend fun forget(peer: JSONObject) {
        val id = peer.text("deviceId")
        if (connection?.peer?.text("deviceId") == id) { disconnect(true); return }
        val next = settings
        next.optJSONObject("pins")?.remove(id)
        if (next.optJSONObject("preferred")?.text("deviceId") == id) {
            next.remove("preferred")
            next.remove("remoteAccount")
        }
        store.set("lanSettings", next)
        notifyChange()
    }
    fun shared(remote: LanConnection) = repo.available().map { it.id }.toSet().intersect(remote.sources)
    suspend fun request(path: String, body: JSONObject): JSONObject {
        val remote = connection ?: error("请先连接设备")
        check(epoch == store.epoch && foreground && enabled)
        val id = randomToken(); requests.add(id)
        try {
            val result = native("request", obj("deviceId" to remote.peer.text("deviceId"), "pin" to remote.peer.text("pin"), "address" to remote.address, "token" to remote.token, "path" to path, "payload" to body, "requestId" to id))
            check(connection === remote && epoch == store.epoch && enabled)
            return result
        } finally { requests.remove(id) }
    }
    private suspend fun event(event: JSONObject, current: String) {
        var response = JSONObject(); var failure = ""
        try {
            check(current == generation && epoch == store.epoch && foreground && enabled)
            val path = event.getString("path"); val body = event.getJSONObject("payload")
            response = if (path == "pair") writes.withLock {
                checkPeer(body)
                check(body.text("deviceId") == event.text("peerId") && body.text("pin") == event.text("pin"))
                check(body.isNull("expectedAccount") || body.text("expectedAccount") == store.lanDocument().replica) { "对方切换了用户，请重新选择设备" }
                check(connection == null || connection!!.peer.text("deviceId") == body.text("deviceId")) { "接收设备已有其他连接" }
                val host = event.text("host"); val address = if (host.contains(':')) "[$host]:${body.getInt("port")}" else "$host:${body.getInt("port")}"
                val remote = parseConnection(body, address, JSONObject(canonical(body)).put("token", body.text("returnToken")))
                check(connection == null || connection!!.account == remote.account)
                val grant = native("allow", obj("deviceId" to body.text("deviceId"), "pin" to body.text("pin")))
                remember(remote); connection = remote; message = "已连接，等待同步"; notifyChange()
                peerConfig().put("token", grant.text("token"))
            } else {
                val remote = connection ?: error("请先连接此设备")
                check(remote.peer.text("deviceId") == event.text("peerId") && remote.peer.text("pin") == event.text("pin"))
                when {
                    path == "status" -> peerConfig().put("manual", manual).put("syncing", syncing || incoming != null).put("playing", playback?.drama?.title ?: "").put("hash", store.lanDocument().hash(shared(remote)))
                    path.startsWith("sync/") -> writes.withLock { receiveSync(path, body, remote) }
                    path.startsWith("play/") -> receivePlay(path, body, remote)
                    else -> error("不支持此设备操作")
                }
            }
        } catch (e: Exception) { failure = e.message ?: "设备操作失败" }
        if (current == generation) runCatching { native("respond", obj("eventId" to event.text("id"), "payload" to response, "error" to failure)) }
    }
    private fun receiveScope(body: JSONObject, remote: LanConnection): Set<String> {
        val sources = body.getJSONArray("sources").strings().toSet()
        require(sources.isNotEmpty() && sources.size <= 32 && shared(remote).containsAll(sources)) { "同步范围超出当前用户权限" }
        return sources
    }
    private suspend fun receiveSync(path: String, body: JSONObject, remote: LanConnection): JSONObject {
        val doc = store.lanDocument()
        if (path == "sync/summary") {
            val sources = receiveScope(body, remote); val base = doc.hash(sources)
            check(body.isNull("base") || body.text("base") == base)
            val rows = doc.records.values.filter { it.getJSONObject("drama").text("source") in sources }.sortedBy { it.getJSONObject("drama").text("id") }
            val offset = body.getInt("offset"); require(offset in 0..rows.size)
            val end = minOf(offset + 128, rows.size); val items = JSONObject()
            rows.subList(offset, end).forEach { items.put(it.getJSONObject("drama").text("id"), lanHash(it)) }
            return obj("base" to base, "items" to items, "next" to if (end < rows.size) end else null, "skipped" to doc.records.size - rows.size)
        }
        if (path == "sync/records") {
            val sources = receiveScope(body, remote); check(body.text("base") == doc.hash(sources))
            val ids = body.getJSONArray("ids").strings(); require(ids.size in 1..16 && ids.distinct().size == ids.size)
            val rows = JSONArray(); var bytes = 0
            for (id in ids) {
                val row = doc.records[id] ?: error("记录已变化")
                require(row.getJSONObject("drama").text("source") in sources)
                val size = canonical(row).toByteArray().size + 1; require(size <= 512 * 1024)
                if (rows.length() > 0 && bytes + size > 640 * 1024) break
                rows.put(row); bytes += size
            }
            return obj("records" to rows)
        }
        val operation = body.text("operation"); require(operation.matches(Regex("[a-f0-9]{32}")))
        val receipt = store.list("lanReceipts").objects().firstOrNull { it.text("operation") == operation }
        if (path == "sync/cancel") { if (incoming?.operation == operation) incoming = null; return obj("receipt" to receipt) }
        if (path == "sync/receipt" || receipt != null) return obj("receipt" to receipt)
        if (path == "sync/begin") {
            check(!syncing && !manual && (incoming == null || incoming!!.operation == operation)) { "正在处理另一次同步" }
            val sources = receiveScope(body, remote); val count = body.getInt("count")
            require(count in 1..25000 && body.text("finalHash").matches(Regex("[a-f0-9]{64}")))
            check(doc.hash(sources) == body.text("base") && (!body.optBoolean("automatic") || automatic))
            if (incoming == null) incoming = IncomingSync(operation, body.text("base"), body.text("finalHash"), sources, count, body.optBoolean("automatic"), remote)
            return obj("ready" to true)
        }
        val pending = incoming ?: error("接收批次已失效")
        check(pending.operation == operation && pending.remote === remote && (!pending.automatic || automatic) && System.currentTimeMillis() - pending.created <= 120000)
        if (path == "sync/chunk") {
            val rows = body.getJSONArray("records").objects(); val offset = body.getInt("offset")
            require(rows.size in 1..16 && rows.size == body.getJSONArray("records").length() && offset in 0..pending.rows.size)
            rows.forEach(::validateLanRecord)
            if (offset < pending.rows.size) {
                require(offset + rows.size <= pending.rows.size)
                rows.forEachIndexed { index, row -> require(canonical(pending.rows.values.elementAt(offset + index)) == canonical(row)) }
                return obj("received" to pending.rows.size)
            }
            require(rows.map { it.getJSONObject("drama").text("id") }.distinct().size == rows.size)
            rows.forEach { row -> val drama = row.getJSONObject("drama"); require(drama.text("source") in pending.sources && !pending.rows.containsKey(drama.text("id"))) }
            val size = canonical(body.getJSONArray("records")).toByteArray().size
            require(pending.bytes + size <= 12 * 1024 * 1024 && pending.rows.size + rows.size <= pending.count)
            rows.forEach { pending.rows[it.getJSONObject("drama").text("id")] = it }; pending.bytes += size
            return obj("received" to pending.rows.size)
        }
        if (path == "sync/commit") {
            check(pending.rows.size == pending.count && doc.hash(pending.sources) == pending.base && shared(remote).containsAll(pending.sources))
            pending.rows.forEach { (id, row) ->
                doc.records[id]?.let { old -> for (field in listOf("member", "status", "progress")) require(canonical(mergeCell(old.getJSONArray(field), row.getJSONArray(field))) == canonical(row.getJSONArray(field))) }
                doc.records[id] = row
            }
            check(doc.hash(pending.sources) == pending.hash)
            store.applyLanRecords(operation, pending.base, pending.sources, pending.rows.values.toList(), epoch) { connection === remote && incoming === pending && (!pending.automatic || automatic) }
            incoming = null; syncMessage = "本机已保存，等待双方同步完成"; notifyChange()
            return obj("receipt" to store.list("lanReceipts").objects().first { it.text("operation") == operation })
        }
        error("不支持此同步操作")
    }
    suspend fun preview(mode: String = "merge"): LanPreview {
        require(mode in setOf("merge", "push", "pull"))
        val remote = connection ?: error("请先连接设备"); val sessionEpoch = store.epoch
        val sources = shared(remote); require(sources.isNotEmpty())
        val doc = store.lanDocument(); val base = doc.hash(sources)
        val hashes = linkedMapOf<String, String>(); var remoteBase = ""; var offset = 0
        var remoteSkipped = 0
        do {
            val summary = request("sync/summary", obj("sources" to JSONArray(sources.toList()), "offset" to offset).apply { if (remoteBase.isNotEmpty()) put("base", remoteBase) })
            remoteSkipped = summary.optInt("skipped").coerceIn(0, 25000)
            val receivedBase = summary.getString("base"); require(receivedBase.matches(Regex("[a-f0-9]{64}")) && (remoteBase.isEmpty() || receivedBase == remoteBase)); remoteBase = receivedBase
            val page = summary.getJSONObject("items"); require(page.length() <= 128)
            page.keys().forEach { id -> require(!hashes.containsKey(id) && id.substringBefore(':') in sources && page.getString(id).matches(Regex("[a-f0-9]{64}"))); hashes[id] = page.getString(id) }
            require(hashes.size <= 25000)
            if (summary.isNull("next")) break
            val next = summary.getInt("next"); require(next == offset + page.length() && next > offset); offset = next
        } while (true)
        val local = doc.records.filterValues { it.getJSONObject("drama").text("source") in sources }
        val other = linkedMapOf<String, JSONObject>()
        val needed = hashes.keys.filter { local[it]?.let(::lanHash) != hashes[it] }.toMutableList()
        local.forEach { (id, row) -> if (hashes[id] == lanHash(row)) other[id] = row }
        while (needed.isNotEmpty()) {
            val ids = needed.take(16)
            val rows = request("sync/records", obj("base" to remoteBase, "sources" to JSONArray(sources.toList()), "ids" to JSONArray(ids))).getJSONArray("records").objects()
            require(rows.isNotEmpty() && rows.size <= ids.size)
            rows.forEachIndexed { i, row -> validateLanRecord(row); val id = row.getJSONObject("drama").text("id"); require(id == ids[i] && lanHash(row) == hashes[id]); other[id] = row }
            repeat(rows.size) { needed.removeAt(0) }
        }
        val result = linkedMapOf<String, JSONObject>()
        for (id in local.keys + other.keys) {
            val a = local[id]; val b = other[id]
            var row = if (a == null) b!! else if (b == null) a else mergeRecord(a, b)
            if (mode != "merge") {
                val authority = if (mode == "push") a else b
                val followed = authority?.getJSONArray("member")?.objects()?.all { it.getBoolean("value") } == true
                row = JSONObject(canonical(row)).apply {
                    put("drama", authority?.getJSONObject("drama") ?: getJSONObject("drama"))
                    put("member", doc.edit(getJSONArray("member"), followed))
                    for (field in listOf("status", "progress")) {
                        val cell = authority?.getJSONArray(field) ?: getJSONArray(field)
                        val value = if (field == "progress" && !followed) null else cell.objects().sortedBy(::canonical).first().opt("value")
                        put(field, doc.edit(getJSONArray(field), value))
                    }
                }
            }
            result[id] = row
        }
        require(result.size <= 25000 && result.values.count { it.getJSONArray("member").objects().all { c -> c.getBoolean("value") } } <= 20000)
        check(connection === remote && sessionEpoch == store.epoch && store.lanDocument().hash(sources) == base)
        return LanPreview(
            remote, sessionEpoch, sources, base, remoteBase, result,
            result.filter { (id, row) -> hashes[id] != lanHash(row) }.values.toList(),
            result.filter { (id, row) -> local[id]?.let(::lanHash) != lanHash(row) }.values.toList(),
            LanChangeCount.between(local, result), LanChangeCount.between(other, result), doc.records.size - local.size + remoteSkipped,
        )
    }
    suspend fun apply(preview: LanPreview, automatically: Boolean = false) {
        check(connection === preview.connection && epoch == preview.epoch && System.currentTimeMillis() - preview.created <= 120000 && store.lanDocument().hash(preview.sources) == preview.base)
        val final = store.lanDocument(); final.records.putAll(preview.result); val hash = final.hash(preview.sources)
        val operation = preview.operation
        var began = false; var commitRequested = false
        try {
            if (preview.remoteChanges.isNotEmpty()) {
                request("sync/begin", obj("operation" to operation, "base" to preview.remoteBase, "finalHash" to hash, "sources" to JSONArray(preview.sources.toList()), "count" to preview.remoteChanges.size, "automatic" to automatically)); began = true
                var offset = 0
                while (offset < preview.remoteChanges.size) {
                    val batch = mutableListOf<JSONObject>(); var bytes = 0
                    for (row in preview.remoteChanges.drop(offset).take(16)) { val size = canonical(row).toByteArray().size + 1; if (batch.isNotEmpty() && bytes + size > 640 * 1024) break; batch.add(row); bytes += size }
                    request("sync/chunk", obj("operation" to operation, "offset" to offset, "records" to JSONArray(batch))); offset += batch.size
                }
                check(store.lanDocument().hash(preview.sources) == preview.base)
                commitRequested = true
                val response = try { request("sync/commit", obj("operation" to operation)) } catch (failure: Exception) { request("sync/receipt", obj("operation" to operation)) }
                check(response.optJSONObject("receipt")?.text("hash") == hash) { "未能确认对方保存的版本，请重新同步" }
            }
            if (preview.localChanges.isNotEmpty()) store.applyLanRecords(operation, preview.base, preview.sources, preview.localChanges, preview.epoch) { connection === preview.connection && (!automatically || automatic && preview.connection.automatic) }
            syncMessage = "双方记录已同步"; lastSync = System.currentTimeMillis(); error = null
            runCatching { request("status", obj("synced" to operation, "hash" to hash)) }
        } finally {
            if (began && !commitRequested) withContext(NonCancellable) { runCatching { request("sync/cancel", obj("operation" to operation)) } }
            notifyChange()
        }
    }
    suspend fun synchronize(automatically: Boolean = false) {
        check(!syncing && incoming == null)
        syncing = true; syncMessage = "正在同步"; syncJob = currentCoroutineContext()[Job]; notifyChange()
        try { apply(preview(), automatically) } catch (cancel: CancellationException) { syncMessage = "同步已取消"; throw cancel } catch (failure: Exception) { syncMessage = "同步未完成"; error = failure.message; throw failure } finally { syncing = false; syncJob = null; notifyChange() }
    }
    suspend fun cancelSync() {
        syncJob?.cancel(); syncJob = null
        for (id in requests.toList()) runCatching { native("cancel", obj("requestId" to id)) }
        syncing = false; incoming = null; notifyChange()
    }
}
