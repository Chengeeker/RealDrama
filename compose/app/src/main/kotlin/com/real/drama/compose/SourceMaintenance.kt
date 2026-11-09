package com.real.drama.compose

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

class SourceMaintenance(private val repo: Repository) {
    val states = MutableStateFlow<Map<String, JSONObject>>(emptyMap())
    private val jobs = mutableMapOf<String, Job>()
    private val scope = (repo.context.applicationContext as DramaApplication).scope
    fun cancelAll() { jobs.values.forEach { it.cancel() }; jobs.clear(); states.value = emptyMap() }
    fun stop(source: String) { jobs[source]?.cancel() }
    fun running(source: String) = jobs[source]?.isActive == true
    private fun change(source: String, vararg fields: Pair<String, Any?>) { states.value = states.value + (source to (states.value[source]?.copy() ?: JSONObject()).merge(obj(*fields))) }
    suspend fun refresh(source: String) {
        val cache = repo.cached(source)
        change(source, "count" to cache?.items?.size, "page" to cache?.page, "hasMore" to (cache?.more ?: true), "unknownVip" to cache?.items?.count { it.json.isNull("vip") })
    }
    fun start(source: String, operation: String) {
        require(operation in setOf("update", "more", "allPages", "metadata", "vipMetadata", "retrySave", "check", "checkCatalog"))
        if (running(source)) return
        val epoch = repo.store.epoch
        check(repo.store.allowed(source))
        val current = scope.launch {
            change(source, "running" to true, "operation" to operation, "stage" to if (operation == "check") "正在检测连接" else "正在同步内容", "startedAt" to Instant.now().toString(), "error" to "")
            try {
                refresh(source)
                val cache = repo.cached(source) ?: Catalog(emptyList(), true, 0)
                when (operation) {
                    "retrySave" -> { repo.saveCatalog(source, "", cache); change(source, "stage" to "已保存") }
                    "metadata", "vipMetadata" -> {
                        val entries = cache.items.take(20); var current = cache
                        change(source, "total" to entries.size, "completed" to 0)
                        entries.forEachIndexed { index, drama ->
                            ensureActive(); check(epoch == repo.store.epoch && repo.store.allowed(source))
                            val fresh = repo.detail(drama, true).drama
                            current = current.copy(items = current.items.map { if (it.id == fresh.id) mergeDramaMetadata(it, fresh) else it })
                            change(source, "completed" to index + 1); delay(500)
                        }
                        repo.saveCatalog(source, "", current); change(source, "stage" to "本次已补齐最多20部资料")
                    }
                    "check", "checkCatalog" -> {
                        val data = repo.runtime.execute(source, "catalog", obj("page" to 1, "category" to ""))
                        val sample = Catalog.parse(data).items.firstOrNull() ?: error("没有可检测条目")
                        val steps = JSONArray().put(obj("name" to "目录", "state" to "ok", "message" to "目录返回正常"))
                        if (operation == "check") {
                            if (repo.source(source)?.kind == "live") {
                                val live = repo.runtime.execute(source, "live", obj("drama" to sample.json)); require(live.getJSONObject("plan").text("url").isNotBlank()) { "未返回媒体地址" }
                            } else {
                                val detail = repo.detail(sample, true); val episode = detail.episodes.firstOrNull() ?: error("未返回分集")
                                val media = repo.resolve(detail.drama, episode, online = true); repo.release(media)
                            }
                            steps.put(obj("name" to "播放解析", "state" to "ok", "message" to "取得媒体地址，尚未实际播放"))
                        }
                        change(source, "health" to obj("checkedAt" to Instant.now().toString(), "state" to if (operation == "check") "resolved" else "catalogOnly", "sample" to sample.title, "steps" to steps), "stage" to "已完成")
                    }
                    else -> {
                        var page = if (operation in setOf("more", "allPages") && cache.items.isNotEmpty()) cache.page + 1 else 1
                        val end = System.currentTimeMillis() + 600000
                        do {
                            ensureActive(); check(epoch == repo.store.epoch && repo.store.allowed(source))
                            val result = repo.catalog(source, page)
                            refresh(source)
                            change(source, "completed" to page, "stage" to "已完成", "updatedAt" to Instant.now().toString(), "added" to ((repo.cached(source)?.items?.size ?: 0) - cache.items.size).coerceAtLeast(0))
                            if (operation != "allPages" || !result.more || page >= 100 || (repo.cached(source)?.items?.size ?: 0) >= 5000 || System.currentTimeMillis() >= end) {
                                if (operation == "allPages" && result.more) change(source, "stage" to "本批加载已结束，剩余页可继续加载")
                                break
                            }
                            page++; delay(1200)
                        } while (true)
                    }
                }
            } catch (cancel: CancellationException) { if (epoch == repo.store.epoch) change(source, "stage" to "已停止"); throw cancel }
            catch (error: Exception) {
                if (epoch == repo.store.epoch) {
                    change(source, "stage" to "未完成", "error" to (error.message ?: "站源请求失败，请检查网络或更新站源"))
                    if (operation in setOf("check", "checkCatalog")) change(source, "health" to obj("state" to "failed", "checkedAt" to Instant.now().toString(), "steps" to JSONArray().put(obj("name" to "检测", "state" to "failed", "message" to "请求失败，请检查网络或更新站源"))))
                }
            } finally { if (epoch == repo.store.epoch) change(source, "running" to false, "finishedAt" to Instant.now().toString()) }
        }
        jobs[source] = current
    }
}
