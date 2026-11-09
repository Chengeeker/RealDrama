package com.real.drama.compose

import com.antonkarpenko.ffmpegkit.FFmpegKit
import com.antonkarpenko.ffmpegkit.FFprobeKit
import com.antonkarpenko.ffmpegkit.ReturnCode
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant

class MediaLibrary(private val repo: Repository) {
    val jobs = MutableStateFlow<List<JSONObject>>(emptyList())
    val status = MutableStateFlow("")
    val media = MutableStateFlow<List<JSONObject>>(emptyList())
    private var skipped = emptySet<String>()
    private var showFolders = JSONObject()
    private var specialNumbers = JSONObject()
    fun automaticSkipped(jobId: String) = jobId in skipped
    private val mutex = Mutex()
    private val processing = Mutex()
    private var root: File? = null
    private var worker: Job? = null
    private var session = 0L
    private val scope = (repo.context.applicationContext as DramaApplication).scope
    suspend fun open() = withContext(Dispatchers.IO) {
        root = File(NativeBridge.call(obj("action" to "downloadDirectory")).getString("directory"))
        val queue = File(root, "compose-merge-queue.json")
        if (!queue.exists()) {
            val old = File(root, "merge-queue.json")
            if (old.exists()) {
                require(old.length() <= 8 * 1024 * 1024)
                val data = JSONObject(old.readText()); require(data.optInt("schema") == 1)
                val downloads = NativeBridge.call(obj("action" to "downloads")).array("jobs").objects().associateBy { it.text("id") }
                jobs.value = data.getJSONArray("jobs").objects().map { row ->
                    val ids = row.getJSONArray("jobIds").strings(); require(ids.size in 2..10000)
                    val tasks = ids.mapNotNull { downloads[it] }
                    val available = tasks.size == ids.size && tasks.all { item ->
                        val saved = row.getJSONObject("versions").text(item.text("id"))
                        saved == version(item) || item.optLong("revision") == 0L && saved == "${version(item)}-0"
                    }
                    row.copy().put("jobs", JSONArray(tasks)).put("state", if (row.text("state") == "completed") "completed" else if (available) "paused" else "failed")
                        .put("error", if (available) "迁移后已暂停，可继续" else "原分集缺失或已重新下载，请重新选择合并")
                }
                require(jobs.value.size <= 500); saveQueue()
            }
        }
        if (queue.exists()) { require(queue.length() <= 8 * 1024 * 1024); jobs.value = JSONArray(queue.readText()).objects().map { if (it.text("state") == "running") it.put("state", "paused") else it } }
        val index = File(root, "compose-media.json")
        if (!index.exists()) {
            val old = File(root, "media-library.json")
            if (old.exists()) {
                require(old.length() <= 16 * 1024 * 1024)
                val data = JSONObject(old.readText())
                val rows = data.getJSONArray("items").objects()
                skipped = data.array("skipped").strings().toSet(); showFolders = data.optJSONObject("showFolders") ?: JSONObject(); specialNumbers = data.optJSONObject("specialNumbers") ?: JSONObject()
                require(rows.size <= 25000 && rows.map { it.text("id") }.distinct().size == rows.size)
                rows.forEach { inside(it.getString("file")); require(it.optDouble("duration").isFinite() && it.optLong("bytes") >= 0) }
                media.value = rows; saveMedia()
            }
        }
        if (index.exists()) {
            require(index.length() <= 16 * 1024 * 1024)
            val text = index.readText()
            if (text.trimStart().startsWith("[")) media.value = JSONArray(text).objects() else {
                val data = JSONObject(text); require(data.optInt("schema") == 1)
                media.value = data.getJSONArray("items").objects(); skipped = data.array("skipped").strings().toSet(); showFolders = data.optJSONObject("showFolders") ?: JSONObject(); specialNumbers = data.optJSONObject("specialNumbers") ?: JSONObject()
            }
            require(media.value.size <= 25000 && media.value.map { it.text("id") }.distinct().size == media.value.size)
            media.value.forEach { item -> val file = inside(item.getString("file")); val pending = File(file.path + ".removing"); if (!file.exists() && pending.exists()) check(pending.renameTo(file)) }
            showFolders.keys().forEach { id -> require(validShowFolder(showFolders.getString(id))); inside(showFolders.getString(id)) }
        }
    }
    private fun inside(relative: String): File {
        require(relative.isNotBlank() && !File(relative).isAbsolute)
        val base = requireNotNull(root).canonicalFile
        val file = File(base, relative).canonicalFile
        require(file.path.startsWith(base.path + File.separator)) { "媒体路径超出下载目录" }
        return file
    }
    private fun saveQueue() { atomicWrite(File(requireNotNull(root), "compose-merge-queue.json"), JSONArray(jobs.value).toString().toByteArray()) }
    private fun saveMedia() { atomicWrite(File(requireNotNull(root), "compose-media.json"), obj("schema" to 1, "items" to JSONArray(media.value), "skipped" to JSONArray(skipped.toList()), "showFolders" to showFolders, "specialNumbers" to specialNumbers).toString().toByteArray()) }
    suspend fun enqueue(selected: List<JSONObject>, cleanup: Boolean = false) = withContext(Dispatchers.IO) {
        check(repo.store.canDownload)
        val ordered = validateMerge(selected)
        if (root == null) open()
        val task = obj("id" to randomToken(), "owner" to repo.store.active, "drama" to ordered.first().getJSONObject("drama"),
            "jobs" to JSONArray(ordered), "state" to "queued", "error" to "", "cleanup" to cleanup, "created" to Instant.now().toString())
        mutex.withLock {
            val versions = ordered.associate { it.text("id") to version(it) }
            require(jobs.value.none { row -> row.text("owner") == repo.store.active && row.text("state") in setOf("queued", "running", "paused") && row.array("jobs").objects().associate { it.text("id") to version(it) } == versions }) { "这些分集已在合并队列中" }
            require(jobs.value.size < 500) { "合并队列已满，请移除已完成任务" }; val previous = jobs.value; jobs.value = jobs.value + task; try { saveQueue() } catch (e: Exception) { jobs.value = previous; throw e }
        }
        DownloadService.start(repo.context)
        start()
    }
    fun start() {
        if (worker?.isActive == true) return
        worker = scope.launch(Dispatchers.IO) {
            while (isActive) {
                val task = jobs.value.firstOrNull { it.text("state") == "queued" && it.text("owner") == repo.store.active } ?: break
                try { change(task.text("id"), "running"); processing.withLock {
                    withContext(NonCancellable) { NativeBridge.call(obj("action" to "workLease", "jobId" to "media", "command" to "start")) }
                    try {
                        val complete = media.value.firstOrNull { it.text("id") == "merged-${task.text("id")}" && it.optBoolean("decodeVerified") && fileFor(it).length() == it.optLong("bytes") }
                        if (complete == null) merge(task)
                    } finally { withContext(NonCancellable) { NativeBridge.call(obj("action" to "workLease", "jobId" to "media", "command" to "end")) } }
                    if (task.optBoolean("cleanup")) {
                        val remaining = repo.downloads().associateBy { it.text("id") }
                        val originals = task.array("jobs").objects().filter { original -> remaining[original.text("id")]?.let { live -> check(version(live) == version(original)) { "原分集已变更，请手动清理" }; true } == true }
                        originals.chunked(500).forEach { chunk -> val result = repo.controlDownloadBatch("remove", chunk); check(result.array("completed").length() == chunk.size) { "合并成品已保留，部分原分集未能删除，请手动清理" } }
                    }
                }; change(task.text("id"), "completed") }
                catch (cancel: CancellationException) { withContext(NonCancellable) { change(task.text("id"), "paused") }; throw cancel }
                catch (error: Exception) { change(task.text("id"), "failed", error.message ?: "处理失败") }
            }
            status.value = ""
        }
    }
    suspend fun change(id: String, state: String, error: String = "") = mutex.withLock {
        withContext(Dispatchers.IO) { val previous = jobs.value; jobs.value = previous.map { if (it.text("id") == id) it.copy().put("state", state).put("error", error) else it }; try { saveQueue() } catch (e: Exception) { jobs.value = previous; throw e } }
    }
    suspend fun pause() { if (session > 0) FFmpegKit.cancel(session); worker?.cancelAndJoin(); status.value = "" }
    suspend fun resume(id: String) { check(repo.store.canDownload); val task = jobs.value.first { it.text("id") == id }; check(task.text("owner") == repo.store.active && repo.store.allowed(task.getJSONObject("drama").text("source"))); DownloadService.start(repo.context); change(id, "queued"); start() }
    suspend fun control(id: String, command: String) {
        val task = jobs.value.first { it.text("id") == id }
        check(repo.store.canDownload && task.text("owner") == repo.store.active && repo.store.allowed(task.getJSONObject("drama").text("source")))
        require(command in setOf("pause", "resume", "cancel", "forget"))
        if (command == "resume") { resume(id); return }
        if (task.text("state") == "running") pause()
        when (command) { "pause" -> change(id, "paused"); "cancel" -> change(id, "cancelled"); "forget" -> { require(task.text("state") in setOf("completed", "cancelled")); removeTask(id) } }
        if (command in setOf("cancel", "forget")) withContext(Dispatchers.IO) { require(id.matches(Regex("[a-zA-Z0-9_-]{1,100}"))); val directory = inside(".merge-work/$id"); if (directory.exists()) check(directory.deleteRecursively()) { "任务已停止，但未能清理中间文件" } }
        start()
    }
    suspend fun removeTask(id: String) = mutex.withLock { withContext(Dispatchers.IO) { val task = jobs.value.first { it.text("id") == id }; check(task.text("owner") == repo.store.active && task.text("state") != "running"); val previous = jobs.value; jobs.value = previous.filterNot { it.text("id") == id }; try { saveQueue() } catch (e: Exception) { jobs.value = previous; throw e } } }
    private suspend fun ffmpeg(arguments: List<String>) = withContext(Dispatchers.IO) {
        ensureActive()
        val pending = CompletableDeferred<com.antonkarpenko.ffmpegkit.FFmpegSession>()
        val running = FFmpegKit.executeWithArgumentsAsync(arguments.toTypedArray(), { pending.complete(it) })
        session = running.sessionId
        try {
            val complete = pending.await()
            check(ReturnCode.isSuccess(complete.returnCode)) { "媒体处理失败，原分集和处理中间文件均保留" }
        } finally { if (!currentCoroutineContext().isActive) FFmpegKit.cancel(running.sessionId); session = 0 }
    }
    private suspend fun merge(task: JSONObject) {
        val epoch = repo.store.epoch
        val original = task.array("jobs").objects()
        val live = repo.downloads().associateBy { it.text("id") }
        original.forEach { item -> require(version(live[item.text("id")] ?: error("原分集已移除")) == version(item)) { "原分集已重新下载，请新建合并任务" } }
        val work = inside(".merge-work/${task.getString("id")}").apply { mkdirs() }
        val normalized = mutableListOf<File>()
        val probes = mutableListOf<MediaProbe>()
        var expectedDuration = 0.0
        for ((i, job) in original.withIndex()) {
            check(epoch == repo.store.epoch && repo.store.canDownload) { "用户已切换" }
            val plan = NativeBridge.call(obj("action" to "localPlayback", "drama" to job.getJSONObject("drama"), "index" to job.optInt("index")))
            require(plan.optBoolean("local") && plan.text("url").isNotEmpty()) { "分集未完成或文件不可用" }
            val output = File(work, "part-$i.mkv")
            status.value = "准备第 ${job.optInt("index")} 集 · ${i + 1}/${original.size}"
            if (!output.exists()) {
                val arguments = mutableListOf("-y", "-v", "error")
                if (plan.text("decryptionKey").isNotEmpty()) arguments.addAll(listOf("-decryption_key", plan.text("decryptionKey")))
                arguments.addAll(listOf("-allowed_extensions", "ALL", "-i", plan.getString("url"), "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-avoid_negative_ts", "make_zero", output.path + ".pending.mkv"))
                ffmpeg(arguments)
                check(File(output.path + ".pending.mkv").renameTo(output))
            }
            val probe = probe(output)
            expectedDuration += probe.duration
            probes.add(probe)
            normalized.add(output)
        }
        val strategy = MergePlan(probes)
        val fingerprint = sha256(canonical(JSONArray(probes.map { it.raw })).toByteArray())
        for (i in normalized.indices) {
            check(epoch == repo.store.epoch && repo.store.canDownload)
            val output = File(work, "normalized-$i-${fingerprint.take(16)}.${if (strategy.transport) "ts" else "mkv"}")
            if (!output.exists()) {
                val temporary = File(output.path + ".pending.${if (strategy.transport) "ts" else "mkv"}")
                status.value = if (strategy.videoChanges[i]) "统一第 ${original[i].optInt("index")} 集视频格式" else if (strategy.audioChanges[i]) "统一第 ${original[i].optInt("index")} 集音轨" else "保留第 ${original[i].optInt("index")} 集码流"
                ffmpeg(strategy.arguments(normalized[i].path, temporary.path, probes[i], i))
                val info = probe(temporary)
                require(kotlin.math.abs(info.duration - probes[i].duration) <= maxOf(3.0, probes[i].duration * .01)) { "分集规范化时长异常" }
                check(temporary.renameTo(output))
            }
            normalized[i] = output
        }
        val listing = File(work, "concat.txt")
        atomicWrite(listing, normalized.joinToString("\n") { "file '${it.path.replace("'", "'\\''")}'" }.toByteArray())
        val output = inside("merged/merged-${task.getString("id")}.mkv"); output.parentFile!!.mkdirs()
        val pending = File(output.path + ".pending.mkv")
        status.value = "合并分集"
        ffmpeg(listOf("-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", listing.path, "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", pending.path))
        status.value = "完整解码校验成品"
        ffmpeg(listOf("-v", "error", "-xerror", "-err_detect", "explode", "-i", pending.path, "-map", "0:v:0", "-map", "0:a:0?", "-f", "null", "-"))
        val duration = FFprobeKit.getMediaInformation(pending.path).mediaInformation?.duration?.toDoubleOrNull() ?: error("无法读取成品时长")
        require(kotlin.math.abs(duration - expectedDuration) <= maxOf(3.0, expectedDuration * .01)) { "合并时长与分集不一致，原文件保留" }
        check(epoch == repo.store.epoch && repo.store.canDownload)
        check(pending.renameTo(output)) { "无法保存合并文件" }
        val item = obj("id" to "merged-${task.getString("id")}", "drama" to task.getJSONObject("drama"), "file" to "merged/${output.name}", "kind" to "merged", "episodes" to JSONArray(original.map { it.optInt("index") }), "duration" to duration, "bytes" to output.length(), "created" to Instant.now().toString(), "decodeVerified" to true, "videoTranscodes" to strategy.videoChanges.count { it }, "audioTranscodes" to strategy.audioChanges.count { it })
        mutex.withLock { val previous = media.value; media.value = previous.filterNot { it.text("id") == item.text("id") } + item; try { saveMedia() } catch (e: Exception) { media.value = previous; throw e } }
    }
    private fun probe(file: File): MediaProbe {
        val result = FFprobeKit.executeWithArguments(arrayOf("-v", "error", "-hide_banner", "-print_format", "json", "-show_format", "-show_streams", "-show_data_hash", "sha256", "-protocol_whitelist", "file,crypto,data", "-i", file.path))
        check(ReturnCode.isSuccess(result.returnCode)) { "无法读取本地视频信息" }
        return MediaProbe(JSONObject(result.output))
    }
    suspend fun exportEpisode(job: JSONObject): File = processing.withLock { withContext(Dispatchers.IO) {
        check(repo.store.canDownload && repo.store.allowed(job.getJSONObject("drama").text("source")))
        if (root == null) open()
        require(job.text("state") == "completed")
        val existing = media.value.firstOrNull { it.text("jobId") == job.text("id") && (it.text("sourceVersion") == version(job) || job.optLong("revision") == 0L && it.text("sourceVersion") == "${version(job)}-0") && it.optBoolean("decodeVerified") }
        if (existing != null && fileFor(existing).isFile && fileFor(existing).length() == existing.optLong("bytes")) return@withContext fileFor(existing)
        DownloadService.start(repo.context)
        val epoch = repo.store.epoch
        withContext(NonCancellable) { NativeBridge.call(obj("action" to "workLease", "jobId" to "media", "command" to "start")) }
        try {
        status.value = "导出第 ${job.optInt("index")} 集"
        val drama = Drama(job.getJSONObject("drama")); val plan = NativeBridge.call(obj("action" to "localPlayback", "drama" to drama.json, "index" to job.optInt("index")))
        val folder = showDirectory(drama)
        val season = File(folder, "Season 01").apply { mkdirs() }
        val name = "S01E${job.optInt("index").toString().padStart(3, '0')}"
        val output = File(season, "$name.mkv"); val temp = File(season, "$name.pending.mkv")
        val args = mutableListOf("-y", "-v", "error")
        if (plan.text("decryptionKey").isNotEmpty()) args.addAll(listOf("-decryption_key", plan.text("decryptionKey")))
        args.addAll(listOf("-allowed_extensions", "ALL", "-i", plan.getString("url"), "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", temp.path))
        ffmpeg(args)
        ffmpeg(listOf("-v", "error", "-xerror", "-i", temp.path, "-f", "null", "-"))
        check(epoch == repo.store.epoch && repo.store.canDownload && repo.store.allowed(drama.source)) { "当前用户已变更，原文件保留" }
        val info = probe(temp)
        check(temp.renameTo(output))
        writeShowMetadata(drama, folder)
        atomicWrite(File(season, "$name.nfo"), ("<?xml version=\"1.0\" encoding=\"utf-8\"?><episodedetails><title>${xml(job.getJSONObject("chapter").text("title"))}</title><showtitle>${xml(drama.title)}</showtitle><season>1</season><episode>${job.optInt("index")}</episode><plot>${xml(drama.description)}</plot><uniqueid type=\"zhenguojian\" default=\"true\">${xml(job.text("id"))}</uniqueid></episodedetails>").toByteArray())
        val item = obj("id" to "export-${job.text("id")}", "drama" to drama.json, "file" to output.relativeTo(root!!).invariantSeparatorsPath, "kind" to "export", "episodes" to JSONArray().put(job.optInt("index")), "duration" to info.duration, "bytes" to output.length(), "created" to Instant.now().toString(), "jobId" to job.text("id"), "sourceVersion" to version(job), "decodeVerified" to true)
        mutex.withLock { val previous = media.value; val oldSkipped = skipped; media.value = previous.filterNot { it.text("id") == item.text("id") } + item; skipped = skipped - job.text("id"); try { saveMedia() } catch (e: Exception) { media.value = previous; skipped = oldSkipped; throw e } }
        output
        } finally { status.value = ""; withContext(NonCancellable) { NativeBridge.call(obj("action" to "workLease", "jobId" to "media", "command" to "end")) } }
    } }
    private suspend fun showDirectory(drama: Drama): File = mutex.withLock {
        val existing = showFolders.text(drama.id)
        if (existing.isNotEmpty()) { require(validShowFolder(existing)); return@withLock inside(existing).apply { mkdirs() } }
        val relative = "exports/${safeName(drama.title)} [${drama.source}-${sha256(drama.id.toByteArray()).take(12)}]"
        require(showFolders.keys().asSequence().none { showFolders.text(it) == relative }) { "导出目录与另一部剧冲突，请检查本地媒体记录" }
        showFolders.put(drama.id, relative)
        try { saveMedia() } catch (error: Exception) { showFolders.remove(drama.id); throw error }
        inside(relative).apply { mkdirs() }
    }
    private suspend fun writeShowMetadata(drama: Drama, folder: File) {
        val poster = File(folder, "poster.jpg")
        if (repo.store.bool("exportPosters", global = true) && !poster.exists()) try { val cover = repo.cover(drama); if (cover.isNotEmpty()) File(cover).copyTo(poster, overwrite = false) } catch (cancel: CancellationException) { throw cancel } catch (_: Exception) { }
        val cover = if (poster.exists()) "poster.jpg" else drama.cover.takeIf { it.startsWith("http://") || it.startsWith("https://") }.orEmpty()
        atomicWrite(File(folder, "tvshow.nfo"), ("<?xml version=\"1.0\" encoding=\"utf-8\"?><tvshow><title>${xml(drama.title)}</title><plot>${xml(drama.description)}</plot><uniqueid type=\"zhenguojian\" default=\"true\">${xml(drama.id)}</uniqueid>" + (if (cover.isNotEmpty()) "<thumb aspect=\"poster\">${xml(cover)}</thumb>" else "") + "<season>1</season><episode>${drama.json.optInt("episodes")}</episode></tvshow>").toByteArray())
    }
    suspend fun exportMerged(source: JSONObject) = processing.withLock { withContext(Dispatchers.IO) {
        val drama = Drama(source.getJSONObject("drama")); val epoch = repo.store.epoch
        check(repo.store.canDownload && repo.store.allowed(drama.source)); require(source.text("kind") == "merged" && source.array("episodes").length() > 0)
        val input = fileFor(source); require(input.isFile && input.length() == source.optLong("bytes")) { "合并成品缺失或不完整，请重新合并" }
        DownloadService.start(repo.context); withContext(NonCancellable) { NativeBridge.call(obj("action" to "workLease", "jobId" to "media", "command" to "start")) }
        try {
            status.value = "准备导出特别篇"
            val folder = showDirectory(drama); val key = "${drama.id}\u0000${source.text("id")}"; val prefix = "${drama.id}\u0000"
            val number = mutex.withLock {
                if (specialNumbers.has(key)) specialNumbers.getInt(key) else {
                    val number = (specialNumbers.keys().asSequence().filter { it.startsWith(prefix) }.maxOfOrNull { specialNumbers.getInt(it) } ?: 0) + 1
                    require(number <= 100000); specialNumbers.put(key, number)
                    try { saveMedia() } catch (e: Exception) { specialNumbers.remove(key); throw e }; number
                }
            }
            val season = File(folder, "Season 00").apply { mkdirs() }; val output = File(season, "S00E${number.toString().padStart(3, '0')}.mkv"); val temp = File(season, output.name + ".pending")
            input.inputStream().use { read -> temp.outputStream().use { write -> val buffer = ByteArray(256 * 1024); while (true) { ensureActive(); check(epoch == repo.store.epoch); val count = read.read(buffer); if (count < 0) break; write.write(buffer, 0, count) }; write.fd.sync() } }
            require(temp.length() == source.optLong("bytes")); val info = probe(temp); require(kotlin.math.abs(info.duration - source.optDouble("duration")) <= maxOf(3.0, info.duration * .01))
            ffmpeg(listOf("-v", "error", "-xerror", "-i", temp.path, "-f", "null", "-"))
            check(epoch == repo.store.epoch && repo.store.canDownload && repo.store.allowed(drama.source)); check(temp.renameTo(output))
            val item = source.copy().put("id", "special-${source.text("id")}").put("file", output.relativeTo(root!!).invariantSeparatorsPath).put("kind", "special").put("specialNumber", number).put("decodeVerified", true).put("created", Instant.now().toString()).put("sourceVersion", "${source.text("id")}-${source.optLong("bytes")}-${source.text("sourceVersion")}")
            val episodes = source.getJSONArray("episodes"); val first = episodes.getInt(0); val last = episodes.getInt(episodes.length() - 1)
            writeShowMetadata(drama, folder)
            atomicWrite(File(season, output.nameWithoutExtension + ".nfo"), ("<?xml version=\"1.0\" encoding=\"utf-8\"?><episodedetails><title>${xml(drama.title)} · 合并第 $first–$last 集</title><showtitle>${xml(drama.title)}</showtitle><season>0</season><episode>$number</episode><displayseason>1</displayseason><displayepisode>${last + 1}</displayepisode><plot>${xml("合并第 $first–$last 集，共 ${episodes.length()} 集。\n${drama.description}")}</plot><uniqueid type=\"zhenguojian\" default=\"true\">${xml(item.text("id"))}</uniqueid></episodedetails>").toByteArray())
            mutex.withLock { val previous = media.value; media.value = previous.filterNot { it.text("id") == item.text("id") } + item; try { saveMedia() } catch (e: Exception) { media.value = previous; throw e } }
        } finally { status.value = ""; withContext(NonCancellable) { NativeBridge.call(obj("action" to "workLease", "jobId" to "media", "command" to "end")) } }
    } }
    fun fileFor(item: JSONObject) = inside(item.getString("file"))
    suspend fun remove(item: JSONObject) = withContext(Dispatchers.IO) {
        check(repo.store.canDownload && repo.store.allowed(item.getJSONObject("drama").text("source")))
        val file = fileFor(item)
        mutex.withLock {
            val previous = media.value
            val pending = File(file.path + ".removing")
            require(!pending.exists()) { "此前删除尚未完成，请先恢复文件" }
            if (file.exists()) check(file.renameTo(pending)) { "文件未能删除，记录已保留" }
            val oldSkipped = skipped
            try { media.value = previous.filterNot { it.text("id") == item.text("id") }; if (item.text("jobId").isNotEmpty()) skipped = skipped + item.text("jobId"); saveMedia() }
            catch (error: Throwable) { media.value = previous; skipped = oldSkipped; if (pending.exists()) pending.renameTo(file); throw error }
            check(!pending.exists() || pending.delete()) { "媒体已移至待删除文件，下次清理时可重试" }
            val metadata = File(file.parentFile, file.nameWithoutExtension + ".nfo"); check(!metadata.exists() || metadata.delete()) { "视频已删除，元数据文件清理失败" }
        }
    }
    companion object {
        fun version(job: JSONObject) = "${job.optLong("created")}-${job.optLong("bytes")}-${job.optInt("actualQuality")}" + if (job.optLong("revision") > 0) "-${job.optLong("revision")}" else ""
        fun validateMerge(jobs: List<JSONObject>): List<JSONObject> {
            require(jobs.size in 2..10000 && jobs.all { it.text("state") == "completed" } && jobs.map { it.getJSONObject("drama").text("id") }.distinct().size == 1) { "请选择同一部剧至少两集已下载视频" }
            val sorted = jobs.sortedBy { it.optInt("index") }
            require(sorted.zipWithNext().all { (a, b) -> b.optInt("index") == a.optInt("index") + 1 }) { "分集不连续或重复，请补齐后合并" }
            return sorted
        }
        fun safeName(value: String): String { val clean = value.replace(Regex("[<>:\"/\\\\|?*\\x00-\\x1F]"), "_").trim().trimEnd('.', ' ').ifEmpty { "短剧" }; return String(clean.codePoints().limit(60).toArray(), 0, minOf(60, clean.codePointCount(0, clean.length))) }
        fun validShowFolder(value: String): Boolean { val parts = value.split('/', '\\'); return parts.size == 2 && parts[0] == "exports" && parts[1].isNotBlank() && parts[1] !in setOf(".", "..") && !parts[1].contains(':') }
        fun xml(value: String) = value.replace(Regex("[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F]"), "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&apos;")
    }
}
