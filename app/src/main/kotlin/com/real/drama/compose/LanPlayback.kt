package com.real.drama.compose

import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject

data class LanPlaybackHost(val identity: Any, val drama: Drama, val episode: Episode, val snapshot: () -> PlaybackState, val stop: suspend () -> Unit) {
    fun intent() = obj("drama" to compactLanDrama(drama.json), "episodeId" to episode.id, "episode" to episode.number, "position" to snapshot().position, "playing" to true)
}
class LanPreparedPlayback(val id: String, val intent: JSONObject, val remote: LanConnection, val previous: Any?, val epoch: Long) {
    val created = System.currentTimeMillis()
    var state = "preparing"
    var message = ""
    var detail: Detail? = null
    var index = 0
    var plan: JSONObject? = null
    var position = intent.optDouble("position")
    var consumed = false
    var firstPosition: Double? = null
    var cancelled = false
    var stop: (suspend () -> Unit)? = null
    var job: Job? = null
    val started = CompletableDeferred<Double>()
    val identity get() = lanHash(JSONArray().put(intent.getJSONObject("drama").text("id")).put(intent.text("episodeId")).put(intent.getInt("episode")))
    fun result() = obj("id" to id, "state" to state, "message" to message, "replacing" to "", "position" to if (state == "playing") position else null)
}
suspend fun LanController.cancelIncomingPlayback(id: String? = null) {
    val pending = prepared ?: return
    if (id != null && pending.id != id) return
    if (pending.state == "playing" && id == null) { prepared = null; return }
    pending.cancelled = true; pending.job?.cancel(); pending.stop?.invoke()
    if (!pending.consumed) repo.release(pending.plan)
    pending.plan = null; pending.state = "cancelled"; pending.started.cancel()
    playReceipts[pending.id] = pending.result()
    while (playReceipts.size > 32) playReceipts.remove(playReceipts.keys.first())
    if (prepared === pending) prepared = null
}
suspend fun LanController.receivePlay(path: String, body: JSONObject, remote: LanConnection): JSONObject {
    val id = body.getString("id"); require(id.matches(Regex("[a-f0-9]{32}")))
    if (path == "play/cancel") {
        if (prepared?.remote === remote) cancelIncomingPlayback(id)
        val receipt = playReceipts.getOrPut(id) { obj("id" to id, "state" to "cancelled") }
        while (playReceipts.size > 32) playReceipts.remove(playReceipts.keys.first())
        return receipt
    }
    val pending = prepared
    if (pending?.id != id) playReceipts[id]?.let { return it }
    if (path == "play/prepare") {
        val intent = body.getJSONObject("intent"); validateLanDrama(intent.getJSONObject("drama"))
        require(intent.opt("episodeId") is String && intent.text("episodeId").length <= 1024 && integral(intent.opt("episode")) && intent.optInt("episode") in 1..1000000 && intent.opt("position") is Number && intent.optDouble("position") in 0.0..604800.0 && intent.opt("playing") is Boolean)
        val drama = Drama(intent.getJSONObject("drama"))
        check(store.allowed(drama.source) && drama.source in remote.sources && intent.getBoolean("playing") && receivePlayback != null)
        if (pending?.id == id) { check(pending.remote === remote && canonical(pending.intent) == canonical(intent)); return pending.result() }
        check(pending == null || pending.state !in setOf("preparing", "prepared", "starting")) { "正在处理另一次推送" }
        val next = LanPreparedPlayback(id, intent, remote, playback?.identity, store.epoch)
        prepared = next
        next.job = scope.launch {
            try {
                var localPlan: JSONObject? = null
                val downloaded = if (store.canDownload) repo.downloads().filter { it.text("state") == "completed" && it.getJSONObject("drama").text("id") == drama.id }.sortedBy { it.optInt("index") } else emptyList()
                val selected = downloaded.firstOrNull { it.optInt("index") == intent.getInt("episode") && (intent.text("episodeId").isEmpty() || it.getJSONObject("chapter").text("id") == intent.text("episodeId")) }
                if (selected != null) try {
                    localPlan = NativeBridge.call(obj("action" to "localPlayback", "drama" to selected.getJSONObject("drama"), "index" to selected.getInt("index"))).takeIf { it.text("url").isNotEmpty() }
                } catch (failure: NativeFailure) { if (failure.code != "local_media") throw failure }
                val detail = if (localPlan != null) Detail(Drama(selected!!.getJSONObject("drama")), downloaded.map { Episode(it.getJSONObject("chapter"), it.getInt("index")) }, "当前仅列出接收设备已下载的分集") else repo.detail(drama)
                val index = detail.episodes.indexOfFirst { it.number == intent.getInt("episode") && (intent.text("episodeId").isEmpty() || it.id == intent.text("episodeId")) }
                check(index >= 0 && detail.drama.id == drama.id) { "接收端没有相同分集" }
                val plan = localPlan ?: repo.resolve(detail.drama, detail.episodes[index], store.json("playback").optInt("quality"))
                if (next.cancelled || prepared !== next || connection !== remote || store.epoch != next.epoch) { repo.release(plan); return@launch }
                next.detail = detail; next.index = index; next.plan = plan; next.state = "prepared"
            } catch (cancel: CancellationException) { throw cancel }
            catch (failure: Exception) { next.state = "failed"; next.message = failure.message ?: "准备播放失败" }
            notifyChange()
        }
        return next.result()
    }
    check(pending != null && pending.id == id && pending.remote === remote && !pending.cancelled && pending.epoch == store.epoch) { "播放准备已过期" }
    if (path == "play/status") return pending.result()
    if (path == "play/start") {
        if (pending.state != "prepared") return pending.result()
        check(playback?.identity === pending.previous) { "接收端播放内容已变化，请重新推送" }
        require(body.optDouble("position") in 0.0..604800.0 && body.text("identity") == pending.identity)
        pending.position = body.getDouble("position"); pending.state = "starting"
        pending.job = scope.launch {
            try {
                receivePlayback?.invoke(pending) ?: error("接收端暂不能开始播放")
                val position = withTimeout(40000) { pending.started.await() }
                check(!pending.cancelled && pending.epoch == store.epoch && prepared === pending)
                pending.position = position; pending.state = "playing"
            } catch (cancel: CancellationException) { throw cancel }
            catch (failure: Exception) {
                pending.stop?.invoke()
                if (!pending.consumed) repo.release(pending.plan)
                pending.state = "failed"; pending.message = failure.message ?: "接收端未确认开播"
            }
            playReceipts[id] = pending.result()
            while (playReceipts.size > 32) playReceipts.remove(playReceipts.keys.first())
            notifyChange()
        }
        return pending.result()
    }
    error("不支持此播放交接操作")
}
suspend fun LanController.sendPlayback(host: LanPlaybackHost, move: Boolean) {
    check(playback?.identity === host.identity && connection != null)
    val id = randomToken(); val intent = host.intent()
    val identity = lanHash(JSONArray().put(host.drama.id).put(host.episode.id).put(host.episode.number))
    var accepted = false
    try {
        var result = request("play/prepare", obj("id" to id, "intent" to intent))
        withTimeout(120000) {
            while (result.text("state") == "preparing") { delay(500); result = request("play/status", obj("id" to id)) }
        }
        check(result.text("state") == "prepared") { result.text("message", "接收端未准备好") }
        check(playback?.identity === host.identity) { "本机分集已变化，请重新推送" }
        result = request("play/start", obj("id" to id, "identity" to identity, "position" to host.snapshot().position))
        withTimeout(30000) {
            while (result.text("state") in setOf("prepared", "starting")) { delay(400); result = request("play/status", obj("id" to id)) }
        }
        check(result.text("state") == "playing") { result.text("message", "对方尚未确认播放，本机继续播放") }
        accepted = true
        if (move && playback?.identity === host.identity) host.stop()
    } finally { if (!accepted) withContext(NonCancellable) { runCatching { request("play/cancel", obj("id" to id)) } } }
}
