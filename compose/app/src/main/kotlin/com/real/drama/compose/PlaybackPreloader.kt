package com.real.drama.compose

import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject

internal fun feedRetainedPlayers(ids: List<String>, current: Int, retained: Set<String>, warm: Boolean, lowMemory: Boolean): Set<String> {
    val selected = ids.getOrNull(current) ?: return emptySet()
    if (lowMemory) return setOf(selected)
    val nearby = ids.subList((current - 2).coerceAtLeast(0), (current + 3).coerceAtMost(ids.size)).toSet()
    return (retained + selected + listOfNotNull(ids.getOrNull(current + 1).takeIf { warm })).intersect(nearby)
}

internal const val feedLookahead = 5

internal fun feedUpcomingPreloads(upcoming: List<Drama>, currentIsDouyin: Boolean, isDouyin: (Drama) -> Boolean): List<Drama> =
    upcoming.take(if (currentIsDouyin) 1 else feedLookahead)
        .filterIndexed { index, drama -> index == 0 || !isDouyin(drama) }

internal fun feedResumeIndex(episodes: List<Episode>, watch: JSONObject?): Int {
    if (watch == null || watch.optDouble("duration") > 1 && watch.optDouble("position") >= watch.optDouble("duration") - 1) return 0
    return episodes.indexOfFirst { it.number == watch.optInt("episode") }.coerceAtLeast(0)
}

internal fun feedExcludedCategories(source: String, config: JSONObject): List<String> {
    if (source == "bilibili") return emptyList()
    val excluded = config.optJSONObject("excludedCategories") ?: JSONObject()
    val labels = excluded.keys().asSequence().map { excluded.text(it) }.toList()
    if (source != "hongguo") return labels
    val selected = config.optJSONObject("categories") ?: JSONObject()
    return labels + mapOf("short_play" to "真人剧", "comic_series" to "漫剧", "ai_series" to "AI剧")
        .filterKeys { !selected.has(it) }.values
}

private val feedCooldownPattern = Regex("已暂停约\\s*(\\d+)\\s*秒")
private val feedRateLimitPattern = Regex("HTTP\\s*429|抖音接口请求较频繁|抖音接口已限流")
internal fun feedRetrySeconds(message: String, douyin: Boolean): Int? {
    if (!douyin) return null
    val cooldown = feedCooldownPattern.find(message)
    if (cooldown == null && !feedRateLimitPattern.containsMatchIn(message)) return null
    return (cooldown?.groupValues?.get(1)?.toIntOrNull() ?: 60).coerceIn(1, 1800)
}

class PlaybackPreloader(private val repo: Repository, private val scope: CoroutineScope) {
    private var identity = ""
    private var job: Job? = null
    private var ready: JSONObject? = null
    private var expires = 0L
    private var retryAt = 0L
    val status = MutableStateFlow("播放后段提前准备下一集")
    private fun key(drama: Drama, episode: Episode, quality: Int) = "${repo.store.epoch}:${drama.id}:${episode.id}:$quality"
    fun prepare(drama: Drama, episode: Episode, quality: Int) {
        val id = key(drama, episode, quality)
        if (identity != id) { clear(); identity = id }
        if (ready != null && System.currentTimeMillis() >= expires) { release(ready); ready = null }
        if (ready != null || job?.isActive == true || System.currentTimeMillis() < retryAt) return
        job = scope.launch {
            var plan: JSONObject? = null
            try {
                status.value = "正在准备下一集"; delay(600)
                plan = repo.resolve(drama, episode, quality)
                plan = repo.warmPlayback(plan, quality)
                ensureActive()
                check(identity == id)
                expires = minOf(System.currentTimeMillis() + 120000, plan.optLong("expiresAt").takeIf { it > 0 }?.minus(5000) ?: Long.MAX_VALUE)
                check(expires > System.currentTimeMillis()) { "下一集播放凭证即将过期" }
                ready = plan; plan = null
                status.value = if (ready!!.optBoolean("local")) "下一集已下载" else if (ready!!.optLong("prefetchedBytes") > 0) "下一集已准备 · 预取 ${(ready!!.optLong("prefetchedBytes") + 1023) / 1024} KB" else "下一集播放地址已准备"
            } catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) { retryAt = System.currentTimeMillis() + 30000; status.value = "下一集预加载暂不可用，切集时会重新获取" }
            finally { withContext(NonCancellable) { repo.release(plan) } }
        }
    }
    fun take(drama: Drama, episode: Episode, quality: Int): JSONObject? {
        val result = ready?.takeIf { identity == key(drama, episode, quality) && System.currentTimeMillis() < expires }
        if (result != null) ready = null
        clear()
        return result
    }
    fun pause() { job?.cancel(); job = null }
    fun clear() { pause(); release(ready); ready = null; identity = ""; retryAt = 0; status.value = "播放后段提前准备下一集" }
    private fun release(plan: JSONObject?) { if (plan != null) (repo.context.applicationContext as DramaApplication).scope.launch { repo.release(plan) } }
}

internal class FeedPlaybackPreparation(private val repo: Repository, private val scope: CoroutineScope) {
    private class Preparation(val episode: Int, val quality: Int, val epoch: Long) {
        val resolved = CompletableDeferred<Unit>()
        lateinit var task: Job
        var plan: JSONObject? = null
        var expires = 0L
        var taken = false
        val finished = MutableStateFlow(false)
    }
    private val details = mutableMapOf<String, Deferred<Result<Detail>>>()
    private val prepared = mutableMapOf<String, Preparation>()
    private val mediaRead = Mutex()
    private var targets = emptySet<String>()

    fun detail(drama: Drama): Deferred<Result<Detail>> = details.getOrPut(drama.id) {
        scope.async {
            try { Result.success(repo.detail(drama)) }
            catch (cancel: CancellationException) { throw cancel }
            catch (error: Exception) { Result.failure(error) }
        }
    }

    fun retain(detailIds: Set<String>, planIds: Set<String>) {
        targets = planIds
        details.keys.filterNot(detailIds::contains).forEach { details.remove(it)?.cancel() }
        prepared.keys.filterNot(planIds::contains).forEach { discard(it) }
    }

    fun prepare(drama: Drama, episode: Episode, quality: Int, needsPrefix: () -> Boolean = { true }): Job? {
        val epoch = repo.store.epoch
        if (drama.id !in targets) return null
        matching(drama, episode, quality)?.let { return it.task }
        discard(drama.id)
        val entry = Preparation(episode.number, quality, epoch)
        prepared[drama.id] = entry
        entry.task = scope.launch(start = CoroutineStart.LAZY) {
            try {
                val plan = repo.resolve(drama, episode, quality)
                entry.plan = plan
                ensureActive()
                val now = System.currentTimeMillis()
                entry.expires = minOf(now + 120000, plan.optLong("expiresAt").takeIf { it > 0 }?.minus(5000) ?: Long.MAX_VALUE)
                check(entry.expires > now && repo.store.epoch == epoch)
                entry.resolved.complete(Unit)
                mediaRead.withLock {
                    if (!entry.taken && needsPrefix() && (repo.source(drama.source)?.group != "douyin" || !repo.runtime.douyinCoolingDown)) {
                        val warmed = repo.warmPlayback(plan, quality)
                        if (!entry.taken) entry.plan = warmed
                    }
                }
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (_: Exception) {
                if (!entry.resolved.isCompleted && prepared[drama.id] === entry) discard(drama.id)
            } finally {
                entry.finished.value = true
                entry.resolved.complete(Unit)
            }
        }
        entry.task.start()
        return entry.task
    }

    suspend fun warm(drama: Drama, episode: Episode, quality: Int): Boolean {
        prepare(drama, episode, quality)?.join()
        return matching(drama, episode, quality)?.plan != null
    }

    suspend fun take(drama: Drama, episode: Episode, quality: Int, canOpen: () -> Boolean = { true }): JSONObject? {
        val entry = matching(drama, episode, quality) ?: return null
        entry.resolved.await()
        if (!canOpen() && !entry.finished.value) {
            entry.finished.combine(snapshotFlow { canOpen() }) { finished, open -> finished || open }.first { it }
        }
        if (matching(drama, episode, quality) !== entry) return null
        val plan = entry.plan ?: return null
        entry.taken = true
        prepared.remove(drama.id)
        entry.task.cancel()
        return plan
    }

    private fun matching(drama: Drama, episode: Episode, quality: Int) = prepared[drama.id]?.takeIf {
        it.episode == episode.number && it.quality == quality && it.epoch == repo.store.epoch &&
            (!it.resolved.isCompleted || it.expires > System.currentTimeMillis())
    }

    private fun discard(id: String) {
        val entry = prepared.remove(id) ?: return
        entry.task.cancel()
        entry.finished.value = true
        entry.resolved.complete(Unit)
        release(entry.plan)
    }

    private fun release(plan: JSONObject?) {
        if (plan == null) return
        (repo.context.applicationContext as DramaApplication).scope.launch { runCatching { repo.release(plan) } }
    }
}
